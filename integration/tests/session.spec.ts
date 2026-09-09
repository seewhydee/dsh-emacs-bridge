// dsh-emacs-bridge — integration spec: the read-only session report route.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Exercises the `sessionQuery` seam the unit suite cannot reach: the bridge's
// `GET /dsh-bridge/session` route observes a live session through the real
// host and returns the wire projection values (sessionStats, tokenUsage,
// modelSelection, permissions, title). Also pins the failure semantics
// (404 unknown, 400 malformed) and the read-only promise (an unknown id is
// never created or resumed).

import { describe, it, expect, inject } from 'vitest'
import { post, get, scriptMock, createSession, openSse } from './util.mjs'

describe('session report route against a live fixture', () => {
  it('returns the live session report with stats and token usage', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [{ kind: 'text', text: 'Reported.' }])
    const sessionId = await createSession(fixture)

    const sse = openSse(fixture, { timeoutMs: 10000 })
    await post(fixture, '/dsh-bridge/send', { text: 'Say one thing.', sessionId })
    await sse.waitFor('turn-complete')
    sse.close()

    const report = await get(fixture, `/dsh-bridge/session?sessionId=${sessionId}`)
    expect(report.status).toBe(200)
    expect(report.body.sessionId).toBe(sessionId)
    expect(report.body.live).toBe(true)
    expect(report.body.basis).toBe('observation')
    expect(Array.isArray(report.body.missing)).toBe(true)
    // The sessionStats/tokenUsage units ride the web profile, so the report
    // carries real numbers after one mock turn (the mock reports usage).
    expect(report.body.stats).not.toBeNull()
    expect(report.body.stats.turns).toBeGreaterThanOrEqual(1)
    expect(report.body.stats.steps).toBeGreaterThanOrEqual(1)
    expect(report.body.tokens).not.toBeNull()
    expect(report.body.tokens.outputTokens).toBeGreaterThan(0)
    expect(report.body.tokens.uncachedInputTokens).toBeGreaterThan(0)
    // The durable model-selection projection is present for a created session.
    expect(report.body.model).not.toBeNull()
    expect(typeof report.body.model.provider).toBe('string')
  }, 90000)

  it('404s an unknown id without creating or resuming it', async () => {
    const fixture = inject('fixture')
    const unknown = 'definitely-not-a-session'
    const missing = await get(fixture, `/dsh-bridge/session?sessionId=${unknown}`)
    expect(missing.status).toBe(404)

    const sessions = await get(fixture, '/dsh-bridge/sessions')
    expect(sessions.status).toBe(200)
    expect(sessions.body.sessions.some((session) => session.id === unknown)).toBe(false)
  }, 60000)

  it('400s a repeated sessionId query parameter', async () => {
    const fixture = inject('fixture')
    const malformed = await get(fixture, '/dsh-bridge/session?sessionId=a&sessionId=b')
    expect(malformed.status).toBe(400)
  }, 60000)

  it('defaults to a session when no id is named', async () => {
    const fixture = inject('fixture')
    const report = await get(fixture, '/dsh-bridge/session')
    expect(report.status).toBe(200)
    expect(typeof report.body.sessionId).toBe('string')
    expect(report.body.sessionId.length).toBeGreaterThan(0)
  }, 60000)
})
