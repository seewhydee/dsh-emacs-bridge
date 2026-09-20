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
