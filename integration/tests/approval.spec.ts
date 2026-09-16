// dsh-emacs-bridge — integration spec: the approval seam (second tenant).
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
// Drives the approval path end-to-end: the model asks `bash` for a
// `danger-full-access` sandbox escalation, and the bridge's
// `approval/request` waterfall answerer must surface an `approval` SSE frame
// to Emacs (with the folded tool-call detail, and replaying to a reconnecting
// Emacs) and settle the turn from `POST /dsh-bridge/approval`.  The bridge
// offers the request to Emacs and, when the web UI is open, to the browser
// forwarder too, so the two presentations race; a `purpose=draft`-only stream
// (the browser, which cannot answer) must NOT be treated as an Emacs answerer,
// and an `answer=0` notify-only Emacs must receive the notification but leave
// the request to the web UI.  A real state change (a marker file the escalated
// command touches) proves the decision reached the sandbox, not merely the
// waterfall.

import { describe, it, expect, inject } from 'vitest'
import { existsSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import {
  post, get, scriptMock, createSession, openSse, REPO_ROOT,
} from './util.mjs'

const bashEscalation = (command: string, justification = 'the command needs wider access') => ({
  kind: 'tool-call',
  name: 'bash',
  arguments: {
    command,
    // `description` is a required bash argument (shown in the UI), independent
    // of the escalation `justification` the approval prompt carries.
    description: 'Run a harmless marker command',
    sandbox_permissions: 'danger-full-access',
    justification,
  },
})
const textReply = (text: string) => ({ kind: 'text', text })

/** A unique marker path under the workspace root the escalated command can touch. */
const markerPath = (label: string) => join(REPO_ROOT, `.dsh-approval-${label}-${process.pid}-${Date.now()}`)

describe('approval surfacing', () => {
  it('surfaces an approval with tool detail, replays it, and runs the command on allowed-once', async () => {
    const fixture = inject('fixture')
    const marker = markerPath('allowed')
    rmSync(marker, { force: true })

    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [
      bashEscalation(`touch ${JSON.stringify(marker)}`),
      textReply('Ran it.'),
    ])

    const sse = openSse(fixture, { timeoutMs: 8000 })
    const sessionId = await createSession(fixture)

    const sent = await post(fixture, '/dsh-bridge/send', { text: 'Touch the marker.', sessionId })
    expect(sent.status).toBe(200)

    // The load-bearing assertion: an approval frame arrives on the live SSE
    // stream, carrying the asker's tool identity and reason.
    const frame = await sse.waitFor('approval')
    expect(frame.sessionId).toBe(sessionId)
    expect(frame.toolName).toBe('bash')
    expect(frame.callId).toBeTruthy()
    expect(frame.reason).toContain('escalate sandbox to danger-full-access')
    // The tool-call detail is folded host-side, so approving is not blind.
    expect(frame.detail?.name).toBe('bash')
    expect(frame.detail?.arguments).toContain(marker)

    // A fresh SSE connection replays the still-pending approval (the /events
    // route re-announces pendingApprovals on subscribe), so an Emacs that
    // connects after the ask still learns of it.
    const replay = openSse(fixture, { timeoutMs: 8000 })
    const replayed = await replay.waitFor('approval')
    expect(replayed.approvalId).toBe(frame.approvalId)
    expect(replayed.detail?.name).toBe('bash')
    replay.close()

    const decision = await post(fixture, '/dsh-bridge/approval', {
      approvalId: frame.approvalId,
      sessionId,
      decision: 'allowed-once',
    })
    expect(decision.status).toBe(200)
    expect(decision.body.accepted).toBe(true)

    const resolved = await sse.waitFor('approval-resolved')
    expect(resolved.approvalId).toBe(frame.approvalId)
    expect(resolved.outcome).toBe('allowed-once')

    const complete = await sse.waitFor('turn-complete')
    expect(complete.sessionId).toBe(sessionId)

    // The escalated command actually ran under the granted mode.
    expect(existsSync(marker)).toBe(true)
    rmSync(marker, { force: true })

    // The model saw the tool result and produced the scripted continuation.
    const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
    const texts = turns.body.turns.flatMap((t: { segments: { text: string }[] }) => t.segments.map((s) => s.text))
    expect(texts).toContain('Ran it.')

    // First settlement wins: a duplicate decision reads 404 not-pending, and a
    // decision naming a different session cannot leak across sessions.
    const late = await post(fixture, '/dsh-bridge/approval', {
      approvalId: frame.approvalId, sessionId, decision: 'rejected',
    })
    expect(late.status).toBe(404)
    expect(late.body.reason).toBe('not-pending')
    const wrongSession = await post(fixture, '/dsh-bridge/approval', {
      approvalId: frame.approvalId, sessionId: 'session-not-this-one', decision: 'rejected',
    })
    expect(wrongSession.status).toBe(404)

    sse.close()
  }, 90000)

  it('fails the tool call and does not run the command on rejected', async () => {
    const fixture = inject('fixture')
    const marker = markerPath('rejected')
    rmSync(marker, { force: true })

    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [
      bashEscalation(`touch ${JSON.stringify(marker)}`),
      textReply('Moving on after rejection.'),
    ])

    const sse = openSse(fixture, { timeoutMs: 8000 })
    const sessionId = await createSession(fixture)
    await post(fixture, '/dsh-bridge/send', { text: 'Touch the marker.', sessionId })

    const frame = await sse.waitFor('approval')
    const decision = await post(fixture, '/dsh-bridge/approval', {
      approvalId: frame.approvalId, sessionId, decision: 'rejected',
    })
    expect(decision.status).toBe(200)

    const resolved = await sse.waitFor('approval-resolved')
    expect(resolved.outcome).toBe('rejected')

    const complete = await sse.waitFor('turn-complete')
    expect(complete.sessionId).toBe(sessionId)

    // The rejection failed the tool call: the command never ran, and the model
    // continued from the failure (rather than the turn erroring out).
    expect(existsSync(marker)).toBe(false)
    const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
    const texts = turns.body.turns.flatMap((t: { segments: { text: string }[] }) => t.segments.map((s) => s.text))
    expect(texts).toContain('Moving on after rejection.')

    sse.close()
  }, 90000)

  it('settles a cancelled approval and does not run the command', async () => {
    const fixture = inject('fixture')
    const marker = markerPath('cancelled')
    rmSync(marker, { force: true })

    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [
      bashEscalation(`touch ${JSON.stringify(marker)}`),
      textReply('Cancelled, moving on.'),
    ])

    const sse = openSse(fixture, { timeoutMs: 8000 })
    const sessionId = await createSession(fixture)
    await post(fixture, '/dsh-bridge/send', { text: 'Touch the marker.', sessionId })

    const frame = await sse.waitFor('approval')
    const decision = await post(fixture, '/dsh-bridge/approval', {
      approvalId: frame.approvalId, sessionId, decision: 'cancelled',
    })
    expect(decision.status).toBe(200)

    const resolved = await sse.waitFor('approval-resolved')
    expect(resolved.outcome).toBe('cancelled')

    await sse.waitFor('turn-complete')
    expect(existsSync(marker)).toBe(false)

    sse.close()
  }, 90000)

  it('offers the approval to the web UI too, then settles it from Emacs', async () => {
    const fixture = inject('fixture')
    const marker = markerPath('raced')
    rmSync(marker, { force: true })

    // Coexistence: with Emacs AND the web UI open, the bridge must still
    // surface the approval to Emacs, but it must also hand the request on to
    // the browser forwarder (next()) so the web UI's own panel appears. The
    // resolution frame reaches the browser stream with the asker's tool
    // identity, which is how the browser plugin dismisses that panel once
    // Emacs answered first.
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [
      bashEscalation(`touch ${JSON.stringify(marker)}`),
      textReply('Ran it after the race.'),
    ])

    const emacs = openSse(fixture, { timeoutMs: 8000 })
    const browser = openSse(fixture, { timeoutMs: 8000, purpose: 'draft' })
    const sessionId = await createSession(fixture)

    const sent = await post(fixture, '/dsh-bridge/send', { text: 'Touch the marker.', sessionId })
    expect(sent.status).toBe(200)

    const frame = await emacs.waitFor('approval')
    expect(frame.toolName).toBe('bash')
    // The browser stream is notified too (the bridge broadcasts to every
    // subscriber), though the web panel itself is driven by the forwarded
    // waterfall rather than this stream.
    const browserFrame = await browser.waitFor('approval')
    expect(browserFrame.approvalId).toBe(frame.approvalId)

    const decision = await post(fixture, '/dsh-bridge/approval', {
      approvalId: frame.approvalId, sessionId, decision: 'allowed-once',
    })
    expect(decision.status).toBe(200)

    // The browser stream learns the same approval is resolved, carrying the
    // tool identity the web panel matches on to dismiss itself.
    const resolved = await browser.waitFor('approval-resolved')
    expect(resolved.approvalId).toBe(frame.approvalId)
    expect(resolved.toolName).toBe('bash')
    expect(resolved.callId).toBe(frame.callId)

    await emacs.waitFor('turn-complete')
    expect(existsSync(marker)).toBe(true)
    rmSync(marker, { force: true })

    emacs.close()
    browser.close()
  }, 90000)

  it('does not claim an approval when only the browser draft stream is connected', async () => {
    const fixture = inject('fixture')

    // Regression: the browser plugin's draft-push EventSource connects on load.
    // With the web UI open and Emacs NOT connected, the bridge must delegate
    // the approval to the host's browser forwarder (next()) rather than claim
    // it — there is no Emacs to decide it, and claiming it exclusively would
    // strand the turn with no panel.
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [bashEscalation('true'), textReply('never reached')])

    const browser = openSse(fixture, { timeoutMs: 8000, purpose: 'draft' })
    const sessionId = await createSession(fixture)
    await post(fixture, '/dsh-bridge/send', { text: 'Escalate.', sessionId })

    await expect(browser.waitFor('approval', 3000)).rejects.toThrow()

    browser.close()
  }, 90000)

  it('notifies a notify-only Emacs without claiming the approval', async () => {
    const fixture = inject('fixture')

    // `dsh-bridge-approval-answer' = `notify-only' connects with `answer=0':
    // the stream still receives the frame (so Emacs can show it), but the host
    // does not count it as an answerer and delegates to the web UI instead.
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [bashEscalation('true'), textReply('never reached')])

    const notify = openSse(fixture, { timeoutMs: 8000, answer: '0' })
    const sessionId = await createSession(fixture)
    await post(fixture, '/dsh-bridge/send', { text: 'Escalate.', sessionId })

    const frame = await notify.waitFor('approval')
    expect(frame.toolName).toBe('bash')
    // There is no bridge-side pending approval to settle: the request went to
    // the browser forwarder, so Emacs cannot decide it.
    const decision = await post(fixture, '/dsh-bridge/approval', {
      approvalId: frame.approvalId, sessionId, decision: 'allowed-once',
    })
    expect(decision.status).toBe(404)
    expect(decision.body.reason).toBe('not-pending')

    notify.close()
  }, 90000)
})
