SHELL := /bin/sh

JEKYLL_HOST ?= 127.0.0.1
JEKYLL_PORT ?= 4100
LIVERELOAD_PORT ?= 35729
DOCKER_COMPOSE ?= docker compose

.DEFAULT_GOAL := help

.PHONY: help dev test shell stop clean docker-clean tag

help:
	@printf "%s\n" "Blog local commands"
	@printf "%s\n" ""
	@printf "%s\n" "Docker:"
	@printf "%s\n" "  make dev          Serve with Docker Compose, starting at http://$(JEKYLL_HOST):$(JEKYLL_PORT)/"
	@printf "%s\n" "  make test         Build the static site inside Docker"
	@printf "%s\n" "  make shell        Open a shell in the dev container"
	@printf "%s\n" "  make stop         Stop Compose services"
	@printf "%s\n" "  make clean        Remove Jekyll build output"
	@printf "%s\n" "  make docker-clean Stop Compose services and remove generated output"
	@printf "%s\n" ""
	@printf "%s\n" "Release:"
	@printf "%s\n" "  make tag TAG=vDD.MM.YYYY  Create and push an annotated deploy tag"

dev:
	@set -e ; \
	$(DOCKER_COMPOSE) down --remove-orphans >/dev/null 2>&1 || true ; \
	PORT="$$(ruby -rsocket -e 'host = "$(JEKYLL_HOST)"; start = "$(JEKYLL_PORT)".to_i; limit = start + 100; port = (start..limit).find { |candidate| begin server = TCPServer.new(host, candidate); server.close; true; rescue SystemCallError; false; end }; abort "No free Jekyll port found from #{start} to #{limit}" unless port; puts port')" ; \
	LR_PORT="$$(ruby -rsocket -e 'host = "$(JEKYLL_HOST)"; start = "$(LIVERELOAD_PORT)".to_i; limit = start + 100; port = (start..limit).find { |candidate| begin server = TCPServer.new(host, candidate); server.close; true; rescue SystemCallError; false; end }; abort "No free LiveReload port found from #{start} to #{limit}" unless port; puts port')" ; \
	printf "%s\n" "Serving Docker Jekyll at http://$(JEKYLL_HOST):$$PORT/" ; \
	printf "%s\n" "Docker LiveReload on http://$(JEKYLL_HOST):$$LR_PORT" ; \
	JEKYLL_PORT=$$PORT LIVERELOAD_PORT=$$LR_PORT $(DOCKER_COMPOSE) up --build site

test:
	$(DOCKER_COMPOSE) run --rm site bundle exec jekyll build

shell:
	$(DOCKER_COMPOSE) run --rm site /bin/sh

stop:
	$(DOCKER_COMPOSE) down --remove-orphans

clean:
	rm -rf _site .jekyll-cache .jekyll-metadata

docker-clean: clean
	$(DOCKER_COMPOSE) down --remove-orphans

tag:
	@test -n "$(TAG)" || { printf "%s\n" "Usage: make tag TAG=vDD.MM.YYYY"; exit 2; }
	@printf "%s\n" "$(TAG)" | grep -Eq '^v(0[1-9]|[12][0-9]|3[01])\.(0[1-9]|1[0-2])\.[0-9]{4}$$' || { printf "%s\n" "Invalid tag format: $(TAG). Expected vDD.MM.YYYY"; exit 2; }
	@test -z "$$(git status --porcelain)" || { printf "%s\n" "Working tree is not clean; commit or stash changes before tagging."; git status --short; exit 2; }
	@if git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null; then printf "%s\n" "Tag already exists: $(TAG)"; exit 2; fi
	git tag -a "$(TAG)" -m "Release $(TAG)"
	git push origin "$(TAG)"
