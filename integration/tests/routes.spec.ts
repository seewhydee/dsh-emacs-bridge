// dsh-emacs-bridge — integration spec: the composer-draft push, the outbox
// messageId deposit, the context route, and the no-active-session bound.
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
// Route coverage the other specs do not reach:
//   - POST /dsh-bridge/draft: the draft frame reaches a purpose=draft (web
//     UI) stream; an Emacs-only subscription cannot consume drafts (409).
//     Broadcast is universal by design — Emacs clients receive kinds they
//     ignore — so the enforceable purpose split pinned here is the 409 arm.
//   - POST /dsh-bridge/outbox { sessionId, messageId }: the host resolves the
//     assistant message's text from the session log (the browser's
//     "Send to Emacs" shape), 404 for an unknown id.
//   - GET /dsh-bridge/context: 204 before any usage/context sample, 200 with
//     the live projection after a turn, and the SSE context frame.
//   - POST /dsh-bridge/send with no active session anywhere: 409 (pinned
//     against a dedicated fixture whose home has never held a session).

import { describe, it, expect, inject } from 'vitest'
import { launch } from '../host/launch.mjs'
import { post, get, scriptMock, mockRequests, createSession, openSse, poll } from './util.mjs'

describe('POST /dsh-bridge/draft (composer-draft push)', () => {
  it('delivers the draft frame to the purpose=draft stream', async () => {
    const fixture = inject('fixture')
    const browser = openSse(fixture, { timeoutMs: 10000, purpose: 'draft' })
    try {
      // The draft route gates on a subscribed browser draft stream; wait for
      // the host to register this one before posting.
      await browser.opened
      const sessionId = await createSession(fixture)

      const pushed = await post(fixture, '/dsh-bridge/draft', {
        text: 'A composer draft from Emacs.', sessionId,
      })
      expect(pushed.status, JSON.stringify(pushed.body)).toBe(200)
      expect(pushed.body.ok).toBe(true)
      expect(pushed.body.sessionId).toBe(sessionId)

      const frame = await browser.waitFor('draft')
      expect(frame.sessionId).toBe(sessionId)
      expect(frame.text).toBe('A composer draft from Emacs.')

      const blank = await post(fixture, '/dsh-bridge/draft', { text: '   ', sessionId })
      expect(blank.status).toBe(400)
    } finally {
      browser.close()
    }
  }, 90000)

  it('refuses with 409 when only an Emacs-purpose client is connected', async () => {
    const fixture = inject('fixture')
    // The purpose split: an unmarked connection is Emacs and can never
    // consume composer drafts, so it does not count as a draft subscriber.
    const emacs = openSse(fixture, { timeoutMs: 10000 })
    try {
      await emacs.opened
      const sessionId = await createSession(fixture)
      // A prior spec's closed browser stream may linger until the host sees
      // the close; a refused attempt also prunes it, so poll for the 409.
      await poll(async () => {
        const refused = await post(fixture, '/dsh-bridge/draft', {
          text: 'No browser is listening.', sessionId,
        })
        return refused.status === 409 && /no browser client/.test(refused.body?.error ?? '')
      }, 10000, 500)
    } finally {
      emacs.close()
    }
  }, 90000)
})

describe('POST /dsh-bridge/outbox { sessionId, messageId }', () => {
  it('resolves the assistant message text host-side from the session log', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [
      { kind: 'text', text: 'First reply.' },
      { kind: 'text', text: 'Second reply.' },
    ])
    const sessionId = await createSession(fixture)

    const sse = openSse(fixture, { timeoutMs: 10000 })
    try {
      await post(fixture, '/dsh-bridge/send', { text: 'one', sessionId })
      await sse.waitFor('turn-complete')
      // The second turn's request replays the first turn's assistant message,
      // which is how the test learns its host-minted message id.
      await post(fixture, '/dsh-bridge/send', { text: 'two', sessionId })
      await poll(() => sse.frames.filter((f) => f.kind === 'turn-complete').length >= 2)
    } finally {
      sse.close()
    }

    const requests = await mockRequests(fixture)
    const main = requests.filter((r) => r.purpose === undefined)
    expect(main.length).toBe(2)
    const replayed = (main[1].messages ?? [])
      .filter((m) => m.role === 'assistant')
      .find((m) => (m.content ?? [])
        .some((b) => b.type === 'text' && b.text === 'First reply.'))
    expect(replayed, 'the second request replays the first reply').toBeDefined()
    expect(typeof replayed.id).toBe('string')

    const deposit = await post(fixture, '/dsh-bridge/outbox', {
      sessionId, messageId: replayed.id,
    })
    expect(deposit.status, JSON.stringify(deposit.body)).toBe(200)
    expect(deposit.body.ok).toBe(true)

    const collected = await get(fixture, '/dsh-bridge/outbox')
    const entry = collected.body.entries.find((e) => e.text === 'First reply.')
    expect(entry).toBeTruthy()
    expect(entry.sessionId).toBe(sessionId)

    const unknown = await post(fixture, '/dsh-bridge/outbox', {
      sessionId, messageId: 'msg-does-not-exist',
    })
    expect(unknown.status).toBe(404)

    const noSession = await post(fixture, '/dsh-bridge/outbox', { text: 'orphan' })
    expect(noSession.status).toBe(400)
  }, 90000)
})

describe('GET /dsh-bridge/context', () => {
  it('is 204 before any sample and 200 with the live projection after a turn', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const sessionId = await createSession(fixture)

    // No turn yet: no usage sample and no request/context record exist, so
    // occupancy is unknown and the route answers 204.
    const before = await get(fixture, `/dsh-bridge/context?sessionId=${sessionId}`)
    expect(before.status).toBe(204)

    // The mock advertises a 128k context window and reports usage, so the
    // token-meter projection publishes a contextPressure view per turn.
    await scriptMock(fixture, [{ kind: 'text', text: 'Context me.' }])
    const sse = openSse(fixture, { timeoutMs: 10000 })
    try {
      const sent = await post(fixture, '/dsh-bridge/send', { text: 'hi', sessionId })
      expect(sent.status).toBe(200)
      await sse.waitFor('turn-complete')

      // The projection change feed pushed a context frame for this session.
      await poll(() => sse.frames.find((f) => f.kind === 'context' && f.sessionId === sessionId))

      const after = await get(fixture, `/dsh-bridge/context?sessionId=${sessionId}`)
      expect(after.status).toBe(200)
      expect(after.body.sessionId).toBe(sessionId)
      expect(after.body.usedTokens).toBeGreaterThan(0)
      expect(after.body.contextWindow).toBe(128000)
    } finally {
      sse.close()
    }
  }, 90000)
})

describe('POST /dsh-bridge/send with no active session', () => {
  it('is 409 on a fixture whose home has never held a session', async () => {
    // A dedicated instance: the shared fixture already holds sessions, which
    // the last-active fallback would legitimately target.
    const fixture = await launch({ timeoutMs: 120000 })
    try {
      const sent = await post(fixture, '/dsh-bridge/send', { text: 'hi' })
      expect(sent.status).toBe(409)
      expect(sent.body.error).toMatch(/no active session/)
    } finally {
      await fixture.kill()
    }
  }, 120000)
})
