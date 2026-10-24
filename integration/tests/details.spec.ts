// dsh-emacs-bridge — integration spec: the optional turn-detail inspector.
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
// Pins the host-plane contract of `GET /details/turn' and `/details/entry':
// baseline `/turns' remains summary-only while the detail routes return the
// complete committed reasoning, exact arguments, result content, and durable
// per-call applied diffs; the observation identity makes a stale read a 409;
// and `turn=latest' discovers the newest visible turn without resuming.

import { afterAll, describe, expect, it, inject } from 'vitest'
import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { get, post, raw, scriptMock, createSession, openSse } from './util.mjs'

const tempDirs = []

function tempWorkspace() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'dsh-bridge-details-')))
  tempDirs.push(dir)
  return dir
}

afterAll(() => {
  for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true })
})

/** One complete turn: create with `write`, then apply `edit`. */
async function scriptTurn(fixture) {
  const marker = `BURIED-REASONING-${process.pid}-${Date.now()}`
  await scriptMock(fixture, [
    {
      kind: 'reasoning',
      text: `Create the note.\n\n${marker}: this paragraph stays out of every summary.`,
      toolCall: {
        name: 'write',
        arguments: { file_path: 'detail-note.txt', content: 'alpha\n' },
      },
    },
    {
      kind: 'reasoning',
      text: 'Now change alpha to beta.',
      toolCall: {
        name: 'edit',
        arguments: { file_path: 'detail-note.txt', old_string: 'alpha', new_string: 'beta' },
      },
    },
    { kind: 'text', text: 'Note written and edited.' },
  ])
  return marker
}

/** Send one prompt and wait for its turn to complete. */
async function runTurn(fixture, sessionId, text) {
  const sse = openSse(fixture, { timeoutMs: 20000 })
  try {
    const sent = await post(fixture, '/dsh-bridge/send', { text, sessionId })
    expect(sent.status, JSON.stringify(sent.body)).toBe(200)
    await sse.waitFor('turn-complete', 30000, frame => frame.sessionId === sessionId)
  } finally {
    sse.close()
  }
}

describe('the turn-detail inspector routes', () => {
  it('serves complete detail while baseline responses stay summary-only', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const dir = tempWorkspace()
    const marker = await scriptTurn(fixture)
    const sessionId = await createSession(fixture, dir)
    await runTurn(fixture, sessionId, 'Make a note.')

    const baseline = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
    expect(baseline.status).toBe(200)
    expect(JSON.stringify(baseline.body)).not.toContain(marker)

    const index = await get(fixture, `/dsh-bridge/details/turn?sessionId=${sessionId}&turn=latest`)
    expect(index.status, JSON.stringify(index.body)).toBe(200)
    const { turn, epoch, cursor } = index.body
    expect(typeof turn).toBe('number')
    expect(typeof epoch).toBe('number')
    expect(typeof cursor).toBe('number')
    expect(index.body.open).toBe(false)
    expect(index.body.entries.map(entry => entry.kind))
      .toEqual(['thinking', 'tool-call', 'tool-result', 'thinking', 'tool-call', 'tool-result'])
    // The index is summary-only too: no full reasoning and no diff text.
    expect(JSON.stringify(index.body)).not.toContain(marker)

    const thinking = index.body.entries.find(entry => entry.kind === 'thinking')
    const thinkingDetail = await get(fixture,
      `/dsh-bridge/details/entry?sessionId=${sessionId}&turn=${turn}&epoch=${epoch}&cursor=${cursor}`
      + `&kind=thinking&seq=${thinking.seq}&ord=${thinking.ord}`)
    expect(thinkingDetail.status, JSON.stringify(thinkingDetail.body)).toBe(200)
    expect(thinkingDetail.body.text).toContain(marker)
    expect(thinkingDetail.body.page.totalBytes).toBeGreaterThan(0)
    expect(thinkingDetail.body.page.hasMore).toBe(false)

    const call = index.body.entries.find(entry => entry.kind === 'tool-call')
    const callDetail = await get(fixture,
      `/dsh-bridge/details/entry?sessionId=${sessionId}&turn=${turn}&epoch=${epoch}&cursor=${cursor}`
      + `&kind=tool-call&seq=${call.seq}`)
    expect(callDetail.status, JSON.stringify(callDetail.body)).toBe(200)
    expect(JSON.parse(callDetail.body.text)).toMatchObject({ file_path: 'detail-note.txt' })

    const results = index.body.entries.filter(entry => entry.kind === 'tool-result')
    expect(results).toHaveLength(2)
    const create = results[0]
    const edit = results[1]
    expect(create.files[0]).toMatchObject({ status: 'create', pathSource: 'recorded' })
    expect(edit.files[0]).toMatchObject({ status: 'applied', pathSource: 'recorded' })
    expect(edit.files[0].fragmentCount).toBeGreaterThan(0)

    const resultDetail = await get(fixture,
      `/dsh-bridge/details/entry?sessionId=${sessionId}&turn=${turn}&epoch=${epoch}&cursor=${cursor}`
      + `&kind=tool-result&seq=${edit.seq}`)
    expect(resultDetail.status, JSON.stringify(resultDetail.body)).toBe(200)
    expect(resultDetail.body.isError).toBe(false)
    expect(resultDetail.body.files[0]).toMatchObject({ status: 'applied' })

    const diff = await get(fixture,
      `/dsh-bridge/details/entry?sessionId=${sessionId}&turn=${turn}&epoch=${epoch}&cursor=${cursor}`
      + `&kind=file-diff&seq=${edit.seq}`)
    expect(diff.status, JSON.stringify(diff.body)).toBe(200)
    expect(diff.body.kind).toBe('file-diff')
    expect(diff.body.files[0]).toMatchObject({ status: 'applied', render: 'ok' })
    expect(diff.body.text).toContain('-alpha')
    expect(diff.body.text).toContain('+beta')
    expect(diff.body.text).toContain('not an appliable patch')
    expect(diff.body.text).not.toContain('@@ -')

    // The create result has no recorded before-image.
    const createDiff = await get(fixture,
      `/dsh-bridge/details/entry?sessionId=${sessionId}&turn=${turn}&epoch=${epoch}&cursor=${cursor}`
      + `&kind=file-diff&seq=${create.seq}`)
    expect(createDiff.status, JSON.stringify(createDiff.body)).toBe(200)
    expect(createDiff.body.files[0].status).toBe('create')
    expect(createDiff.body.text).toContain('no recorded before-image')

    // Archiving removes a run target, not read access: the same observation
    // stays readable, and the detail route never resumes it.
    const archived = await post(fixture, '/dsh-bridge/sessions/archive', { sessionId })
    expect(archived.status, JSON.stringify(archived.body)).toBe(200)
    const archivedIndex = await get(fixture, `/dsh-bridge/details/turn?sessionId=${sessionId}&turn=latest`)
    expect(archivedIndex.status, JSON.stringify(archivedIndex.body)).toBe(200)
  }, 90000)

  it('rejects malformed selectors, unknown turns, stale observations, and missing auth', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [{ kind: 'reasoning', text: 'A stale-read thought.' }, { kind: 'text', text: 'One turn.' }])
    const sessionId = await createSession(fixture)
    await runTurn(fixture, sessionId, 'Hello.')

    const repeated = await get(fixture,
      `/dsh-bridge/details/turn?sessionId=${sessionId}&sessionId=other&turn=latest`)
    expect(repeated.status).toBe(400)
    const badKind = await get(fixture,
      `/dsh-bridge/details/entry?sessionId=${sessionId}&turn=1&epoch=0&cursor=1&kind=nope&seq=1`)
    expect(badKind.status).toBe(400)
    const unknownTurn = await get(fixture,
      `/dsh-bridge/details/turn?sessionId=${sessionId}&turn=9999`)
    expect(unknownTurn.status).toBe(404)

    const index = await get(fixture, `/dsh-bridge/details/turn?sessionId=${sessionId}&turn=latest`)
    expect(index.status).toBe(200)
    const thinking = index.body.entries.find(entry => entry.kind === 'thinking')
    expect(thinking, 'the scripted reasoning block must be indexed').toBeDefined()
    const stale = await get(fixture,
      `/dsh-bridge/details/entry?sessionId=${sessionId}&turn=${index.body.turn}`
      + `&epoch=${index.body.epoch + 1}&cursor=${index.body.cursor}`
      + `&kind=thinking&seq=${thinking.seq}&ord=${thinking.ord}`)
    expect(stale.status).toBe(409)
    expect(stale.body.reason).toBe('stale')

    const unauthorized = await raw(fixture, 'GET',
      `/dsh-bridge/details/turn?sessionId=${sessionId}&turn=latest`)
    expect(unauthorized.status).toBe(401)
  }, 90000)
})
