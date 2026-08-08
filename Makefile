# tank-os Makefile

# Registry configuration (no defaults - must be set explicitly)
IMAGE_REGISTRY ?=
IMAGE_NAMESPACE ?=
IMAGE := tank-os
FEDORA_BOOTC_BASE ?=
# Pinned, date-stamped CSB tag -- see
# docs/dev/csb-bootc-deployment-design.md Open Question 1. CSB rebuilds
# daily; do not default this to a moving tag like csb-latest.
CSB_IMAGE_TAG ?= quay.io/redhat-et/openclaw:csb-arm64-openclaw-v2026.7.2-beta.7
# Single point of control for the OpenShell RPMs bootc/Containerfile
# installs on the host -- its own ARG default exists only for standalone
# builds run without this Makefile, and must be bumped together with
# this value.
OPENSHELL_VERSION ?= 0.0.99

# KubeVirt containerDisk (wraps out-tank-os/qcow2/disk.qcow2, see
# deploy/containerdisk/Containerfile) -- override if you're publishing to
# a different registry.
IMAGE_CONTAINERDISK_URI ?= quay.io/redhat-et/tank-os-containerdisk

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

# Image URI construction (main tank-os image only)
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

BUILD_ARGS := --build-arg CSB_IMAGE_TAG=$(CSB_IMAGE_TAG) \
  --build-arg OPENSHELL_VERSION=$(OPENSHELL_VERSION)
ifneq ($(FEDORA_BOOTC_BASE),)
  BUILD_ARGS += --build-arg FEDORA_BOOTC_BASE=$(FEDORA_BOOTC_BASE)
endif

.PHONY: help
help:
	@echo "tank-os Makefile"
	@echo ""
	@echo "Common targets:"
	@echo "  build          Build the bootc container image locally"
	@echo "  push           Push the image to registry (requires IMAGE_REGISTRY and IMAGE_NAMESPACE)"
	@echo "  build-qcow2    Build a QCOW2 disk image using bootc-image-builder"
	@echo "  build-containerdisk  Wrap the qcow2 as a KubeVirt containerDisk (run build-qcow2 first)"
	@echo "  push-containerdisk   Push it to IMAGE_CONTAINERDISK_URI:latest (single-arch, see WARNING)"
	@echo "  push-containerdisk-arch  Push it to IMAGE_CONTAINERDISK_URI:\$$(ARCH), safe for multi-arch merge"
	@echo "  build-iso      Build an ISO installer using bootc-image-builder"
	@echo "  lint           Run bootc container lint (if available)"
	@echo "  verify         Verify image signature with cosign (if COSIGN_PUBLIC_KEY is set)"
	@echo "  clean          Remove build artifacts"
	@echo ""
	@echo "Current configuration:"
	@echo "  ARCH:            $(ARCH)"
	@echo "  PLATFORM:        $(PLATFORM)"
	@echo "  IMAGE_URI:       $(IMAGE_URI)"
	@echo "  CSB_IMAGE_TAG:   $(CSB_IMAGE_TAG)"
	@echo "  IMAGE_CONTAINERDISK_URI: $(IMAGE_CONTAINERDISK_URI)"
	@echo "  OPENSHELL_VERSION: $(OPENSHELL_VERSION)"
	@echo "  IMAGE_REGISTRY:  $(IMAGE_REGISTRY)"
	@echo "  IMAGE_NAMESPACE: $(IMAGE_NAMESPACE)"
	@echo "  FEDORA_BOOTC_BASE: $(FEDORA_BOOTC_BASE)"

.PHONY: build
build:
	podman build --platform $(PLATFORM) $(BUILD_ARGS) -t $(IMAGE_URI):latest -f bootc/Containerfile bootc

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

# KubeVirt containerDisk -- run this AFTER build-qcow2, it wraps that
# target's output (out-tank-os/qcow2/disk.qcow2). See
# docs/openshift-virtualization.md for the full pipeline.
.PHONY: build-containerdisk
build-containerdisk:
	@if [ ! -f "out-tank-os/qcow2/disk.qcow2" ]; then \
		echo "Error: out-tank-os/qcow2/disk.qcow2 not found. Run 'make build-qcow2' first."; \
		exit 1; \
	fi
	cp out-tank-os/qcow2/disk.qcow2 deploy/containerdisk/disk.qcow2
	podman build --platform $(PLATFORM) \
		-t $(IMAGE_CONTAINERDISK_URI):latest \
		-f deploy/containerdisk/Containerfile deploy/containerdisk
	rm -f deploy/containerdisk/disk.qcow2

.PHONY: push-containerdisk
push-containerdisk:
	@echo "WARNING: $(IMAGE_CONTAINERDISK_URI):latest is expected to be a"; \
	echo "multi-arch manifest list. This target pushes a single-arch"; \
	echo "($(ARCH)) image straight to that tag, which silently REPLACES the"; \
	echo "manifest list with a single-arch image -- breaking every other"; \
	echo "architecture's pull. If you're updating the shared published"; \
	echo "image, push each arch under its own tag instead and merge with"; \
	echo "'podman manifest create/add' + 'push --all' -- see"; \
	echo "docs/openshift-virtualization.md's \"Publishing a multi-arch"; \
	echo "containerdisk\" section. Only push straight to :latest for a"; \
	echo "personal single-arch build you don't intend anyone else to pull."
	podman push $(IMAGE_CONTAINERDISK_URI):latest

# Safe building block for publishing a multi-arch containerdisk -- pushes
# under an arch-specific tag instead of :latest, so it can never clobber
# the published manifest list. Run on each architecture's own native
# host, then merge the resulting tags into a manifest list with `podman
# manifest create`/`push --all` -- see
# docs/openshift-virtualization.md's "Publishing a multi-arch
# containerdisk" section for the exact commands.
.PHONY: push-containerdisk-arch
push-containerdisk-arch:
	podman tag $(IMAGE_CONTAINERDISK_URI):latest $(IMAGE_CONTAINERDISK_URI):$(ARCH)
	podman push $(IMAGE_CONTAINERDISK_URI):$(ARCH)

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
	rm -f deploy/containerdisk/disk.qcow2
