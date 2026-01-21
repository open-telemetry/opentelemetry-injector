ARCH?=amd64
VERSION?=0.0.0-dev
INSTALL_DIR:=/usr/lib/opentelemetry/otelinject
DIST_DIR_BINARY:=dist
BINARY_NAME_PREFIX:=libotelinject
BINARY_NAME_NO_ARCH:=$(BINARY_NAME_PREFIX).so
BINARY_NAME:=$(BINARY_NAME_PREFIX)_$(ARCH).so
DIST_DIR_PACKAGE:=instrumentation/dist
PACKAGE_NAME:=opentelemetry-injector

# Docker repository used.
DOCKER_REPO?=docker.io

DIST_SRCS:=\
	$(wildcard src/*.*) \
	build.zig \
	build.zig.zon \
	Dockerfile \
	zig-version

DIST_TARGET:=$(DIST_DIR_BINARY)/$(BINARY_NAME)

COMMON_PACKAGE_SRCS:=\
  $(DIST_SRCS) \
	$(wildcard packaging/*-release.txt) \
	$(wildcard packaging/fpm/*.*) \
	$(wildcard packaging/fpm/etc/*.*) \
	$(wildcard packaging/fpm/etc/**/*.*)

DEB_PACKAGE_SRCS:=\
	$(COMMON_PACKAGE_SRCS) \
	$(wildcard packaging/fpm/deb/*.*)
DEB_PACKAGE_TARGET:=$(DIST_DIR_PACKAGE)/$(PACKAGE_NAME)_$(VERSION)_$(ARCH).deb

RPM_PACKAGE_SRCS:=\
	$(COMMON_PACKAGE_SRCS) \
	$(wildcard packaging/fpm/rpm/*.*)
ifeq ($(ARCH),arm64)
  RPM_PACKAGE_ARCH:=aarch64
else
  RPM_PACKAGE_ARCH:=x86_64
endif
RPM_VERSION=$(subst -,_,$(VERSION))
RPM_PACKAGE_TARGET := $(DIST_DIR_PACKAGE)/$(PACKAGE_NAME)-$(RPM_VERSION)-1.$(RPM_PACKAGE_ARCH).rpm

.PHONY: all
all: so/$(BINARY_NAME_NO_ARCH)

so:
	@mkdir -p so

obj:
	@mkdir -p obj

.PHONY: clean
clean:
	rm -rf so $(DIST_DIR_BINARY) $(DIST_DIR_PACKAGE) zig-out .zig-cache

so/$(BINARY_NAME_NO_ARCH): so
	zig build -Dcpu-arch=${ARCH} --prominent-compile-errors --summary none

$(DIST_TARGET): $(DIST_SRCS)
	@echo building the injector binary for architecture $(ARCH)
	@set -e
	@mkdir -p $(DIST_DIR_BINARY)
	if [[ "$(ARCH)" = arm64 ]]; then \
	  ZIG_ARCHITECTURE=aarch64; \
	elif [[ "$(ARCH)" = amd64 ]]; then \
	  ZIG_ARCHITECTURE=x86_64; \
	fi; \
	docker buildx build --platform linux/$(ARCH) --build-arg DOCKER_REPO=$(DOCKER_REPO) --build-arg ZIG_ARCHITECTURE=$$ZIG_ARCHITECTURE -o type=image,name=libotelinject-builder:$(ARCH),push=false .
	docker rm -f libotelinject-builder 2>/dev/null || true
	docker run -d --platform linux/$(ARCH) --name libotelinject-builder libotelinject-builder:$(ARCH) sleep inf
	docker exec libotelinject-builder make ARCH=$(ARCH) SHELL=/bin/sh all
	docker cp libotelinject-builder:/libotelinject/so/$(BINARY_NAME_NO_ARCH) $(DIST_DIR_BINARY)/$(BINARY_NAME)
	docker rm -f libotelinject-builder

.PHONY: dist
dist: $(DIST_TARGET)

.PHONY: deb-package
deb-package: $(DEB_PACKAGE_TARGET)

.PHONY: rpm-package
rpm-package: $(RPM_PACKAGE_TARGET)

$(DEB_PACKAGE_TARGET): $(DEB_PACKAGE_SRCS)
	$(MAKE) dist
	@$(call build_package,deb,$(VERSION))

$(RPM_PACKAGE_TARGET): $(RPM_PACKAGE_SRCS)
	$(MAKE) dist
	@$(call build_package,rpm,$(RPM_VERSION))

define build_package
$(eval $@_SYS_PACKAGE = $(1))
$(eval $@_VERSION = $(2))
@echo building the injector package for architecture $(ARCH) and system package type $($@_SYS_PACKAGE)
@mkdir -p $(DIST_DIR_PACKAGE)
docker build -t instrumentation-fpm packaging/fpm
docker rm -f libotelinject-packager 2>/dev/null || true
docker run -d --name libotelinject-packager --rm -v $(CURDIR):/repo -e PACKAGE=$* -e VERSION=$($@_VERSION) -e ARCH=$(ARCH) instrumentation-fpm sleep inf
docker exec libotelinject-packager ./packaging/fpm/$($@_SYS_PACKAGE)/build.sh "$($@_VERSION)" "$(ARCH)" "/repo/$(DIST_DIR_PACKAGE)"
docker cp --quiet libotelinject-packager:/repo/$(DIST_DIR_PACKAGE)/. $(DIST_DIR_PACKAGE)
docker rm -f libotelinject-packager 2>/dev/null
endef

# Run this to install and enable the auto-instrumentation files. Mostly intended for development.
.PHONY: install
install: all uninstall
	mkdir -p $(INSTALL_DIR)
	cp javaagent.jar $(INSTALL_DIR)
	cp so/$(BINARY_NAME_NO_ARCH) $(INSTALL_DIR)
	echo $(INSTALL_DIR)/$(BINARY_NAME_NO_ARCH) > /etc/ld.so.preload

.PHONY: uninstall
uninstall:
	rm -f /etc/ld.so.preload
	rm -f $(INSTALL_DIR)/javaagent.jar
	rm -f $(INSTALL_DIR)/$(BINARY_NAME_NO_ARCH)

# Run this from with this directory to build and run the development container.
# Once you have a command line inside the container, you can run make zig-build, make zig-unit-tests,
# make watch-zig-build, make watch-zig-unit-tests etc.
# Alternatively, you can also use the same commands directly on your development machine, without using the development
# container.
# By explicitly setting ARCH=arm64 or ARCH=amd64 you can run and test on different CPU platforms.
# Mostly intended for development.
.PHONY: docker-dev-run
docker-dev-run:
	ARCH=$(ARCH) ./start-injector-dev-container.sh

.PHONY: check-zig-installed
check-zig-installed:
	@set +x
	@if ! zig version > /dev/null; then \
	  echo "error: zig is not installed. Run 'brew install zig' or similar."; \
	  exit 1; \
	fi

.PHONY: zig-build
zig-build: check-zig-installed
	@mkdir -p so
	@(zig build -Dcpu-arch=${ARCH} --prominent-compile-errors --summary none && echo $(shell date) build successful) || (echo $(shell date) build failed && exit 1)

.PHONY: watch-zig-build
watch-zig-build: check-zig-installed
	@fd -e zig | entr make zig-build

.PHONY: zig-unit-tests
zig-unit-tests: check-zig-installed
	@(zig build test -Dcpu-arch=${ARCH} --prominent-compile-errors --summary none && echo $(shell date) tests successful) || (echo $(shell date) tests failed && exit 1)

.PHONY: watch-zig-unit-tests
watch-zig-unit-tests: check-zig-installed
	@fd -e zig | entr make zig-unit-tests

.PHONY: tests
tests: zig-unit-tests injector-integration-tests-for-one-architecture

.PHONY: injector-integration-tests-for-one-architecture
injector-integration-tests-for-one-architecture:
	ARCHITECTURES=$(ARCH) test/scripts/test-all.sh

.PHONY: injector-integration-tests-for-all-architectures
injector-integration-tests-for-all-architectures:
	test/scripts/test-all.sh

.PHONY: lint
lint: zig-fmt-check zig-validate-test-imports shellcheck-lint

.PHONY: zig-fmt-check
zig-fmt-check: check-zig-installed
	@zig fmt --check src

# Run this to auto-format Zig code.
.PHONY: zig-fmt
zig-fmt: check-zig-installed
	zig fmt src

.PHONY: zig-validate-test-imports
zig-validate-test-imports:
	@set -e; \
	files=$$(cd src && grep -l 'test "' ./*.zig 2>/dev/null || true); \
	[ -n "$$files" ] || { echo "None of the .zig files contain any tests, this is likely an error in the zig-validate-test-imports make recipe."; exit 1; }; \
	echo $$names; \
	names=$$(printf '%s\n' $$files | sed -e 's|.*/||'); \
	missing=0; \
	for n in $$names; do \
	  if ! grep -q "@import(\"$$n\")" src/test.zig; then \
	    echo "- The file \"src/test.zig\" is missing an import for \"$$n\", tests in \"$$n\" will ignored."; \
	    missing=1; \
	  fi; \
	done; \
	if [ $$missing -gt 0 ]; then \
	  echo ;\
	  echo "The file \"src/test.zig\" is missing imports to files with Zig unit tests, see above. Please add all files with test cases to \"src/test.zig\"."; \
	  exit 1; \
	fi

.PHONY: check-shellcheck-installed
check-shellcheck-installed:
	@set +x
	@if ! shellcheck --version > /dev/null; then \
	echo "error: shellcheck is not installed. See https://github.com/koalaman/shellcheck?tab=readme-ov-file#installing for installation instructions."; \
	exit 1; \
	fi

.PHONY: shellcheck-lint
shellcheck-lint: check-shellcheck-installed
	@echo "linting shell scripts with shellcheck"
	find . -name \*.sh | xargs shellcheck -x

SHELL = /bin/bash
.SHELLFLAGS = -o pipefail -c

# SRC_ROOT is the top of the source tree.
SRC_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
TOOLS_BIN_DIR    := $(SRC_ROOT)/.tools
CHLOGGEN_CONFIG  := .chloggen/config.yaml
CHLOGGEN         := $(TOOLS_BIN_DIR)/chloggen

$(TOOLS_BIN_DIR):
	mkdir -p $@

$(CHLOGGEN): $(TOOLS_BIN_DIR)
	GOBIN=$(TOOLS_BIN_DIR) go install go.opentelemetry.io/build-tools/chloggen@v0.23.1

FILENAME?=$(shell git branch --show-current)
.PHONY: chlog-new
chlog-new: $(CHLOGGEN)
	$(CHLOGGEN) new --config $(CHLOGGEN_CONFIG) --filename $(FILENAME)

.PHONY: chlog-validate
chlog-validate: $(CHLOGGEN)
	$(CHLOGGEN) validate --config $(CHLOGGEN_CONFIG)

.PHONY: chlog-preview
chlog-preview: $(CHLOGGEN)
	$(CHLOGGEN) update --config $(CHLOGGEN_CONFIG) --dry

.PHONY: chlog-update
chlog-update: $(CHLOGGEN)
	$(CHLOGGEN) update --config $(CHLOGGEN_CONFIG) --version $(VERSION)

list:
	@grep '^[^#[:space:]].*:' Makefile

.PHONY: packaging-integration-test-deb
packaging-integration-test-deb-%: deb-package
	(cd packaging/tests/deb/$* && ARCH=$(ARCH) ./run.sh)

.PHONY: packaging-integration-test-rpm
packaging-integration-test-rpm-%: rpm-package
	(cd packaging/tests/rpm/$* && ARCH=$(ARCH) ./run.sh)
