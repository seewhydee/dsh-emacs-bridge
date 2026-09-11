// dsh-emacs-bridge — integration spec: the /turns epoch contract behind
// incremental DSH-View filling.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// The Emacs DSH-View splices a grown turn in place only while the client's
// history epoch matches the host's `surface.replaceGeneration`, because that
// equality is what guarantees the turn list can only have grown by appending
// segments (see `turnsSince` in dsh-plugin/src/logic.ts). This spec pins that
// contract on a live host: a running turn grows segment by segment under a
// stable epoch, the inclusive `since` fetch re-sends the boundary turn in full
// (the exact record the Emacs splice consumes), and a stale epoch forces the
// full list the renderer falls back to. The Emacs seat of the splice itself is
// `dsh-bridge-it-incremental-fill-*` in integration/dsh-bridge-it.el.

import { describe, it, expect, inject } from 'vitest'
import { post, get, scriptMock, createSession, openSse, poll } from './util.mjs'

describe('the /turns epoch contract behind incremental fill', () => {
  it('grows a live turn under a stable epoch and re-sends the boundary turn in full', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [
      {
        kind: 'tool-call',
        name: 'ask_user_question',
        text: 'First segment.',
        arguments: {
          questions: [{ id: 'q1', question: 'Pause here', options: [{ label: 'Go' }] }],
        },
      },
      { kind: 'text', text: 'Second segment.' },
    ])
    const sessionId = await createSession(fixture)
    const sse = openSse(fixture, { timeoutMs: 20000 })
    try {
      await post(fixture, '/dsh-bridge/send', { text: 'Go.', sessionId })
      // The first committed segment nudges Emacs to refill the view.
      const nudged = await poll(() =>
        sse.frames.find((f) => f.kind === 'replies-changed' && f.sessionId === sessionId))
      // The turn then parks on the question, a deterministic one-segment state.
      const ask = await sse.waitFor('ask-user')

      const full = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      const epoch = full.body.epoch
      const turn = full.body.turns[0].turn
      expect(nudged.turn).toBe(turn)
      expect(full.body.running).toBe(true)
      expect(full.body.turns[0].segments.map((s) => s.text))
        .toEqual(['First segment.'])

      const mid = await get(
        fixture,
        `/dsh-bridge/turns?sessionId=${sessionId}&since=${turn}&epoch=${epoch}`,
      )
      expect(mid.body.incremental).toBe(true)
      expect(mid.body.epoch).toBe(epoch)
      expect(mid.body.turns[0].turn).toBe(turn)
      expect(mid.body.turns[0].segments.length).toBe(1)

      await post(fixture, '/dsh-bridge/answer', {
        questionId: ask.questionId,
        sessionId,
        answers: [{ id: 'q1', selected: ['Go'] }],
      })
      await sse.waitFor('turn-complete')

      // The same epoch now serves a two-segment boundary turn: the record the
      // Emacs splice compares its provenance keys against.
      const grown = await get(
        fixture,
        `/dsh-bridge/turns?sessionId=${sessionId}&since=${turn}&epoch=${epoch}`,
      )
      expect(grown.body.incremental).toBe(true)
      expect(grown.body.epoch).toBe(epoch)
      expect(grown.body.turns[0].turn).toBe(turn)
      expect(grown.body.turns[0].segments.map((s) => s.text))
        .toEqual(['First segment.', 'Second segment.'])
      // The `(step . time)' identity Emacs keys a segment on is stable and ordered.
      expect(grown.body.turns[0].segments.map((s) => s.step)).toEqual([1, 2])
      expect(grown.body.turns[0].segments.every((s) => typeof s.time === 'number'))
        .toBe(true)
    } finally {
      sse.close()
    }
  }, 90000)

  it('serves the full list (incremental: false) when the client epoch is stale', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [{ kind: 'text', text: 'One turn.' }])
    const sessionId = await createSession(fixture)
    const sse = openSse(fixture, { timeoutMs: 20000 })
    try {
      await post(fixture, '/dsh-bridge/send', { text: 'hi', sessionId })
      await sse.waitFor('turn-complete')
      const full = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      const { epoch } = full.body
      const turn = full.body.turns[0].turn
      const stale = await get(
        fixture,
        `/dsh-bridge/turns?sessionId=${sessionId}&since=${turn}&epoch=${epoch + 1}`,
      )
      expect(stale.body.incremental).toBe(false)
      expect(stale.body.turns.length).toBeGreaterThanOrEqual(1)
    } finally {
      sse.close()
    }
  }, 90000)
})
