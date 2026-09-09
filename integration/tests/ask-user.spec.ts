// dsh-emacs-bridge — integration spec: the ask-user seam (first tenant).
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Drives the ask-user path end-to-end: the model calls `ask_user_question`
// mid-turn, and the bridge's `user-questions/request` waterfall answerer must
// surface an `ask-user` SSE frame to Emacs (replaying it to a reconnecting
// Emacs client) and settle the turn from `/dsh-bridge/answer`. With the web UI
// also open the same request must still reach the browser forwarder, and the
// resolution frame must carry the asker's question ids so the browser plugin
// can dismiss its own panel. A browser-identified draft stream alone must NOT
// claim the question (there is no Emacs to answer it). This spec drives the
// real plugin against a real host over real HTTP/SSE — no other layer can see
// this seam.

import { describe, it, expect, inject } from 'vitest'
import {
  post, get, scriptMock, mockRequests, createSession, openSse,
} from './util.mjs'

const askUserQuestion = (id, question) => ({
  kind: 'tool-call',
  name: 'ask_user_question',
  arguments: {
    questions: [{ id, question, options: [{ label: 'Red' }, { label: 'Blue' }] }],
  },
})
const textReply = (text) => ({ kind: 'text', text })

describe('ask-user surfacing', () => {
  it('surfaces an ask-user SSE frame, replays on reconnect, and answers', async () => {
    const fixture = inject('fixture')

    // If we get here the ask surfaced; drive the answer flow to completion.
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [askUserQuestion('q1', 'Pick a color'), textReply('Proceeding with your choice.')])

    const sse = openSse(fixture, { timeoutMs: 8000 })
    const sessionId = await createSession(fixture)

    const sent = await post(fixture, '/dsh-bridge/send', { text: 'Pick a color for me.', sessionId })
    expect(sent.status).toBe(200)

    // The load-bearing assertion: an ask-user frame must arrive on the live SSE
    // stream — the proof the waterfall answerer is wired correctly.
    const askFrame = await sse.waitFor('ask-user')

    // If we get here the bug is fixed; drive the answer flow to completion.
    expect(askFrame.sessionId).toBe(sessionId)

    // A fresh SSE connection replays the still-pending question (the bridge's
    // /events route re-announces pendingQuestions on subscribe), so an Emacs
    // that connects after the ask still learns of it.
    const replay = openSse(fixture, { timeoutMs: 8000 })
    const replayed = await replay.waitFor('ask-user')
    expect(replayed.questionId).toBe(askFrame.questionId)
    replay.close()

    // The answer shape is the harness's AskUserQuestionAnswer contract:
    // { id, selected: string[], custom? } — validated host-side by the bridge's
    // answerMatchesQuestions against the pending request's question ids.
    const answer = await post(fixture, '/dsh-bridge/answer', {
      questionId: askFrame.questionId,
      sessionId,
      answers: [{ id: 'q1', selected: ['Red'] }],
    })
    expect(answer.status).toBe(200)

    const resolved = await sse.waitFor('ask-user-resolved')
    expect(resolved.questionId).toBe(askFrame.questionId)

    const complete = await sse.waitFor('turn-complete')
    expect(complete.sessionId).toBe(sessionId)

    // The turn should be visible with both the pre-ask and post-answer segments.
    const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
    expect(turns.body.running).toBe(false)
    expect(turns.body.turns.length).toBeGreaterThan(0)

    // The mock saw exactly two main-turn calls (no purpose): the ask and the
    // post-answer continuation. The session-title call is separate (see
    // turns.spec for the title separation assertion).
    const requests = await mockRequests(fixture)
    const mainTurns = requests.filter((r) => r.purpose === undefined)
    // One fresh session still fires an automatic first-prompt title call; but
    // under this scenario the turn is one main call for the ask + one for the
    // continuation after the answer.
    expect(mainTurns.length).toBeGreaterThanOrEqual(2)
    expect(mainTurns.filter((r) => r.provider === 'mock').length).toBe(mainTurns.length)

    sse.close()
  }, 90000)

  it('offers the question to the web UI too, then settles it from Emacs', async () => {
    const fixture = inject('fixture')

    // Coexistence: with Emacs AND the web UI open, the bridge must still
    // surface the question to Emacs, but it must also hand the request on to
    // the browser forwarder (next()) so the web UI's own panel appears. The
    // resolution frame reaches the browser stream with the asker's question
    // ids, which is how the browser plugin dismisses that panel once Emacs
    // answered first.
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [askUserQuestion('q1', 'Pick a color'), textReply('Proceeding with your choice.')])

    const emacs = openSse(fixture, { timeoutMs: 8000 })
    const browser = openSse(fixture, { timeoutMs: 8000, purpose: 'draft' })
    const sessionId = await createSession(fixture)

    const sent = await post(fixture, '/dsh-bridge/send', { text: 'Pick a color for me.', sessionId })
    expect(sent.status).toBe(200)

    const askFrame = await emacs.waitFor('ask-user')
    expect(askFrame.sessionId).toBe(sessionId)

    const answer = await post(fixture, '/dsh-bridge/answer', {
      questionId: askFrame.questionId,
      sessionId,
      answers: [{ id: 'q1', selected: ['Red'] }],
    })
    expect(answer.status).toBe(200)

    // The browser stream learns the same question is resolved, with the ids
    // the web panel can match on.
    const resolved = await browser.waitFor('ask-user-resolved')
    expect(resolved.questionId).toBe(askFrame.questionId)
    expect(resolved.questionIds).toEqual(['q1'])

    const complete = await emacs.waitFor('turn-complete')
    expect(complete.sessionId).toBe(sessionId)

    emacs.close()
    browser.close()
  }, 90000)

  it('does not claim a question when only the browser draft stream is connected', async () => {
    const fixture = inject('fixture')

    // Regression: the ask-user ownership check once counted every SSE
    // client, and the browser plugin's draft-push EventSource connects on
    // load. With the web UI open and Emacs NOT connected, the bridge must
    // delegate the question to the host's browser forwarder (next()) rather
    // than claim it — there is no Emacs to answer it.
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [askUserQuestion('q1', 'Pick a color'), textReply('never reached')])

    // The browser's marked draft stream (purpose=draft), and no Emacs client.
    const browser = openSse(fixture, { timeoutMs: 8000, purpose: 'draft' })
    const sessionId = await createSession(fixture)

    const sent = await post(fixture, '/dsh-bridge/send', { text: 'Pick a color for me.', sessionId })
    expect(sent.status).toBe(200)

    // The load-bearing assertion: no ask-user frame may reach the stream —
    // the bridge did not claim the question on the browser's behalf. (The
    // turn itself then waits on the host's browser forwarder; the fixture is
    // torn down with the turn pending, which is fine.)
    await expect(browser.waitFor('ask-user', 3000)).rejects.toThrow()

    browser.close()
  }, 90000)
})
