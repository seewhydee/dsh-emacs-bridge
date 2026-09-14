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
    // post-answer continuation. The session-title call is separate (it carries
    // purpose 'session-title'; see turns.spec for the title separation
    // assertion).
    const requests = await mockRequests(fixture)
    const mainTurns = requests.filter((r) => r.purpose === undefined)
    expect(mainTurns.length).toBe(2)
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

  it('settles a cancel from Emacs: the tool call fails and the turn continues', async () => {
    const fixture = inject('fixture')

    // {cancelled: true} rejects the waterfall listener's wait, which the
    // asker surfaces as the tool-call failure (the old cancel-envelope
    // semantics) — the turn is not parked: the model is called again with the
    // failed tool result and the scripted continuation completes it.
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [
      askUserQuestion('q1', 'Pick a color'),
      textReply('Cancelled, moving on.'),
    ])

    const sse = openSse(fixture, { timeoutMs: 8000 })
    const sessionId = await createSession(fixture)

    const sent = await post(fixture, '/dsh-bridge/send', { text: 'Pick a color for me.', sessionId })
    expect(sent.status).toBe(200)

    const askFrame = await sse.waitFor('ask-user')
    const cancel = await post(fixture, '/dsh-bridge/answer', {
      questionId: askFrame.questionId,
      sessionId,
      cancelled: true,
    })
    expect(cancel.status).toBe(200)
    expect(cancel.body.accepted).toBe(true)

    const resolved = await sse.waitFor('ask-user-resolved')
    expect(resolved.questionId).toBe(askFrame.questionId)
    expect(resolved.outcome).toBe('cancelled')

    // The turn ran to completion on the continuation reply.
    const complete = await sse.waitFor('turn-complete')
    expect(complete.sessionId).toBe(sessionId)
    expect(complete.reason).toBe('completed')

    const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
    const texts = turns.body.turns.flatMap((t) => t.segments.map((s) => s.text))
    expect(texts).toContain('Cancelled, moving on.')

    // Two main-turn calls: the ask, then the continuation past the failed
    // tool call.
    const requests = await mockRequests(fixture)
    const mainTurns = requests.filter((r) => r.purpose === undefined)
    expect(mainTurns.length).toBe(2)

    sse.close()
  }, 90000)

  it('reads 404 not-pending for a late or duplicate answer', async () => {
    const fixture = inject('fixture')

    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [askUserQuestion('q1', 'Pick a color'), textReply('Done.')])

    const sse = openSse(fixture, { timeoutMs: 8000 })
    const sessionId = await createSession(fixture)

    const sent = await post(fixture, '/dsh-bridge/send', { text: 'Pick a color for me.', sessionId })
    expect(sent.status).toBe(200)

    const askFrame = await sse.waitFor('ask-user')

    // A question the bridge never registered (or already retired) is 404.
    const unknown = await post(fixture, '/dsh-bridge/answer', {
      questionId: 'question-never-pending',
      sessionId,
      answers: [{ id: 'q1', selected: ['Red'] }],
    })
    expect(unknown.status).toBe(404)
    expect(unknown.body.accepted).toBe(false)
    expect(unknown.body.reason).toBe('not-pending')

    // First settlement wins...
    const answer = await post(fixture, '/dsh-bridge/answer', {
      questionId: askFrame.questionId,
      sessionId,
      answers: [{ id: 'q1', selected: ['Red'] }],
    })
    expect(answer.status).toBe(200)

    // ...so a duplicate POST (or one arriving after an abort) reads 404.
    const late = await post(fixture, '/dsh-bridge/answer', {
      questionId: askFrame.questionId,
      sessionId,
      answers: [{ id: 'q1', selected: ['Blue'] }],
    })
    expect(late.status).toBe(404)
    expect(late.body.accepted).toBe(false)
    expect(late.body.reason).toBe('not-pending')

    await sse.waitFor('turn-complete')
    sse.close()
  }, 90000)

  it('reads 400 bad-response for a malformed answer body and keeps the question pending', async () => {
    const fixture = inject('fixture')

    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [askUserQuestion('q1', 'Pick a color'), textReply('Done.')])

    const sse = openSse(fixture, { timeoutMs: 8000 })
    const sessionId = await createSession(fixture)

    const sent = await post(fixture, '/dsh-bridge/send', { text: 'Pick a color for me.', sessionId })
    expect(sent.status).toBe(200)

    const askFrame = await sse.waitFor('ask-user')

    // Missing ids entirely.
    const noIds = await post(fixture, '/dsh-bridge/answer', {})
    expect(noIds.status).toBe(400)
    expect(noIds.body.reason).toBe('bad-response')

    // Well-formed ids but no answers (and no cancelled flag).
    const noAnswers = await post(fixture, '/dsh-bridge/answer', {
      questionId: askFrame.questionId,
      sessionId,
    })
    expect(noAnswers.status).toBe(400)
    expect(noAnswers.body.accepted).toBe(false)
    expect(noAnswers.body.reason).toBe('bad-response')

    // Answers naming a question id the asker never asked about.
    const wrongId = await post(fixture, '/dsh-bridge/answer', {
      questionId: askFrame.questionId,
      sessionId,
      answers: [{ id: 'q-nope', selected: ['Red'] }],
    })
    expect(wrongId.status).toBe(400)
    expect(wrongId.body.reason).toBe('bad-response')

    // None of the rejects settled the question: a proper answer still lands.
    const answer = await post(fixture, '/dsh-bridge/answer', {
      questionId: askFrame.questionId,
      sessionId,
      answers: [{ id: 'q1', selected: ['Red'] }],
    })
    expect(answer.status).toBe(200)

    await sse.waitFor('turn-complete')
    sse.close()
  }, 90000)
})
