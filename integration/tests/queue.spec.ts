// dsh-emacs-bridge — integration spec: `/send` mode and the queue counts.
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
// The two host-plane seams the Emacs busy-send choice rides on:
//   - POST /dsh-bridge/send accepts only an absent/`null` mode or `"steer"`,
//     so a version-skewed field never degrades a steer into a queued send.
//   - GET /dsh-bridge/sessions/queue folds the live agent's inbox: a hanging
//     turn lets a follow-up park in `next-turn` (queued) and a steer park in
//     `next-step` (steering), while injected context is excluded; an absent
//     or unknown id reads as zeros rather than 404.

import { describe, it, expect, inject } from 'vitest'
import { post, get, scriptMock, mockRequests, createSession, openSse, poll } from './util.mjs'

describe('POST /dsh-bridge/send mode', () => {
  it('rejects an unknown mode with 400 and accepts a steer', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [{ kind: 'text', text: 'Done.' }])
    const sessionId = await createSession(fixture)

    // `queue` is the host's absent-mode behavior, not a wire value: only
    // `steer` may be named, so a typo cannot silently become a queued send.
    const bad = await post(fixture, '/dsh-bridge/send', {
      text: 'Rejected.', sessionId, mode: 'queue',
    })
    expect(bad.status, JSON.stringify(bad.body)).toBe(400)
    expect(bad.body.error).toMatch(/mode/)
    expect(await mockRequests(fixture)).toHaveLength(0)

    const steered = await post(fixture, '/dsh-bridge/send', {
      text: 'Steer an idle session.', sessionId, mode: 'steer',
    })
    expect(steered.status, JSON.stringify(steered.body)).toBe(200)
    expect(steered.body.sessionId).toBe(sessionId)
  }, 90000)
})

describe('GET /dsh-bridge/sessions/queue', () => {
  it('counts parked prompts on a live agent and zeroes elsewhere', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const sessionId = await createSession(fixture)

    // A hanging main turn keeps the agent running with its step open, so a
    // follow-up parks in next-turn and a steer parks in next-step.
    await scriptMock(fixture, [{ kind: 'hang' }])
    const sse = openSse(fixture, { timeoutMs: 10000 })
    try {
      await post(fixture, '/dsh-bridge/send', { text: 'Never finish.', sessionId })
      await sse.waitFor('turn-start')

      const queued = await post(fixture, '/dsh-bridge/send', { text: 'after', sessionId })
      expect(queued.status, JSON.stringify(queued.body)).toBe(200)
      const steering = await post(fixture, '/dsh-bridge/send', {
        text: 'steer', sessionId, mode: 'steer',
      })
      expect(steering.status, JSON.stringify(steering.body)).toBe(200)

      const counts = await poll(async () => {
        const { status, body } = await get(
          fixture, `/dsh-bridge/sessions/queue?sessionId=${sessionId}`)
        return status === 200 && body.queued >= 1 && body.steering >= 1 ? body : null
      })
      expect(counts.queued).toBe(1)
      expect(counts.steering).toBe(1)

      // An unknown id and an absent id are the same answer as empty, not 404.
      const unknown = await get(fixture, '/dsh-bridge/sessions/queue?sessionId=nope')
      expect(unknown.status).toBe(200)
      expect(unknown.body).toEqual({ queued: 0, steering: 0 })
      const absent = await get(fixture, '/dsh-bridge/sessions/queue')
      expect(absent.status).toBe(200)
      expect(absent.body).toEqual({ queued: 0, steering: 0 })
    } finally {
      sse.close()
    }
  }, 90000)
})

describe('GET /dsh-bridge/prompts pending', () => {
  it('reports pending prompts in action order with ids and metadata', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const sessionId = await createSession(fixture)

    await scriptMock(fixture, [{ kind: 'hang' }])
    const sse = openSse(fixture, { timeoutMs: 10000 })
    try {
      await post(fixture, '/dsh-bridge/send', { text: 'Never finish.', sessionId })
      await sse.waitFor('turn-start')

      await post(fixture, '/dsh-bridge/send', { text: 'first queued', sessionId })
      await post(fixture, '/dsh-bridge/send', { text: 'second queued', sessionId })
      await post(fixture, '/dsh-bridge/send', {
        text: 'steer me', sessionId, mode: 'steer',
      })

      const body = await poll(async () => {
        const { status, body } = await get(
          fixture, `/dsh-bridge/prompts?sessionId=${sessionId}`)
        return status === 200 && body.pending?.length === 3 ? body : null
      })
      expect(body.pending.map((item) => item.text))
        .toEqual(['steer me', 'first queued', 'second queued'])
      expect(body.pending.map((item) => item.placement))
        .toEqual(['steering', 'queued', 'queued'])
      expect(body.pending[0].position).toBeUndefined()
      expect(body.pending[1].position).toBe(1)
      expect(body.pending[2].position).toBe(2)
      for (const item of body.pending) {
        expect(typeof item.id).toBe('string')
        expect(item.id).not.toBe('')
        expect(item.textOnly).toBe(true)
        expect(item.attachments).toEqual([])
      }
      expect(new Set(body.pending.map((item) => item.id)).size).toBe(3)
      expect(Array.isArray(body.prompts)).toBe(true)
    } finally {
      sse.close()
    }
  }, 90000)
})

describe('POST /dsh-bridge/sessions/queue', () => {
  it('removes and steers exact items, and rejects stale or malformed requests', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const sessionId = await createSession(fixture)

    await scriptMock(fixture, [{ kind: 'hang' }])
    const sse = openSse(fixture, { timeoutMs: 10000 })
    try {
      await post(fixture, '/dsh-bridge/send', { text: 'Never finish.', sessionId })
      await sse.waitFor('turn-start')

      // Two identical texts: only the durable id can address one of them.
      await post(fixture, '/dsh-bridge/send', { text: 'same text', sessionId })
      await post(fixture, '/dsh-bridge/send', { text: 'same text', sessionId })

      const before = await poll(async () => {
        const { status, body } = await get(
          fixture, `/dsh-bridge/prompts?sessionId=${sessionId}`)
        return status === 200 && body.pending?.length === 2 ? body : null
      })
      const first = before.pending[0]
      const second = before.pending[1]
      expect(first.text).toBe('same text')
      expect(second.text).toBe('same text')
      expect(first.id).not.toBe(second.id)

      const removed = await post(fixture, '/dsh-bridge/sessions/queue', {
        sessionId, itemId: first.id, action: 'remove',
      })
      expect(removed.status, JSON.stringify(removed.body)).toBe(200)
      expect(removed.body).toEqual({ accepted: true })

      const afterRemove = await poll(async () => {
        const { status, body } = await get(
          fixture, `/dsh-bridge/prompts?sessionId=${sessionId}`)
        return status === 200 && body.pending?.length === 1 ? body : null
      })
      expect(afterRemove.pending[0].id).toBe(second.id)

      const steered = await post(fixture, '/dsh-bridge/sessions/queue', {
        sessionId, itemId: second.id, action: 'steer',
      })
      expect(steered.status, JSON.stringify(steered.body)).toBe(200)

      const afterSteer = await poll(async () => {
        const { status, body } = await get(
          fixture, `/dsh-bridge/prompts?sessionId=${sessionId}`)
        return status === 200 && body.pending?.length === 1
          && body.pending[0].placement === 'steering' ? body : null
      })
      expect(afterSteer.pending[0].id).toBe(second.id)

      // It is parked for the next step boundary now: not steerable again.
      const steerAgain = await post(fixture, '/dsh-bridge/sessions/queue', {
        sessionId, itemId: second.id, action: 'steer',
      })
      expect(steerAgain.status, JSON.stringify(steerAgain.body)).toBe(409)

      // A stale id and an unknown session are conflicts, not 404s.
      const stale = await post(fixture, '/dsh-bridge/sessions/queue', {
        sessionId, itemId: 'no-such-item', action: 'remove',
      })
      expect(stale.status, JSON.stringify(stale.body)).toBe(409)
      const unknown = await post(fixture, '/dsh-bridge/sessions/queue', {
        sessionId: 'no-such-session', itemId: 'no-such-item', action: 'remove',
      })
      expect(unknown.status, JSON.stringify(unknown.body)).toBe(409)

      // Malformed requests: bad action, supplied text, missing ids.
      const badAction = await post(fixture, '/dsh-bridge/sessions/queue', {
        sessionId, itemId: second.id, action: 'edit', text: 'replacement',
      })
      expect(badAction.status).toBe(400)
      const suppliedText = await post(fixture, '/dsh-bridge/sessions/queue', {
        sessionId, itemId: second.id, action: 'remove', text: 'x',
      })
      expect(suppliedText.status).toBe(400)
      const missing = await post(fixture, '/dsh-bridge/sessions/queue', {
        sessionId, action: 'remove',
      })
      expect(missing.status).toBe(400)
    } finally {
      sse.close()
    }
  }, 90000)
})

describe('queue-changed SSE frame', () => {
  it('carries counts only, on enqueue and on steer', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const sessionId = await createSession(fixture)

    await scriptMock(fixture, [{ kind: 'hang' }])
    const sse = openSse(fixture, { timeoutMs: 10000 })
    try {
      await post(fixture, '/dsh-bridge/send', { text: 'Never finish.', sessionId })
      await sse.waitFor('turn-start')

      const queued = await post(fixture, '/dsh-bridge/send', {
        text: 'parking', sessionId,
      })
      expect(queued.status).toBe(200)
      const frame = await sse.waitFor('queue-changed', 10000,
        (candidate) => candidate.sessionId === sessionId && candidate.queued === 1)
      expect(frame.steering).toBe(0)
      expect(Object.keys(frame).sort()).toEqual(['kind', 'queued', 'sessionId', 'steering'])

      await post(fixture, '/dsh-bridge/send', {
        text: 'steering now', sessionId, mode: 'steer',
      })
      const steeringFrame = await sse.waitFor('queue-changed', 10000,
        (candidate) => candidate.sessionId === sessionId && candidate.steering === 1)
      expect(steeringFrame.queued).toBe(1)
      expect(steeringFrame.text).toBeUndefined()
      expect(steeringFrame.attachments).toBeUndefined()
    } finally {
      sse.close()
    }
  }, 90000)
})
