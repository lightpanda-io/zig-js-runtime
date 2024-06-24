# Variables
# ---------

ZIG := zig

# OS and ARCH
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Linux)
	OS := linux
else ifeq ($(UNAME_S),Darwin)
	OS := macos
else
	$(error "OS not supported")
endif
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M),x86_64)
	ARCH := x86_64
else ifeq ($(UNAME_M),aarch64)
	ARCH := aarch64
else ifeq ($(UNAME_M),arm64)
	ARCH := aarch64
else
	$(error "CPU not supported")
endif
ifeq ($(OS), macos && ($(ARCH), x86_64))
	$(error "OS/CPU not supported")
endif


# Infos
# -----
.PHONY: help

## Display this help screen
help:
	@printf "\e[36m%-35s %s\e[0m\n" "Command" "Usage"
	@sed -n -e '/^## /{'\
		-e 's/## //g;'\
		-e 'h;'\
		-e 'n;'\
		-e 's/:.*//g;'\
		-e 'G;'\
		-e 's/\n/ /g;'\
		-e 'p;}' Makefile | awk '{printf "\033[33m%-35s\033[0m%s\n", $$1, substr($$0,length($$1)+1)}'

# Git commands
git_clean := git diff --quiet; echo $$?
git_current_branch := git branch --show-current
git_last_commit_full := git log --pretty=format:'%cd_%h' -n 1 --date=format:'%Y-%m-%d_%H-%M'

# List files
tree:
	@tree -I zig-cache -I zig-out -I vendor -I questions -I benchmarks -I build -I "*~"

# Install and build required dependencies commands
# ------------
.PHONY: install-submodule
.PHONY: _install-v8 install-v8-dev install-dev install-v8 install

## Install and build dependencies for release
install: install-submodule install-v8

## Install and build dependencies for dev
install-dev: install-submodule install-v8-dev

## Install and build v8 engine for release
install-v8: _install-v8
install-v8: mode=release
install-v8: zig_opts=-Doptimize=ReleaseSafe

## Install and build v8 engine for dev
install-v8-dev: _install-v8
install-v8-dev: mode=debug

_install-v8:
	@mkdir -p vendor/v8/$(ARCH)-$(OS)/$(mode)
	@cd vendor/zig-v8 && \
	$(ZIG) build get-tools && \
	$(ZIG) build get-v8 && \
	$(ZIG) build $(zig_opts) && \
	cd ../../ && \
	cp vendor/zig-v8/v8-build/$(ARCH)-$(OS)/$(mode)/ninja/obj/zig/libc_v8.a vendor/v8/$(ARCH)-$(OS)/$(mode)/

## Init and update git submodule
install-submodule:
	@git submodule init && \
	git submodule update

# Zig commands
# ------------
.PHONY: build build-release run run-release shell test bench

## Build in debug mode
build:
	@printf "\e[36mBuilding (debug)...\e[0m\n"
	@$(ZIG) build bench -Dengine=v8 || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)
	@printf "\e[33mBuild OK\e[0m\n"

build-release:
	@printf "\e[36mBuilding (release safe)...\e[0m\n"
	@$(ZIG) build -Doptimize=ReleaseSafe -Dengine=v8 || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)
	@printf "\e[33mBuild OK\e[0m\n"

## Run the benchmark in release-safe mode
run: build-release
	@printf "\e[36mRunning...\e[0m\n"
	@./zig-out/bin/zig-js-runtime-bench || (printf "\e[33mRun ERROR\e[0m\n"; exit 1;)
	@printf "\e[33mRun OK\e[0m\n"

## Run a JS shell in release-safe mode
shell:
	@printf "\e[36mBuilding shell (debug)...\e[0m\n"
	@$(ZIG) build shell -Dengine=v8 || (printf "\e[33mBuild ERROR\e[0m\n"; exit 1;)

## Test
test:
	@printf "\e[36mTesting...\e[0m\n"
	@$(ZIG) build test -Dengine=v8 || (printf "\e[33mTest ERROR\e[0m\n"; exit 1;)
	@printf "\e[33mTest OK\e[0m\n"

## run + save results in benchmarks dir
bench: build-release
# Check repo is clean
ifneq ($(shell $(git_clean)), 0)
	$(error repo is not clean)
endif
	@mkdir -p benchmarks && \
	./zig-out/bin/zig-js-runtime-bench > benchmarks/$(shell $(git_last_commit_full))_$(shell $(git_current_branch)).txt
