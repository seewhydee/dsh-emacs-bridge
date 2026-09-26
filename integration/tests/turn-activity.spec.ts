// dsh-emacs-bridge — integration spec: the turn-activity fold and its SSE nudge.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Pins the host-plane contract behind DSH-View turn activity on a live host:
// `GET /turns` serves one entry per dispatched tool call, its result, and a
// one-line summary per reasoning block (never the full chain of thought), and
// a turn whose opening steps produced no text is served live with
// `segments: []` so the view can stream activity before the first reply. The
// debounced `activity-changed` frame nudges Emacs to re-pull. The Emacs seat of
// the render/toggle is `dsh-bridge-it-activity-*` in integration/dsh-bridge-it.el.

import { afterAll, describe, expect, it, inject } from 'vitest'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { post, get, scriptMock, createSession, openSse } from './util.mjs'

/** Temp workspace directories created by this spec, removed on teardown. */
const tempDirs = []

/** A fresh, canonical scratch workspace for one test. */
function tempWorkspace() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'dsh-bridge-activity-')))
  tempDirs.push(dir)
  return dir
}

afterAll(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true })
})

/** The ask-user tool call that parks a turn in a deterministic live state. */
function askUserCall(question) {
  return {
    kind: 'tool-call',
    name: 'ask_user_question',
    arguments: { questions: [{ id: 'q1', question, options: [{ label: 'Yes' }] }] },
  }
}

describe('the turn-activity fold', () => {
  it('serves tool calls, results, and thinking summaries, summary-only', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const dir = tempWorkspace()
    const cot = 'Thinking about how to take the note.\n\n'
      + 'Weighing the options, one paragraph at a time.\n\n'
      + 'INTERNAL-REASONING-MARKER: this buried paragraph never crosses the wire.'
    await scriptMock(fixture, [
      {
        kind: 'reasoning',
        text: cot,
        toolCall: {
          name: 'write',
          arguments: { file_path: 'note.txt', content: 'alpha\n' },
        },
      },
      { kind: 'text', text: 'Wrote the note.' },
    ])
    const sessionId = await createSession(fixture, dir)
    const sse = openSse(fixture, { timeoutMs: 20000 })
    // The fixture host is shared across specs and keeps serving their
    // sessions, so every stream wait names this test's session.
    const mine = (frame) => frame.sessionId === sessionId
    try {
      const sent = await post(fixture, '/dsh-bridge/send', { text: 'Take a note.', sessionId })
      expect(sent.status).toBe(200)
      await sse.waitFor('turn-complete', 20000, mine)
      // The debounced activity nudge fires after the burst; it is a bare
      // session-scoped notice, not a payload.
      const nudge = await sse.waitFor('activity-changed', 8000, mine)
      expect(nudge.sessionId).toBe(sessionId)
      // The whole burst (reasoning message, call, result) coalesces into that
      // one frame: nothing relevant is logged after turn-complete, so once we
      // are well past the 500 ms debounce window no second frame may arrive.
      await new Promise((resolve) => { setTimeout(resolve, 2000) })
      expect(sse.frames.filter((frame) => frame.kind === 'activity-changed' && mine(frame)))
        .toHaveLength(1)

      const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      const turn = turns.body.turns.find((record) => record.activity !== undefined)
      expect(turn).toBeTruthy()
      expect(turn.activity.map((entry) => entry.kind))
        .toEqual(['thinking', 'tool-call', 'tool-result'])
      const [thinking, call, result] = turn.activity
      // The summary is the block's first line, parity with the web client's
      // settled ReasoningRow preview.
      expect(thinking.summary).toBe('Thinking about how to take the note.')
      expect(call).toMatchObject({ name: 'write', summary: 'note.txt' })
      expect(result).toMatchObject({ name: 'write', isError: false })
      // Every entry carries its identity and ordering facts.
      for (const entry of turn.activity) {
        expect(entry.turn).toBe(turn.turn)
        expect(typeof entry.step).toBe('number')
        expect(typeof entry.time).toBe('number')
        expect(typeof entry.seq).toBe('number')
        expect(typeof entry.ord).toBe('number')
      }
      // Summary-only: the reasoning's later paragraphs stay on the host.
      expect(JSON.stringify(turns.body)).not.toContain('INTERNAL-REASONING-MARKER')

      // The incremental suffix (the Emacs splice's input) carries the same list.
      const suffix = await get(
        fixture,
        `/dsh-bridge/turns?sessionId=${sessionId}&since=${turn.turn}&epoch=${turns.body.epoch}`,
      )
      expect(suffix.body.incremental).toBe(true)
      expect(suffix.body.turns[0].activity).toEqual(turn.activity)
    } finally {
      sse.close()
    }
  }, 90000)

  it('serves live activity for a textless first step (reasoning plus a call)', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [
      {
        kind: 'reasoning',
        text: 'Ask the user before touching anything.',
        toolCall: {
          name: 'ask_user_question',
          arguments: { questions: [{ id: 'q1', question: 'Proceed?', options: [{ label: 'Yes' }] }] },
        },
      },
      { kind: 'text', text: 'Done after the answer.' },
    ])
    const sessionId = await createSession(fixture)
    const sse = openSse(fixture, { timeoutMs: 20000 })
    const mine = (frame) => frame.sessionId === sessionId
    try {
      await post(fixture, '/dsh-bridge/send', { text: 'Start.', sessionId })
      const ask = await sse.waitFor('ask-user', 20000, mine)

      // Mid-turn: no text segment exists yet, so the record is activity-only.
      const live = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      expect(live.body.running).toBe(true)
      const pending = live.body.turns.find((record) => record.turn !== undefined
        && record.activity !== undefined)
      expect(pending).toBeTruthy()
      expect(pending.segments).toEqual([])
      expect(pending.activity.map((entry) => entry.kind)).toEqual(['thinking', 'tool-call'])
      expect(pending.activity[0].summary).toContain('Ask the user')
      expect(pending.activity[1]).toMatchObject({ name: 'ask_user_question' })

      await post(fixture, '/dsh-bridge/answer', {
        questionId: ask.questionId,
        sessionId,
        answers: [{ id: 'q1', selected: ['Yes'] }],
      })
      await sse.waitFor('turn-complete', 20000, mine)

      const settled = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      const record = settled.body.turns.find((entry) => entry.turn === pending.turn)
      expect(record.segments.map((segment) => segment.text)).toEqual(['Done after the answer.'])
      expect(record.activity.map((entry) => entry.kind))
        .toEqual(['thinking', 'tool-call', 'tool-result'])
    } finally {
      sse.close()
    }
  }, 90000)

  it('serves a tool-only first step live (no text and no reasoning)', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [
      askUserCall('Proceed with no preamble?'),
      { kind: 'text', text: 'Finished.' },
    ])
    const sessionId = await createSession(fixture)
    const sse = openSse(fixture, { timeoutMs: 20000 })
    const mine = (frame) => frame.sessionId === sessionId
    try {
      await post(fixture, '/dsh-bridge/send', { text: 'Go.', sessionId })
      const ask = await sse.waitFor('ask-user', 20000, mine)

      const live = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      const pending = live.body.turns.find((record) => record.activity !== undefined)
      expect(pending).toBeTruthy()
      expect(pending.segments).toEqual([])
      expect(pending.activity.map((entry) => entry.kind)).toEqual(['tool-call'])
      expect(pending.activity[0]).toMatchObject({ name: 'ask_user_question' })

      await post(fixture, '/dsh-bridge/answer', {
        questionId: ask.questionId,
        sessionId,
        answers: [{ id: 'q1', selected: ['Yes'] }],
      })
      await sse.waitFor('turn-complete', 20000, mine)
    } finally {
      sse.close()
    }
  }, 90000)
})
