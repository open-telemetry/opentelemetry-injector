ARCH=amd64
INSTALL_DIR=/usr/lib/opentelemetry/otelinject

# Docker repository used.
DOCKER_REPO?=docker.io

.PHONY: all
all: so/libotelinject.so

# make -d: Prerequisite 'obj' is newer than target 'obj/logger.o'.
so:
	@mkdir -p so

obj:
	@mkdir -p obj

.PHONY: clean
clean:
	rm -f tests so/* obj/*

obj/main.o: obj src/main.c
	gcc -c -Wall -Werror -fpic -o obj/main.o src/main.c

so/libotelinject.so: obj so obj/main.o
	gcc -shared -o so/libotelinject.so obj/main.o

.PHONY: dist
dist:
	@mkdir -p dist
	docker buildx build --platform linux/$(ARCH) --build-arg DOCKER_REPO=$(DOCKER_REPO) -o type=image,name=libotelinject-builder:$(ARCH),push=false .
	docker rm -f libotelinject-builder 2>/dev/null || true
	docker run -d --platform linux/$(ARCH) --name libotelinject-builder libotelinject-builder:$(ARCH) sleep inf
	docker exec libotelinject-builder make all
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

# Run this from within this directory to create the devel image (just debian with gcc and a jdk). You only have to run
# this once-ish. Mostly intended for development.
.PHONY: docker-build
docker-build:
	docker build -t instr-devel -f devel.Dockerfile .

# Run this from with this directory to run and get a command line into the devel container created by dev-docker-build.
# Once you have a command line, you can run `make test`. Mostly intended for development.
.PHONY: docker-run
docker-run:
	docker run --rm -it -v `pwd`:/instr instr-devel

.PHONY: tests
tests: test-java test-nodejs test-dotnet

.PHONY: test-dotnet-java-nodejs
test-%: dist
	(cd tests/$* && ARCH=$(ARCH) ./test.sh)

SHELL = /bin/bash
.SHELLFLAGS = -o pipefail -c

# SRC_ROOT is the top of the source tree.
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
