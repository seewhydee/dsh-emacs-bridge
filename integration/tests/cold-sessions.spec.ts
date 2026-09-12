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
// with its durable title folded back. Regression guard: a title-fold fault
// used to reject the whole persisted batch, silently reducing `/sessions` to
// the live rows only.

import { describe, it, expect } from 'vitest'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { launch } from '../host/launch.mjs'
import { get, post, REPO_ROOT } from './util.mjs'

/**
 * Create a session, retrying while the freshly booted host's workspace
 * registry is still completing its async bootstrap (it answers 501 until it
 * is active). No mutation precedes that 501, so retrying is safe.
 */
async function createSessionWhenReady(fixture, timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    const created = await post(fixture, '/dsh-bridge/sessions/create', { path: REPO_ROOT })
    if (created.status !== 501) return created
    if (Date.now() >= deadline) {
      throw new Error(`workspace registry did not become ready: ${JSON.stringify(created.body)}`)
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250))
  }
}

describe('cold (persisted-only) session listing', () => {
  it('lists a session persisted by a previous host boot', async () => {
    const dshHome = mkdtempSync(join(tmpdir(), 'dsh-bridge-cold-'))
    let first
    let second
    try {
      first = await launch({ dshHome, timeoutMs: 120000 })

      const created = await createSessionWhenReady(first)
      expect(created.status).toBe(201)
      const id = created.body.sessionId

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
})
