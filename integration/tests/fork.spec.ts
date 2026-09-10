// dsh-emacs-bridge — integration spec: branch a turn into a new session.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Drives POST /dsh-bridge/fork against the shared live fixture and the real
// sessionController service seam: the /turns `endSeq` anchor, the child's
// lineage and inherited prefix, the atSeq-omitted fallback, and the failure
// taxonomy (unknown source, bad argument, an anchor that pins an open turn).
// Each test uses its own session so the shared fixture stays deterministic.

import { describe, it, expect, inject } from 'vitest'
import {
  post, get, scriptMock, createSession, openSse,
} from './util.mjs'

/** Send one scripted text turn and wait for it to complete. */
async function runTextTurn(fixture, sessionId, text = 'The reply.') {
  await scriptMock(fixture, [{ kind: 'text', text }])
  const sse = openSse(fixture, { timeoutMs: 10000 })
  try {
    const sent = await post(fixture, '/dsh-bridge/send', { text: 'Say it.', sessionId })
    expect(sent.status).toBe(200)
    await sse.waitFor('turn-complete')
  } finally {
    sse.close()
  }
}

describe('branching a turn (POST /dsh-bridge/fork)', () => {
  it('forks the shown turn at its endSeq and exposes the child lineage', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const sessionId = await createSession(fixture)
    await runTextTurn(fixture, sessionId, 'Branch me.')

    // /turns now carries the closing turn's endSeq: the fork anchor.
    const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
    const newest = turns.body.turns[0]
    expect(typeof newest.endSeq).toBe('number')

    const forked = await post(fixture, '/dsh-bridge/fork', {
      sessionId, atSeq: newest.endSeq,
    })
    expect(forked.status).toBe(201)
    expect(forked.body.ok).toBe(true)
    expect(typeof forked.body.sessionId).toBe('string')
    expect(forked.body.sessionId).not.toBe(sessionId)
    expect(forked.body.parentSessionId).toBe(sessionId)
    expect(forked.body.atSeq).toBe(newest.endSeq)
    const childId = forked.body.sessionId

    // The child is a seeded, ordinary session under the source.
    const report = await get(fixture, `/dsh-bridge/session?sessionId=${childId}`)
    expect(report.status).toBe(200)
    expect(report.body.live).toBe(true)
    expect(report.body.parentSession).toBe(sessionId)
    expect(report.body.isSeeded).toBe(true)

    // It is on the live roster.
    const sessions = await get(fixture, '/dsh-bridge/sessions')
    const row = (sessions.body.sessions ?? []).find((s) => s.id === childId)
    expect(row).toBeDefined()
    expect(row.live).toBe(true)

    // The fork seeded the child with the source's completed turns.
    const childTurns = await get(fixture, `/dsh-bridge/turns?sessionId=${childId}`)
    expect(childTurns.body.turns.length).toBeGreaterThanOrEqual(1)
    expect(childTurns.body.turns[0].segments[0].text).toBe('Branch me.')
  }, 90000)

  it('forks the last completed turn when atSeq is omitted', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const sessionId = await createSession(fixture)
    await runTextTurn(fixture, sessionId)

    const forked = await post(fixture, '/dsh-bridge/fork', { sessionId })
    expect(forked.status).toBe(201)
    expect(forked.body.atSeq).toBeNull()
    expect(forked.body.sessionId).not.toBe(sessionId)
  }, 90000)

  it('refuses an anchor that pins an open (incomplete) turn', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const sessionId = await createSession(fixture)

    // A hanging turn leaves the session's only turn open: no turn/end to cut at.
    await scriptMock(fixture, [{ kind: 'hang' }])
    const sse = openSse(fixture, { timeoutMs: 10000 })
    await post(fixture, '/dsh-bridge/send', { text: 'Never finish.', sessionId })
    await sse.waitFor('turn-start')

    const refused = await post(fixture, '/dsh-bridge/fork', { sessionId, atSeq: 1 })
    expect(refused.status).toBe(409)
    expect(refused.body.error).toMatch(/fork|completed|turn/i)
    sse.close()
  }, 90000)

  it('rejects a bad atSeq and an unknown source (400 / 404)', async () => {
    const fixture = inject('fixture')
    for (const atSeq of [-1, 1.5, 'x']) {
      const bad = await post(fixture, '/dsh-bridge/fork', {
        sessionId: 'session-does-not-exist', atSeq,
      })
      expect(bad.status).toBe(400)
    }

    const unknown = await post(fixture, '/dsh-bridge/fork', {
      sessionId: 'session-does-not-exist',
    })
    expect(unknown.status).toBe(404)
  }, 30000)
})
