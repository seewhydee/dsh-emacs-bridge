// dsh-emacs-bridge — stage the Emacs half of the plugin package.
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
// Both distribution paths stage the same clean leaf:
//
//   dsh-plugin/emacs/dsh-bridge-<version>/
//     dsh-bridge.el
//     dsh-bridge-extras.el
//     dsh-bridge-pkg.el
//
// `make build' invokes this helper through `pnpm build' (or the Makefile's
// direct-tsdown fallback), and the package's `prepack' hook invokes it again
// idempotently, so a `link:' development install and a packed registry install
// carry equivalent content.  The directory is recreated on every run: a stale
// leaf from an older version, a test file, or an editor backup must never be
// swept into a package.  It deliberately does not build the TypeScript
// bundles; the caller owns that.

import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const packageDir = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const sourceDir = resolve(packageDir, '..', 'emacs')
const templatePath = join(sourceDir, 'dsh-bridge-pkg.el.template')
const versionPlaceholder = '@VERSION@'

/** The three source files a staged leaf carries, in package-list order. */
export const STAGED_FILES = ['dsh-bridge.el', 'dsh-bridge-extras.el', 'dsh-bridge-pkg.el']

/** Read the version from the single source of truth, the core library header. */
export function readCoreVersion(source = join(sourceDir, 'dsh-bridge.el')) {
  const text = readFileSync(source, 'utf8')
  const match = /^;; Version: (\S+)$/m.exec(text)
  if (match === null) throw new Error(`${source} has no Version header`)
  return match[1]
}

/** Render the package descriptor from the checked-in template. */
export function renderDescriptor(template, version) {
  if (!template.includes(versionPlaceholder)) {
    throw new Error(`emacs/dsh-bridge-pkg.el.template has no ${versionPlaceholder} placeholder`)
  }
  if (template.split(versionPlaceholder).length !== 2) {
    throw new Error(`emacs/dsh-bridge-pkg.el.template has more than one ${versionPlaceholder} placeholder`)
  }
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    throw new Error(`refusing to render a non-X.Y.Z version: ${version}`)
  }
  return template.replace(versionPlaceholder, version)
}

/** The versioned leaf directory a package install consumes. */
export function stagedLeaf(version, base = packageDir) {
  return join(base, 'emacs', `dsh-bridge-${version}`)
}

/**
 * Recreate the staged Emacs package directory and fill it with exactly the
 * core library, the optional extras library, and the generated descriptor.
 * @returns the staged leaf directory.
 */
export function stageEmacs(options = {}) {
  const source = options.sourceDir ?? sourceDir
  const outputBase = options.outputBase ?? packageDir
  const manifestPath = options.manifestPath ?? join(packageDir, 'package.json')
  const version = readCoreVersion(join(source, 'dsh-bridge.el'))
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
  if (manifest.version !== version) {
    throw new Error(`dsh-plugin/package.json is ${manifest.version}, but emacs/dsh-bridge.el is ${version}`)
  }
  const core = readFileSync(join(source, 'dsh-bridge.el'), 'utf8')
  const defconst = /^\(defconst dsh-bridge-version "([^"]+)"/m.exec(core)?.[1]
  if (defconst !== version) {
    throw new Error(`the dsh-bridge-version defconst is ${defconst ?? '(none)'}, but the header is ${version}`)
  }
  for (const name of ['dsh-bridge.el', 'dsh-bridge-extras.el']) {
    if (!existsSync(join(source, name))) {
      throw new Error(`missing emacs/${name}; pack from a checkout of the whole dsh-emacs-bridge repository`)
    }
  }
  const descriptor = renderDescriptor(readFileSync(join(source, 'dsh-bridge-pkg.el.template'), 'utf8'), version)
  const leaf = stagedLeaf(version, outputBase)
  const parent = join(outputBase, 'emacs')
  const temporary = join(outputBase, `.emacs-stage-${process.pid}`)
  // Populate a sibling first, so a failed copy leaves the installable tree
  // untouched. Replacing the parent also drops old versions and stray files.
  rmSync(temporary, { recursive: true, force: true })
  try {
    const temporaryLeaf = join(temporary, `dsh-bridge-${version}`)
    mkdirSync(temporaryLeaf, { recursive: true })
    for (const name of ['dsh-bridge.el', 'dsh-bridge-extras.el']) {
      copyFileSync(join(source, name), join(temporaryLeaf, name))
    }
    writeFileSync(join(temporaryLeaf, 'dsh-bridge-pkg.el'), descriptor)
    rmSync(parent, { recursive: true, force: true })
    renameSync(temporary, parent)
  } finally {
    rmSync(temporary, { recursive: true, force: true })
  }
  if (!options.quiet) {
    console.log(`stage-emacs: staged emacs/dsh-bridge-${version} (${STAGED_FILES.length} files)`)
  }
  return leaf
}

// `--descriptor' prints the descriptor without touching the staged tree; the
// Makefile compares it with its own Node-free sed rendering in `make test'.
if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.includes('--descriptor')) {
      const version = readCoreVersion()
      process.stdout.write(renderDescriptor(readFileSync(templatePath, 'utf8'), version))
    } else {
      stageEmacs()
    }
  } catch (error) {
    console.error(`stage-emacs: ${error instanceof Error ? error.message : String(error)}`)
    process.exitCode = 1
  }
}
