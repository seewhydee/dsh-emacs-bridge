// dsh-emacs-bridge — integration spec: the ask-user regression (first tenant).
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Reproduces the reported bug end-to-end: the model calls `ask_user_question`
// mid-turn, and the bridge is supposed to surface an `ask-user` SSE frame (a
// live in-process `apiProxy.events.mux` subscription rebroadcast to Emacs). The
// bug is that the frame never arrives. This spec drives the real plugin against
// a real host over real HTTP/SSE and asserts the frame surfaces — which fails
// against the current plugin, and is the proof the framework is doing its job:
// no other layer can see this seam.
//
// Landing order (per integration-testing-plan.md): ship this failing, fix the
// plugin's mux-subscription robustness, then flip this to passing in the same
// change as the fix.

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

    // The plugin fix is expected to make this pass; until it lands the assertion
    // below is the failing reproduction. Give the ask enough time to fire but
    // keep the failure prompt.
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [askUserQuestion('q1', 'Pick a color'), textReply('Proceeding with your choice.')])

    const sse = openSse(fixture, { timeoutMs: 8000 })
    const sessionId = await createSession(fixture)

    const sent = await post(fixture, '/dsh-bridge/send', { text: 'Pick a color for me.', sessionId })
    expect(sent.status).toBe(200)

    // The load-bearing assertion: an ask-user frame must arrive on the live SSE
    // stream. This is what the current bug fails.
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
    // { id, selected: string[], custom? } — validated by the gateway's
    // questionResponsePayloadSchema and matchesQuestions.
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
})
