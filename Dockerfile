# =====================================================================
#  Nginx WAF Hardened — Multi-stage build
#  5-stage: fetcher -> builder -> gobuilder -> prep -> FROM scratch
#  Conformite Docker Hardened Image :
#   - FROM scratch final stage: zero shell, zero package manager
#   - utilisateur non-root (uid 1999)
#   - binaires strip + RELRO + PIE + stack-protector
#   - entrypoint + healthcheck en binaire Go statique
#   - tini-static PID 1
#
#  Auto-versioning: si NGINX_VER/MODSEC_VER/OWASP_CRS_VER ne sont pas
#  fournis en build-arg, le fetcher interroge les APIs upstream.
#
#  Proxy-aware: passe http_proxy/https_proxy via les predefined ARGs
#  BuildKit (non baked dans l'image finale).
# =====================================================================

# ---------------------------------------------------------------------------
# Stage 0: fetcher — resout les dernieres versions stables
# ---------------------------------------------------------------------------
FROM alpine:3.24 AS fetcher

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache curl jq grep

ARG NGINX_VER=""
ARG MODSEC_VER=""
ARG OWASP_CRS_VER=""

RUN set -eux; \
    if [ -z "$NGINX_VER" ]; then \
      NGINX_VER=$(curl -fsSL https://nginx.org/en/download.html \
        | grep -oP 'Stable version</h4>.*?Legacy' \
        | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+' | sed -n '1p'); \
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
FROM alpine:3.24 AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

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
COPY keys/ /tmp/gpg-keys/

RUN . /etc/profile.d/ver.sh && \
    curl -fsSL "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz" -o /tmp/nginx.tar.gz && \
    curl -fsSL "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz.asc" -o /tmp/nginx.tar.gz.asc && \
    GNUPGHOME="$(mktemp -d)" && export GNUPGHOME && \
    gpg --batch --import /tmp/gpg-keys/*.key && \
    gpg --batch --verify /tmp/nginx.tar.gz.asc /tmp/nginx.tar.gz && \
    rm -rf "$GNUPGHOME" /tmp/nginx.tar.gz.asc /tmp/gpg-keys && \
    mkdir -p /usr/src && \
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
      --with-cc-opt='-Os -fstack-protector-strong -fstack-clash-protection -fPIC -D_FORTIFY_SOURCE=2' \
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

# --- Persist resolved versions for downstream consumption ---
RUN . /etc/profile.d/ver.sh && \
    echo "nginx=${NGINX_VER} modsec=${MODSEC_VER} crs=${OWASP_CRS_VER}" > /tmp/image-versions

# ---------------------------------------------------------------------------
# Stage 2: Go builder (entrypoint + healthcheck)
# ---------------------------------------------------------------------------
FROM golang:1.26-alpine AS gobuilder
WORKDIR /build
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -o /init .

# ---------------------------------------------------------------------------
# Stage 3: prep (assemble runtime filesystem)
# ---------------------------------------------------------------------------
FROM alpine:3.24 AS prep

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# 1/2  Core runtime libs
RUN sed -i 's|https://|http://|g' /etc/apk/repositories \
 && apk add --no-cache \
        ca-certificates libcurl libgcc libmaxminddb libstdc++ \
        libxml2 lmdb openssl pcre2 tzdata yajl zlib geoip \
        tini-static

# 2/2  Create user
RUN addgroup -g 1999 -S nginx \
 && adduser -S -D -H -u 1999 -h /var/cache/nginx -s /sbin/nologin -G nginx nginx

# Nginx binary + modules from builder
COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /usr/lib/nginx/modules/ /usr/lib/nginx/modules/
COPY --from=builder /usr/local/modsecurity/lib/ /usr/local/modsecurity/lib/
COPY --from=builder /usr/local/owasp-modsecurity-crs/ /usr/local/owasp-modsecurity-crs/
COPY --from=builder /etc/nginx/geoip/ /etc/nginx/geoip/
COPY --from=builder /etc/nginx/mime.types /etc/nginx/mime.types
COPY --from=builder /tmp/image-versions /etc/image-versions

# Copy configuration
COPY --chown=nginx:nginx errors/ /usr/share/nginx/errors/
COPY --chown=root:nginx conf/nginx/nginx.conf /etc/nginx/nginx.conf
COPY --chown=root:nginx conf/nginx/conf.d/ /etc/nginx/conf.d/
COPY --chown=root:nginx conf/modsec/ /etc/nginx/modsec/

# Harden: permissions + link libs
RUN chmod 755 /usr/sbin/nginx \
 && chmod 644 /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/modsec/* \
 && chmod 755 /usr/lib/nginx/modules/*.so \
 && ln -sf /usr/lib/nginx/modules /etc/nginx/modules \
 && printf '/lib\n/usr/local/lib\n/usr/lib\n/usr/local/modsecurity/lib\n' > /etc/ld-musl-x86_64.path

# Strip APK/package-manager artifacts
RUN rm -rf /lib/apk /lib/libapk* /var/cache/apk /etc/apk /sbin/apk

# ---------------------------------------------------------------------------
# Stage 4: FROM scratch (final hardened image)
# ---------------------------------------------------------------------------
FROM scratch

LABEL org.opencontainers.image.title="nginx-waf-hardened" \
      org.opencontainers.image.description="Nginx WAF FROM scratch — ModSecurity v3, OWASP CRS, non-root, zero shell" \
      org.opencontainers.image.vendor="jbsky" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/jbsky/nginx-waf-hardened"

# User accounts
COPY --link --from=prep /etc/passwd /etc/passwd
COPY --link --from=prep /etc/group  /etc/group

# Dynamic linker (musl) + shared libraries
COPY --link --from=prep /lib/ /lib/
COPY --link --from=prep /usr/lib/ /usr/lib/

# ModSecurity shared libraries
COPY --link --from=prep /usr/local/modsecurity/lib/ /usr/local/modsecurity/lib/

# Nginx binary + modules
COPY --link --from=prep /usr/sbin/nginx /usr/sbin/nginx
COPY --link --from=prep /usr/lib/nginx/modules/ /usr/lib/nginx/modules/
COPY --link --from=prep /etc/nginx/ /etc/nginx/

# OWASP CRS rules
COPY --link --from=prep /usr/local/owasp-modsecurity-crs/ /usr/local/owasp-modsecurity-crs/

# Custom error pages + html
COPY --link --from=prep /usr/share/nginx/ /usr/share/nginx/

# Version info
COPY --link --from=prep /etc/image-versions /etc/image-versions

# Musl library path config
COPY --link --from=prep /etc/ld-musl-x86_64.path /etc/ld-musl-x86_64.path

# TLS trust store + timezone data
COPY --link --from=prep /etc/ssl/ /etc/ssl/
COPY --link --from=prep /usr/share/zoneinfo/ /usr/share/zoneinfo/

# PID 1 — tini-static (no musl dependency for PID 1 reliability)
COPY --link --from=prep /sbin/tini-static /sbin/tini

# Go init binary (static, entrypoint + healthcheck + setup-dirs)
COPY --link --from=gobuilder /init /usr/local/bin/init

# Create runtime directories with correct ownership (no shell needed)
RUN ["/usr/local/bin/init", "--setup-dirs"]

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

USER 1999:1999

EXPOSE 80 443
STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/init", "--healthcheck"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/init"]
CMD ["nginx", "-g", "daemon off;"]
