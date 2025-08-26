ARCH=amd64
INSTALL_DIR=/usr/lib/opentelemetry/otelinject

# Docker repository used.
DOCKER_REPO?=docker.io

.PHONY: all
all: so/libotelinject.so

so:
	@mkdir -p so

obj:
	@mkdir -p obj

.PHONY: clean
clean:
	rm -rf so dist instrumentation zig-out .zig-cache

so/libotelinject.so: so
	zig build -Dcpu-arch=${ARCH} --prominent-compile-errors --summary none

.PHONY: dist
dist:
	@mkdir -p dist
	docker buildx build --platform linux/$(ARCH) --build-arg DOCKER_REPO=$(DOCKER_REPO) -o type=image,name=libotelinject-builder:$(ARCH),push=false .
	docker rm -f libotelinject-builder 2>/dev/null || true
	docker run -d --platform linux/$(ARCH) --name libotelinject-builder libotelinject-builder:$(ARCH) sleep inf
	docker exec libotelinject-builder make ARCH=$(ARCH) SHELL=/bin/sh all
	docker cp libotelinject-builder:/libotelinject/so/libotelinject.so dist/libotelinject_$(ARCH).so
	docker rm -f libotelinject-builder

.PHONY: deb-rpm-package
%-package:
ifneq ($(SKIP_COMPILE), true)
	$(MAKE) dist
endif
	@mkdir -p dist
	docker build -t instrumentation-fpm packaging/fpm
	docker run --rm -v $(CURDIR):/repo -e PACKAGE=$* -e VERSION=$(VERSION) -e ARCH=$(ARCH) instrumentation-fpm

# Run this to install and enable the auto-instrumentation files. Mostly intended for development.
.PHONY: install
install: all uninstall
	mkdir -p $(INSTALL_DIR)
	cp javaagent.jar $(INSTALL_DIR)
	cp so/libotelinject.so $(INSTALL_DIR)
	echo $(INSTALL_DIR)/libotelinject.so > /etc/ld.so.preload

.PHONY: uninstall
uninstall:
	rm -f /etc/ld.so.preload
	rm -f $(INSTALL_DIR)/javaagent.jar
	rm -f $(INSTALL_DIR)/libotelinject.so

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

.PHONY: zig-build
zig-build:
	@mkdir -p so
	@(zig build --prominent-compile-errors --summary none && echo $(shell date) build successful) || (echo $(shell date) build failed && exit 1)

.PHONY: watch-zig-build
watch-zig-build:
	@fd -e zig | entr make zig-build

.PHONY: zig-unit-tests
zig-unit-tests:
	@(zig build test --prominent-compile-errors --summary none && echo $(shell date) tests successful) || (echo $(shell date) tests failed && exit 1)

.PHONY: watch-zig-unit-tests
watch-zig-unit-tests:
	@fd -e zig | entr make zig-unit-tests

.PHONY: tests
tests: zig-unit-tests injector-integration-tests-for-one-architecture

.PHONY: injector-integration-tests-for-one-architecture
injector-integration-tests-for-one-architecture:
	ARCHITECTURES=$(ARCH) test/scripts/test-all.sh

.PHONY: injector-integration-tests-for-all-architectures
injector-integration-tests-for-all-architectures:
	test/scripts/test-all.sh

SHELL = /bin/bash
.SHELLFLAGS = -o pipefail -c

# SRC_ROOT is the top of the source tree.
# TODO: This causes "/bin/sh: git: not found" when we are using the Makefile in containers that do not have git
# installed.
SRC_ROOT := $(shell git rev-parse --show-toplevel)
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
packaging-integration-test-deb-%: dist deb-package
	(cd packaging/tests/deb/$* && ARCH=$(ARCH) ./run.sh)

.PHONY: packaging-integration-test-rpm
packaging-integration-test-rpm-%: dist rpm-package
	(cd packaging/tests/rpm/$* && ARCH=$(ARCH) ./run.sh)