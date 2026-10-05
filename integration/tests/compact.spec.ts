// dsh-emacs-bridge — integration spec: user-triggered context compaction.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Drives the compaction seam no other suite reaches: POST
// /dsh-bridge/sessions/compact through the live slash-command registry
// (`ctx.commands.execute(agent, '/compact', ...)`), which the standard preset
// mounts as `command-compact`.  A real turn establishes compactable history,
// then the manual compaction must (i) succeed with a 200 carrying the harness's
// own "Compacted N history items" text, (ii) surface `compaction` SSE frames
// carrying `sourceCommandId` (present exactly for a manual `/compact`), and
// (iii) broadcast the end frame before the 200 response resolves, because
// `commands.execute` awaits the whole transaction.  An empty session is a
// deterministic no-op: a 200 "No compactable history yet." with no
// `compaction` frame following.

import { describe, it, expect, inject } from 'vitest'
import {
  post, get, scriptMock, mockRequests, createSession, openSse, poll,
} from './util.mjs'

// The end frame and the 200 are read off two connections, so their client-side
// parse order can differ from the host's write order by a scheduling tick.
// The frame is broadcast during `commands.execute` and the 200 is only written
// afterwards, so the frame must never trail the response by more than this.
const ORDER_TOLERANCE_MS = 50

/**
 * POST /sessions/compact until one attempt is accepted, retrying while the
 * host reports the agent busy.  The agent may not be idle the instant the last
 * `turn-complete` lands, so a first attempt can settle as 409 without
 * compacting anything and without emitting a `compaction` frame; such an
 * attempt is cheap and non-mutating.
 *
 * Returns the accepted attempt's `{response, endSeen, postResolved}`, where
 * the two timestamps are the client-side parse times of its end frame and its
 * response (`endSeen` is null when no frame ever arrived).
 */
async function compactUntilAccepted(fixture, sessionId, sse) {
  const endMatch = (f) => f.sessionId === sessionId && f.phase === 'end'
  for (let attempt = 0; attempt < 20; attempt += 1) {
    let endSeen = null
    let postResolved = null
    const postPromise = post(fixture, '/dsh-bridge/sessions/compact', { sessionId })
      .then((response) => { postResolved = Date.now(); return response })
    const endPromise = sse.waitFor('compaction', 10000, endMatch)
      .then(() => { endSeen = Date.now(); return true })
      .catch(() => false)
    const winner = await Promise.race([
      endPromise.then((arrived) => (arrived ? 'end' : 'timeout')),
      postPromise.then(() => 'response'),
    ])
    if (winner === 'end') {
      // The frame landed first; the response is still in flight, so awaiting it
      // timestamps the 200 after the frame.
      return { response: await postPromise, endSeen, postResolved }
    }
    const response = await postPromise
    if (response.status === 200) {
      // Accepted, so the frame was broadcast before this response was written:
      // wait for it rather than leaving the ordering check unasserted.
      await endPromise
      return { response, endSeen, postResolved }
    }
    expect(response.status, JSON.stringify(response.body)).toBe(409)
    await new Promise((resolve) => setTimeout(resolve, 300))
  }
  throw new Error('compaction never settled as accepted')
}

describe('user-triggered compaction against a live fixture', () => {
  it('reports a no-op compaction on an empty session with no compaction frame', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const sessionId = await createSession(fixture)

    const sse = openSse(fixture, { timeoutMs: 8000 })
    const res = await post(fixture, '/dsh-bridge/sessions/compact', { sessionId })
    expect(res.status).toBe(200)
    expect(res.body.ok).toBe(true)
    expect(res.body.sessionId).toBe(sessionId)
    // A session with no compactable history is a success here, not an error.
    expect(res.body.text).toBe('No compactable history yet.')

    // No `compaction/start` was appended, so no `compaction` frame follows; let
    // the stream quiesce briefly and confirm none arrived.
    await new Promise((r) => setTimeout(r, 300))
    expect(sse.frames.filter((f) => f.kind === 'compaction')).toHaveLength(0)
    sse.close()
  }, 90000)

  it('compacts a session with history, framing manual events before the 200', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    // Two turns give the session real compactable surface history.
    await scriptMock(fixture, [
      { kind: 'text', text: 'First reply.' },
      { kind: 'text', text: 'Second reply.' },
    ])
    const sessionId = await createSession(fixture)

    const sse = openSse(fixture, { timeoutMs: 10000 })
    const completedTurns = () =>
      sse.frames.filter((f) => f.kind === 'turn-complete' && f.sessionId === sessionId).length
    await post(fixture, '/dsh-bridge/send', { text: 'Turn one.', sessionId })
    await poll(async () => completedTurns() >= 1, 20000)
    await post(fixture, '/dsh-bridge/send', { text: 'Turn two.', sessionId })
    await poll(async () => completedTurns() >= 2, 20000)

    // The frames are derived from the `compaction/*` log events, which the
    // test observes through this per-frame SSE contract (the log events are
    // log-only and not exposed by any client read route).
    const { response, endSeen, postResolved } = await compactUntilAccepted(fixture, sessionId, sse)

    expect(response.status).toBe(200)
    expect(response.body.ok).toBe(true)
    expect(response.body.sessionId).toBe(sessionId)
    expect(response.body.text).toMatch(/Compacted \d+ history items/)

    const frames = sse.frames.filter((f) => f.kind === 'compaction' && f.sessionId === sessionId)
    const start = frames.find((f) => f.phase === 'start')
    const end = frames.find((f) => f.phase === 'end')
    expect(start).toBeTruthy()
    expect(end).toBeTruthy()
    // A manual `/compact` carries sourceCommandId on its frames; the end frame
    // carries the summary's reclaimed token count.
    expect(start.sourceCommandId).toBeTruthy()
    expect(end.sourceCommandId).toBeTruthy()
    expect(typeof end.tokensReclaimed).toBe('number')
    // On the same stream the start edge precedes the end edge outright.
    expect(sse.frames.indexOf(start)).toBeLessThan(sse.frames.indexOf(end))
    // The end frame must be seen at or before the 200 response resolves.  Both
    // timestamps are always collected on the accepted attempt, so this is
    // asserted unconditionally.
    expect(endSeen).not.toBeNull()
    expect(endSeen - postResolved).toBeLessThanOrEqual(ORDER_TOLERANCE_MS)
    sse.close()
  }, 90000)

  it('runs the summarizer auxiliary call and replaces the surface', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [{ kind: 'text', text: 'Something to forget.' }])
    const sessionId = await createSession(fixture)

    const sse = openSse(fixture, { timeoutMs: 10000 })
    await post(fixture, '/dsh-bridge/send', { text: 'Worth forgetting.', sessionId })
    await sse.waitFor('turn-complete')

    // Retried like the framing test: the agent may still be settling when the
    // turn's boundary frame lands.  A 200 proves the summarizer's reply was
    // usable — a failed summarization would instead surface a 409 'summary'.
    const { response, endSeen } = await compactUntilAccepted(fixture, sessionId, sse)
    expect(response.status, JSON.stringify(response.body)).toBe(200)
    expect(endSeen).not.toBeNull()

    // The compaction summarization is an auxiliary model call with
    // purpose 'compaction'.
    const requests = await mockRequests(fixture)
    expect(requests.some((r) => r.purpose === 'compaction')).toBe(true)

    // The replacement surface is a single user/message checkpoint, so the turn
    // list still serves the compacted turn and the surface is consistent.
    const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
    expect(turns.status).toBe(200)
    expect(turns.body.running).toBe(false)
    sse.close()
  }, 90000)
})
