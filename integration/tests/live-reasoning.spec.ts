// dsh-emacs-bridge — integration spec: on-demand inspection of live reasoning.
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
// Pins the host-plane contract of the process-local assistant stream: while an
// attempt runs, `/turns` carries one summary-only transient thinking entry with
// an opaque id and no seq, `/details/item` serves its retained prefix on
// explicit request (bearer-authenticated), later chunks grow that snapshot, and
// settlement replaces the transient entry with exactly one committed entry
// while the old transient selector resolves to the committed item.

import { afterAll, describe, expect, it, inject } from 'vitest'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { get, poll, post, raw, scriptMock, createSession, openSse } from './util.mjs'

const tempDirs = []

function tempWorkspace() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'dsh-bridge-live-')))
  tempDirs.push(dir)
  return dir
}

afterAll(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true })
})

function liveThinking(turns) {
  for (const turn of turns.turns ?? []) {
    for (const entry of turn.activity ?? []) {
      if (entry.inFlight === true) return { turn, entry }
    }
  }
  return undefined
}

describe('in-flight reasoning', () => {
  it('serves a growing snapshot, never on SSE, and hands off at settlement', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const dir = tempWorkspace()
    const firstLine = 'FIRST-LINE live summary.'
    const marker = `BURIED-LIVE-MARKER-${process.pid}-${Date.now()}`
    const cot = `${firstLine}\n\n${marker}: this paragraph stays out of the summary.`
    await scriptMock(fixture, [
      {
        kind: 'reasoning',
        text: cot,
        pauses: [
          { after: firstLine.length, key: 'live-prefix' },
          { after: cot.length - 1, key: 'live-rest' },
        ],
      },
    ])
    const sessionId = await createSession(fixture, dir)
    const sse = openSse(fixture, { timeoutMs: 20000 })
    const mine = frame => frame.sessionId === sessionId
    try {
      const sent = await post(fixture, '/dsh-bridge/send', { text: 'Think live.', sessionId })
      expect(sent.status, JSON.stringify(sent.body)).toBe(200)

      const paused = await poll(async () => {
        const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
        return liveThinking(turns.body)
      }, 20000)
      expect(paused.entry).toMatchObject({
        kind: 'thinking', inFlight: true, turn: paused.turn.turn,
      })
      expect(typeof paused.entry.inFlightId).toBe('string')
      expect(paused.entry.inFlightId).not.toBe('')
      expect(typeof paused.entry.attemptId).toBe('string')
      expect(typeof paused.entry.revision).toBe('number')
      expect(paused.entry).not.toHaveProperty('seq')
      expect(paused.entry.summary).toBe(firstLine)

      const turnsDuring = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      expect(turnsDuring.body.turns[0].activityRevision).toEqual(expect.any(Number))
      expect(turnsDuring.body.turns[0].activityEpoch).toEqual(expect.any(String))
      // Summary-only: the host has the first line, but never serves the rest.
      expect(JSON.stringify(turnsDuring.body)).not.toContain(marker)
      expect(JSON.stringify(sse.frames)).not.toContain(marker)

      const selector = `sessionId=${sessionId}&turn=${paused.turn.turn}`
        + `&kind=thinking&inFlightId=${encodeURIComponent(paused.entry.inFlightId)}&ord=0`
      const first = await get(fixture, `/dsh-bridge/details/item?${selector}`)
      expect(first.status, JSON.stringify(first.body)).toBe(200)
      expect(first.body).toMatchObject({
        kind: 'thinking', inFlight: true, inFlightId: paused.entry.inFlightId,
        attemptId: paused.entry.attemptId, ord: 0, turn: paused.turn.turn,
      })
      expect(first.body).not.toHaveProperty('seq')
      expect(first.body.parts.reasoning.text).toBe(firstLine)
      expect(first.body.parts.reasoning.totalBytes).toBe(Buffer.byteLength(firstLine))

      // The live read is bearer-authenticated and explicit.
      const unauthorized = await raw(fixture, 'GET', `/dsh-bridge/details/item?${selector}`)
      expect(unauthorized.status).toBe(401)
      const wrongTurn = await get(fixture,
        `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${paused.turn.turn + 10}`
        + `&kind=thinking&inFlightId=${encodeURIComponent(paused.entry.inFlightId)}&ord=0`)
      expect(wrongTurn.status).toBe(404)
      const unknown = await get(fixture,
        `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${paused.turn.turn}`
        + '&kind=thinking&inFlightId=not-a-live-id&ord=0')
      expect(unknown.status).toBe(404)
      const noText = await get(fixture,
        `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${paused.turn.turn}`
        + `&kind=thinking&inFlightId=${encodeURIComponent(paused.entry.inFlightId)}&ord=1`)
      expect(noText.status).toBe(404)
      const combined = await get(fixture,
        `/dsh-bridge/details/item?${selector}&seq=1`)
      expect(combined.status).toBe(400)
      const wrongKind = await get(fixture,
        `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${paused.turn.turn}`
        + `&kind=tool&callId=x&inFlightId=${encodeURIComponent(paused.entry.inFlightId)}`)
      expect(wrongKind.status).toBe(400)

      // Release the later paragraph; an explicit read sees the larger snapshot,
      // while `/turns` still carries only the first-line summary.
      expect((await post(fixture, '/mock-llm/release', { key: 'live-prefix' })).status).toBe(200)
      const second = await poll(async () => {
        const detail = await get(fixture, `/dsh-bridge/details/item?${selector}`)
        return detail.status === 200 && detail.body.parts.reasoning.text.includes(marker)
          ? detail
          : undefined
      }, 20000)
      expect(second.body.parts.reasoning.text.length)
        .toBeGreaterThan(first.body.parts.reasoning.text.length)
      const turnsAfter = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      expect(turnsAfter.body.turns[0].activityRevision)
        .toBeGreaterThan(turnsDuring.body.turns[0].activityRevision)
      expect(turnsAfter.body.turns[0].activityEpoch)
        .toBe(turnsDuring.body.turns[0].activityEpoch)
      expect(JSON.stringify(turnsAfter.body)).not.toContain(marker)
      expect(JSON.stringify(sse.frames)).not.toContain(marker)

      // Settle the attempt: exactly one committed line replaces the transient one.
      expect((await post(fixture, '/mock-llm/release', { key: 'live-rest' })).status).toBe(200)
      await sse.waitFor('turn-complete', 20000, mine)
      const committed = await poll(async () => {
        const detail = await get(fixture, `/dsh-bridge/details/item?${selector}`)
        return detail.status === 200 && typeof detail.body.seq === 'number' ? detail : undefined
      }, 20000)
      expect(committed.body).toMatchObject({
        kind: 'thinking', seq: expect.any(Number), ord: 0,
      })
      expect(committed.body).not.toHaveProperty('inFlight')
      expect(committed.body.parts.reasoning.text).toContain(marker)
      const settledTurns = await poll(async () => {
        const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
        const live = liveThinking(turns.body)
        return live === undefined ? turns.body : undefined
      }, 20000)
      const record = settledTurns.turns.find(entry => entry.turn === paused.turn.turn)
      expect(record.activity.filter(entry => entry.kind === 'thinking')).toHaveLength(1)
      expect(record.activity[0]).toMatchObject({ summary: firstLine })
      expect(record.activity[0]).not.toHaveProperty('inFlight')
      expect(JSON.stringify(settledTurns)).not.toContain(marker)
    } finally {
      sse.close()
    }
  }, 90000)
})
