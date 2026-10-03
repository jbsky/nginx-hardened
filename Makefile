.PHONY: help build up down logs ps scan test clean

DC := docker compose

help:
	@echo "Cibles disponibles :"
	@echo "  make build   - Build de l'image hardenee"
	@echo "  make up      - Demarre le conteneur"
	@echo "  make down    - Arrete le conteneur"
	@echo "  make logs    - Tail des logs"
	@echo "  make ps      - Etat du conteneur"
	@echo "  make test    - Test healthcheck + ModSec"
	@echo "  make scan    - Scan Trivy de l'image"
	@echo "  make clean   - Supprime volumes + image"

# Memes versions que la CI : sans build-arg, le Dockerfile resoudrait les
# dernieres versions amont et l'image locale divergerait de celle publiee.
build:
	DOCKER_BUILDKIT=1 $(DC) build --pull \
	  --build-arg NGINX_VER=$$(jq -r '.nginx' versions.json) \
	  --build-arg MODSEC_VER=$$(jq -r '.modsecurity' versions.json) \
	  --build-arg OWASP_CRS_VER=$$(jq -r '."owasp-crs"' versions.json)

up:
	$(DC) up -d

down:
	$(DC) down

logs:
	$(DC) logs -f --tail=200

ps:
	$(DC) ps

test:
	./scripts/test.sh

scan:
	./scripts/deploy.sh scan

clean:
	$(DC) down -v
	docker image rm localhost/nginx-waf-hardened:latest 2>/dev/null || true
