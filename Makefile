BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
COMMIT := $(shell git log -1 --format='%H')
APPNAME := acme
BUILDDIR ?= $(CURDIR)/build
DOCKER := $(shell which docker)

# don't override user values
ifeq (,$(VERSION))
  VERSION := $(shell git describe --exact-match 2>/dev/null)
  # if VERSION is empty, then populate it with branch's name and raw commit hash
  ifeq (,$(VERSION))
    VERSION := $(BRANCH)-$(COMMIT)
  endif
endif

help: ## List Commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: help

################################################################################
##                                  Pre-push                                  ##
################################################################################

all: ## Convenience to make sure everything is all good
	@$(MAKE) proto-all
	@$(MAKE) build
	@$(MAKE) test-unit
	@$(MAKE) lint
	@$(MAKE) docker-build

.PHONY: all

pre-push: ## Verify clean git state, run 'all', then re-verify clean
	@echo "--> Verifying working tree is clean"
	@git update-index -q --refresh
	@status=$$(git status --porcelain); if [ -n "$$status" ]; then \
		echo "Error: working tree is dirty. Commit or stash changes before running pre-push."; echo "$$status"; exit 1; \
	fi
	@$(MAKE) all
	@echo "--> Re-verifying working tree is clean"
	@git update-index -q --refresh
	@status=$$(git status --porcelain); if [ -n "$$status" ]; then \
		echo "Error: build or codegen produced changes. Please commit generated changes."; echo "$$status"; exit 1; \
	fi
	@echo "OK: pre-push checks passed."

.PHONY: pre-push

################################################################################
##                                   Build                                    ##
################################################################################

build_tags = netgo
build_tags += $(BUILD_TAGS)
build_tags := $(strip $(build_tags))

whitespace :=
empty = $(whitespace) $(whitespace)
comma := ,
build_tags_comma_sep := $(subst $(empty),$(comma),$(build_tags))

# process linker flags

# TODO: Figure out if '-s -w' is still needed 
# flags '-s -w' resolves an issue with xcode 16 and signing of go binaries
# ref: https://github.com/golang/go/issues/63997
ldflags = -X github.com/cosmos/cosmos-sdk/version.Name=$(APPNAME) \
		  -X github.com/cosmos/cosmos-sdk/version.AppName=$(APPNAME) \
		  -X github.com/cosmos/cosmos-sdk/version.Version=$(VERSION) \
		  -X github.com/cosmos/cosmos-sdk/version.Commit=$(COMMIT) \
		  -X "github.com/cosmos/cosmos-sdk/version.BuildTags=$(build_tags_comma_sep)" \
		  -s -w

ifeq ($(LINK_STATICALLY),true)
	ldflags += -linkmode=external -extldflags "-Wl,-z,muldefs -static"
endif
ldflags += $(LDFLAGS)
ldflags := $(strip $(ldflags))

BUILD_FLAGS := -tags "$(build_tags_comma_sep)" -ldflags '$(ldflags)' -trimpath

build: go.sum ## Build acmed
	@echo "Building acmed"
	go build -mod=readonly $(BUILD_FLAGS) -o $(BUILDDIR)/acmed ./cmd/acmed

# docker-build kept around as alias for backwards compat
docker-build: build-local-image
build-local-image: ## Build Docker image
	@echo "--> Building Docker image"
	docker build -t acme-chain:local .

clean: ## Clean build artifacts
	rm -rf $(BUILDDIR)/ artifacts/

.PHONY: build build-local-image docker-build clean

################################################################################
##                                   Test                                     ##
################################################################################

test-unit: ## Run unit tests
	@echo Running unit tests...
	@go test -mod=readonly -v -timeout 30m ./...

test-cover: ## Run unit tests and create coverage report
	@echo Running unit tests and creating coverage report...
	@go test -mod=readonly -v -timeout 30m -coverprofile=$(COVER_FILE) -covermode=atomic ./...
	@go tool cover -html=$(COVER_FILE) -o $(COVER_HTML_FILE)
	@rm $(COVER_FILE)

.PHONY: test-unit test-cover

################################################################################
##                                   Install                                  ##
################################################################################

install: ## Install dependencies
	@echo "--> ensure dependencies have not been modified"
	@go mod verify
	@echo "--> installing $(APPNAME)d"
	@go install $(BUILD_FLAGS) -mod=readonly ./cmd/$(APPNAME)d

.PHONY: install

################################################################################
##                                   Protobuf                                 ##
################################################################################

protoVer=0.17.1
protoImageName=ghcr.io/cosmos/proto-builder:$(protoVer)
protoImage=$(DOCKER) run --rm -v $(CURDIR):/workspace --workdir /workspace $(protoImageName)

proto-all: proto-format proto-lint proto-gen ## Generate Protobuf files

proto-gen: ## Generate Protobuf files
	@echo "Generating Protobuf files"
	@$(protoImage) sh ./scripts/protocgen.sh
	@go mod tidy

proto-format: ## Format Protobuf files
	@echo "Formatting Protobuf files"
	@$(protoImage) find ./ -name "*.proto" -exec clang-format -i {} \;

proto-lint: ## Lint Protobuf files
	@$(protoImage) buf lint --error-format=json

.PHONY: proto-gen

################################################################################
##                                   Linting                                  ##
################################################################################

golangci_lint_cmd=golangci-lint

lint: ## Run linter
	@echo "--> Running linter"
	@$(golangci_lint_cmd) run ./... --timeout 15m

lint-fix: ## Run linter and fix issues
	@echo "--> Running linter and fixing issues"
	@$(golangci_lint_cmd) run ./... --fix --timeout 15m

.PHONY: lint lint-fix

################################################################################
##                                   Single Node                              ##
################################################################################

single-node: build ## Run single node
	./scripts/single-node.sh

kill-single-node: ## Kill single node
	./scripts/kill-single-node.sh

.PHONY: single-node kill-single-node

