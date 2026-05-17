# =====================================================================
#  Nginx WAF Hardened — Multi-stage build
#  - Stage 1 (fetcher):  Résout les dernières versions stables
#  - Stage 2 (builder):  Compile Nginx + ModSecurity + modules
#  - Stage 3 (production): Runtime minimal Alpine
#
#  Auto-versioning: si NGINX_VER/MODSEC_VER/OWASP_CRS_VER ne sont pas
#  fournis en build-arg, le fetcher interroge les APIs upstream.
#
#  Proxy-aware: passe http_proxy/https_proxy via les predefined ARGs
#  BuildKit (non baked dans l'image finale).
# =====================================================================
# hadolint global ignore=DL3018

# ---------------------------------------------------------------------------
# Stage 0: fetcher — résout les dernières versions stables
# ---------------------------------------------------------------------------
FROM alpine:3.21 AS fetcher

RUN apk add --no-cache curl jq grep

ARG NGINX_VER=""
ARG MODSEC_VER=""
ARG OWASP_CRS_VER=""

# hadolint ignore=SC2015
RUN set -eux; \
    if [ -z "$NGINX_VER" ]; then \
      NGINX_VER=$(curl -fsSL https://nginx.org/en/download.html \
        | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+' | head -1); \
    fi; \
    echo "$NGINX_VER" > /tmp/NGINX_VER; \
    if [ -z "$MODSEC_VER" ]; then \
      MODSEC_VER=$(curl -fsSL https://api.github.com/repos/owasp-modsecurity/ModSecurity/releases/latest \
        | jq -r '.tag_name' | sed 's/^v//'); \
    fi; \
    echo "$MODSEC_VER" > /tmp/MODSEC_VER; \
    if [ -z "$OWASP_CRS_VER" ]; then \
      OWASP_CRS_VER=$(curl -fsSL https://api.github.com/repos/coreruleset/coreruleset/releases/latest \
        | jq -r '.tag_name' | sed 's/^v//'); \
    fi; \
    echo "$OWASP_CRS_VER" > /tmp/OWASP_CRS_VER; \
    echo "=== Resolved: Nginx=$NGINX_VER ModSec=$MODSEC_VER CRS=$OWASP_CRS_VER ==="

# ---------------------------------------------------------------------------
# Stage 1: builder — compile tout from source
# ---------------------------------------------------------------------------
FROM alpine:3.21 AS builder

# Trust homelab CA if provided (for builds behind SSL-bumping proxy)
RUN --mount=type=secret,id=ca-certs,target=/tmp/ca-bundle.crt,required=false \
    if [ -f /tmp/ca-bundle.crt ]; then \
      cat /tmp/ca-bundle.crt >> /etc/ssl/certs/ca-certificates.crt; \
    fi

COPY --from=fetcher /tmp/NGINX_VER /tmp/MODSEC_VER /tmp/OWASP_CRS_VER /tmp/

RUN echo "export NGINX_VER=$(cat /tmp/NGINX_VER)" >> /etc/profile.d/ver.sh && \
    echo "export MODSEC_VER=$(cat /tmp/MODSEC_VER)" >> /etc/profile.d/ver.sh && \
    echo "export OWASP_CRS_VER=$(cat /tmp/OWASP_CRS_VER)" >> /etc/profile.d/ver.sh && \
    chmod +x /etc/profile.d/ver.sh

# Build deps — split into multiple RUN to stay within proxy timeouts
RUN apk add --no-cache \
    autoconf automake byacc curl curl-dev flex g++ gcc geoip-dev git \
    gnupg libc-dev libmaxminddb-dev libstdc++ libtool libxml2-dev \
    linux-headers lmdb-dev make openssl-dev pcre2-dev yajl-dev zlib-dev

WORKDIR /opt

# --- ModSecurity v3 ---
RUN . /etc/profile.d/ver.sh && \
    git clone -b "v${MODSEC_VER}" --depth 1 \
      https://github.com/owasp-modsecurity/ModSecurity.git && \
    cd ModSecurity && \
    git submodule update --init --recursive && \
    ./build.sh && \
    ./configure --with-lmdb --with-pcre2 && \
    make -j"$(nproc)" && \
    make install && \
    cd /opt && rm -rf ModSecurity

# --- Nginx modules sources ---
RUN git clone -b master --depth 1 https://github.com/owasp-modsecurity/ModSecurity-nginx.git && \
    git clone -b master --depth 1 https://github.com/leev/ngx_http_geoip2_module.git && \
    git clone -b master --depth 1 https://github.com/vozlt/nginx-module-vts.git && \
    git clone -b master --depth 1 https://github.com/openresty/headers-more-nginx-module.git

# --- OWASP CRS ---
RUN . /etc/profile.d/ver.sh && \
    git clone -b "v${OWASP_CRS_VER}" --depth 1 \
      https://github.com/coreruleset/coreruleset.git /usr/local/owasp-modsecurity-crs && \
    rm -rf /usr/local/owasp-modsecurity-crs/.git \
           /usr/local/owasp-modsecurity-crs/.github \
           /usr/local/owasp-modsecurity-crs/tests \
           /usr/local/owasp-modsecurity-crs/docs && \
    if [ -f /usr/local/owasp-modsecurity-crs/crs-setup.conf.example ] && \
       [ ! -f /usr/local/owasp-modsecurity-crs/crs-setup.conf ]; then \
      cp /usr/local/owasp-modsecurity-crs/crs-setup.conf.example \
         /usr/local/owasp-modsecurity-crs/crs-setup.conf; \
    fi

# --- Download + GPG verify + compile Nginx ---
ARG GPG_KEYS=B0F4253373F8F6F510D42178520A9993A1C052F8

RUN . /etc/profile.d/ver.sh && \
    curl -fsSL "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz" -o /tmp/nginx.tar.gz && \
    curl -fsSL "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz.asc" -o /tmp/nginx.tar.gz.asc && \
    export GNUPGHOME="$(mktemp -d)" && \
    for server in hkps://keys.openpgp.org hkps://keyserver.ubuntu.com:443; do \
      gpg --keyserver "$server" --recv-keys "$GPG_KEYS" && break || true; \
    done && \
    gpg --batch --verify /tmp/nginx.tar.gz.asc /tmp/nginx.tar.gz && \
    rm -rf "$GNUPGHOME" /tmp/nginx.tar.gz.asc && \
    tar -xzC /usr/src -f /tmp/nginx.tar.gz && rm /tmp/nginx.tar.gz

# Compile Nginx with hardening flags
# hadolint ignore=SC2086
RUN . /etc/profile.d/ver.sh && \
    cd "/usr/src/nginx-${NGINX_VER}" && \
    ./configure \
      --prefix=/etc/nginx \
      --sbin-path=/usr/sbin/nginx \
      --modules-path=/usr/lib/nginx/modules \
      --conf-path=/etc/nginx/nginx.conf \
      --error-log-path=/var/log/nginx/error.log \
      --http-log-path=/var/log/nginx/access.log \
      --pid-path=/var/run/nginx/nginx.pid \
      --lock-path=/var/run/nginx/nginx.lock \
      --http-client-body-temp-path=/var/cache/nginx/client_temp \
      --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
      --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
      --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
      --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
      --user=nginx --group=nginx \
      --with-compat --with-threads --with-file-aio --with-pcre-jit \
      --with-http_ssl_module \
      --with-http_v2_module \
      --with-http_realip_module \
      --with-http_gzip_static_module \
      --with-http_stub_status_module \
      --with-http_auth_request_module \
      --with-http_sub_module \
      --with-http_gunzip_module \
      --with-http_secure_link_module \
      --with-stream --with-stream_ssl_module \
      --with-stream_ssl_preread_module \
      --with-stream_realip_module \
      --with-cc-opt='-Os -fstack-protector-strong -fPIE -D_FORTIFY_SOURCE=2' \
      --with-ld-opt='-Wl,-z,relro,-z,now,-z,noexecstack -pie' \
      --without-http_autoindex_module \
      --without-http_ssi_module \
      --without-mail_pop3_module \
      --without-mail_imap_module \
      --without-mail_smtp_module \
      --add-dynamic-module=/opt/ModSecurity-nginx \
      --add-dynamic-module=/opt/ngx_http_geoip2_module \
      --add-dynamic-module=/opt/nginx-module-vts \
      --add-dynamic-module=/opt/headers-more-nginx-module && \
    make -j"$(nproc)" && make install && \
    strip /usr/sbin/nginx && \
    strip /usr/lib/nginx/modules/*.so

# --- GeoIP databases (db-ip free, current month) ---
ARG GEO_DB_RELEASE=""
RUN GEO_DB_RELEASE="${GEO_DB_RELEASE:-$(date +%Y-%m)}" && \
    mkdir -p /etc/nginx/geoip && \
    curl -fsSL "https://download.db-ip.com/free/dbip-city-lite-${GEO_DB_RELEASE}.mmdb.gz" \
      | gzip -d > /etc/nginx/geoip/dbip-city-lite.mmdb && \
    curl -fsSL "https://download.db-ip.com/free/dbip-country-lite-${GEO_DB_RELEASE}.mmdb.gz" \
      | gzip -d > /etc/nginx/geoip/dbip-country-lite.mmdb

# ---------------------------------------------------------------------------
# Stage 2: production — runtime minimal
# ---------------------------------------------------------------------------
FROM alpine:3.21 AS production

LABEL org.opencontainers.image.title="nginx-waf-hardened" \
      org.opencontainers.image.description="Hardened Nginx + ModSecurity v3 + OWASP CRS + GeoIP2 + VTS" \
      org.opencontainers.image.vendor="jbsky" \
      org.opencontainers.image.licenses="MIT"

# Runtime deps only
RUN apk add --no-cache \
    ca-certificates curl libcurl libgcc libmaxminddb libstdc++ \
    libxml2 lmdb openssl pcre2 tzdata yajl zlib && \
    addgroup -g 1999 -S nginx && \
    adduser -S -D -H -u 1999 -h /var/cache/nginx -s /sbin/nologin -G nginx nginx && \
    mkdir -p /var/log/nginx /var/cache/nginx/client_temp /var/cache/nginx/proxy_temp \
             /var/cache/nginx/fastcgi_temp /var/cache/nginx/uwsgi_temp \
             /var/cache/nginx/scgi_temp /var/run/nginx \
             /var/lib/modsecurity/tmp /var/lib/modsecurity/data \
             /etc/nginx/conf.d /etc/nginx/modsec /etc/nginx/geoip \
             /usr/lib/nginx/modules /usr/share/nginx/html /usr/share/nginx/errors \
             /var/www/html && \
    chown -R nginx:nginx /var/log/nginx /var/cache/nginx /var/run/nginx \
                         /var/lib/modsecurity /usr/share/nginx /var/www/html && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

# Copy from builder
COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /usr/lib/nginx/modules/ /usr/lib/nginx/modules/
COPY --from=builder /usr/local/modsecurity/lib/ /usr/local/modsecurity/lib/
COPY --from=builder /usr/local/owasp-modsecurity-crs/ /usr/local/owasp-modsecurity-crs/
COPY --from=builder /etc/nginx/geoip/ /etc/nginx/geoip/

# Copy configuration
COPY --chown=nginx:nginx errors/ /usr/share/nginx/errors/
COPY --chown=root:nginx conf/nginx/nginx.conf /etc/nginx/nginx.conf
COPY --chown=root:nginx conf/nginx/conf.d/ /etc/nginx/conf.d/
COPY --chown=root:nginx conf/modsec/ /etc/nginx/modsec/
COPY --chown=root:nginx conf/owasp/ /usr/local/owasp-modsecurity-crs/

# Harden + link libs
RUN chmod 755 /usr/sbin/nginx && \
    chmod 644 /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/modsec/* && \
    chmod 755 /usr/lib/nginx/modules/*.so && \
    touch /var/run/nginx/nginx.pid && chown nginx:nginx /var/run/nginx/nginx.pid && \
    echo "/usr/local/modsecurity/lib" >> /etc/ld-musl-x86_64.path

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:80/healthz || exit 1

WORKDIR /var/www/html
EXPOSE 80 443
STOPSIGNAL SIGQUIT
USER nginx
CMD ["nginx", "-g", "daemon off;"]
