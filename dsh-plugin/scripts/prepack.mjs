// dsh-emacs-bridge — npm `prepack' hook for the DSH plugin package: stage the
// Emacs half beside the built bundles, and refuse to pack a package whose
// version or entry points are not the ones a release must carry.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
// npm, pnpm, and `make release' all run this before packing or publishing the
// package directory, so `files' can name emacs/dsh-bridge.el and be telling the
// truth: the elisp the Plugins-page card installs is carried by the plugin
// tarball rather than fetched from anywhere.  It deliberately does not build —
// `make release' owns the build, and the Makefile documents why invoking
// `pnpm build' here could fail exactly where releases are cut.

import { copyFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const packageDir = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const source = resolve(packageDir, '..', 'emacs', 'dsh-bridge.el')
const staged = join(packageDir, 'emacs', 'dsh-bridge.el')

/** Stage the Emacs half and assert the package is the one a release publishes. */
function stage() {
  const { version } = JSON.parse(readFileSync(join(packageDir, 'package.json'), 'utf8'))
  if (typeof version !== 'string' || version === '') {
    throw new Error('dsh-plugin/package.json has no version to check the Emacs half against')
  }
  if (!existsSync(source)) {
    throw new Error(`missing ${source}; pack from a checkout of the whole dsh-emacs-bridge repository`)
  }
  const elisp = readFileSync(source, 'utf8')
  // The same three-way agreement `make package' enforces, repeated here because
  // a direct `pnpm pack' or `npm publish' never runs the Makefile — and a drift
  // that reaches the registry is permanent.
  const header = /^;; Version: (\S+)$/m.exec(elisp)?.[1]
  if (header !== version) {
    throw new Error(`emacs/dsh-bridge.el has Version ${header ?? '(none)'}, but this package is ${version}`)
  }
  const defconst = /^\(defconst dsh-bridge-version "([^"]+)"/m.exec(elisp)?.[1]
  if (defconst !== version) {
    throw new Error(`the dsh-bridge-version defconst is ${defconst ?? '(none)'}, but this package is ${version}`)
  }
  // A `files' entry naming a missing path is dropped silently, so without this
  // a pack from an unbuilt tree ships a package with no loadable entry point.
  for (const built of ['lib/index.js', 'lib/client.js']) {
    if (!existsSync(join(packageDir, built))) {
      throw new Error(`${built} is missing; run "make build" before packing`)
    }
  }
  mkdirSync(dirname(staged), { recursive: true })
  copyFileSync(source, staged)
  console.log(`prepack: staged emacs/dsh-bridge.el (version ${version})`)
}

try {
  stage()
} catch (error) {
  console.error(`prepack: ${error instanceof Error ? error.message : String(error)}`)
  process.exitCode = 1
}
