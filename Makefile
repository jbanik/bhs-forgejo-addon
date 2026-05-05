.PHONY: lint build smoke clean

ARCH ?= amd64
IMAGE ?= bhs/forgejo-addon-test:$(ARCH)

lint:
	@if command -v hadolint >/dev/null; then hadolint forgejo/Dockerfile; else echo "hadolint not installed, skipping"; fi
	@if command -v shellcheck >/dev/null; then shellcheck $$(find forgejo/rootfs tests \( -name '*.sh' -o -name 'run' -o -name 'up' \) -type f); else echo "shellcheck not installed, skipping"; fi
	@if command -v yamllint >/dev/null; then yamllint forgejo/ repository.yaml; else echo "yamllint not installed, skipping"; fi

build:
	docker build \
		--build-arg BUILD_FROM=ghcr.io/hassio-addons/base:15.0.10 \
		-t $(IMAGE) \
		forgejo/

smoke: build
	bash tests/smoke.sh $(IMAGE)

clean:
	-docker rm -f forgejo-smoke 2>/dev/null
	-docker rmi $(IMAGE) 2>/dev/null
	rm -rf test-data
