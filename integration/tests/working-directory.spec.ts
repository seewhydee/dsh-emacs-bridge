// dsh-emacs-bridge — integration spec: the effective working directory.
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
// Pins the host-plane seam behind every reported session directory: the base
// profile mounts `working-directory` and its `working_directory` tool, so a
// committed `working-directory/change` must move the `cwd` the bridge serves on
// `/turns`, `/session`, and `/sessions`.  The header keeps only the original
// project, and the directory tool is not a file mutation.  Runs against a
// scratch workspace so the repository is never dirtied.

import { afterAll, describe, expect, it, inject } from 'vitest'
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { post, get, scriptMock, createSession, openSse } from './util.mjs'

/** Temp workspace directories created by this spec, removed on teardown. */
const tempDirs = []

/** A fresh, canonical scratch workspace for one test. */
function tempWorkspace() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'dsh-bridge-cwd-')))
  tempDirs.push(dir)
  return dir
}

afterAll(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true })
})

describe('the effective working directory', () => {
  it('follows a working_directory change in the turns header, report, and roster', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const dir = tempWorkspace()
    const sub = join(dir, 'sub')
    mkdirSync(sub)
    await scriptMock(fixture, [
      { kind: 'tool-call', name: 'working_directory', arguments: { cd: sub } },
      { kind: 'text', text: 'Moved into sub.' },
    ])
    const sessionId = await createSession(fixture, dir)
    const sse = openSse(fixture, { timeoutMs: 20000 })
    try {
      const sent = await post(fixture, '/dsh-bridge/send', { text: 'Move into sub.', sessionId })
      expect(sent.status).toBe(200)
      await sse.waitFor('turn-complete')

      const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      expect(turns.body.cwd).toBe(sub)
      // The directory tool changes no file, so the turn carries no attribution.
      expect(turns.body.turns[0].files).toBeUndefined()

      const report = await get(fixture, `/dsh-bridge/session?sessionId=${sessionId}`)
      expect(report.body.cwd).toBe(sub)

      const roster = await get(fixture, '/dsh-bridge/sessions')
      const row = roster.body.sessions.find(session => session.id === sessionId)
      expect(row.cwd).toBe(sub)
    } finally {
      sse.close()
    }
  }, 90000)
})
