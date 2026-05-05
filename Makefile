.PHONY: lint build smoke clean

ARCH ?= amd64
IMAGE ?= bhs/forgejo-addon-test:$(ARCH)

lint:
	@command -v hadolint >/dev/null && hadolint forgejo/Dockerfile || echo "hadolint not installed, skipping"
	@command -v shellcheck >/dev/null && shellcheck $$(find forgejo/rootfs tests -name '*.sh' -o -name 'run' -o -name 'up') || echo "shellcheck not installed, skipping"
	@command -v yamllint >/dev/null && yamllint forgejo/ repository.yaml || echo "yamllint not installed, skipping"

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
