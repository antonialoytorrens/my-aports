#!/usr/bin/make -f

# Packages are discovered by convention:
#   main/<name>/APKBUILD
# Version comes from pkgver=... in the APKBUILD (no VERSION file).
#
# abuild cannot target a foreign architecture by itself; builds must run
# under the real arch (native runner or QEMU via Docker --platform).

SHELL := /bin/bash

include settings.cfg

DISCOVER := ./scripts/discover.sh
MAKE_TARGETS := $(shell $(DISCOVER) make-targets)

.PHONY: all help clean docker-build docker-shell docker-down \
	$(MAKE_TARGETS) $(addprefix docker-,$(MAKE_TARGETS))

all: help

help:
	@echo "Usage: make <package>-<arch>"
	@echo "       make docker-<target>   # same via docker compose"
	@echo ""
	@echo "Examples:"
	@echo "  make wg-easy-x86_64"
	@echo "  make seafile-x86_64"
	@echo "  make docker-libsearpc-aarch64"
	@echo ""
	@echo "Packages (from main/*/APKBUILD):"
	@$(DISCOVER) list | while read -r p; do \
	  arches="$$($(DISCOVER) arches "$$p" | tr '\n' ' ')"; \
	  echo "  $$p: $$arches"; \
	done
	@echo ""
	@echo "Other targets:"
	@echo "  clean          - Remove built .apk artifacts"
	@echo "  docker-build   - Build (or rebuild) the compose builder image"
	@echo "  docker-shell   - Interactive shell in the builder container"
	@echo "  docker-down    - Remove compose containers"
	@echo ""
	@echo " Foreign-arch builds need QEMU binfmt once, e.g.:"
	@echo "   docker run --privileged --rm tonistiigi/binfmt --install all"

clean:
	rm -f ./*.apk

docker-build:
	$(COMPOSE) build

docker-shell:
	$(COMPOSE) run --rm $(SERVICE) bash

docker-down:
	$(COMPOSE) down

# Generic package builds (discovered targets)
$(MAKE_TARGETS):
	$(DISCOVER) build "$@"

# Docker-wrapped: make docker-<target>
$(addprefix docker-,$(MAKE_TARGETS)):
	@target="$(@:docker-%=%)"; \
	case "$$target" in \
	  *-x86_64) platform=linux/amd64 ;; \
	  *-aarch64) platform=linux/arm64 ;; \
	  *-armv7) platform=linux/arm/v7 ;; \
	  *) echo "ERROR: unknown docker target '$$target'"; exit 1 ;; \
	esac; \
	DOCKER_PLATFORM=$$platform $(COMPOSE) run --rm $(SERVICE) make $$target
