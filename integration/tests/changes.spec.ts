// dsh-emacs-bridge — integration spec: the changed-files fold and /changes.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Pins the host-plane contract behind the DSH-View footer on a live host: a
// real `write`/`edit` turn is attributed to its turn in `GET /turns` (the
// mutation vocabulary replicated from the web client's turn-deliverables fold),
// and `GET /changes` serves the recorded hunks.  Runs against a scratch
// workspace so the repository is never dirtied, and always ends the script with
// a text reply because `/turns` only records text-bearing turns.

import { afterAll, describe, expect, it, inject } from 'vitest'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { post, get, scriptMock, createSession, openSse } from './util.mjs'

/** Temp workspace directories created by this spec, removed on teardown. */
const tempDirs = []

/** A fresh, canonical scratch workspace for one test. */
function tempWorkspace() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'dsh-bridge-changes-')))
  tempDirs.push(dir)
  return dir
}

afterAll(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true })
})

describe('the changed-files fold and the /changes route', () => {
  it('attributes a write and an edit to their turn and serves the recorded hunks', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const dir = tempWorkspace()
    await scriptMock(fixture, [
      {
        kind: 'tool-call',
        name: 'write',
        arguments: { file_path: 'note.txt', content: 'alpha\n' },
      },
      {
        kind: 'tool-call',
        name: 'edit',
        arguments: { file_path: 'note.txt', old_string: 'alpha', new_string: 'gamma' },
      },
      { kind: 'text', text: 'Wrote and edited note.txt.' },
    ])
    const sessionId = await createSession(fixture, dir)
    const sse = openSse(fixture, { timeoutMs: 20000 })
    try {
      const sent = await post(fixture, '/dsh-bridge/send', { text: 'Make a note.', sessionId })
      expect(sent.status).toBe(200)
      await sse.waitFor('turn-complete')

      const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      const turn = turns.body.turns.find((record) => record.files !== undefined)
      expect(turn).toBeTruthy()
      // Deduped by path, first-seen order, first operation preserved.
      expect(turn.files).toEqual([{ path: 'note.txt', op: 'write' }])

      // The incremental suffix carries the same attribution.
      const suffix = await get(
        fixture,
        `/dsh-bridge/turns?sessionId=${sessionId}&since=${turn.turn}&epoch=${turns.body.epoch}`,
      )
      expect(suffix.body.incremental).toBe(true)
      expect(suffix.body.turns[0].files).toEqual([{ path: 'note.txt', op: 'write' }])

      const changes = await get(
        fixture,
        `/dsh-bridge/changes?sessionId=${sessionId}&path=${encodeURIComponent('note.txt')}`,
      )
      expect(changes.status).toBe(200)
      expect(changes.body.path).toBe('note.txt')
      expect(changes.body.absolute).toBe(join(dir, 'note.txt'))
      // The whole-file create falls back to the call args, then the edit's
      // applied hunk; both sides are the log's before/after text.
      expect(changes.body.hunks.length).toBeGreaterThanOrEqual(2)
      expect(changes.body.hunks[0]).toMatchObject({ tool: 'write', op: 'write', oldText: null })
      const edit = changes.body.hunks.find((hunk) => hunk.tool === 'edit')
      expect(edit.oldText).toContain('alpha')
      expect(edit.newText).toContain('gamma')
    } finally {
      sse.close()
    }
  }, 90000)

  it('404s a path the fold never changed and 400s a missing path', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const dir = tempWorkspace()
    await scriptMock(fixture, [
      { kind: 'tool-call', name: 'write', arguments: { file_path: 'only.txt', content: 'x\n' } },
      { kind: 'text', text: 'done' },
    ])
    const sessionId = await createSession(fixture, dir)
    const sse = openSse(fixture, { timeoutMs: 20000 })
    try {
      await post(fixture, '/dsh-bridge/send', { text: 'write', sessionId })
      await sse.waitFor('turn-complete')

      const missing = await get(fixture, `/dsh-bridge/changes?sessionId=${sessionId}`)
      expect(missing.status).toBe(400)

      // A repeated sessionId is a malformed request, exactly like /session.
      const repeated = await get(
        fixture,
        `/dsh-bridge/changes?sessionId=${sessionId}&sessionId=${sessionId}`
        + `&path=${encodeURIComponent('only.txt')}`,
      )
      expect(repeated.status).toBe(400)

      const other = await get(
        fixture,
        `/dsh-bridge/changes?sessionId=${sessionId}&path=${encodeURIComponent('nope.txt')}`,
      )
      expect(other.status).toBe(404)
      expect(other.body.code).toBe('not-changed')
    } finally {
      sse.close()
    }
  }, 90000)
})
