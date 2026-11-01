// dsh-emacs-bridge — integration spec: the optional single-item inspector.
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
// Pins the host-plane contract of `GET /details/item': baseline `/turns'
// remains summary-only while a direct item read returns complete committed
// reasoning, exact arguments, result content, and durable per-call applied
// diffs. Independent continuations require their original observation, and
// the retired turn/index routes no longer exist.

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

async function currentActivity(fixture, sessionId) {
  const baseline = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
  expect(baseline.status, JSON.stringify(baseline.body)).toBe(200)
  const current = baseline.body.turns[0]
  expect(current).toBeDefined()
  expect(current.activity?.length).toBeGreaterThan(0)
  return { baseline, current }
}

describe('the single-item inspector route', () => {
  it('serves exact selected items with independent result and diff parts', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    const dir = tempWorkspace()
    const marker = await scriptTurn(fixture)
    const sessionId = await createSession(fixture, dir)
    await runTurn(fixture, sessionId, 'Make a note.')

    const { baseline, current } = await currentActivity(fixture, sessionId)
    expect(JSON.stringify(baseline.body)).not.toContain(marker)
    const { turn } = current
    const thinking = current.activity.find(entry => entry.kind === 'thinking')
    expect(thinking).toBeDefined()

    const thinkingDetail = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${turn}`
      + `&kind=thinking&seq=${thinking.seq}&ord=${thinking.ord}`)
    expect(thinkingDetail.status, JSON.stringify(thinkingDetail.body)).toBe(200)
    const { epoch, cursor } = thinkingDetail.body
    expect(typeof epoch).toBe('number')
    expect(typeof cursor).toBe('number')
    expect(thinkingDetail.body).toMatchObject({
      sessionId, turn, kind: 'thinking', open: false,
      parts: { reasoning: { byteOffset: 0, hasMore: false } },
    })
    expect(thinkingDetail.body.parts.reasoning.text).toContain(marker)
    expect(thinkingDetail.body.parts.reasoning.text).not.toContain('Now change alpha to beta.')
    expect(thinkingDetail.body.entries).toBeUndefined()

    const calls = current.activity.filter(entry => entry.kind === 'tool-call')
    expect(calls).toHaveLength(2)
    const createDetail = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${turn}&kind=tool&callId=${calls[0].callId}`)
    expect(createDetail.status, JSON.stringify(createDetail.body)).toBe(200)
    expect(createDetail.body).toMatchObject({
      kind: 'tool', callId: calls[0].callId, name: 'write', settlement: 'settled',
      parts: { arguments: { byteOffset: 0 }, result: { byteOffset: 0 } },
      files: [{ status: 'create', pathSource: 'recorded' }],
    })
    expect(JSON.parse(createDetail.body.parts.arguments.text)).toMatchObject({ file_path: 'detail-note.txt' })
    expect(createDetail.body.files[0].diff.text).toContain('no recorded before-image')
    expect(JSON.stringify(createDetail.body)).not.toContain(marker)
    expect(createDetail.body.entries).toBeUndefined()

    const editDetail = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${turn}&kind=tool&callId=${calls[1].callId}`)
    expect(editDetail.status, JSON.stringify(editDetail.body)).toBe(200)
    expect(editDetail.body.result.isError).toBe(false)
    expect(editDetail.body.files[0]).toMatchObject({ status: 'applied', pathSource: 'recorded' })
    expect(editDetail.body.files[0].fragmentCount).toBeGreaterThan(0)
    expect(editDetail.body.files[0].diff).toMatchObject({
      byteOffset: 0, hasMore: false, render: 'ok',
    })
    expect(editDetail.body.files[0].diff.text).toContain('-alpha')
    expect(editDetail.body.files[0].diff.text).toContain('+beta')
    expect(editDetail.body.files[0].diff.text).toContain('not an appliable patch')
    expect(editDetail.body.files[0].diff.text).not.toContain('@@ -')

    const argumentsPage = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${turn}&kind=tool&callId=${calls[1].callId}`
      + `&epoch=${epoch}&cursor=${cursor}&part=arguments&byteOffset=0`)
    expect(argumentsPage.status, JSON.stringify(argumentsPage.body)).toBe(200)
    expect(argumentsPage.body.part).toBe('arguments')
    expect(argumentsPage.body.parts.arguments).toBeDefined()
    expect(argumentsPage.body.parts.result).toBeUndefined()
    expect(argumentsPage.body.result).toBeUndefined()
    expect(argumentsPage.body.files).toBeUndefined()

    const diffPage = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${turn}&kind=tool&callId=${calls[1].callId}`
      + `&epoch=${epoch}&cursor=${cursor}&part=diff&byteOffset=0&fileIndex=0`)
    expect(diffPage.status, JSON.stringify(diffPage.body)).toBe(200)
    expect(diffPage.body).toMatchObject({ kind: 'tool', part: 'diff', fileIndex: 0, files: { length: 1 } })
    expect(diffPage.body.parts.arguments).toBeUndefined()
    expect(diffPage.body.parts.result).toBeUndefined()

    const badFile = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${turn}&kind=tool&callId=${calls[1].callId}`
      + `&epoch=${epoch}&cursor=${cursor}&part=diff&byteOffset=0&fileIndex=99`)
    expect(badFile.status).toBe(404)
    expect(badFile.body.reason).toBe('unknown-file')

    // Archiving removes a run target, not read access: the same concrete item
    // stays readable, and the detail route never resumes it.
    const archived = await post(fixture, '/dsh-bridge/sessions/archive', { sessionId })
    expect(archived.status, JSON.stringify(archived.body)).toBe(200)
    const archivedItem = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${turn}`
      + `&kind=thinking&seq=${thinking.seq}&ord=${thinking.ord}`)
    expect(archivedItem.status, JSON.stringify(archivedItem.body)).toBe(200)
  }, 90000)

  it('rejects malformed/unknown/stale requests, missing auth, and retired routes', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [{ kind: 'reasoning', text: 'A stale-read thought.' }, { kind: 'text', text: 'One turn.' }])
    const sessionId = await createSession(fixture)
    await runTurn(fixture, sessionId, 'Hello.')
    const { current } = await currentActivity(fixture, sessionId)
    const { turn } = current
    const thinking = current.activity.find(entry => entry.kind === 'thinking')
    expect(thinking).toBeDefined()
    const selector = `sessionId=${sessionId}&turn=${turn}&kind=thinking&seq=${thinking.seq}&ord=${thinking.ord}`

    const repeated = await get(fixture, `/dsh-bridge/details/item?${selector}&sessionId=other`)
    expect(repeated.status).toBe(400)
    const badKind = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${turn}&kind=nope&seq=${thinking.seq}`)
    expect(badKind.status).toBe(400)
    const latest = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=latest&kind=tool&callId=none`)
    expect(latest.status).toBe(400)
    const wrongSelector = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${turn}&kind=tool&callId=none&seq=${thinking.seq}`)
    expect(wrongSelector.status).toBe(400)
    const unknownTurn = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=9999&kind=tool&callId=none`)
    expect(unknownTurn.status).toBe(404)
    const unknownItem = await get(fixture,
      `/dsh-bridge/details/item?sessionId=${sessionId}&turn=${turn}&kind=tool&callId=none`)
    expect(unknownItem.status).toBe(404)

    const initial = await get(fixture, `/dsh-bridge/details/item?${selector}`)
    expect(initial.status, JSON.stringify(initial.body)).toBe(200)
    const stale = await get(fixture,
      `/dsh-bridge/details/item?${selector}&epoch=${initial.body.epoch + 1}&cursor=${initial.body.cursor}`
      + '&part=reasoning&byteOffset=0')
    expect(stale.status).toBe(409)
    expect(stale.body).toMatchObject({
      reason: 'stale', epoch: initial.body.epoch, cursor: initial.body.cursor,
    })

    const unauthorized = await raw(fixture, 'GET', `/dsh-bridge/details/item?${selector}`)
    expect(unauthorized.status).toBe(401)
    for (const retired of [
      `/dsh-bridge/details/turn?sessionId=${sessionId}&turn=${turn}`,
      `/dsh-bridge/details/entry?${selector}&epoch=${initial.body.epoch}&cursor=${initial.body.cursor}`,
    ]) {
      const absent = await get(fixture, retired)
      expect(absent.status).toBe(404)
    }
  }, 90000)
})
