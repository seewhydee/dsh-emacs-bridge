# Build rules for the dsh-emacs-bridge package tar.
#
# `make package` builds the DSH plugin bundles and stages a multi-file
# Emacs package tar (dsh-bridge-<version>.tar) containing the Emacs
# package, a generated dsh-bridge-pkg.el, and the prebuilt plugin as
# payload.  Install it with `M-x package-install-file', then run
# `M-x dsh-bridge-install-plugin' to install the plugin into DSH.
#
# The package version's single source of truth is the Version header of
# emacs/dsh-bridge.el.  It is stamped into the staged plugin manifest so
# the installed payload identifies itself and version bumps force pnpm to
# refresh the copied plugin on re-install.  Two other copies must agree —
# the `dsh-bridge-version' defconst (the runtime staleness comparison) and
# the source plugin manifest (what a source-checkout install reports) —
# and the tar recipe refuses to build when either drifts.

VERSION := $(shell sed -n 's/^;; Version: //p' emacs/dsh-bridge.el | head -1)

TAR   := dsh-bridge-$(VERSION).tar
STAGE := .package/dsh-bridge-$(VERSION)

PLUGIN_SRC := $(wildcard dsh-plugin/src/*.ts dsh-plugin/src/client/*.ts dsh-plugin/src/client/*.tsx)

.PHONY: all build package test clean

all: package

build: dsh-plugin/lib/index.js dsh-plugin/lib/client.js

dsh-plugin/node_modules:
	cd dsh-plugin && pnpm install

# pnpm refuses to run scripts against a node_modules it does not
# recognize (e.g. a symlink to the harness checkout) without a TTY;
# fall back to invoking the builders directly.  node_modules is an
# order-only prerequisite so its mtime alone never forces a rebuild.
dsh-plugin/lib/index.js dsh-plugin/lib/client.js: $(PLUGIN_SRC) dsh-plugin/tsdown.config.ts dsh-plugin/tsdown.client.config.ts | dsh-plugin/node_modules
	cd dsh-plugin && { pnpm build || { \
	  echo "pnpm build failed; invoking tsdown directly"; \
	  ./node_modules/.bin/tsdown && ./node_modules/.bin/tsdown --config tsdown.client.config.ts; \
	}; }

package: $(TAR)

$(TAR): build emacs/dsh-bridge.el dsh-plugin/package.json dsh-plugin/cordis.patch.yml
	@grep -q '(defconst dsh-bridge-version "$(VERSION)"' emacs/dsh-bridge.el || \
	  { echo "error: dsh-bridge-version defconst disagrees with the Version header ($(VERSION))"; exit 1; }
	@grep -q '"version": "$(VERSION)"' dsh-plugin/package.json || \
	  { echo "error: dsh-plugin/package.json version disagrees with the Version header ($(VERSION))"; exit 1; }
	rm -rf .package
	mkdir -p $(STAGE)/dsh-plugin/lib
	cp emacs/dsh-bridge.el $(STAGE)/
	cp dsh-plugin/package.json dsh-plugin/cordis.patch.yml $(STAGE)/dsh-plugin/
	sed -i 's/"version": "[^"]*"/"version": "$(VERSION)"/' $(STAGE)/dsh-plugin/package.json
	cp dsh-plugin/lib/index.js dsh-plugin/lib/client.js $(STAGE)/dsh-plugin/lib/
	printf '%s\n' \
	  ';; -*- no-byte-compile: t -*-' \
	  '(define-package "dsh-bridge" "$(VERSION)"' \
	  '  "Connect Emacs to a DeepSeek Harness session."' \
	  '  (quote ((emacs "29.1"))))' \
	  > $(STAGE)/dsh-bridge-pkg.el
	tar --format=ustar -cf $@ -C .package dsh-bridge-$(VERSION)

test:
	cd dsh-plugin && pnpm test
	emacs --batch -L emacs -l emacs/dsh-bridge-tests.el \
	      -f ert-run-tests-batch-and-exit

# Integration-testing framework (integration/): boots a live DSH host with the
# freshly built plugin and a mock LLM, then runs the Vitest seam specs and the
# batch Emacs end-to-end layer. Separate from `make test`, which stays
# unit-only and fast. The framework needs a working `dsh` (on PATH, or via
# DSH_BRIDGE_DSH_COMMAND) and, for a checkout dsh, DSH_BRIDGE_FIXTURE_CWD —
# see integration/README.md.
integration-test: build
	cd integration && { test -d node_modules || pnpm install; }
	cd integration && pnpm test
	emacs --batch -L emacs -L integration -l integration/dsh-bridge-it.el \
	      -f ert-run-tests-batch-and-exit

clean:
	rm -rf .package dsh-bridge-*.tar
