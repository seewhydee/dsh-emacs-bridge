// dsh-emacs-bridge — Vitest specs for the Emacs batch-install logic.
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

import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  buildEmacsInstallForm,
  buildEmacsStatusForm,
  classifyEmacsInstall,
  classifyEmacsProbeOutput,
  classifyEmacsVersionProbe,
  elispString,
  emacsVersionMeetsFloor,
  normalizeEmacsCommand,
  parseEmacsVersionOutput,
  resolveBundledElisp,
} from '../src/logic.ts'

describe('normalizeEmacsCommand', () => {
  it('falls back to plain emacs for nil, empty, and blank values', () => {
    expect(normalizeEmacsCommand(undefined)).toEqual(['emacs'])
    expect(normalizeEmacsCommand(null)).toEqual(['emacs'])
    expect(normalizeEmacsCommand('')).toEqual(['emacs'])
    expect(normalizeEmacsCommand('   \t  ')).toEqual(['emacs'])
    expect(normalizeEmacsCommand([])).toEqual(['emacs'])
  })

  it('returns an array verbatim', () => {
    expect(normalizeEmacsCommand(['/opt/my emacs/bin/emacs', '-Q']))
      .toEqual(['/opt/my emacs/bin/emacs', '-Q'])
  })

  it('splits a string on whitespace', () => {
    expect(normalizeEmacsCommand('emacs -l ~/.emacs.d/init.el'))
      .toEqual(['emacs', '-l', '~/.emacs.d/init.el'])
    expect(normalizeEmacsCommand('emacs\t--batch\n--eval')).toEqual(['emacs', '--batch', '--eval'])
  })

  it('honors single quotes literally', () => {
    expect(normalizeEmacsCommand("emacs -l '/path with spaces/init.el'"))
      .toEqual(['emacs', '-l', '/path with spaces/init.el'])
    expect(normalizeEmacsCommand("emacs 'a\\b'")) // backslash stays inside single quotes
      .toEqual(['emacs', 'a\\b'])
    expect(normalizeEmacsCommand("''")).toEqual(['']) // an empty quoted word is a real argument
  })

  it('honors double quotes with backslash escapes', () => {
    expect(normalizeEmacsCommand('emacs "/path with spaces/init.el"'))
      .toEqual(['emacs', '/path with spaces/init.el'])
    expect(normalizeEmacsCommand('emacs "a\\"b"')).toEqual(['emacs', 'a"b'])
    expect(normalizeEmacsCommand('emacs "a\\\\b"')).toEqual(['emacs', 'a\\b'])
    // A backslash before anything else survives inside double quotes.
    expect(normalizeEmacsCommand('emacs "a\\nb"')).toEqual(['emacs', 'a\\nb'])
  })

  it('honors backslash escapes outside quotes', () => {
    expect(normalizeEmacsCommand('emacs a\\ b')).toEqual(['emacs', 'a b'])
    expect(normalizeEmacsCommand('emacs a\\\\b')).toEqual(['emacs', 'a\\b'])
  })

  it('mixes quoted and unquoted fragments inside one word', () => {
    expect(normalizeEmacsCommand('emacs a"b c"d')).toEqual(['emacs', 'ab cd'])
  })

  it('tolerates an unterminated quote', () => {
    expect(normalizeEmacsCommand('emacs "unterminated')).toEqual(['emacs', 'unterminated'])
    expect(normalizeEmacsCommand("emacs 'unterminated")).toEqual(['emacs', 'unterminated'])
  })
})

describe('elispString', () => {
  it('wraps a plain string in quotes', () => {
    expect(elispString('/home/user/.emacs.d/elpa/')).toBe('"/home/user/.emacs.d/elpa/"')
  })

  it('escapes double quotes and backslashes', () => {
    expect(elispString('a"b')).toBe('"a\\"b"')
    expect(elispString('C:\\Users\\me\\emacs')).toBe('"C:\\\\Users\\\\me\\\\emacs"')
  })

  it('escapes newlines and other control characters', () => {
    expect(elispString('a\nb')).toBe('"a\\nb"')
    expect(elispString('a\tb')).toBe('"a\\tb"')
    expect(elispString('a\rb')).toBe('"a\\rb"')
    // A control character without a named escape prints as exactly three
    // octal digits, so a following digit cannot join the escape.
    expect(elispString('a3')).toBe('"a\\0013"')
  })
})

describe('buildEmacsStatusForm', () => {
  it('embeds the prin1-quoted bundled version', () => {
    expect(buildEmacsStatusForm('0.17.0')).toBe(
      `(progn (require 'package) (prin1 (list (not (null (package-installed-p 'dsh-bridge))) (not (null (package-installed-p 'dsh-bridge (version-to-list "0.17.0")))) (expand-file-name package-user-dir))))`)
  })
})

describe('buildEmacsInstallForm', () => {
  it('builds the fixed install form with a prin1-quoted path', () => {
    expect(buildEmacsInstallForm('/opt/dsh/emacs/dsh-bridge.el')).toBe(
      `(progn (require 'package) (package-install-file "/opt/dsh/emacs/dsh-bridge.el"))`)
  })

  it('quotes a path with spaces, quotes, and backslashes', () => {
    expect(buildEmacsInstallForm('/opt/my "dsh"/emacs/dsh-bridge.el')).toBe(
      `(progn (require 'package) (package-install-file "/opt/my \\"dsh\\"/emacs/dsh-bridge.el"))`)
  })
})

describe('parseEmacsVersionOutput', () => {
  it('parses released versions', () => {
    expect(parseEmacsVersionOutput('GNU Emacs 29.1')).toEqual({ major: 29, minor: 1 })
    expect(parseEmacsVersionOutput('GNU Emacs 28.2')).toEqual({ major: 28, minor: 2 })
  })

  it('tolerates extra version components and trailing lines', () => {
    expect(parseEmacsVersionOutput('GNU Emacs 30.0.50')).toEqual({ major: 30, minor: 0 })
    expect(parseEmacsVersionOutput('GNU Emacs 29.1\nCopyright (C) 2024 Free Software Foundation'))
      .toEqual({ major: 29, minor: 1 })
  })

  it('returns null for unrecognized output', () => {
    expect(parseEmacsVersionOutput('')).toBeNull()
    expect(parseEmacsVersionOutput('emacs 29.1')).toBeNull()
    expect(parseEmacsVersionOutput('GNU Emacs')).toBeNull()
    expect(parseEmacsVersionOutput('not an emacs at all')).toBeNull()
  })
})

describe('emacsVersionMeetsFloor', () => {
  it('compares against the 29.1 default floor', () => {
    expect(emacsVersionMeetsFloor({ major: 29, minor: 1 })).toBe(true)
    expect(emacsVersionMeetsFloor({ major: 29, minor: 4 })).toBe(true)
    expect(emacsVersionMeetsFloor({ major: 30, minor: 0 })).toBe(true)
    expect(emacsVersionMeetsFloor({ major: 29, minor: 0 })).toBe(false)
    expect(emacsVersionMeetsFloor({ major: 28, minor: 2 })).toBe(false)
  })

  it('honors an explicit floor', () => {
    expect(emacsVersionMeetsFloor({ major: 28, minor: 2 }, { major: 28, minor: 2 })).toBe(true)
    expect(emacsVersionMeetsFloor({ major: 28, minor: 1 }, { major: 28, minor: 2 })).toBe(false)
  })
})

describe('classifyEmacsProbeOutput', () => {
  it('parses every t/nil combination', () => {
    expect(classifyEmacsProbeOutput('(t t "/home/user/.emacs.d/elpa/")')).toEqual({
      installed: true, atLeastBundled: true, packageUserDir: '/home/user/.emacs.d/elpa/',
    })
    expect(classifyEmacsProbeOutput('(t nil "/home/user/.emacs.d/elpa/")')).toEqual({
      installed: true, atLeastBundled: false, packageUserDir: '/home/user/.emacs.d/elpa/',
    })
    expect(classifyEmacsProbeOutput('(nil nil "/home/user/.emacs.d/elpa/")')).toEqual({
      installed: false, atLeastBundled: false, packageUserDir: '/home/user/.emacs.d/elpa/',
    })
  })

  it('parses a path with spaces and escaped characters', () => {
    expect(classifyEmacsProbeOutput('(t nil "/home/my user/.emacs.d/elpa/")'))
      .toEqual({
        installed: true, atLeastBundled: false, packageUserDir: '/home/my user/.emacs.d/elpa/',
      })
    expect(classifyEmacsProbeOutput('(nil nil "C:\\\\Users\\\\me\\\\elpa\\\\")'))
      .toEqual({
        installed: false, atLeastBundled: false, packageUserDir: 'C:\\Users\\me\\elpa\\',
      })
  })

  it('finds the list amid surrounding output', () => {
    const noisy = 'Loading /etc/emacs/site-start.el...\n(t nil "/home/user/.emacs.d/elpa/")'
    expect(classifyEmacsProbeOutput(noisy)).toEqual({
      installed: true, atLeastBundled: false, packageUserDir: '/home/user/.emacs.d/elpa/',
    })
  })

  it('returns null for unparseable output', () => {
    expect(classifyEmacsProbeOutput('')).toBeNull()
    expect(classifyEmacsProbeOutput('nil')).toBeNull()
    expect(classifyEmacsProbeOutput('(t nil)')).toBeNull()
    expect(classifyEmacsProbeOutput('(maybe no "/path/")')).toBeNull()
  })
})

describe('resolveBundledElisp', () => {
  const dirs: string[] = []

  function makeDir(): string {
    const dir = mkdtempSync(join(tmpdir(), 'dsh-bundled-elisp-'))
    dirs.push(dir)
    return dir
  }

  function placeElisp(dir: string): string {
    const emacsDir = join(dir, 'emacs')
    mkdirSync(emacsDir, { recursive: true })
    const file = join(emacsDir, 'dsh-bridge.el')
    writeFileSync(file, ';;; dsh-bridge.el\n')
    return file
  }

  afterEach(() => {
    while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
  })

  it('finds the packed-tarball layout (emacs/ inside the package)', () => {
    const packageDir = makeDir()
    const file = placeElisp(packageDir)
    expect(resolveBundledElisp(packageDir)).toBe(file)
  })

  it('finds the source-checkout layout (../emacs/ beside the package)', () => {
    const checkout = makeDir()
    const file = placeElisp(checkout)
    const packageDir = join(checkout, 'dsh-plugin')
    mkdirSync(packageDir)
    expect(resolveBundledElisp(packageDir)).toBe(file)
  })

  it('prefers the in-package candidate when both exist', () => {
    const checkout = makeDir()
    placeElisp(checkout)
    const packageDir = join(checkout, 'dsh-plugin')
    mkdirSync(packageDir)
    const inPackage = placeElisp(packageDir)
    expect(resolveBundledElisp(packageDir)).toBe(inPackage)
  })

  it('returns null when neither candidate exists', () => {
    expect(resolveBundledElisp(makeDir())).toBeNull()
  })
})

describe('classifyEmacsVersionProbe', () => {
  it('reports a missing Emacs from a spawn ENOENT', () => {
    expect(classifyEmacsVersionProbe({ kind: 'spawn-error', error: 'spawn emacs ENOENT', code: 'ENOENT' }))
      .toEqual({ ok: false, problem: 'emacs-not-found' })
  })

  it('reports unknown versions for other spawn failures, timeouts, and garbage', () => {
    expect(classifyEmacsVersionProbe({ kind: 'spawn-error', error: 'spawn emacs EACCES', code: 'EACCES' }))
      .toEqual({ ok: false, problem: 'emacs-version-unknown' })
    expect(classifyEmacsVersionProbe({ kind: 'timeout', output: '' }))
      .toEqual({ ok: false, problem: 'emacs-version-unknown' })
    expect(classifyEmacsVersionProbe({ kind: 'ok', exitStatus: 1, output: 'usage: emacs ...' }))
      .toEqual({ ok: false, problem: 'emacs-version-unknown' })
  })

  it('reports an Emacs below the floor, carrying its version', () => {
    expect(classifyEmacsVersionProbe({ kind: 'ok', exitStatus: 0, output: 'GNU Emacs 28.2' }))
      .toEqual({ ok: false, problem: 'emacs-too-old', version: { major: 28, minor: 2 } })
  })

  it('accepts an Emacs at or above the floor', () => {
    expect(classifyEmacsVersionProbe({ kind: 'ok', exitStatus: 0, output: 'GNU Emacs 29.1' }))
      .toEqual({ ok: true, version: { major: 29, minor: 1 } })
  })
})

describe('classifyEmacsInstall', () => {
  it('judges only by exit status, never by output', () => {
    // The batch install prints a known harmless free-variable warning while
    // exiting 0; output text must not flip the verdict.
    expect(classifyEmacsInstall({
      kind: 'ok', exitStatus: 0,
      output: 'Warning: reference to free variable ‘dsh-bridge--prompt-header-line-format’',
    })).toEqual({ ok: true })
    expect(classifyEmacsInstall({ kind: 'ok', exitStatus: 1, output: '' }))
      .toEqual({ ok: false, problem: 'nonzero-exit' })
    expect(classifyEmacsInstall({ kind: 'ok', exitStatus: null, output: '' }))
      .toEqual({ ok: false, problem: 'nonzero-exit' })
  })

  it('maps spawn errors and timeouts', () => {
    expect(classifyEmacsInstall({ kind: 'spawn-error', error: 'spawn emacs ENOENT' }))
      .toEqual({ ok: false, problem: 'spawn-failed' })
    expect(classifyEmacsInstall({ kind: 'timeout', output: 'partial' }))
      .toEqual({ ok: false, problem: 'timed-out' })
  })
})
