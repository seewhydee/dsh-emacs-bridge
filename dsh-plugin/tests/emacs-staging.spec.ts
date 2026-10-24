// dsh-emacs-bridge — Vitest specs for the multi-file Emacs package staging.
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

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync, readdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  STAGED_FILES,
  readCoreVersion,
  renderDescriptor,
  stageEmacs,
  stagedLeaf,
} from '../scripts/stage-emacs.mjs'

const roots: string[] = []

function tempRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'dsh-stage-emacs-'))
  roots.push(root)
  return root
}

afterEach(() => {
  while (roots.length > 0) rmSync(roots.pop() as string, { recursive: true, force: true })
})

const TEMPLATE = `;; -*- no-byte-compile: t -*-
(define-package "dsh-bridge" "@VERSION@"
  "Connect Emacs to a DeepSeek Harness session."
  '((emacs "29.1")))
`

function writeSource(root: string, version = '1.2.3'): { source: string; pkg: string } {
  const source = join(root, 'emacs')
  const pkg = join(root, 'dsh-plugin')
  mkdirSync(source, { recursive: true })
  mkdirSync(pkg, { recursive: true })
  writeFileSync(join(source, 'dsh-bridge.el'),
    `;;; dsh-bridge.el --- test  -*- lexical-binding: t; -*-\n;; Version: ${version}\n(defconst dsh-bridge-version "${version}")\n`)
  writeFileSync(join(source, 'dsh-bridge-extras.el'), ';;; dsh-bridge-extras.el --- test\n')
  writeFileSync(join(source, 'dsh-bridge-extras-tests.el'), ';;; tests must never ship\n')
  writeFileSync(join(source, 'dsh-bridge-pkg.el.template'), TEMPLATE)
  writeFileSync(join(pkg, 'package.json'), JSON.stringify({ version }))
  return { source, pkg }
}

describe('renderDescriptor', () => {
  it('substitutes the single version placeholder', () => {
    expect(renderDescriptor(TEMPLATE, '1.2.3')).toBe(`;; -*- no-byte-compile: t -*-
(define-package "dsh-bridge" "1.2.3"
  "Connect Emacs to a DeepSeek Harness session."
  '((emacs "29.1")))
`)
  })

  it('refuses a template without exactly one placeholder', () => {
    expect(() => renderDescriptor(';; none here\n', '1.2.3')).toThrow(/placeholder/)
    expect(() => renderDescriptor('@VERSION@ @VERSION@', '1.2.3')).toThrow(/more than one/)
  })

  it('refuses a version package.el cannot parse', () => {
    expect(() => renderDescriptor(TEMPLATE, '1.2.3-dev')).toThrow(/X\.Y\.Z/)
  })
})

describe('the checked-in version sources', () => {
  it('agrees across the core header, defconst, and package manifest', () => {
    const root = process.cwd()
    const core = readFileSync(join(root, '..', 'emacs', 'dsh-bridge.el'), 'utf8')
    const header = /^;; Version: (\S+)$/m.exec(core)?.[1]
    const defconst = /^\(defconst dsh-bridge-version "([^"]+)"/m.exec(core)?.[1]
    const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
    expect(readCoreVersion()).toBe(header)
    expect(defconst).toBe(header)
    expect(manifest.version).toBe(header)
  })
})

describe('stageEmacs', () => {
  it('recreates exactly the two libraries and the generated descriptor', () => {
    const root = tempRoot()
    const { source, pkg } = writeSource(root)
    const stale = join(pkg, 'emacs', 'dsh-bridge-1.2.2')
    mkdirSync(stale, { recursive: true })
    writeFileSync(join(stale, 'dsh-bridge.el'), 'stale\n')
    writeFileSync(join(pkg, 'emacs', 'stray.el'), 'stray\n')

    const leaf = stageEmacs({ sourceDir: source, outputBase: pkg, manifestPath: join(pkg, 'package.json') })
    expect(leaf).toBe(stagedLeaf('1.2.3', pkg))
    expect(readdirSync(leaf).sort()).toEqual([...STAGED_FILES].sort())
    expect(existsSync(stale)).toBe(false)
    expect(existsSync(join(pkg, 'emacs', 'stray.el'))).toBe(false)
    expect(existsSync(join(leaf, 'dsh-bridge-extras-tests.el'))).toBe(false)
    expect(readFileSync(join(leaf, 'dsh-bridge-pkg.el'), 'utf8'))
      .toBe(renderDescriptor(TEMPLATE, '1.2.3'))
  })

  it('refuses drift between the core header and package.json', () => {
    const root = tempRoot()
    const { source, pkg } = writeSource(root, '1.2.3')
    writeFileSync(join(pkg, 'package.json'), JSON.stringify({ version: '1.2.4' }))
    expect(() => stageEmacs({ sourceDir: source, outputBase: pkg, manifestPath: join(pkg, 'package.json') }))
      .toThrow(/package\.json is 1\.2\.4/)
  })

  it('refuses a missing optional library rather than shipping a broken leaf', () => {
    const root = tempRoot()
    const { source, pkg } = writeSource(root)
    rmSync(join(source, 'dsh-bridge-extras.el'))
    expect(() => stageEmacs({ sourceDir: source, outputBase: pkg, manifestPath: join(pkg, 'package.json') }))
      .toThrow(/missing emacs\/dsh-bridge-extras\.el/)
  })
})
