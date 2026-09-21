// dsh-emacs-bridge — integration spec: plan mode and the goal lifecycle.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Exercises the mutation seams the unit suite cannot reach: POST
// /dsh-bridge/plan-mode through the preset's entry-local planMode controller
// (agentPresets.serviceFor), and the /dsh-bridge/goal/* lifecycle through the
// host-plane goals service (create-or-edit, CAS, transitions, clear). Also
// pins the failure semantics (400 invalid input, 404 no current goal) and the
// report's live plan/goal sections.

import { describe, it, expect, inject } from 'vitest'
import { post, get, createSession } from './util.mjs'

describe('plan mode and goals against a live fixture', () => {
  it('toggles plan mode through the preset controller and reports it', async () => {
    const fixture = inject('fixture')
    const sessionId = await createSession(fixture)

    const before = await get(fixture, `/dsh-bridge/session?sessionId=${sessionId}`)
    expect(before.status).toBe(200)
    // The standard preset mounts plan mode, so the section is live and off.
    expect(before.body.plan).not.toBeNull()
    expect(before.body.plan.active).toBe(false)
    expect(before.body.missing ?? []).not.toContain('plan')

    const on = await post(fixture, '/dsh-bridge/plan-mode', { sessionId, active: true })
    expect(on.status).toBe(200)
    expect(['committed', 'queued']).toContain(on.body.outcome)

    const afterOn = await get(fixture, `/dsh-bridge/session?sessionId=${sessionId}`)
    expect(afterOn.body.plan.active).toBe(true)

    const off = await post(fixture, '/dsh-bridge/plan-mode', { sessionId, active: false })
    expect(off.status).toBe(200)
    expect(['committed', 'queued', 'cancelled']).toContain(off.body.outcome)
  }, 90000)

  it('runs the goal lifecycle: create, edit, pause, resume, clear', async () => {
    const fixture = inject('fixture')
    const sessionId = await createSession(fixture)

    const empty = await get(fixture, `/dsh-bridge/session?sessionId=${sessionId}`)
    expect(empty.body.goal).toBeNull()

    const created = await post(fixture, '/dsh-bridge/goal/set', {
      sessionId, objective: 'ship it',
    })
    expect(created.status).toBe(200)
    expect(created.body.operation).toBe('created')
    expect(created.body.objective).toBe('ship it')

    const report = await get(fixture, `/dsh-bridge/session?sessionId=${sessionId}`)
    expect(report.body.goal.goal.objective).toBe('ship it')
    expect(report.body.goal.goal.phase).toBe('active')
    expect(report.body.goal.activation).toBe('armed')

    const edited = await post(fixture, '/dsh-bridge/goal/set', {
      sessionId, objective: 'ship it now', maxGoalRounds: 12,
    })
    expect(edited.status).toBe(200)
    expect(edited.body.operation).toBe('updated')
    const editedReport = await get(fixture, `/dsh-bridge/session?sessionId=${sessionId}`)
    expect(editedReport.body.goal.goal.objective).toBe('ship it now')
    expect(editedReport.body.goal.goal.maxGoalRounds).toBe(12)

    const paused = await post(fixture, '/dsh-bridge/goal/pause', { sessionId })
    expect(paused.status).toBe(200)
    expect(paused.body.phase).toBe('paused')
    expect(paused.body.activation).toBe('disarmed')

    const resumed = await post(fixture, '/dsh-bridge/goal/resume', { sessionId })
    expect(resumed.status).toBe(200)
    expect(resumed.body.phase).toBe('active')
    expect(resumed.body.activation).toBe('armed')

    const cleared = await post(fixture, '/dsh-bridge/goal/clear', { sessionId })
    expect(cleared.status).toBe(200)
    expect(cleared.body.operation).toBe('cleared')

    const gone = await get(fixture, `/dsh-bridge/session?sessionId=${sessionId}`)
    expect(gone.body.goal).toBeNull()

    // No current goal: the route answers the stable 404 code.
    const noGoal = await post(fixture, '/dsh-bridge/goal/pause', { sessionId })
    expect(noGoal.status).toBe(404)
    expect(noGoal.body.code).toBe('GOAL_NOT_FOUND')
  }, 90000)

  it('validates the goal set body and the plan active flag (400)', async () => {
    const fixture = inject('fixture')
    const sessionId = await createSession(fixture)

    const blank = await post(fixture, '/dsh-bridge/goal/set', { sessionId, objective: '   ' })
    expect(blank.status).toBe(400)
    const badCap = await post(fixture, '/dsh-bridge/goal/set', {
      sessionId, objective: 'x', maxGoalRounds: 0,
    })
    expect(badCap.status).toBe(400)

    const badActive = await post(fixture, '/dsh-bridge/plan-mode', { sessionId, active: 'yes' })
    expect(badActive.status).toBe(400)
  }, 90000)
})
