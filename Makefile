# Build rules for dsh-emacs-bridge.
#
# `make package` stages a pure-elisp Emacs package tar
# (dsh-bridge-<version>.tar: dsh-bridge.el plus a generated
# dsh-bridge-pkg.el).  Install it with `M-x package-install-file'.
# `make' with no target builds the plugin bundles too; `make package'
# alone needs no Node toolchain.
#
# `make release' additionally packs the built DSH plugin
# (dsh-emacs-bridge-<version>.tgz, via `pnpm pack') and stages both
# artifacts in .release/, ready to attach to a GitHub release.  The
# plugin tarball carries the Emacs half too: emacs/dsh-bridge.el is
# staged into dsh-plugin/emacs/ at pack time so `make package' stays
# pure-elisp and Node-free.  Publishing is a separate, deliberate step;
# see "Release procedure" in AGENTS.md.
#
# The package version's single source of truth is the Version header of
# emacs/dsh-bridge.el.  Two other copies must agree — the
# `dsh-bridge-version' defconst (the runtime staleness comparison) and
# dsh-plugin/package.json (what the packed plugin reports) — and the tar
# recipe refuses to build when either drifts.

VERSION := $(shell sed -n 's/^;; Version: //p' emacs/dsh-bridge.el | head -1)

TAR   := dsh-bridge-$(VERSION).tar
STAGE := .package/dsh-bridge-$(VERSION)

PLUGIN_SRC := $(wildcard dsh-plugin/src/*.ts dsh-plugin/src/client/*.ts dsh-plugin/src/client/*.tsx)

.PHONY: all build package release test clean no-stale-elc

all: build package

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

$(TAR): emacs/dsh-bridge.el dsh-plugin/package.json
	@grep -q '(defconst dsh-bridge-version "$(VERSION)"' emacs/dsh-bridge.el || \
	  { echo "error: dsh-bridge-version defconst disagrees with the Version header ($(VERSION))"; exit 1; }
	@grep -q '"version": "$(VERSION)"' dsh-plugin/package.json || \
	  { echo "error: dsh-plugin/package.json version disagrees with the Version header ($(VERSION))"; exit 1; }
	rm -rf .package
	mkdir -p $(STAGE)
	cp emacs/dsh-bridge.el $(STAGE)/
	printf '%s\n' \
	  ';; -*- no-byte-compile: t -*-' \
	  '(define-package "dsh-bridge" "$(VERSION)"' \
	  '  "Connect Emacs to a DeepSeek Harness session."' \
	  '  (quote ((emacs "29.1"))))' \
	  > $(STAGE)/dsh-bridge-pkg.el
	tar --format=ustar -cf $@ -C .package dsh-bridge-$(VERSION)

RELEASE_DIR := .release
PLUGIN_TGZ := dsh-emacs-bridge-$(VERSION).tgz

# Stage both release artifacts in .release/.  The plugin tarball also
# carries the Emacs half: emacs/dsh-bridge.el is staged into the package
# before `pnpm pack' honors the `files' list, so the Plugins-page
# install button has the elisp at hand.  The copy is a build output
# (gitignored, removed by `make clean'); the assertion after packing
# fails the release rather than ship a plugin whose button cannot work.
# Publishing the stage is a separate step (AGENTS.md).
release: build package
	rm -rf $(RELEASE_DIR)
	mkdir -p $(RELEASE_DIR)
	rm -rf dsh-plugin/emacs
	mkdir -p dsh-plugin/emacs
	cp emacs/dsh-bridge.el dsh-plugin/emacs/
	cd dsh-plugin && pnpm pack
	tar -tzf dsh-plugin/$(PLUGIN_TGZ) | grep -qx 'package/emacs/dsh-bridge.el' || \
	  { echo "error: packed plugin tarball is missing emacs/dsh-bridge.el"; exit 1; }
	mv dsh-plugin/$(PLUGIN_TGZ) $(RELEASE_DIR)/
	cp $(TAR) $(RELEASE_DIR)/

test: no-stale-elc
	cd dsh-plugin && pnpm test
	emacs --batch -L emacs -l emacs/dsh-bridge-tests.el \
	      -f ert-run-tests-batch-and-exit

# Emacs loads a byte-compiled file in preference to newer source, so an
# emacs/*.elc left from an earlier compile makes the Emacs test layers grade
# code that is not in the tree.  Any target that boots Emacs against -L emacs
# must grade source, so drop the artifacts outright: an mtime comparison only
# guesses at staleness, and a .elc copied in from another tree — or compiled
# from an uncommitted buffer — can compare as fresh.
no-stale-elc:
	rm -f emacs/*.elc

# Integration-testing framework (integration/): boots a live DSH host with the
# freshly built plugin and a mock LLM, then runs the Vitest seam specs and the
# batch Emacs end-to-end layer. Separate from `make test`, which stays
# unit-only and fast. The framework needs a working `dsh` (on PATH, or via
# DSH_BRIDGE_DSH_COMMAND) and, for a checkout dsh, DSH_BRIDGE_FIXTURE_CWD —
# see integration/README.md.
integration-test: build no-stale-elc
	cd integration && { test -d node_modules || pnpm install; }
	cd integration && pnpm test
	emacs --batch -L emacs -L integration -l integration/dsh-bridge-it.el \
	      -f ert-run-tests-batch-and-exit

clean:
	rm -rf .package .release dsh-bridge-*.tar dsh-plugin/dsh-emacs-bridge-*.tgz dsh-plugin/emacs
