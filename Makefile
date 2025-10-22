.POSIX:

# utility variables
space := $(subst ,, )
mydir := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))

# Set local cargo directory (for binaries)
# note: $(mydir) ends with '/'
CARGO_DIR := $(mydir).cargo

# add local Cargo install path (only once)
PATH := $(subst :${CARGO_DIR}/bin,,$(PATH)):${CARGO_DIR}/bin
# add users home Cargo install path (only once)
PATH := $(subst :${HOME}/.cargo/bin,,$(PATH)):${HOME}/.cargo/bin
# add nix build result path (only once)
PATH := $(subst :$(mydir)/result/bin,,$(PATH)):$(mydir)/result/bin
# use custom PATH in all shell processes
# escape spaces
SHELL := env PATH=$(subst $(space),\$(space),$(PATH)) $(shell which bash)

# use custom Cargo config file for each invocation
cargo := cargo --config ${CARGO_DIR}/config.toml

all: help

.PHONY: init
init: ## initialize repository (idempotent operation)
	for gh in `find .githooks/ -type f`; do \
		ln -sf "../../$${gh}" .git/hooks/; \
	done

.PHONY: smart-contract-test
smart-contract-test: # forge test smart contracts
	$(MAKE) -C ethereum/contracts/ sc-test