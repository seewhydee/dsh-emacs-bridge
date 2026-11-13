// dsh-emacs-bridge — Vitest specs for the optional single-item inspector.
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

import { describe, expect, it } from 'vitest'
import {
  buildDetailItem,
  buildDetailItemProjection,
  buildDetailItemResponse,
  parseDetailItemQuery,
  turnBoundaries,
  DETAIL_FULL_LOAD_BYTES,
  MAX_DETAIL_FILE_CHANGES,
  MAX_DETAIL_FILE_FRAGMENTS,
  type DetailFileChange,
  type DetailItemKind,
  type DetailQueryParams,
  type SessionEventLike,
} from '../src/logic.ts'
import { renderFileChanges } from '../src/detail.ts'

// -- Fixtures ----------------------------------------------------------------

function log(): { events: SessionEventLike[]; add: (event: SessionEventLike) => SessionEventLike } {
  const events: SessionEventLike[] = []
  return {
    events,
    add(event) {
      const withSeq = { ...event, seq: event.seq ?? events.length }
      events.push(withSeq)
      return withSeq
    },
  }
}

function turnStart(turn: number): SessionEventLike {
  return { time: turn * 1000, type: 'turn/start', data: { turn } }
}

function turnEnd(turn: number, failure?: { code?: string; message: string }): SessionEventLike {
  return {
    time: turn * 1000 + 500,
    type: 'turn/end',
    data: failure === undefined
      ? { turn, reason: { kind: 'completed' } }
      : { turn, reason: { kind: 'error', error: failure } },
  }
}

function assistant(
  turn: number,
  step: number,
  blocks: Array<{ type: string; text?: string }>,
  opts: { surfaceOp?: unknown } = {},
): SessionEventLike {
  return {
    time: turn * 1000 + step,
    type: 'assistant/message',
    data: { turn, step, message: { role: 'assistant', content: blocks } },
    surfaceOp: opts.surfaceOp ?? 'append',
  }
}

function toolCall(turn: number, step: number, callId: string, name: string, args: unknown): SessionEventLike {
  return {
    time: turn * 1000 + step,
    type: 'tool/call',
    data: {
      turn,
      step,
      callId,
      name,
      arguments: typeof args === 'string' ? args : JSON.stringify(args),
    },
  }
}

function toolResult(
  turn: number,
  step: number,
  callId: string,
  opts: {
    isError?: boolean
    content?: unknown[]
    meta?: unknown
    error?: unknown
    surfaceOp?: unknown
  } = {},
): SessionEventLike {
  return {
    time: turn * 1000 + step,
    type: 'tool/result',
    data: {
      turn,
      step,
      message: {
        role: 'tool',
        source: { kind: 'tool', callId },
        isError: opts.isError === true,
        content: opts.content ?? [{ type: 'text', text: 'ok' }],
      },
      ...opts.meta === undefined ? {} : { meta: opts.meta },
      ...opts.error === undefined ? {} : { error: opts.error },
    },
    surfaceOp: opts.surfaceOp ?? 'append',
  }
}

function currentSurface(events: readonly SessionEventLike[], omit: number[] = []): Set<number> {
  const omitted = new Set(omit)
  return new Set(events
    .filter(event => event.surfaceOp !== undefined && !omitted.has(event.seq as number))
    .map(event => event.seq as number))
}

type Selector = { seq: number; ord: number } | { callId: string }

function itemOf(
  events: readonly SessionEventLike[], turn: number, kind: DetailItemKind, selector: Selector,
  opts: { surface?: Set<number>; cwd?: string } = {},
) {
  return buildDetailItem({
    turn, events, surfaceSeqs: opts.surface ?? currentSurface(events),
    boundaries: turnBoundaries(events), headerCwd: opts.cwd ?? '/work', kind, ...selector,
  })
}

function renderDiff(file: DetailFileChange) {
  const rendered = renderFileChanges([file])
  const metadata = rendered.files[0]
  if (metadata === undefined) throw new Error('missing rendered file')
  return {
    text: rendered.text,
    render: metadata.render,
    added: metadata.added,
    removed: metadata.removed,
    truncated: rendered.truncated,
  }
}

function responseOf(
  events: readonly SessionEventLike[], turn: number, kind: DetailItemKind, selector: Selector,
  opts: {
    surface?: Set<number>
    cwd?: string
    full?: true
    renderDiff?: typeof renderDiff
  } = {},
) {
  const projection = buildDetailItemProjection({
    turn, events, surfaceSeqs: opts.surface ?? currentSurface(events),
    boundaries: turnBoundaries(events), headerCwd: opts.cwd ?? '/work',
  })
  const selected = buildDetailItem({
    turn, events, surfaceSeqs: opts.surface ?? currentSurface(events),
    boundaries: turnBoundaries(events), headerCwd: opts.cwd ?? '/work', kind, ...selector, projection,
  })
  if (!selected.ok) return selected
  return buildDetailItemResponse({
    sessionId: 's1', epoch: 2, cursor: events.length, cwd: '/final',
    item: selected.item,
    request: opts.full === true ? { full: true } : {},
    renderDiff: opts.renderDiff ?? renderDiff,
  })
}

function params(query: Record<string, string | string[]>): DetailQueryParams {
  return { getAll: (name: string) => {
    const value = query[name]
    return value === undefined ? [] : Array.isArray(value) ? value : [value]
  } }
}

// -- Direct item selection ---------------------------------------------------

describe('buildDetailItem', () => {
  it('selects exact reasoning blocks by seq+ord and returns no turn roster', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 2, [
      { type: 'reasoning', text: 'first line\nfull body' },
      { type: 'text', text: 'visible reply' },
      { type: 'reasoning', text: 'second thought' },
    ]))
    l.add(turnEnd(1))
    const first = responseOf(l.events, 1, 'thinking', { seq: 1, ord: 0 })
    expect(first).toMatchObject({
      ok: true,
      response: {
        sessionId: 's1', turn: 1, epoch: 2, cursor: 3, cwd: '/final',
        kind: 'thinking', seq: 1, ord: 0, time: 1002, step: 2, open: false,
        parts: { reasoning: { text: 'first line\nfull body', totalBytes: 20 } },
        totalBytes: 20,
      },
    })
    if (!first.ok) return
    expect(first.response).not.toHaveProperty('entries')
    expect(first.response).not.toHaveProperty('droppedEntries')
    expect(JSON.stringify(first.response)).not.toContain('second thought')
    expect(responseOf(l.events, 1, 'thinking', { seq: 1, ord: 1 })).toMatchObject({
      ok: true, response: { parts: { reasoning: { text: 'second thought' } } },
    })
    expect(itemOf(l.events, 1, 'thinking', { seq: 1, ord: 2 })).toMatchObject({
      ok: false, status: 404, reason: 'unknown-ordinal',
    })
  })

  it('returns one logical tool with exact arguments and its visible result', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'unrelated thought' }]))
    l.add(toolCall(1, 0, 'c1', 'bash', '{"command":"printf hi"}'))
    l.add(toolResult(1, 0, 'c1', { content: [{ type: 'text', text: 'exact result' }] }))
    l.add(toolResult(1, 1, 'other', { content: [{ type: 'text', text: 'unrelated result' }] }))
    l.add(turnEnd(1))
    const selected = responseOf(l.events, 1, 'tool', { callId: 'c1' })
    expect(selected).toMatchObject({
      ok: true,
      response: {
        kind: 'tool', seq: 2, callId: 'c1', name: 'bash', settlement: 'settled', callCwd: '/work',
        parts: {
          arguments: { text: '{"command":"printf hi"}' },
          result: { text: 'exact result' },
        },
        result: { seq: 3, isError: false, content: { blocks: [], textBlocks: 1, omittedBlocks: 0 } },
      },
    })
    if (!selected.ok) return
    expect(JSON.stringify(selected.response)).not.toContain('unrelated thought')
    expect(JSON.stringify(selected.response)).not.toContain('unrelated result')
    expect(selected.response).not.toHaveProperty('entries')
  })

  it('keeps pending calls result-free and rejects them after the turn closes', () => {
    const open = log()
    open.add(turnStart(1))
    open.add(toolCall(1, 0, 'c1', 'bash', { command: 'ls' }))
    expect(responseOf(open.events, 1, 'tool', { callId: 'c1' })).toMatchObject({
      ok: true,
      response: { kind: 'tool', settlement: 'pending', parts: { arguments: { text: '{"command":"ls"}' } } },
    })
    const pending = responseOf(open.events, 1, 'tool', { callId: 'c1' })
    if (pending.ok) expect(pending.response).not.toHaveProperty('result')

    const closed = log()
    closed.add(turnStart(1))
    closed.add(toolCall(1, 0, 'c1', 'bash', { command: 'ls' }))
    closed.add(turnEnd(1))
    expect(itemOf(closed.events, 1, 'tool', { callId: 'c1' })).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })
  })

  it('returns current orphan results without borrowing call arguments', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(toolResult(1, 3, 'orphan', {
      content: [
        { type: 'text', text: 'failed' },
        { type: 'image', attachment: { mediaType: 'image/png', bytes: 12, width: 1, height: 2, attachmentId: 'secret' } },
        { type: 'future-block', secret: 'nope' },
      ],
      isError: true,
      error: { name: 'AuthError', code: 'AUTH', reason: 'key-123' },
    }))
    l.add(turnEnd(1))
    const selected = responseOf(l.events, 1, 'tool-result', { callId: 'orphan' })
    expect(selected).toMatchObject({
      ok: true,
      response: {
        kind: 'tool-result', seq: 1, step: 3, callId: 'orphan', name: 'tool', settlement: 'orphan',
        isError: true,
        content: {
          blocks: [
            { type: 'image', mediaType: 'image/png', bytes: 12, width: 1, height: 2 },
            { type: 'future-block' },
          ],
          textBlocks: 1,
          omittedBlocks: 1,
        },
        error: { name: 'AuthError', code: 'AUTH' },
        parts: { result: { text: 'failed' } },
      },
    })
    if (selected.ok) {
      expect(selected.response).not.toHaveProperty('parts.arguments')
      expect(JSON.stringify(selected.response)).not.toContain('secret')
      expect(JSON.stringify(selected.response)).not.toContain('key-123')
    }
  })

  it('rejects paired results on the orphan-only selector', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(toolCall(1, 0, 'c1', 'read', {}))
    l.add(toolResult(1, 0, 'c1'))
    l.add(turnEnd(1))
    expect(itemOf(l.events, 1, 'tool-result', { callId: 'c1' })).toMatchObject({
      ok: false, status: 404, reason: 'not-orphan',
    })
  })

  it('validates call ids within the requested turn and expected kind', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(toolCall(1, 0, 'shared', 'read', { path: 'one' }))
    l.add(toolResult(1, 0, 'shared'))
    l.add(turnEnd(1))
    l.add(turnStart(2))
    l.add(toolCall(2, 0, 'shared', 'read', { path: 'two' }))
    l.add(toolResult(2, 0, 'shared'))
    l.add(turnEnd(2))
    expect(itemOf(l.events, 1, 'tool', { callId: 'missing' })).toMatchObject({ ok: false, status: 404 })
    expect(responseOf(l.events, 1, 'tool', { callId: 'shared' })).toMatchObject({
      ok: true, response: { parts: { arguments: { text: '{"path":"one"}' } } },
    })
    expect(itemOf(l.events, 1, 'thinking', { seq: 5, ord: 0 })).toMatchObject({ ok: false, status: 404 })
  })

  it('does not pair an orphan with a same-id call in another turn', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(toolResult(1, 0, 'shared', { content: [{ type: 'text', text: 'orphan one' }] }))
    l.add(turnEnd(1))
    l.add(turnStart(2))
    l.add(toolCall(2, 0, 'shared', 'read', { path: 'two' }))
    l.add(toolResult(2, 0, 'shared'))
    l.add(turnEnd(2))
    expect(responseOf(l.events, 1, 'tool-result', { callId: 'shared' })).toMatchObject({
      ok: true, response: { kind: 'tool-result', parts: { result: { text: 'orphan one' } } },
    })
  })

  it('applies visibility per item when other entries of the turn survive', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'keep me' }]))
    l.add(assistant(1, 1, [{ type: 'reasoning', text: 'shadow me' }]))
    l.add(toolCall(1, 1, 'c1', 'read', {}))
    l.add(toolResult(1, 1, 'c1'))
    l.add(turnEnd(1))
    const surface = currentSurface(l.events, [2, 4])
    expect(itemOf(l.events, 1, 'thinking', { seq: 1, ord: 0 }, { surface })).toMatchObject({ ok: true })
    expect(itemOf(l.events, 1, 'thinking', { seq: 2, ord: 0 }, { surface })).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })
    expect(itemOf(l.events, 1, 'tool', { callId: 'c1' }, { surface })).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })
    expect(itemOf(l.events, 1, 'tool-result', { callId: 'c1' }, { surface })).toMatchObject({
      ok: false, status: 404, reason: 'not-orphan',
    })
  })

  it('accepts current append and replacement copies and uses the latest visible result', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'append copy' }]))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'replacement copy' }], { surfaceOp: 'replace' }))
    l.add(toolCall(1, 0, 'c1', 'read', {}))
    l.add(toolResult(1, 0, 'c1', { content: [{ type: 'text', text: 'old current copy' }] }))
    l.add(toolResult(1, 0, 'c1', {
      content: [{ type: 'text', text: 'latest current copy' }], surfaceOp: 'replace',
    }))
    l.add(turnEnd(1))
    expect(itemOf(l.events, 1, 'thinking', { seq: 1, ord: 0 })).toMatchObject({ ok: true })
    expect(itemOf(l.events, 1, 'thinking', { seq: 2, ord: 0 })).toMatchObject({ ok: true })
    expect(responseOf(l.events, 1, 'tool', { callId: 'c1' })).toMatchObject({
      ok: true, response: { parts: { result: { text: 'latest current copy' } } },
    })
  })

  it('rejects whitespace-only and malformed current reasoning', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: '  \n' }]))
    const malformed = assistant(1, 1, [{ type: 'reasoning', text: 'not inspectable' }])
    if (typeof malformed.data === 'object' && malformed.data !== null) {
      delete (malformed.data as { step?: unknown }).step
    }
    l.add(malformed)
    l.add(turnEnd(1))
    expect(itemOf(l.events, 1, 'thinking', { seq: 1, ord: 0 })).toMatchObject({ ok: false, status: 409 })
    expect(itemOf(l.events, 1, 'thinking', { seq: 2, ord: 0 })).toMatchObject({ ok: false, status: 409 })
    expect(itemOf(l.events, 99, 'thinking', { seq: 1, ord: 0 })).toMatchObject({
      ok: false, status: 404, reason: 'unknown-turn',
    })
  })

  it('has no index-entry cap or truncation state', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, Array.from({ length: 2001 }, (_, i) => ({
      type: 'reasoning', text: `thought ${i}`,
    }))))
    l.add(turnEnd(1))
    expect(itemOf(l.events, 1, 'thinking', { seq: 1, ord: 0 })).toMatchObject({ ok: true })
    expect(itemOf(l.events, 1, 'thinking', { seq: 1, ord: 2000 })).toMatchObject({ ok: true })
  })
})

// -- Durable file-change classification --------------------------------------

describe('file-change classification', () => {
  function fileChanges(meta: unknown, args: unknown, opts: { name?: string; cwd?: string } = {}): DetailFileChange[] {
    const l = log()
    l.add(turnStart(1))
    if (opts.cwd !== undefined) {
      l.add({ time: 1000, type: 'working-directory/change', data: { cwd: opts.cwd } })
    }
    l.add(assistant(1, 0, [{ type: 'text', text: 'edit' }]))
    l.add(toolCall(1, 0, 'c1', opts.name ?? 'write', args))
    l.add(toolResult(1, 0, 'c1', { meta }))
    l.add(turnEnd(1))
    const selected = itemOf(l.events, 1, 'tool', { callId: 'c1' })
    if (!selected.ok || selected.item.kind !== 'tool') return []
    return selected.item.result?.files ?? []
  }

  it('classifies applied write/update hunks and keeps canonical paths', () => {
    const files = fileChanges({
      operation: 'update',
      path: '/abs/file.txt',
      diffs: [{ path: '/abs/file.txt', oldText: 'a', newText: 'b' }],
    }, { file_path: 'file.txt', content: 'b' })
    expect(files).toHaveLength(1)
    expect(files[0]).toMatchObject({
      path: '/abs/file.txt', absolute: '/abs/file.txt', pathSource: 'recorded',
      operation: 'update', status: 'applied', fragments: [{ oldText: 'a', newText: 'b' }],
    })
  })

  it('classifies create and identical update as different empty states', () => {
    const create = fileChanges({
      operation: 'create', path: '/abs/new.txt', diffs: [],
    }, { file_path: 'new.txt', content: '' })
    expect(create[0]).toMatchObject({ status: 'create', operation: 'create', fragments: [] })
    const empty = fileChanges({
      operation: 'update', path: '/abs/same.txt', diffs: [],
    }, { file_path: 'same.txt', content: 'same' })
    expect(empty[0]).toMatchObject({ status: 'empty', operation: 'update' })
  })

  it('classifies a recognized mutation with no durable diff as none and infers its path', () => {
    const files = fileChanges(undefined, {
      command: 'str_replace', path: 'src/x.txt', old_str: 'a', new_str: 'b',
    }, { name: 'str_replace_editor' })
    expect(files[0]).toMatchObject({
      path: 'src/x.txt', absolute: '/work/src/x.txt', pathSource: 'inferred',
      status: 'none', fragments: [],
    })
    expect(files[0]?.operation).toBeUndefined()
  })

  it('resolves an inferred path against the call-time directory', () => {
    const files = fileChanges(undefined, { file_path: 'late.txt', content: 'x' }, { cwd: '/elsewhere' })
    expect(files[0]).toMatchObject({ path: 'late.txt', absolute: '/elsewhere/late.txt', cwd: '/elsewhere' })
  })

  it('classifies malformed metadata as unavailable', () => {
    const files = fileChanges({ diffs: [{ path: 1 }] }, { file_path: 'x', content: 'y' })
    expect(files[0]).toMatchObject({ status: 'unavailable' })
    for (const diffs of [null, { path: 'x' }, 'not-an-array']) {
      const malformed = fileChanges({ diffs }, { file_path: 'x', content: 'y' })
      expect(malformed[0]).toMatchObject({ status: 'unavailable', path: 'x' })
    }
    const notAnObject = fileChanges('not-a-record', { file_path: 'x', content: 'y' })
    expect(notAnObject[0]).toMatchObject({ status: 'unavailable' })
  })

  it('exposes a valid orphan result durable diff without inventing a call', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(toolResult(1, 0, 'orphan-file', {
      meta: { path: '/w/orphan.txt', operation: 'create', diffs: [] },
    }))
    l.add(turnEnd(1))
    expect(responseOf(l.events, 1, 'tool-result', { callId: 'orphan-file' })).toMatchObject({
      ok: true,
      response: {
        files: [{
          status: 'create', path: '/w/orphan.txt', absolute: '/w/orphan.txt', pathSource: 'recorded',
          diff: { text: expect.stringContaining('no recorded before-image') },
        }],
      },
    })
  })

  it('resolves orphan and fallback paths at their own event directories, not the final cwd', () => {
    const l = log()
    l.add(turnStart(1))
    l.add({ time: 1000, type: 'working-directory/change', data: { cwd: '/call' } })
    l.add(toolCall(1, 0, 'c1', 'write', { file_path: 'call.txt', content: 'x' }))
    l.add({ time: 1001, type: 'working-directory/change', data: { cwd: '/result' } })
    l.add(toolResult(1, 0, 'c1', {
      meta: { path: 'call.txt', diffs: [{ path: 'call.txt', oldText: null, newText: 'x' }] },
    }))
    l.add({ time: 1002, type: 'working-directory/change', data: { cwd: '/orphan' } })
    l.add(toolResult(1, 1, 'orphan', {
      meta: { path: 'orphan.txt', diffs: [{ path: 'orphan.txt', oldText: null, newText: 'y' }] },
    }))
    l.add({ time: 1003, type: 'working-directory/change', data: { cwd: '/final' } })
    l.add(turnEnd(1))
    expect(itemOf(l.events, 1, 'tool', { callId: 'c1' })).toMatchObject({
      ok: true, item: { result: { files: [{ absolute: '/call/call.txt', cwd: '/call' }] } },
    })
    expect(itemOf(l.events, 1, 'tool-result', { callId: 'orphan' })).toMatchObject({
      ok: true, item: { result: { files: [{ absolute: '/orphan/orphan.txt', cwd: '/orphan' }] } },
    })
  })

  it('does not claim a failed mutation as an applied change', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(toolCall(1, 0, 'c1', 'write', { file_path: 'a', content: 'b' }))
    l.add(toolResult(1, 0, 'c1', {
      isError: true, meta: { diffs: [{ path: 'a', oldText: 'a', newText: 'b' }] },
    }))
    l.add(turnEnd(1))
    const selected = itemOf(l.events, 1, 'tool', { callId: 'c1' })
    expect(selected).toMatchObject({ ok: true, item: { result: { isError: true, files: [] } } })
  })

  it('reports durable file totals and drops beyond the per-result file cap', () => {
    const total = MAX_DETAIL_FILE_CHANGES + 2
    const files = fileChanges({
      diffs: Array.from({ length: total }, (_, i) => ({ path: `f${i}.txt`, oldText: 'a', newText: 'b' })),
    }, { file_path: 'fallback.txt', content: 'b' })
    expect(files).toHaveLength(MAX_DETAIL_FILE_CHANGES)
    const l = log()
    l.add(turnStart(1))
    l.add(toolResult(1, 0, 'orphan', {
      meta: { diffs: Array.from({ length: total }, (_, i) => ({ path: `f${i}.txt`, oldText: 'a', newText: 'b' })) },
    }))
    l.add(turnEnd(1))
    expect(responseOf(l.events, 1, 'tool-result', { callId: 'orphan' })).toMatchObject({
      ok: true,
      response: {
        files: { length: MAX_DETAIL_FILE_CHANGES },
        totalFiles: total, droppedFiles: 2, filesTruncated: true,
      },
    })
  })

  it('reports durable fragment totals and drops beyond the per-file fragment cap', () => {
    const total = MAX_DETAIL_FILE_FRAGMENTS + 3
    const diffs = Array.from({ length: total }, (_, i) => ({ path: 'f.txt', oldText: `a${i}`, newText: `b${i}` }))
    const files = fileChanges({ diffs }, { file_path: 'f.txt', content: 'b' })
    expect(files[0]).toMatchObject({
      fragments: { length: MAX_DETAIL_FILE_FRAGMENTS },
      totalFragments: total, droppedFragments: 3,
    })
    const l = log()
    l.add(turnStart(1))
    l.add(toolResult(1, 0, 'orphan', { meta: { diffs } }))
    l.add(turnEnd(1))
    expect(responseOf(l.events, 1, 'tool-result', { callId: 'orphan' })).toMatchObject({
      ok: true,
      response: {
        files: [{
          fragmentCount: total,
          retainedFragmentCount: MAX_DETAIL_FILE_FRAGMENTS,
          droppedFragments: 3,
          fragmentsTruncated: true,
        }],
      },
    })
  })
})

// -- Query parsing, size probe, and full load -------------------------------

describe('detail item query parsing', () => {
  it('accepts the three concrete selectors', () => {
    expect(parseDetailItemQuery(params({ sessionId: 's', turn: '3', kind: 'thinking', seq: '4', ord: '0' })))
      .toEqual({ ok: true, request: { sessionId: 's', turn: 3, kind: 'thinking', seq: 4, ord: 0 } })
    expect(parseDetailItemQuery(params({ sessionId: 's', turn: '3', kind: 'tool', callId: 'c1' })))
      .toEqual({ ok: true, request: { sessionId: 's', turn: 3, kind: 'tool', callId: 'c1' } })
    expect(parseDetailItemQuery(params({ sessionId: 's', turn: '3', kind: 'tool-result', callId: 'orphan' })))
      .toEqual({ ok: true, request: { sessionId: 's', turn: 3, kind: 'tool-result', callId: 'orphan' } })
  })

  it('requires one non-empty session id and a numeric turn, never latest', () => {
    expect(parseDetailItemQuery(params({ turn: '1', kind: 'tool', callId: 'c' }))).toMatchObject({ ok: false })
    expect(parseDetailItemQuery(params({ sessionId: '', turn: '1', kind: 'tool', callId: 'c' }))).toMatchObject({ ok: false })
    expect(parseDetailItemQuery(params({ sessionId: ['a', 'b'], turn: '1', kind: 'tool', callId: 'c' }))).toMatchObject({ ok: false })
    for (const turn of ['latest', '-1', '1.5', 'x']) {
      expect(parseDetailItemQuery(params({ sessionId: 's', turn, kind: 'tool', callId: 'c' }))).toMatchObject({ ok: false })
    }
  })

  it('repeated and wrong-kind selector fields are malformed', () => {
    expect(parseDetailItemQuery(params({ sessionId: 's', turn: ['1', '2'], kind: 'tool', callId: 'c' }))).toMatchObject({ ok: false })
    expect(parseDetailItemQuery(params({ sessionId: 's', turn: '1', kind: 'nope', callId: 'c' }))).toMatchObject({ ok: false })
    expect(parseDetailItemQuery(params({ sessionId: 's', turn: '1', kind: 'thinking', seq: '1' }))).toMatchObject({ ok: false })
    expect(parseDetailItemQuery(params({ sessionId: 's', turn: '1', kind: 'thinking', seq: '1', ord: '0', callId: 'c' }))).toMatchObject({ ok: false })
    expect(parseDetailItemQuery(params({ sessionId: 's', turn: '1', kind: 'tool', callId: '' }))).toMatchObject({ ok: false })
    expect(parseDetailItemQuery(params({ sessionId: 's', turn: '1', kind: 'tool', callId: 'c', seq: '1' }))).toMatchObject({ ok: false })
    expect(parseDetailItemQuery(params({ sessionId: 's', turn: '1', kind: 'tool-result', callId: 'c', ord: '0' }))).toMatchObject({ ok: false })
  })

  it('accepts the full-load flag and rejects malformed values', () => {
    const base = { sessionId: 's', turn: '1', kind: 'tool', callId: 'c' }
    expect(parseDetailItemQuery(params({ ...base, full: '1' })))
      .toMatchObject({ ok: true, request: { ...base, turn: 1, full: true } })
    expect(parseDetailItemQuery(params({ ...base, full: 'true' })))
      .toMatchObject({ ok: true, request: { ...base, turn: 1, full: true } })
    expect(parseDetailItemQuery(params({ ...base, full: '0' }))).toMatchObject({ ok: false })
    expect(parseDetailItemQuery(params({ ...base, full: ['1', '1'] }))).toMatchObject({ ok: false })
  })

  it('rejects the removed pagination parameters', () => {
    const base = { sessionId: 's', turn: '1', kind: 'tool', callId: 'c' }
    for (const legacy of [
      { epoch: '2' }, { cursor: '8' }, { part: 'arguments' },
      { byteOffset: '0' }, { fileIndex: '0' },
    ]) {
      expect(parseDetailItemQuery(params({ ...base, ...legacy }))).toMatchObject({ ok: false })
    }
  })
})

describe('size probe and full load', () => {
  it('returns a small item complete', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'short thought' }]))
    l.add(turnEnd(1))
    const result = responseOf(l.events, 1, 'thinking', { seq: 1, ord: 0 })
    if (!result.ok || result.response.kind !== 'thinking') throw new Error('missing thinking response')
    expect(result.response.deferred).toBeUndefined()
    expect(result.response.parts.reasoning?.text).toBe('short thought')
    expect(result.response.totalBytes).toBe(Buffer.byteLength('short thought', 'utf8'))
  })

  it('withholds a large item and reports its bytes', () => {
    const text = 'x'.repeat(DETAIL_FULL_LOAD_BYTES + 1)
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text }]))
    l.add(turnEnd(1))
    const result = responseOf(l.events, 1, 'thinking', { seq: 1, ord: 0 })
    if (!result.ok || result.response.kind !== 'thinking') throw new Error('missing thinking response')
    expect(result.response.deferred).toBe(true)
    expect(result.response.totalBytes).toBe(Buffer.byteLength(text, 'utf8'))
    expect(result.response.parts.reasoning?.text).toBe('')
    expect(result.response.parts.reasoning?.totalBytes).toBe(Buffer.byteLength(text, 'utf8'))
  })

  it('returns the complete item when full is requested', () => {
    const text = 'x'.repeat(DETAIL_FULL_LOAD_BYTES + 1)
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text }]))
    l.add(turnEnd(1))
    const result = responseOf(l.events, 1, 'thinking', { seq: 1, ord: 0 }, { full: true })
    if (!result.ok || result.response.kind !== 'thinking') throw new Error('missing thinking response')
    expect(result.response.deferred).toBeUndefined()
    expect(result.response.parts.reasoning?.text).toBe(text)
    expect(result.response.totalBytes).toBe(Buffer.byteLength(text, 'utf8'))
  })

  it('sizes a large tool item across arguments, result, and files', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(toolCall(1, 0, 'c1', 'edit', { file_path: 'f.txt', old_string: 'a', new_string: 'b' }))
    l.add(toolResult(1, 0, 'c1', {
      content: [{ type: 'text', text: 'result' }],
      meta: { path: '/work/f.txt', operation: 'update',
        diffs: [{ path: 'f.txt', oldText: 'a', newText: 'b' }] },
    }))
    l.add(turnEnd(1))
    const fakeRender = (file: DetailFileChange) => ({
      text: file.path, render: 'ok' as const, added: 1, removed: 1, truncated: false,
    })
    const result = responseOf(l.events, 1, 'tool', { callId: 'c1' }, { renderDiff: fakeRender })
    if (!result.ok || result.response.kind !== 'tool') throw new Error('missing tool response')
    expect(result.response.files).toHaveLength(1)
    expect(result.response.files?.[0]?.diff.text).toBe('/work/f.txt')
    expect(result.response.files?.[0]?.diff.totalBytes).toBe(Buffer.byteLength('/work/f.txt', 'utf8'))
    expect(result.response.totalBytes).toBe(
      Buffer.byteLength(JSON.stringify({ file_path: 'f.txt', old_string: 'a', new_string: 'b' }), 'utf8')
      + Buffer.byteLength('result', 'utf8')
      + Buffer.byteLength('/work/f.txt', 'utf8'),
    )
  })

  it('leaves a pending tool call result-free without a continuation error', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(toolCall(1, 0, 'c1', 'bash', {}))
    const result = responseOf(l.events, 1, 'tool', { callId: 'c1' })
    if (!result.ok || result.response.kind !== 'tool') throw new Error('missing tool response')
    expect(result.response.result).toBeUndefined()
    expect(result.response.parts.result).toBeUndefined()
  })
})

// -- Display diff rendering -------------------------------------------------

describe('renderFileChanges', () => {
  function applied(fragments: Array<{ oldText: string | null; newText: string }>): DetailFileChange {
    return {
      path: '/w/f.txt', absolute: '/w/f.txt', pathSource: 'recorded', cwd: '/w',
      operation: 'update', status: 'applied', fragments,
      totalFragments: fragments.length, droppedFragments: 0,
    }
  }

  it('renders an exact bounded fragment and counts lines', () => {
    const rendered = renderFileChanges([applied([{ oldText: 'a\nb', newText: 'a\nc' }])])
    expect(rendered.files[0]).toMatchObject({ render: 'ok', added: 1, removed: 1 })
    expect(rendered.text).toContain('-b')
    expect(rendered.text).toContain('+c')
    expect(rendered.text).toContain('display only; not an appliable patch')
    expect(rendered.text).not.toContain('\\ No newline')
  })

  it('renders create/empty/none/unavailable without fabricating a diff', () => {
    for (const status of ['create', 'empty', 'none', 'unavailable'] as const) {
      const rendered = renderFileChanges([{
        path: '/w/f.txt', absolute: '/w/f.txt', pathSource: 'recorded', status, fragments: [],
        totalFragments: 0, droppedFragments: 0,
      }])
      expect(rendered.files[0]?.status).toBe(status)
      expect(rendered.text).toContain(`status: ${status}`)
    }
  })

  it('marks oversized input too-large before diffing', () => {
    const rendered = renderFileChanges(
      [applied([{ oldText: 'aa', newText: 'bb' }])],
      { maxInputBytes: 1 },
    )
    expect(rendered.files[0]).toMatchObject({ status: 'applied', render: 'too-large', added: 0, removed: 0 })
    expect(rendered.text).toContain('too large to diff')
  })

  it('falls back to a coarse whole-fragment display when edit search is bounded', () => {
    const rendered = renderFileChanges(
      [applied([{ oldText: 'a\nb\nc', newText: 'x\ny\nz' }])],
      { maxEditLength: 1 },
    )
    expect(rendered.files[0]?.render).toBe('coarse')
    expect(rendered.text).toContain('edit search bound exceeded')
    expect(rendered.text).toContain('-a')
    expect(rendered.text).toContain('+x')
  })

  it('reports retained-fragment truncation without understating the durable total', () => {
    const file = applied([{ oldText: 'a', newText: 'b' }])
    file.totalFragments = 4
    file.droppedFragments = 3
    const rendered = renderFileChanges([file])
    expect(rendered.truncated).toBe(true)
    expect(rendered.files[0]).toMatchObject({
      fragments: 4, retainedFragments: 1, droppedFragments: 3, truncated: true,
    })
    expect(rendered.text).toContain('3 durable fragments omitted')
  })

  it('bounds output bytes and reports truncation', () => {
    const rendered = renderFileChanges(
      [applied([{ oldText: 'a'.repeat(200), newText: 'b'.repeat(200) }])],
      { maxOutputBytes: 40 },
    )
    expect(rendered.truncated).toBe(true)
    expect(Buffer.byteLength(rendered.text, 'utf8')).toBeLessThan(120)
    expect(rendered.text).toContain('truncated')
  })
})
