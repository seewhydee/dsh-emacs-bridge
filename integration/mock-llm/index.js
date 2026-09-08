// dsh-emacs-bridge — integration-testing mock LLM plugin.
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
// Plain-ESM Cordis plugin (no build step) that plugs a scripted LLM adapter
// into the harness's `ctx.llm` seam so integration tests and the interactive
// UX runner need no real model.  It imports nothing from the harness packages
// — the adapter is a plain object implementing every method LlmRuntime calls
// (providerInfo/providerRetryPolicy/listModels/resolveModel/prepareCall/stream)
// and emits StreamChunk plain objects — so the dsh Loader can import this file
// by absolute path without any node_modules of its own.
//
// Control routes on the same loopback webServer are guarded by the same bearer
// token as the bridge routes, read lazily per request from
// `$DSH_HOME/dsh-bridge-token` (the bridge writes that file at its own boot,
// which may order after ours, so the read must not happen at mock boot).

import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { textChunks, toolCallChunks, auxChunks } from './chunks.js'

export const name = 'dsh-bridge-mock-llm'

export const inject = ['llm', 'webServer']

/** Read the shared bridge token from $DSH_HOME/dsh-bridge-token, or null. */
function readToken() {
  const dshHome = process.env.DSH_HOME || join(homedir(), '.dsh')
  const path = join(dshHome, 'dsh-bridge-token')
  if (!existsSync(path)) return null
  const value = readFileSync(path, 'utf8').trim()
  return value === '' ? null : value
}

/** Constant-time-ish bearer comparison against the shared token. */
function bearerOk(req) {
  const header = req.headers.authorization
  if (typeof header !== 'string') return false
  const prefix = 'Bearer '
  if (!header.startsWith(prefix)) return false
  const provided = header.slice(prefix.length)
  const token = readToken()
  if (token === null || provided.length !== token.length) return false
  let diff = 0
  for (let i = 0; i < provided.length; i += 1) diff |= provided.charCodeAt(i) ^ token.charCodeAt(i)
  return diff === 0
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let body = ''
    req.setEncoding('utf8')
    req.on('data', (chunk) => { body += chunk })
    req.on('end', () => {
      try { resolve(body === '' ? undefined : JSON.parse(body)) } catch (error) { reject(error) }
    })
    req.on('error', reject)
  })
}

function sendJson(res, status, value) {
  const payload = JSON.stringify(value)
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(payload)
}

/** One model call's script queue is held on the adapter instance. */
class MockAdapter {
  constructor() {
    /** Every GenerateOptions received, for later assertion. */
    this.requests = []
    /** Script queue, one entry per main-turn call. */
    this.script = []
  }

  providerInfo(provider) {
    return { id: provider, name: provider }
  }

  providerRetryPolicy() {
    return undefined
  }

  async listModels(provider) {
    return [
      { provider, id: 'mock-model', name: 'Mock Model', description: 'The default mock model' },
      { provider, id: 'mock-model-pro', name: 'Mock Model Pro', description: 'A richer mock model' },
    ]
  }

  async resolveModel(provider, model) {
    return { provider, id: model, name: model }
  }

  async prepareCall(provider, model, signal) {
    const modelInfo = await this.resolveModel(provider, model, signal)
    return { model: modelInfo, stream: (options) => this.stream(options) }
  }

  sleep(ms, signal) {
    return new Promise((resolve) => {
      const timer = setTimeout(resolve, ms)
      if (signal) signal.addEventListener('abort', () => { clearTimeout(timer); resolve() }, { once: true })
    })
  }

  /** Yield chunks, pacing text deltas by delayMs when set. */
  async *paced(chunks, delayMs, signal) {
    for (const chunk of chunks) {
      if (signal?.aborted) throw new Error('aborted')
      yield chunk
      if (delayMs > 0 && chunk.type === 'text-delta') await this.sleep(delayMs, signal)
    }
  }

  async *hang(options) {
    yield { type: 'block-start', index: 0, blockType: 'text' }
    yield { type: 'text-delta', index: 0, text: 'partial' }
    await new Promise((_resolve, reject) => {
      if (options.signal?.aborted) { reject(new Error('aborted')); return }
      options.signal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true })
    })
  }

  async *stream(options) {
    this.requests.push(options)
    // Auxiliary calls (session-title, compaction) never consume the queue.
    if (options.purpose) {
      yield* this.paced(auxChunks(options.purpose), 0, options.signal)
      return
    }
    const entry = this.script.shift()
    if (entry === undefined) {
      // Unscripted: answer so a turn always terminates, and record it as such.
      yield* this.paced(textChunks('(mock: no scripted reply)'), 0, options.signal)
      return
    }
    switch (entry.kind) {
      case 'text': {
        const delay = typeof entry.delayMs === 'number' ? entry.delayMs : 0
        yield* this.paced(textChunks(entry.text), delay, options.signal)
        return
      }
      case 'tool-call': {
        const argumentsJson = JSON.stringify(entry.arguments ?? {})
        yield* this.paced(toolCallChunks(entry.name, argumentsJson, entry.text), 0, options.signal)
        return
      }
      case 'hang': {
        yield* this.hang(options)
        return
      }
      case 'error':
        throw new Error(entry.message)
      default:
        throw new Error(`mock-llm: unknown script entry kind ${String(entry.kind)}`)
    }
  }
}

export function apply(ctx) {
  const webServer = ctx.get('webServer')
  const adapter = new MockAdapter()

  // Adds the `mock` provider route (registerAdapter throws on a duplicate
  // route, and nothing in the profile registers `mock`). The fixture overlay's
  // agent-default-model override is what actually routes sessions to it. The
  // registration is owned by this plugin's fiber, so a config hot-reload
  // releases it.
  ctx.llm.registerAdapter(['mock'], adapter)

  // Control routes. Registered inside an effect so hot-reload re-applies them
  // without a duplicate (kind, path) registration throw.
  ctx.effect(() => webServer.register({
    kind: 'prefix',
    path: '/mock-llm',
    handler: async (req, res) => {
      const url = new URL(req.url ?? '/', 'http://localhost')
      const pathname = url.pathname
      if (!bearerOk(req)) {
        sendJson(res, 401, { error: 'unauthorized' })
        return
      }
      if (req.method === 'POST' && pathname === '/mock-llm/script') {
        const body = (await readJson(req)) ?? {}
        if (!Array.isArray(body.script)) {
          sendJson(res, 400, { error: 'body.script must be an array' })
          return
        }
        adapter.script = body.script
        sendJson(res, 200, { ok: true, queued: adapter.script.length })
        return
      }
      if (req.method === 'POST' && pathname === '/mock-llm/push') {
        const body = (await readJson(req)) ?? {}
        if (!Array.isArray(body.script)) {
          sendJson(res, 400, { error: 'body.script must be an array' })
          return
        }
        adapter.script.push(...body.script)
        sendJson(res, 200, { ok: true, queued: adapter.script.length })
        return
      }
      if (req.method === 'GET' && pathname === '/mock-llm/requests') {
        sendJson(res, 200, { requests: adapter.requests })
        return
      }
      if (req.method === 'POST' && pathname === '/mock-llm/reset') {
        adapter.script = []
        adapter.requests = []
        sendJson(res, 200, { ok: true })
        return
      }
      sendJson(res, 404, { error: 'not found' })
    },
  }), 'dsh-bridge-mock-llm: control routes')
}
