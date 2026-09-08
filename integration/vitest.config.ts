// dsh-emacs-bridge — integration-testing vitest config.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Boots one live fixture in globalSetup (a fresh temp DSH_HOME, the rendered
// overlay root-mounting the freshly built bridge + mock-LLM, the mock
// provider default, and a pinned loopback port). The fixture facts are
// provided to specs via `inject('fixture')`. `make integration-test` runs this
// through `dsh-plugin/node_modules`'s vitest (the sandbox here cannot `pnpm
// install` into `integration/`; a normal environment uses `pnpm install` in
// `integration/` and `pnpm test`). See integration/README.md.

import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'

const here = dirname(fileURLToPath(import.meta.url))

export default defineConfig({
  root: here,
  test: {
    // Paths below are relative to `root` (= integration/).
    include: ['tests/**/*.spec.ts'],
    // A fixture boot (fresh profile auto-init + plugin mount) is genuinely slow.
    testTimeout: 60000,
    hookTimeout: 120000,
    globalSetup: ['./tests/global-setup.mjs'],
    // Integration suites drive one shared, stateful host; keep them serial so a
    // hanging ask-user turn from one spec cannot race another.
    fileParallelism: false,
  },
})
