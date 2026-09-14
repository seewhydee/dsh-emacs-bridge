// dsh-emacs-bridge — integration spec: the cold (persisted-only) session roster.
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
// The shared fixture never sees a cold session (it boots one fresh DSH_HOME),
// so this spec boots its own pair of hosts against one caller-supplied home:
// the first creates and persists a session, the second starts with no live
// agent for it and must still enumerate it through `sessionPersistence.list()`
// with its durable title folded back. Two regression modes are guarded:
//   - a title-fold fault that rejected the whole persisted batch, silently
//     reducing `/sessions` to the live rows only;
//   - trusting a projection-cache null title, when the write-behind checkpoint
//     lagged the log past a rename (the cache row is written before shutdown),
//     which made the title vanish whenever the checkpoint happened to be stale.
// The rename-then-kill sequence below is what makes the second case likely.
// The second half drives the documented cold WRITE paths: naming a persisted-
// only id in POST /dsh-bridge/send resumes the session on demand and lands the
// prompt, and POST /dsh-bridge/sessions/resume brings a cold id live directly.

import { describe, it, expect } from 'vitest'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { launch } from '../host/launch.mjs'
import { get, post, scriptMock, mockRequests, createSession, openSse, poll, REPO_ROOT } from './util.mjs'

describe('cold (persisted-only) session listing', () => {
  it('lists a session persisted by a previous host boot', async () => {
    const dshHome = mkdtempSync(join(tmpdir(), 'dsh-bridge-cold-'))
    let first
    let second
    try {
      first = await launch({ dshHome, timeoutMs: 120000 })

      const id = await createSession(first)

      // A durable title gives the cold fold something identifiable to recover.
      const title = `Cold session ${process.pid}-${Date.now()}`
      const renamed = await post(first, '/dsh-bridge/sessions/rename', { sessionId: id, title })
      expect(renamed.status).toBe(200)

      await first.kill()
      first = undefined

      second = await launch({ dshHome, timeoutMs: 120000 })
      const sessions = await get(second, '/dsh-bridge/sessions')
      expect(sessions.status).toBe(200)

      const row = sessions.body.sessions.find((session) => session.id === id)
      expect(row).toBeDefined()
      // No live agent survives the restart: the row is cold.
      expect(row.live).toBe(false)
      expect(row.running).toBe(false)
      expect(row.title).toBe(title)
      expect(row.cwd).toBe(REPO_ROOT)

      // The read-only report's cold arm observes the stored log without
      // resuming it, so the session is still cold after the read.
      const report = await get(second, `/dsh-bridge/session?sessionId=${id}`)
      expect(report.status).toBe(200)
      expect(report.body.sessionId).toBe(id)
      expect(report.body.live).toBe(false)
      expect(report.body.title).toBe(title)
    } finally {
      if (first !== undefined) await first.kill()
      if (second !== undefined) await second.kill()
      rmSync(dshHome, { recursive: true, force: true })
    }
  }, 240000)

  it('resumes a persisted-only session on demand when a prompt names it', async () => {
    const dshHome = mkdtempSync(join(tmpdir(), 'dsh-bridge-cold-send-'))
    let first
    let second
    try {
      first = await launch({ dshHome, timeoutMs: 120000 })
      // One session per arm: `send` resumes the first on demand, the explicit
      // resume route takes the second.
      const sendId = await createSession(first)
      const resumeId = await createSession(first)
      await first.kill()
      first = undefined

      second = await launch({ dshHome, timeoutMs: 120000 })

      // Sanity: both rows start cold on the fresh host.
      const coldRows = (await get(second, '/dsh-bridge/sessions')).body.sessions
      expect(coldRows.find((s) => s.id === sendId)?.live).toBe(false)
      expect(coldRows.find((s) => s.id === resumeId)?.live).toBe(false)

      // Naming the cold id in /send routes through the on-demand resume: the
      // call returns 200 only after the agent exists, and the scripted turn
      // then runs on the resumed session.
      await scriptMock(second, [{ kind: 'text', text: 'Resumed reply.' }])
      const sse = openSse(second, { timeoutMs: 20000 })
      try {
        const sent = await post(second, '/dsh-bridge/send', {
          text: 'Still there?', sessionId: sendId,
        })
        expect(sent.status, JSON.stringify(sent.body)).toBe(200)
        expect(sent.body.ok).toBe(true)
        expect(sent.body.sessionId).toBe(sendId)
        const started = await sse.waitFor('turn-start')
        expect(started.sessionId).toBe(sendId)
        await sse.waitFor('turn-complete')
      } finally {
        sse.close()
      }

      // The prompt landed: the mock's main-turn call carried it.
      const requests = await mockRequests(second)
      const main = requests.filter((r) => r.purpose === undefined)
      expect(main.length).toBeGreaterThanOrEqual(1)
      const promptTexts = main.flatMap((r) => (r.messages ?? [])
        .filter((m) => m.role === 'user' && m.source?.kind === 'user')
        .flatMap((m) => m.content ?? [])
        .filter((b) => b.type === 'text')
        .map((b) => b.text))
      expect(promptTexts).toContain('Still there?')

      // The explicit resume route brings the second cold id live directly.
      const resumed = await post(second, '/dsh-bridge/sessions/resume', { sessionId: resumeId })
      expect(resumed.status, JSON.stringify(resumed.body)).toBe(200)
      expect(resumed.body.ok).toBe(true)
      expect(resumed.body.sessionId).toBe(resumeId)

      // Both sessions are live rows now.
      await poll(async () => {
        const rows = (await get(second, '/dsh-bridge/sessions')).body.sessions
        const sendRow = rows.find((s) => s.id === sendId)
        const resumeRow = rows.find((s) => s.id === resumeId)
        return sendRow?.live === true && resumeRow?.live === true
      })
    } finally {
      if (first !== undefined) await first.kill()
      if (second !== undefined) await second.kill()
      rmSync(dshHome, { recursive: true, force: true })
    }
  }, 240000)
})
