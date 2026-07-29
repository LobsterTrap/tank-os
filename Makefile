# tank-os Makefile

# Registry configuration (no defaults - must be set explicitly)
IMAGE_REGISTRY ?=
IMAGE_NAMESPACE ?=
IMAGE := tank-os
FEDORA_BOOTC_BASE ?=
OPENCLAW_REF ?= 2026.7.1
# Single point of control for both Containerfiles that install/download
# OpenShell (bootc/Containerfile's RPMs, bootc/openclaw-openshell's CLI
# tarball) -- their own ARG defaults exist only for standalone builds run
# without this Makefile, and must be bumped together with this value.
OPENSHELL_VERSION ?= 0.0.92

# Derived OpenClaw+OpenShell image has its own dedicated, already-published
# repo (unlike IMAGE_URI above, which has no default and must be set
# explicitly) -- override with IMAGE_OPENCLAW_OPENSHELL_URI=... if you need
# a different destination (e.g. a fork's own registry).
IMAGE_OPENCLAW_OPENSHELL_URI ?= quay.io/redhat-et/tank-claw-openshell

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

# Image URI construction (main tank-os image only -- the derived
# OpenClaw+OpenShell image's URI is set unconditionally above)
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

BUILD_ARGS := --build-arg OPENCLAW_REF=$(OPENCLAW_REF) \
  --build-arg OPENCLAW_OPENSHELL_IMAGE=$(IMAGE_OPENCLAW_OPENSHELL_URI):$(OPENCLAW_REF) \
  --build-arg OPENSHELL_VERSION=$(OPENSHELL_VERSION)
ifneq ($(FEDORA_BOOTC_BASE),)
  BUILD_ARGS += --build-arg FEDORA_BOOTC_BASE=$(FEDORA_BOOTC_BASE)
endif

.PHONY: help
help:
	@echo "tank-os Makefile"
	@echo ""
	@echo "Common targets:"
	@echo "  build-openclaw-openshell  Build the derived OpenClaw+openshell image (build this FIRST)"
	@echo "  push-openclaw-openshell   Push it to IMAGE_OPENCLAW_OPENSHELL_URI"
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
	@echo "  IMAGE_OPENCLAW_OPENSHELL_URI: $(IMAGE_OPENCLAW_OPENSHELL_URI)"
	@echo "  OPENCLAW_REF:    $(OPENCLAW_REF)"
	@echo "  OPENSHELL_VERSION: $(OPENSHELL_VERSION)"
	@echo "  IMAGE_REGISTRY:  $(IMAGE_REGISTRY)"
	@echo "  IMAGE_NAMESPACE: $(IMAGE_NAMESPACE)"
	@echo "  FEDORA_BOOTC_BASE: $(FEDORA_BOOTC_BASE)"

.PHONY: build
build:
	@if ! podman image exists $(IMAGE_OPENCLAW_OPENSHELL_URI):$(OPENCLAW_REF); then \
		echo "Warning: $(IMAGE_OPENCLAW_OPENSHELL_URI):$(OPENCLAW_REF) not found in local Podman storage."; \
		echo "  openclaw.container references this image by tag -- if it's not already pushed to its"; \
		echo "  registry either, run 'make build-openclaw-openshell push-openclaw-openshell' first, or"; \
		echo "  the resulting disk image will fail to pull it on boot."; \
	fi
	podman build --platform $(PLATFORM) $(BUILD_ARGS) -t $(IMAGE_URI):latest -f bootc/Containerfile bootc

.PHONY: push
push:
	@if [ -z "$(IMAGE_REGISTRY)" ] || [ -z "$(IMAGE_NAMESPACE)" ]; then \
		echo "Error: IMAGE_REGISTRY and IMAGE_NAMESPACE must be set to push images"; \
		echo "Example: make push IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=myorg"; \
		exit 1; \
	fi
	podman push $(IMAGE_URI):latest

# Derived OpenClaw image (OpenClaw + openssh-client + the openshell CLI --
# see bootc/openclaw-openshell/Containerfile). Build and push this BEFORE
# `build`/`push` above: the main tank-os image's Quadlet unit references
# it by the tag computed here (IMAGE_OPENCLAW_OPENSHELL_URI:OPENCLAW_REF).
.PHONY: build-openclaw-openshell
build-openclaw-openshell:
	podman build --platform $(PLATFORM) \
		--build-arg OPENCLAW_REF=$(OPENCLAW_REF) \
		--build-arg OPENSHELL_VERSION=$(OPENSHELL_VERSION) \
		--build-arg TARGETARCH=$(ARCH) \
		-t $(IMAGE_OPENCLAW_OPENSHELL_URI):$(OPENCLAW_REF) \
		-f bootc/openclaw-openshell/Containerfile bootc/openclaw-openshell

.PHONY: push-openclaw-openshell
push-openclaw-openshell:
	podman push $(IMAGE_OPENCLAW_OPENSHELL_URI):$(OPENCLAW_REF)

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
