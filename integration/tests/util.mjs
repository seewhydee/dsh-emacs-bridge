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

/**
 * A request against the fixture with explicit control over the credentials:
 * `token` undefined sends no Authorization header, a string is used as the
 * bearer token verbatim, and `origin` sets the Origin header (the hostile-
 * origin fence tests). `body`, when given, is JSON-encoded.
 */
export async function raw(fixture, method, path, { token, origin, body } = {}) {
  const headers = {}
  if (token !== undefined) headers.authorization = `Bearer ${token}`
  if (origin !== undefined) headers.origin = origin
  if (body !== undefined) headers['content-type'] = 'application/json'
  const res = await fetch(`${fixture.url}${path}`, {
    method,
    headers,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
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

/** Poll PREDICATE until it returns truthy, or throw after timeoutMs. */
export async function poll(predicate, timeoutMs = 15000, intervalMs = 250) {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    const value = await predicate()
    if (value) return value
    if (Date.now() >= deadline) throw new Error(`poll: predicate still false after ${timeoutMs}ms`)
    await new Promise((resolve) => setTimeout(resolve, intervalMs))
  }
}

/**
 * Create a session in a workspace by path; the session id is returned.
 * Retries while the freshly booted host's workspace registry is still
 * completing its async bootstrap (it answers 501 until it is active). No
 * mutation precedes that 501, so retrying is safe.
 */
export async function createSession(fixture, path = REPO_ROOT, timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    const { status, body } = await post(fixture, '/dsh-bridge/sessions/create', { path })
    if (status !== 501) {
      if (body?.sessionId === undefined) {
        throw new Error(`create-session failed (${status}): ${JSON.stringify(body)}`)
      }
      return body.sessionId
    }
    if (Date.now() >= deadline) {
      throw new Error(`workspace registry did not become ready: ${JSON.stringify(body)}`)
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250))
  }
}

/**
 * Open an SSE stream to `/dsh-bridge/events` and collect parsed frames.
 * `waitFor(kind)` resolves with the first frame of that kind seen after the
 * call, or rejects on timeout. `opened` resolves once the host has accepted
 * the connection (await it before driving a route that gates on client
 * presence, e.g. POST /draft). `close()` aborts the stream. `purpose`
 * ('draft') marks the connection as the browser's draft stream, the way the
 * browser plugin's EventSource identifies itself. `answer` ('0') marks an
 * Emacs stream that will not answer approvals (the `notify-only` posture): it
 * still receives approval frames, but the host does not count it as an
 * answerer.
 */
export function openSse(fixture, { timeoutMs = 15000, purpose, answer } = {}) {
  const controller = new AbortController()
  const frames = []
  const waiters = new Map() // kind -> [{resolve, reject, timer}]
  // Resolves once the stream's response headers arrive (the host has accepted
  // and registered this client); rejects if the open itself fails.
  let markOpened
  let failOpened
  const opened = new Promise((resolvePromise, rejectPromise) => {
    markOpened = resolvePromise
    failOpened = rejectPromise
  })

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
    const query = `token=${fixture.token}${purpose === undefined ? '' : `&purpose=${purpose}`}${answer === undefined ? '' : `&answer=${answer}`}`
    const res = await fetch(`${fixture.url}/dsh-bridge/events?${query}`, {
      signal: controller.signal,
      headers: { accept: 'text/event-stream' },
    })
    if (!res.ok || !res.body) {
      failOpened(new Error(`SSE open failed: HTTP ${res.status}`))
      failAll(new Error(`SSE open failed: HTTP ${res.status}`))
      return
    }
    markOpened()
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
    if (error?.name !== 'AbortError') { failOpened(error); failAll(error) }
  })
  // Specs that never await `opened` must not trip an unhandled rejection.
  opened.catch(() => {})

  return {
    frames,
    opened,
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
