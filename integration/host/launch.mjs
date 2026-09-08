#! /usr/bin/env node
// dsh-emacs-bridge — integration-testing fixture launcher.
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
// A CLI and a library that boots one live DSH fixture: a fresh temp DSH_HOME,
// the rendered overlay mounting the freshly built bridge plugin (`make build`
// first) and the mock-LLM plugin by absolute path, the agent-default-model
// override pointing at the mock provider, and the webserver pinned to loopback
// + a per-instance free port so suites can run in parallel.  Each test suite
// boots its own instance (no shared state), and the interactive scenario runner
// reuses the same code path.

import { spawn } from 'node:child_process'
import { createWriteStream, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const INTEGRATION_ROOT = resolve(__dirname, '..')
const REPO_ROOT = resolve(INTEGRATION_ROOT, '..')
const BRIDGE_ENTRY = resolve(REPO_ROOT, 'dsh-plugin', 'lib', 'index.js')
const MOCK_LLM_ENTRY = resolve(INTEGRATION_ROOT, 'mock-llm', 'index.js')
const OVERLAY_TEMPLATE = join(__dirname, 'overlay.template.yml')

const sleep = (ms) => new Promise((resolvePromise) => setTimeout(resolvePromise, ms))

/** Pick a free TCP port on loopback (the OS-assigned value for a 0 bind). */
function freePort() {
  return new Promise((resolvePromise, reject) => {
    const server = createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolvePromise(port))
    })
  })
}

/**
 * Resolve the `dsh` command the launcher spawns. Env override
 * `DSH_BRIDGE_DSH_COMMAND` (whitespace-split) wins; else `dsh` on PATH. This is
 * launcher-only: `dsh-bridge-dsh-command` in the elisp is a richer defcustom and
 * does not read this env var.
 */
export function resolveDshCommand() {
  const envCmd = process.env.DSH_BRIDGE_DSH_COMMAND
  if (envCmd !== undefined && envCmd.trim() !== '') return envCmd.trim().split(/\s+/)
  return ['dsh']
}

/** Poll `GET /dsh-bridge/status` until the bridge answers, or timeout. */
async function waitForReady(url, timeoutMs, child) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`fixture exited early (code ${child.exitCode})`)
    }
    try {
      const res = await fetch(`${url}/dsh-bridge/status`, { signal: AbortSignal.timeout(2000) })
      if (res.ok) {
        const body = await res.json()
        if (body !== null && typeof body === 'object' && body.name === 'dsh-emacs-bridge') {
          return body
        }
      }
    } catch {
      // Not up yet, or a transient connection reset; keep polling.
    }
    await sleep(500)
  }
  throw new Error(`fixture did not become ready within ${timeoutMs}ms`)
}

/**
 * Render the overlay template with concrete values into a YAML string.
 * `disable` names rows to turn off (a degraded profile): each becomes its own
 * `disabled: true` row so the bridge boots with an optional service removed.
 */
function renderOverlay({ dshHome, bridgeEntry, mockLlmEntry, port, disable }) {
  const template = readFileSync(OVERLAY_TEMPLATE, 'utf8')
  const body = template
    .replaceAll('{{DSH_HOME}}', dshHome)
    .replaceAll('{{BRIDGE_ENTRY}}', bridgeEntry)
    .replaceAll('{{MOCK_LLM_ENTRY}}', mockLlmEntry)
    .replaceAll('{{PORT}}', String(port))
  const disabled = (disable ?? [])
    .map((id) => `\n- id: ${id}\n  disabled: true\n`)
    .join('')
  return body + disabled
}

/**
 * Boot one fixture instance. Returns a handle with the live facts and a `kill`
 * teardown. `dshHome` may be provided to reuse a persisted home across two
 * boots (cold-resume tests); otherwise a fresh temp dir is created.
 */
export async function launch(options = {}) {
  const { patch, disable, dshHome, timeoutMs = 90000 } = options
  // A checkout-based `DSH_BRIDGE_DSH_COMMAND` (e.g. the harness's `tsx` CLI)
  // may need its package resolution rooted at the harness directory; a PATH
  // `dsh` does not. Default to `process.cwd()`, override with the `cwd` option
  // or `DSH_BRIDGE_FIXTURE_CWD`.
  const cwd = options.cwd ?? process.env.DSH_BRIDGE_FIXTURE_CWD ?? process.cwd()
  const port = options.port ?? (await freePort())
  // The launcher removes the home on teardown only when it created it; a
  // caller-supplied dshHome (cold-resume tests reusing a persisted home)
  // belongs to the caller.
  const ownsHome = dshHome === undefined
  const homeDir = dshHome ?? mkdtempSync(join(tmpdir(), 'dsh-bridge-it-'))
  mkdirSync(homeDir, { recursive: true })
  const overlayPath = join(homeDir, 'overlay.yml')
  writeFileSync(
    overlayPath,
    renderOverlay({ dshHome: homeDir, bridgeEntry: BRIDGE_ENTRY, mockLlmEntry: MOCK_LLM_ENTRY, port, disable }),
  )
  const dshCmd = resolveDshCommand()
  const args = [...dshCmd.slice(1), '--profile', 'web', '--patch', overlayPath]
  if (patch !== undefined) args.push('--patch', patch)
  const child = spawn(dshCmd[0], args, {
    cwd,
    env: { ...process.env, DSH_HOME: homeDir },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const logPath = join(homeDir, 'fixture.log')
  const log = createWriteStream(logPath)
  child.stdout.pipe(log)
  child.stderr.pipe(log)
  // Teardown: remove the launcher-owned temp home once the dsh child is gone.
  // The log stream may still be flushing at exit; on Linux the unlinked file
  // simply keeps the fd, so a synchronous rm here is safe.
  child.once('exit', () => {
    if (ownsHome) rmSync(homeDir, { recursive: true, force: true })
  })

  const url = `http://127.0.0.1:${port}`
  let info
  try {
    info = await waitForReady(url, timeoutMs, child)
  } catch (error) {
    // Await the exit so the exit handler's temp-home cleanup runs before the
    // caller's process exits on this failure path.
    child.kill('SIGTERM')
    if (child.exitCode === null) {
      await new Promise((resolvePromise) => {
        child.once('exit', resolvePromise)
        setTimeout(resolvePromise, 3000).unref()
      })
      if (child.exitCode === null) child.kill('SIGKILL')
    }
    throw error
  }
  const tokenPath = join(homeDir, 'dsh-bridge-token')
  const token = existsSync(tokenPath) ? readFileSync(tokenPath, 'utf8').trim() : ''
  return {
    url,
    port,
    pid: child.pid,
    dshHome: homeDir,
    token,
    logPath,
    overlayPath,
    version: info.version,
    // SIGTERM the dsh child and resolve on its exit (the exit handler above
    // removes a launcher-owned temp home). Escalates to SIGKILL after 3s.
    // Callers must AWAIT this: a process that exits right after a fire-and-
    // forget kill (vitest globalSetup teardown, the CLI's signal handler)
    // would orphan the child and leak the temp home.
    kill() {
      if (child.exitCode !== null) return Promise.resolve()
      child.kill('SIGTERM')
      return new Promise((resolvePromise) => {
        const killer = setTimeout(() => {
          if (child.exitCode === null) child.kill('SIGKILL')
        }, 3000)
        child.once('exit', () => {
          clearTimeout(killer)
          resolvePromise()
        })
      })
    },
  }
}

/** The CLI: boot a fixture, print its env block, and (with --keep) leave it up. */
async function runCli() {
  const args = process.argv.slice(2)
  const keep = args.includes('--keep')
  const portIndex = args.indexOf('--port')
  const port = portIndex >= 0 ? Number(args[portIndex + 1]) : undefined
  const disableIndex = args.indexOf('--disable')
  const disable = disableIndex >= 0 ? args[disableIndex + 1].split(',').filter(Boolean) : undefined
  const handle = await launch({ keep, port, disable })
  const envBlock = [
    `#!/usr/bin/env bash`,
    `export DSH_BRIDGE_FIXTURE_URL="${handle.url}"`,
    `export DSH_BRIDGE_FIXTURE_TOKEN="${handle.token}"`,
    `export DSH_BRIDGE_FIXTURE_HOME="${handle.dshHome}"`,
    `export DSH_BRIDGE_FIXTURE_PORT="${handle.port}"`,
  ].join('\n')
  const info = {
    url: handle.url,
    port: handle.port,
    pid: handle.pid,
    dshHome: handle.dshHome,
    token: handle.token,
    logPath: handle.logPath,
    version: handle.version,
  }
  // A single-line machine marker for the batch Emacs ERT layer to parse from
  // stdout (the dsh child's output is redirected to the log file, never stdout).
  process.stdout.write(`FIXTURE_JSON ${JSON.stringify(info)}\n`)
  console.log(JSON.stringify(info, null, 2))
  if (keep) {
    console.log('\n--keep: fixture still running; paste this into a shell to drive it:\n')
    console.log(envBlock)
  } else {
    console.error('fixture ready (no --keep); send SIGTERM to this process to tear it down.')
  }
  // Ensure a teardown signal on the launcher also kills the spawned `dsh` child,
  // so a batch caller (vitest globalSetup or the ERT layer's make-process) is
  // never left with an orphaned host.
  const shutdown = () => {
    handle.kill().finally(() => process.exit(0))
  }
  process.on('SIGTERM', shutdown)
  process.on('SIGINT', shutdown)
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  runCli().catch((error) => {
    console.error(String(error?.stack ?? error))
    process.exit(1)
  })
}
