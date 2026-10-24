// dsh-emacs-bridge — Vitest specs for the optional turn-detail inspector.
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
  buildTurnDetailEntry,
  buildTurnDetailIndex,
  buildTurnDetailProjection,
  parseDetailEntryQuery,
  parseDetailTurnQuery,
  turnBoundaries,
  utf8Page,
  visibleDetailTurns,
  DETAIL_PAGE_BYTES,
  MAX_DETAIL_ENTRIES,
  MAX_DETAIL_FILE_CHANGES,
  MAX_DETAIL_FILE_FRAGMENTS,
  type DetailFileChange,
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

function userMessage(turn: number, text: string): SessionEventLike {
  return {
    time: turn * 1000,
    type: 'user/message',
    data: { turn, step: 0, message: { role: 'user', content: [{ type: 'text', text }] } },
    surfaceOp: 'append',
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

function indexOf(events: readonly SessionEventLike[], turn: number, surface = currentSurface(events), cwd = '/work') {
  return buildTurnDetailIndex({
    sessionId: 's1', turn, events, surfaceSeqs: surface, epoch: 2, cursor: events.length,
    boundaries: turnBoundaries(events), headerCwd: cwd,
  })
}

function entryOf(
  events: readonly SessionEventLike[], turn: number,
  kind: 'thinking' | 'tool-call' | 'tool-result' | 'file-diff', seq: number,
  opts: { ord?: number; surface?: Set<number>; cwd?: string } = {},
) {
  return buildTurnDetailEntry({
    turn, events, surfaceSeqs: opts.surface ?? currentSurface(events),
    boundaries: turnBoundaries(events), headerCwd: opts.cwd ?? '/work',
    kind, seq, ...opts.ord === undefined ? {} : { ord: opts.ord },
  })
}

function params(query: Record<string, string | string[]>): DetailQueryParams {
  return { getAll: (name: string) => {
    const value = query[name]
    return value === undefined ? [] : Array.isArray(value) ? value : [value]
  } }
}

// -- Index and visibility ----------------------------------------------------

describe('buildTurnDetailIndex', () => {
  it('lists complete reasoning blocks with seq+ord identity', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [
      { type: 'reasoning', text: 'first line\nfull body' },
      { type: 'text', text: 'visible reply' },
      { type: 'reasoning', text: 'second thought' },
    ]))
    l.add(turnEnd(1))
    const index = indexOf(l.events, 1)
    expect(index).not.toBeNull()
    const thinking = index!.entries.filter(entry => entry.kind === 'thinking')
    expect(thinking).toEqual([
      { kind: 'thinking', seq: 1, ord: 0, time: 1000, step: 0, summary: 'first line' },
      { kind: 'thinking', seq: 1, ord: 1, time: 1000, step: 0, summary: 'second thought' },
    ])
    expect(index!.epoch).toBe(2)
    expect(index!.open).toBe(false)
  })

  it('pairs calls with current results and keeps orphan results', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'text', text: 'working' }]))
    l.add(toolCall(1, 0, 'c1', 'read', { path: 'a' }))
    l.add(toolResult(1, 0, 'c1'))
    l.add(toolResult(1, 0, 'orphan'))
    l.add(turnEnd(1))
    const index = indexOf(l.events, 1)!
    const tools = index.entries.filter(entry => entry.kind !== 'thinking')
    expect(tools.map(entry => [entry.kind, entry.settlement])).toEqual([
      ['tool-call', 'settled'],
      ['tool-result', 'settled'],
      ['tool-result', 'orphan'],
    ])
  })

  it('excludes shadowed reasoning/results while keeping other entries of the turn', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'keep me' }]))
    l.add(assistant(1, 1, [{ type: 'reasoning', text: 'shadow me' }]))
    l.add(toolCall(1, 1, 'c1', 'read', {}))
    l.add(toolResult(1, 1, 'c1'))
    l.add(turnEnd(1))
    const surface = currentSurface(l.events, [2, 4])
    const index = indexOf(l.events, 1, surface)!
    expect(index.entries.map(entry => entry.seq)).toEqual([1])
    // The call's only result is shadowed: the call must not survive alone.
    expect(index.entries.some(entry => entry.kind === 'tool-call')).toBe(false)
  })

  it('keeps an unsettled log-only call only in an open turn', () => {
    const open = log()
    open.add(turnStart(1))
    open.add(assistant(1, 0, [{ type: 'text', text: 'starting' }]))
    open.add(toolCall(1, 0, 'c1', 'bash', { command: 'ls' }))
    expect(indexOf(open.events, 1)!.entries.some(entry => entry.kind === 'tool-call')).toBe(true)

    const closed = log()
    closed.add(turnStart(1))
    closed.add(assistant(1, 0, [{ type: 'text', text: 'starting' }]))
    closed.add(toolCall(1, 0, 'c1', 'bash', { command: 'ls' }))
    closed.add(turnEnd(1))
    expect(indexOf(closed.events, 1)).toBeNull()
  })

  it('keeps a failure-only turn visible and carries the sanitized failure', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(turnEnd(1, { code: 'AUTH', message: 'bad key' }))
    const index = indexOf(l.events, 1)!
    expect(index.entries).toEqual([])
    expect(index.failure).toEqual({ code: 'AUTH', message: '' })
  })

  it('bounds the index with explicit truncation metadata', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, Array.from({ length: MAX_DETAIL_ENTRIES + 3 }, (_, i) => ({
      type: 'reasoning', text: `thought ${i}`,
    }))))
    l.add(turnEnd(1))
    const index = indexOf(l.events, 1)!
    expect(index.entries).toHaveLength(MAX_DETAIL_ENTRIES)
    expect(index.truncated).toBe(true)
    expect(index.droppedEntries).toBe(3)
    expect(index.truncatedFromSeq).toBe(1)
  })

  it('returns null for a shadowed turn even when its user prompt survives', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(userMessage(1, 'a real prompt retained by compaction'))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'gone' }]))
    l.add(turnEnd(1))
    const surface = currentSurface(l.events, [2])
    expect(surface.has(1)).toBe(true)
    expect(indexOf(l.events, 1, surface)).toBeNull()
    expect(visibleDetailTurns(l.events, surface, turnBoundaries(l.events))).toEqual([])
  })
})

describe('visibleDetailTurns', () => {
  it('chooses the newest detail-producing turn, not a fully shadowed user-only turn', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(userMessage(1, 'old prompt'))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'old' }]))
    l.add(turnEnd(1))
    l.add(turnStart(2))
    l.add(userMessage(2, 'new prompt survives'))
    l.add(assistant(2, 0, [{ type: 'reasoning', text: 'shadowed newest' }]))
    l.add(turnEnd(2))
    const surface = currentSurface(l.events, [6])
    expect(visibleDetailTurns(l.events, surface, turnBoundaries(l.events))).toEqual([1])
  })

  it('keeps mixed surviving user and assistant surface entries without reviving shadowed detail', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(userMessage(1, 'prompt survives'))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'visible thought' }]))
    l.add(assistant(1, 1, [{ type: 'reasoning', text: 'shadowed thought' }]))
    l.add(turnEnd(1))
    const surface = currentSurface(l.events, [3])
    const index = indexOf(l.events, 1, surface)!
    expect(index.entries.map(entry => [entry.kind, entry.seq])).toEqual([['thinking', 2]])
    expect(visibleDetailTurns(l.events, surface, turnBoundaries(l.events))).toEqual([1])
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
    const index = indexOf(l.events, 1)
    const result = index!.entries.find(entry => entry.kind === 'tool-result')
    if (result?.kind !== 'tool-result' || result.files === undefined) return []
    const detail = entryOf(l.events, 1, 'file-diff', result.seq)
    return detail.ok && detail.entry.kind === 'file-diff' ? detail.entry.files : []
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

  it("exposes a valid orphan result durable diff without inventing a call", () => {
    const l = log()
    l.add(turnStart(1))
    l.add(toolResult(1, 0, 'orphan-file', {
      meta: { path: '/w/orphan.txt', operation: 'create', diffs: [] },
    }))
    l.add(turnEnd(1))
    const index = indexOf(l.events, 1)!
    const result = index.entries.find(entry => entry.kind === 'tool-result') as
      | { files?: Array<Record<string, unknown>> }
      | undefined
    expect(result?.files?.[0]).toMatchObject({
      status: 'create', path: '/w/orphan.txt', absolute: '/w/orphan.txt', pathSource: 'recorded',
    })
  })

  it('resolves orphan and fallback paths at their own event directories, not the final cwd', () => {
    const l = log()
    l.add(turnStart(1))
    l.add({ time: 1000, type: 'working-directory/change', data: { cwd: '/call' } })
    l.add(assistant(1, 0, [{ type: 'text', text: 'write' }]))
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
    const paired = entryOf(l.events, 1, 'file-diff', 5)
    const orphan = entryOf(l.events, 1, 'file-diff', 7)
    expect(paired).toMatchObject({ ok: true, entry: { files: [{ absolute: '/call/call.txt', cwd: '/call' }] } })
    expect(orphan).toMatchObject({ ok: true, entry: { files: [{ absolute: '/orphan/orphan.txt', cwd: '/orphan' }] } })
  })

  it('does not claim a failed mutation as an applied change', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'text', text: 'edit' }]))
    l.add(toolCall(1, 0, 'c1', 'write', { file_path: 'a', content: 'b' }))
    l.add(toolResult(1, 0, 'c1', { isError: true, meta: { diffs: [{ path: 'a', oldText: 'a', newText: 'b' }] } }))
    l.add(turnEnd(1))
    const index = indexOf(l.events, 1)!
    expect(index.entries.find(entry => entry.kind === 'tool-result')).toMatchObject({ isError: true })
    expect(index.entries.some(entry => entry.kind === 'tool-result' && entry.files !== undefined)).toBe(false)
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
    const index = indexOf(l.events, 1)!
    expect(index.entries[0]).toMatchObject({
      files: { length: MAX_DETAIL_FILE_CHANGES },
      totalFiles: total, droppedFiles: 2, filesTruncated: true,
    })
    expect(entryOf(l.events, 1, 'file-diff', 1)).toMatchObject({
      ok: true,
      entry: {
        files: { length: MAX_DETAIL_FILE_CHANGES },
        totalFiles: total, droppedFiles: 2, filesTruncated: true,
      },
    })
    expect(entryOf(l.events, 1, 'tool-result', 1)).toMatchObject({
      ok: true,
      entry: { totalFiles: total, droppedFiles: 2, filesTruncated: true },
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
    const index = indexOf(l.events, 1)!
    expect(index.entries[0]).toMatchObject({
      files: [{
        fragmentCount: total,
        retainedFragmentCount: MAX_DETAIL_FILE_FRAGMENTS,
        droppedFragments: 3,
        fragmentsTruncated: true,
      }],
    })
  })
})

// -- Entry selection ---------------------------------------------------------

describe('buildTurnDetailEntry', () => {
  it('returns complete reasoning text by block ordinal', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [
      { type: 'reasoning', text: 'one' },
      { type: 'reasoning', text: 'two\nfull' },
    ]))
    l.add(turnEnd(1))
    const one = entryOf(l.events, 1, 'thinking', 1, { ord: 0 })
    expect(one).toMatchObject({ ok: true, entry: { kind: 'thinking', ord: 0, text: 'one' } })
    const two = entryOf(l.events, 1, 'thinking', 1, { ord: 1 })
    expect(two).toMatchObject({ ok: true, entry: { text: 'two\nfull' } })
    expect(entryOf(l.events, 1, 'thinking', 1, { ord: 2 })).toMatchObject({
      ok: false, status: 404, reason: 'unknown-ordinal',
    })
  })

  it('returns exact tool arguments', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'text', text: 'call' }]))
    l.add(toolCall(1, 0, 'c1', 'bash', '{"command":"printf hi"}'))
    l.add(toolResult(1, 0, 'c1'))
    l.add(turnEnd(1))
    expect(entryOf(l.events, 1, 'tool-call', 2)).toMatchObject({
      ok: true,
      entry: { kind: 'tool-call', name: 'bash', arguments: '{"command":"printf hi"}' },
    })
  })

  it('returns every result content block, error, and sanitized AUTH diagnostic', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'text', text: 'call' }]))
    l.add(toolCall(1, 0, 'c1', 'read', {}))
    l.add(toolResult(1, 0, 'c1', {
      isError: true,
      content: [
        { type: 'text', text: 'failed' },
        { type: 'image', attachment: { mediaType: 'image/png', bytes: 12, width: 1, height: 2, attachmentId: 'secret' } },
        { type: 'future-block', secret: 'nope' },
      ],
      error: { name: 'AuthError', code: 'AUTH', reason: 'key-123' },
    }))
    l.add(turnEnd(1))
    const result = entryOf(l.events, 1, 'tool-result', 3)
    expect(result.ok).toBe(true)
    if (!result.ok || result.entry.kind !== 'tool-result') return
    expect(result.entry.isError).toBe(true)
    expect(result.entry.content.text).toBe('failed')
    expect(result.entry.content.blocks).toEqual([
      { type: 'image', mediaType: 'image/png', bytes: 12, width: 1, height: 2 },
      { type: 'future-block' },
    ])
    expect(result.entry.content.omittedBlocks).toBe(1)
    expect(result.entry.error).toEqual({ name: 'AuthError', code: 'AUTH' })
  })

  it('rejects a shadowed entry with 409 and an unknown seq with 404', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'shadowed' }]))
    l.add(turnEnd(1))
    const surface = new Set<number>()
    expect(entryOf(l.events, 1, 'thinking', 1, { ord: 0, surface })).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })
    expect(entryOf(l.events, 1, 'thinking', 99, { ord: 0, surface })).toMatchObject({
      ok: false, status: 404, reason: 'unknown-entry',
    })
  })

  it('reports a valid entry dropped by the index bound as 409 truncated', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, Array.from({ length: MAX_DETAIL_ENTRIES + 1 }, (_, i) => ({
      type: 'reasoning', text: `thought ${i}`,
    }))))
    l.add(turnEnd(1))
    expect(entryOf(l.events, 1, 'thinking', 1, { ord: 0 })).toMatchObject({
      ok: false, status: 409, reason: 'truncated',
    })
  })

  it('rejects whitespace-only and malformed current reasoning that has no index entry', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: '  \n' }]))
    const malformed = assistant(1, 1, [{ type: 'reasoning', text: 'not indexed' }])
    if (typeof malformed.data === 'object' && malformed.data !== null) {
      delete (malformed.data as { step?: unknown }).step
    }
    l.add(malformed)
    l.add(turnEnd(1))
    expect(entryOf(l.events, 1, 'thinking', 1, { ord: 0 })).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })
    expect(entryOf(l.events, 1, 'thinking', 2, { ord: 0 })).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })
  })

  it('requires matching index entries for direct call, result, and file-diff reads', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(toolCall(1, 0, 'c1', 'read', {}))
    l.add(toolResult(1, 0, 'c1'))
    l.add(turnEnd(1))
    const surface = currentSurface(l.events, [2])
    expect(entryOf(l.events, 1, 'tool-call', 1, { surface })).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })
    expect(entryOf(l.events, 1, 'tool-result', 2, { surface })).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })
    expect(entryOf(l.events, 1, 'file-diff', 2, { surface })).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })
    expect(entryOf(l.events, 1, 'file-diff', 2)).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })
  })

  it('uses a shared projection for identical index and entry visibility', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'shared' }]))
    l.add(turnEnd(1))
    const args = {
      sessionId: 's1', turn: 1, events: l.events, surfaceSeqs: currentSurface(l.events),
      epoch: 2, cursor: l.events.length, boundaries: turnBoundaries(l.events), headerCwd: '/work',
    }
    const projection = buildTurnDetailProjection(args)
    expect(projection.index?.entries).toHaveLength(1)
    expect(buildTurnDetailEntry({ ...args, kind: 'thinking', seq: 1, ord: 0, projection }))
      .toMatchObject({ ok: true, entry: { text: 'shared' } })
  })

  it('rejects a seq that names another turn', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistant(1, 0, [{ type: 'reasoning', text: 'one' }]))
    l.add(turnEnd(1))
    l.add(turnStart(2))
    l.add(assistant(2, 0, [{ type: 'reasoning', text: 'two' }]))
    l.add(turnEnd(2))
    expect(entryOf(l.events, 1, 'thinking', 4, { ord: 0 })).toMatchObject({ ok: false, status: 404 })
  })
})

// -- Query parsing and pagination -------------------------------------------

describe('detail query parsing', () => {
  it('accepts numeric and latest turn requests', () => {
    expect(parseDetailTurnQuery(params({ sessionId: 's', turn: '3' })))
      .toEqual({ ok: true, request: { sessionId: 's', turn: 3 } })
    expect(parseDetailTurnQuery(params({ sessionId: 's', turn: 'latest' })))
      .toEqual({ ok: true, request: { sessionId: 's', turn: 'latest' } })
  })

  it('requires one non-empty session id', () => {
    expect(parseDetailTurnQuery(params({ turn: '1' }))).toMatchObject({ ok: false })
    expect(parseDetailTurnQuery(params({ sessionId: '', turn: '1' }))).toMatchObject({ ok: false })
    expect(parseDetailTurnQuery(params({ sessionId: ['a', 'b'], turn: '1' }))).toMatchObject({ ok: false })
  })

  it('rejects repeated and malformed parameters', () => {
    expect(parseDetailTurnQuery(params({ sessionId: 's', turn: ['1', '2'] }))).toMatchObject({ ok: false })
    expect(parseDetailTurnQuery(params({ sessionId: 's', turn: '-1' }))).toMatchObject({ ok: false })
    expect(parseDetailTurnQuery(params({ sessionId: 's', turn: '1.5' }))).toMatchObject({ ok: false })
    expect(parseDetailEntryQuery(params({
      sessionId: 's', turn: '1', epoch: '0', cursor: '4', kind: 'thinking', seq: '1', ord: '0', byteOffset: 'x',
    }))).toMatchObject({ ok: false })
  })

  it('requires ord for thinking and rejects it elsewhere', () => {
    const base = { sessionId: 's', turn: '1', epoch: '0', cursor: '4', seq: '1' }
    expect(parseDetailEntryQuery(params({ ...base, kind: 'thinking' }))).toMatchObject({ ok: false })
    expect(parseDetailEntryQuery(params({ ...base, kind: 'thinking', ord: '0' }))).toMatchObject({
      ok: true, request: { kind: 'thinking', ord: 0 },
    })
    expect(parseDetailEntryQuery(params({ ...base, kind: 'tool-call', ord: '0' }))).toMatchObject({ ok: false })
    expect(parseDetailEntryQuery(params({ ...base, kind: 'tool-call' }))).toMatchObject({
      ok: true, request: { kind: 'tool-call', byteOffset: 0 },
    })
  })
})

describe('utf8Page', () => {
  it('splits only on code-point boundaries and reports the total', () => {
    const text = 'aé😀z'
    const first = utf8Page(text, 0, 3)
    expect(first).toEqual({ text: 'aé', byteOffset: 0, nextByteOffset: 3, totalBytes: 8, hasMore: true })
    const second = utf8Page(text, first!.nextByteOffset, 4)
    expect(second).toEqual({ text: '😀', byteOffset: 3, nextByteOffset: 7, totalBytes: 8, hasMore: true })
    const third = utf8Page(text, second!.nextByteOffset, DETAIL_PAGE_BYTES)
    expect(third).toEqual({ text: 'z', byteOffset: 7, nextByteOffset: 8, totalBytes: 8, hasMore: false })
  })

  it('still makes progress when the byte budget is smaller than one code point', () => {
    const page = utf8Page('😀x', 0, 1)
    expect(page).toMatchObject({ text: '😀', nextByteOffset: 4, totalBytes: 5, hasMore: true })
  })

  it('rejects an offset inside a code point or past the end', () => {
    expect(utf8Page('😀', 1)).toBeNull()
    expect(utf8Page('abc', 4)).toBeNull()
    expect(utf8Page('abc', 0, 0)).toBeNull()
  })

  it('returns an empty final page at the total', () => {
    expect(utf8Page('abc', 3)).toEqual({
      text: '', byteOffset: 3, nextByteOffset: 3, totalBytes: 3, hasMore: false,
    })
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
