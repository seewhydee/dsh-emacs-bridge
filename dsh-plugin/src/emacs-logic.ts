// dsh-emacs-bridge — pure Emacs batch-install logic.
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

import { existsSync } from 'node:fs'
import { join } from 'node:path'

// ---- Emacs batch install (the /emacs and /emacs/install routes) ----

/** The Emacs command with every fallback applied: a spawn-ready argv. */
export const EMACS_DEFAULT_COMMAND = 'emacs'

/**
 * Whitespace-split TEXT shell-style, the semantics of elisp
 * `split-string-and-unquote`: single quotes group literally, double quotes
 * group with backslash escaping only `"` and `\`, and a backslash outside
 * quotes escapes the next character. An unterminated quote runs to the end
 * of input rather than failing — the command came from the profile owner's
 * own config, so leniency beats a route error.
 */
function splitShellWords(text: string): string[] {
  const words: string[] = []
  let current = ''
  // A quote can open a word that stays empty ('' is a real, empty argument),
  // so "is there a token" cannot be read off `current` alone.
  let inWord = false
  let i = 0
  while (i < text.length) {
    const ch = text[i] as string
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\f' || ch === '\v') {
      if (inWord) { words.push(current); current = ''; inWord = false }
      i += 1
    } else if (ch === "'") {
      inWord = true
      i += 1
      while (i < text.length && text[i] !== "'") { current += text[i]; i += 1 }
      i += 1
    } else if (ch === '"') {
      inWord = true
      i += 1
      while (i < text.length && text[i] !== '"') {
        if (text[i] === '\\' && i + 1 < text.length
          && (text[i + 1] === '"' || text[i + 1] === '\\')) {
          current += text[i + 1]
          i += 2
        } else {
          current += text[i]
          i += 1
        }
      }
      i += 1
    } else if (ch === '\\') {
      inWord = true
      if (i + 1 < text.length) { current += text[i + 1]; i += 2 } else { i += 1 }
    } else {
      inWord = true
      current += ch
      i += 1
    }
  }
  if (inWord) words.push(current)
  return words
}

/**
 * Normalize the configured `emacsCommand` to an argv. A string is split
 * shell-style (so `"emacs -l ~/.emacs.d/init.el"` works as users of the old
 * `dsh-bridge-dsh-command` expect); a list is verbatim (the form for paths
 * with spaces); nil, blank, and empty fall back to plain `emacs`.
 */
export function normalizeEmacsCommand(value: string | readonly string[] | null | undefined): string[] {
  if (typeof value === 'string') {
    const words = splitShellWords(value)
    return words.length === 0 ? [EMACS_DEFAULT_COMMAND] : words
  }
  if (Array.isArray(value)) return value.length === 0 ? [EMACS_DEFAULT_COMMAND] : [...value]
  return [EMACS_DEFAULT_COMMAND]
}

/**
 * prin1-style quoting of S for interpolation into an elisp form. The batch
 * forms embed the bundled elisp's path, which is whatever directory the user
 * installed the profile into — quotes, backslashes, and newlines are all
 * legal there, so string concatenation would be an injection surface.
 * Control characters without a named escape print as exactly three octal
 * digits: the elisp reader consumes at most three, so a digit following the
 * escape can never join it.
 */
export function elispString(s: string): string {
  let out = '"'
  for (const ch of s) {
    const code = ch.codePointAt(0) as number
    if (ch === '\\') out += '\\\\'
    else if (ch === '"') out += '\\"'
    else if (ch === '\n') out += '\\n'
    else if (ch === '\t') out += '\\t'
    else if (ch === '\r') out += '\\r'
    else if (code < 0x20 || code === 0x7f) out += `\\${code.toString(8).padStart(3, '0')}`
    else out += ch
  }
  return `${out}"`
}

/**
 * The batch status probe: print ONE list of (installed-p at-least-bundled-p
 * package-user-dir), the three facts the plugin-page card renders. The two
 * `package-installed-p` calls distinguish installed/outdated/absent without
 * depending on `package-alist`'s shape; `not (null …)` forces the booleans
 * to print as exactly `t`/`nil`. The user directory is evaluated, never
 * hardcoded: XDG setups are not under `~/.emacs.d`, and a user-supplied init
 * may move it anywhere.
 */
export function buildEmacsStatusForm(bundledVersion: string): string {
  return `(progn (require 'package) (prin1 (list (not (null (package-installed-p 'dsh-bridge))) (not (null (package-installed-p 'dsh-bridge (version-to-list ${elispString(bundledVersion)})))) (expand-file-name package-user-dir))))`
}

/**
 * The batch install form. Fixed shape; only the path varies, prin1-quoted.
 */
export function buildEmacsInstallForm(bundledPath: string): string {
  return `(progn (require 'package) (package-install-file ${elispString(bundledPath)}))`
}

/** An Emacs version, truncated to the components the 29.1 floor compares. */
export interface EmacsVersion {
  major: number
  minor: number
}

/**
 * The package's declared Emacs floor (`dsh-bridge.el` requires 29.1).
 * package.el enforces `Package-Requires` itself, but the failure reads badly
 * without a preflight naming the actual problem.
 */
export const EMACS_VERSION_FLOOR: EmacsVersion = { major: 29, minor: 1 }

/**
 * Parse the first line of `emacs --version` ("GNU Emacs 29.1"). Extra
 * version components (a development build's "30.0.50") and trailing text are
 * tolerated; anything else — including another program's `--version` — is
 * null.
 */
export function parseEmacsVersionOutput(text: string): EmacsVersion | null {
  const firstLine = text.split('\n', 1)[0] as string
  const match = /^GNU Emacs (\d+)\.(\d+)(?:\.\d+)?/.exec(firstLine)
  if (match === null) return null
  return { major: Number(match[1]), minor: Number(match[2]) }
}

/** Version-compare against the floor (major first, then minor). */
export function emacsVersionMeetsFloor(version: EmacsVersion, floor: EmacsVersion = EMACS_VERSION_FLOOR): boolean {
  return version.major > floor.major
    || (version.major === floor.major && version.minor >= floor.minor)
}

/**
 * Undo the escaping `elispString` applied, for reading the probe's printed
 * list back. Unknown escapes keep their character (the elisp reader's rule
 * for punctuation); a trailing lone backslash is unparseable.
 */
function unquoteElispString(raw: string): string | null {
  let out = ''
  let i = 0
  while (i < raw.length) {
    const ch = raw[i] as string
    if (ch !== '\\') { out += ch; i += 1; continue }
    if (i + 1 >= raw.length) return null
    const next = raw[i + 1] as string
    if (next === 'n') { out += '\n'; i += 2 }
    else if (next === 't') { out += '\t'; i += 2 }
    else if (next === 'r') { out += '\r'; i += 2 }
    else if (next >= '0' && next <= '7') {
      const octal = /^[0-7]{1,3}/.exec(raw.slice(i + 1)) as RegExpExecArray
      out += String.fromCharCode(parseInt(octal[0], 8))
      i += 1 + octal[0].length
    } else { out += next; i += 2 }
  }
  return out
}

/** The probe's printed list, decoded: the three facts the card renders. */
export interface EmacsProbeState {
  installed: boolean
  atLeastBundled: boolean
  packageUserDir: string
}

/**
 * Extract the probe's `(t nil "/path/")` list from the batch output. The
 * match scans the whole output rather than anchoring: a chatty Emacs (a
 * site-start warning, a compiler note on stdout) must not fail the parse.
 * Null when no well-formed list is present.
 */
export function classifyEmacsProbeOutput(text: string): EmacsProbeState | null {
  const match = /\((t|nil)\s+(t|nil)\s+"((?:[^"\\]|\\[\s\S])*)"\)/.exec(text)
  if (match === null) return null
  const packageUserDir = unquoteElispString(match[3] as string)
  if (packageUserDir === null) return null
  return {
    installed: match[1] === 't',
    atLeastBundled: match[2] === 't',
    packageUserDir,
  }
}

/**
 * The staged Emacs package directory, or null. Both installation surfaces
 * consume the same versioned multi-file leaf:
 *
 *   emacs/dsh-bridge-<version>/
 *     dsh-bridge.el
 *     dsh-bridge-extras.el
 *     dsh-bridge-pkg.el
 *
 * Inside the packed plugin the leaf sits under the package's own `emacs/`; a
 * `link:` development install gets the identical leaf because the plugin's
 * build staging helper (`scripts/stage-emacs.mjs`) creates it there.  The raw
 * source directory is deliberately never accepted: package.el needs the
 * descriptor, and installing unbuilt sources would bypass the versioned leaf's
 * authority.  A missing or incomplete leaf is a broken installation — the
 * caller must refuse, never run Emacs against it.
 *
 * @param packageDir - the installed plugin package root.
 * @param version - the package version whose leaf to resolve.
 * @returns the leaf directory, or null when it is absent or incomplete.
 */
export function resolveBundledEmacsPackage(packageDir: string, version: string): string | null {
  if (version === '') return null
  const candidate = join(packageDir, 'emacs', `dsh-bridge-${version}`)
  const required = ['dsh-bridge.el', 'dsh-bridge-extras.el', 'dsh-bridge-pkg.el']
  if (!required.every(name => existsSync(join(candidate, name)))) return null
  return candidate
}

/** The settled outcome of one Emacs subprocess run; `runEmacs` never throws. */
export type EmacsRunResult =
  | { kind: 'ok'; exitStatus: number | null; output: string }
  | { kind: 'spawn-error'; error: string; code?: string }
  | { kind: 'timeout'; output: string }

/** The three preflight verdicts a card can word. */
export type EmacsPreflightProblem = 'emacs-not-found' | 'emacs-version-unknown' | 'emacs-too-old'

/**
 * Judge an `emacs --version` run. A spawn ENOENT is "not found" (any other
 * spawn failure, a timeout, or an unparseable banner is "version unknown" —
 * the distinction the card needs is only between "install Emacs" and "Emacs
 * misbehaves"); a parsed version below the floor is "too old".
 */
export function classifyEmacsVersionProbe(
  result: EmacsRunResult,
  floor: EmacsVersion = EMACS_VERSION_FLOOR,
): { ok: true; version: EmacsVersion } | { ok: false; problem: EmacsPreflightProblem; version?: EmacsVersion } {
  if (result.kind === 'spawn-error') {
    return result.code === 'ENOENT'
      ? { ok: false, problem: 'emacs-not-found' }
      : { ok: false, problem: 'emacs-version-unknown' }
  }
  const version = parseEmacsVersionOutput(result.output)
  if (version === null) return { ok: false, problem: 'emacs-version-unknown' }
  if (!emacsVersionMeetsFloor(version, floor)) return { ok: false, problem: 'emacs-too-old', version }
  return { ok: true, version }
}

/** The install run's failure tags. */
export type EmacsInstallProblem = 'spawn-failed' | 'timed-out' | 'nonzero-exit'

/**
 * Judge the batch install run. ONLY the exit status decides success: the
 * install byte-compiles the package and prints its known harmless
 * free-variable warning while exiting 0, so scraping the output for
 * "error"-looking text would misjudge a good install.
 */
export function classifyEmacsInstall(result: EmacsRunResult): { ok: boolean; problem?: EmacsInstallProblem } {
  switch (result.kind) {
    case 'ok':
      return result.exitStatus === 0 ? { ok: true } : { ok: false, problem: 'nonzero-exit' }
    case 'spawn-error':
      return { ok: false, problem: 'spawn-failed' }
    case 'timeout':
      return { ok: false, problem: 'timed-out' }
  }
}
