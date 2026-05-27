# tank-os Makefile

# Registry configuration (no defaults - must be set explicitly)
IMAGE_REGISTRY ?=
IMAGE_NAMESPACE ?=
IMAGE := tank-os

# Auto-detect architecture
UNAME_ARCH := $(shell uname -m)
ifeq ($(UNAME_ARCH),x86_64)
	ARCH := amd64
else ifeq ($(UNAME_ARCH),aarch64)
	ARCH := arm64
else ifeq ($(UNAME_ARCH),arm64)
	ARCH := arm64
else
	ARCH := $(UNAME_ARCH)
endif

# Image URI construction
ifneq ($(IMAGE_REGISTRY),)
  ifneq ($(IMAGE_NAMESPACE),)
    IMAGE_URI := $(IMAGE_REGISTRY)/$(IMAGE_NAMESPACE)/$(IMAGE)
  else
    IMAGE_URI := localhost/$(IMAGE)
  endif
else
  IMAGE_URI := localhost/$(IMAGE)
endif

PLATFORM := linux/$(ARCH)

.PHONY: help
help:
	@echo "tank-os Makefile"
	@echo ""
	@echo "Common targets:"
	@echo "  build          Build the bootc container image locally"
	@echo "  push           Push the image to registry (requires IMAGE_REGISTRY and IMAGE_NAMESPACE)"
	@echo "  build-qcow2    Build a QCOW2 disk image using bootc-image-builder"
	@echo "  build-iso      Build an ISO installer using bootc-image-builder"
	@echo "  lint           Run bootc container lint (if available)"
	@echo "  verify         Verify image signature with cosign (if COSIGN_PUBLIC_KEY is set)"
	@echo "  clean          Remove build artifacts"
	@echo ""
	@echo "Current configuration:"
	@echo "  ARCH:            $(ARCH)"
	@echo "  PLATFORM:        $(PLATFORM)"
	@echo "  IMAGE_URI:       $(IMAGE_URI)"
	@echo "  IMAGE_REGISTRY:  $(IMAGE_REGISTRY)"
	@echo "  IMAGE_NAMESPACE: $(IMAGE_NAMESPACE)"

.PHONY: build
build:
	podman build --platform $(PLATFORM) -t $(IMAGE_URI):latest -f bootc/Containerfile bootc

.PHONY: push
push:
	@if [ -z "$(IMAGE_REGISTRY)" ] || [ -z "$(IMAGE_NAMESPACE)" ]; then \
		echo "Error: IMAGE_REGISTRY and IMAGE_NAMESPACE must be set to push images"; \
		echo "Example: make push IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=myorg"; \
		exit 1; \
	fi
	podman push $(IMAGE_URI):latest

.PHONY: build-qcow2
build-qcow2:
	@if [ ! -f "config.toml" ]; then \
		echo "Error: config.toml not found. Create one in the repo root for bootc-image-builder."; \
		echo "See docs/build.md for examples."; \
		exit 1; \
	fi
	mkdir -p out-tank-os
	podman run --rm --privileged \
		--security-opt label=type:unconfined_t \
		-v ./out-tank-os:/output \
		-v ./config.toml:/config.toml:ro \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		quay.io/centos-bootc/bootc-image-builder:latest \
		$(IMAGE_URI):latest \
		--output /output/ \
		--local \
		--type qcow2 \
		--target-arch $(ARCH) \
		--rootfs xfs \
		--config /config.toml

.PHONY: build-iso
build-iso:
	@if [ ! -f "config.toml" ]; then \
		echo "Error: config.toml not found. Create one in the repo root for bootc-image-builder."; \
		echo "See docs/build.md for examples."; \
		exit 1; \
	fi
	mkdir -p out-tank-os
	podman run --rm --privileged \
		--security-opt label=type:unconfined_t \
		-v ./out-tank-os:/output \
		-v ./config.toml:/config.toml:ro \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		quay.io/centos-bootc/bootc-image-builder:latest \
		$(IMAGE_URI):latest \
		--output /output/ \
		--local \
		--type anaconda-iso \
		--target-arch $(ARCH) \
		--rootfs xfs \
		--config /config.toml

.PHONY: lint
lint:
	@if command -v podman >/dev/null 2>&1; then \
		podman run --rm $(IMAGE_URI):latest bootc container lint; \
	else \
		echo "podman command not found, skipping lint"; \
	fi

.PHONY: verify
verify:
	@if [ -z "$(COSIGN_PUBLIC_KEY)" ]; then \
		echo "COSIGN_PUBLIC_KEY not set, skipping verification"; \
		exit 0; \
	fi
	@if [ -z "$(IMAGE_REGISTRY)" ] || [ -z "$(IMAGE_NAMESPACE)" ]; then \
		echo "Error: IMAGE_REGISTRY and IMAGE_NAMESPACE must be set to verify images"; \
		exit 1; \
	fi
	@if ! command -v cosign >/dev/null 2>&1; then \
		echo "Error: cosign command not found"; \
		exit 1; \
	fi
	@trap 'rm -f /tmp/cosign.pub' EXIT; \
	printf '%s\n' "$$COSIGN_PUBLIC_KEY" > /tmp/cosign.pub && \
	cosign verify --key /tmp/cosign.pub $(IMAGE_URI):latest

.PHONY: clean
clean:
	rm -rf out-tank-os
