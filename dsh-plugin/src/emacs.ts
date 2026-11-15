// dsh-emacs-bridge — bounded Emacs subprocess adapter.
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

import { spawn } from 'node:child_process'
import type { ChildProcess } from 'node:child_process'
import { errorMessage } from './errors.ts'
import {
  classifyEmacsVersionProbe,
  type EmacsRunResult,
  type EmacsVersion,
} from './emacs-logic.ts'

/** Hard bound on captured subprocess output (stdout + stderr combined), in
 *  JavaScript string units: a close-enough guard on how much a chatty or
 *  looping child can hold in memory. */
const EMACS_OUTPUT_CAP = 64 * 1024

/**
 * Fixed timeout for the `emacs --version` preflight, independent of the
 * configured install timeout: a healthy Emacs answers in well under a second,
 * and the preflight must not inherit a generous install budget.
 */
const EMACS_PREFLIGHT_TIMEOUT_MS = 15_000

/** Fixed timeout for the batch status probe (same reasoning as the preflight). */
export const EMACS_PROBE_TIMEOUT_MS = 60_000

/** Grace between SIGTERM and SIGKILL when a run exceeds its timeout. */
const EMACS_KILL_GRACE_MS = 5_000

/**
 * Run Emacs (ARGV[0] plus its leading arguments) with ARGS appended, batch or
 * `--version` alike. Never throws: every failure mode settles as an
 * `EmacsRunResult`, so the routes can word it for the card. stdin is ignored
 * (a batch Emacs must never block on input); stdout+stderr are captured
 * together up to `EMACS_OUTPUT_CAP`, after which appending stops — the
 * output is diagnostic, not a success signal, so a flood must not grow
 * memory; past the timeout the child is killed (SIGKILL after a grace), so a
 * wedged Emacs cannot strand the serialized install section.
 */
export function runEmacs(
  argv: readonly string[],
  args: readonly string[],
  timeoutMs: number,
): Promise<EmacsRunResult> {
  return new Promise((resolve) => {
    if (argv.length === 0) {
      resolve({ kind: 'spawn-error', error: 'empty emacs command' })
      return
    }
    let child: ChildProcess
    try {
      child = spawn(argv[0] as string, [...argv.slice(1), ...args], {
        shell: false,
        stdio: ['ignore', 'pipe', 'pipe'],
      })
    } catch (error: unknown) {
      // Synchronous spawn failures (invalid arguments); ENOENT arrives via
      // the 'error' event below.
      resolve({ kind: 'spawn-error', error: errorMessage(error) })
      return
    }
    let output = ''
    let timedOut = false
    let settled = false
    let killTimer: ReturnType<typeof setTimeout> | undefined
    const timer = setTimeout(() => {
      timedOut = true
      child.kill('SIGTERM')
      killTimer = setTimeout(() => { child.kill('SIGKILL') }, EMACS_KILL_GRACE_MS)
    }, timeoutMs)
    const finish = (result: EmacsRunResult): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (killTimer !== undefined) clearTimeout(killTimer)
      resolve(result)
    }
    // Listeners keep draining past the cap so the child never blocks on a
    // full pipe; only appending stops.
    const append = (chunk: Buffer): void => {
      if (output.length >= EMACS_OUTPUT_CAP) return
      output += chunk.toString('utf8')
      if (output.length > EMACS_OUTPUT_CAP) output = output.slice(0, EMACS_OUTPUT_CAP)
    }
    child.stdout?.on('data', append)
    child.stderr?.on('data', append)
    child.on('error', (error: Error & { code?: string }) => {
      finish({
        kind: 'spawn-error',
        error: error.message,
        ...error.code === undefined ? {} : { code: error.code },
      })
    })
    child.on('close', (code: number | null) => {
      finish(timedOut
        ? { kind: 'timeout', output }
        : { kind: 'ok', exitStatus: code, output })
    })
  })
}

/** Render a parsed Emacs version for the response (`29.1`). */
export function formatEmacsVersion(version: EmacsVersion): string {
  return `${version.major}.${version.minor}`
}

export async function preflightEmacs(
  argv: readonly string[],
): Promise<
  | { ok: true; version: EmacsVersion }
  | { ok: false; report: Record<string, unknown> }
> {
  const preflight = classifyEmacsVersionProbe(
    await runEmacs(argv, ['--version'], EMACS_PREFLIGHT_TIMEOUT_MS))
  if (preflight.ok) return { ok: true, version: preflight.version }
  return {
    ok: false,
    report: {
      problem: preflight.problem,
      ...preflight.version === undefined
        ? {}
        : { emacsVersion: formatEmacsVersion(preflight.version) },
    },
  }
}
