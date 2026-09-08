// dsh-emacs-bridge — integration-testing HTTP/SSE client helpers.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Thin helpers for driving a live fixture over real HTTP/SSE: authorized
// GET/POST against the bridge routes, and a chunked SSE reader that collects
// frames by kind so specs can `waitFor` a specific frame (the ask-user
// regression asserts an `ask-user` frame arrives and times out otherwise).

import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** The repo root — the workspace path fixture sessions are created under. */
export const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')

/** Authorized GET against the fixture. */
export async function get(fixture, path) {
  const res = await fetch(`${fixture.url}${path}`, {
    headers: { authorization: `Bearer ${fixture.token}` },
  })
  const text = await res.text()
  const body = text === '' ? null : JSON.parse(text)
  return { status: res.status, body }
}

/** Authorized POST against the fixture. `body` is JSON-encoded. */
export async function post(fixture, path, body) {
  const res = await fetch(`${fixture.url}${path}`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${fixture.token}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(body ?? {}),
  })
  const text = await res.text()
  let parsed = null
  try { parsed = text === '' ? null : JSON.parse(text) } catch { parsed = text }
  return { status: res.status, body: parsed }
}

/** Replace the mock LLM's script queue. */
export async function scriptMock(fixture, script) {
  return post(fixture, '/mock-llm/script', { script })
}

/** Append entries to the mock LLM's script queue. */
export async function pushMockScript(fixture, script) {
  return post(fixture, '/mock-llm/push', { script })
}

/** The calls the mock has recorded so far. */
export async function mockRequests(fixture) {
  const { body } = await get(fixture, '/mock-llm/requests')
  return body.requests ?? []
}

/** Create a session in a workspace by path; the session id is returned. */
export async function createSession(fixture, path = REPO_ROOT) {
  const { status, body } = await post(fixture, '/dsh-bridge/sessions/create', { path })
  if (body?.sessionId === undefined) {
    throw new Error(`create-session failed (${status}): ${JSON.stringify(body)}`)
  }
  return body.sessionId
}

/**
 * Open an SSE stream to `/dsh-bridge/events` and collect parsed frames.
 * `waitFor(kind)` resolves with the first frame of that kind seen after the
 * call, or rejects on timeout. `close()` aborts the stream.
 */
export function openSse(fixture, { timeoutMs = 15000 } = {}) {
  const controller = new AbortController()
  const frames = []
  const waiters = new Map() // kind -> [{resolve, reject, timer}]

  function settle(kind, frame) {
    const list = waiters.get(kind)
    if (!list) return
    waiters.delete(kind)
    for (const w of list) {
      clearTimeout(w.timer)
      w.resolve(frame ?? null)
    }
  }

  function failAll(reason) {
    for (const [kind, list] of waiters) {
      for (const w of list) {
        clearTimeout(w.timer)
        w.reject(reason)
      }
    }
    waiters.clear()
  }

  const run = (async () => {
    const res = await fetch(`${fixture.url}/dsh-bridge/events?token=${fixture.token}`, {
      signal: controller.signal,
      headers: { accept: 'text/event-stream' },
    })
    if (!res.ok || !res.body) {
      failAll(new Error(`SSE open failed: HTTP ${res.status}`))
      return
    }
    const reader = res.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ''
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      // Split on event boundaries; each event is blank-line terminated.
      let sep
      while ((sep = buffer.indexOf('\n\n')) >= 0) {
        const block = buffer.slice(0, sep)
        buffer = buffer.slice(sep + 2)
        for (const line of block.split('\n')) {
          if (!line.startsWith('data:')) continue
          const payload = line.slice(5).trim()
          if (payload === '') continue
          let frame
          try { frame = JSON.parse(payload) } catch { continue }
          const kind = frame.kind
          frames.push(frame)
          settle(kind, frame)
        }
      }
    }
    failAll(new Error('SSE stream closed'))
  })().catch((error) => {
    if (error?.name !== 'AbortError') failAll(error)
  })

  return {
    frames,
    waitFor(kind, timeout = timeoutMs) {
      const existing = frames.find((f) => f.kind === kind)
      if (existing !== undefined) return Promise.resolve(existing)
      return new Promise((resolvePromise, reject) => {
        const timer = setTimeout(() => {
          const list = waiters.get(kind)
          if (list) {
            const i = list.findIndex((w) => w.timer === timer)
            if (i >= 0) list.splice(i, 1)
          }
          reject(new Error(`timed out waiting for SSE frame kind ${kind}`))
        }, timeout)
        const list = waiters.get(kind) ?? []
        list.push({ resolve: resolvePromise, reject, timer })
        waiters.set(kind, list)
      })
    },
    close() { controller.abort() },
    async done() { await run },
  }
}
