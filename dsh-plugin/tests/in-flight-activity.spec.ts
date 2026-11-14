// dsh-emacs-bridge — Vitest specs for the in-flight reasoning registry.
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
  buildDetailItemResponse,
  buildInFlightDetailItem,
  DETAIL_FULL_LOAD_BYTES,
  InFlightActivityRegistry,
  MAX_INFLIGHT_HANDOFFS_PER_SESSION,
  MAX_INFLIGHT_PIECES_PER_BLOCK,
  MAX_INFLIGHT_REASONING_BYTES,
  MAX_INFLIGHT_SESSIONS,
  parseDetailItemQuery,
  turnActivity,
  turnBoundaries,
  withActivityTurns,
  withInFlightActivity,
  type SessionEventLike,
  type TurnActivity,
} from '../src/logic.ts'

// -- Fixtures ----------------------------------------------------------------

/** A registry with deterministic selectors. */
function registry(mint: () => string = (() => {
  let counter = 0
  return () => {
    counter += 1
    return `live-${counter}`
  }
})()): InFlightActivityRegistry {
  return new InFlightActivityRegistry(mint)
}

const AGENT = { name: 'owner' }

function startFrame(attemptId = 's:1', revision = 1, turn = 1, step = 1) {
  return { type: 'start', attemptId, revision, turn, step }
}

function chunkFrame(
  attemptId: string, revision: number, index: number, chunk: unknown, time = 1000 + index,
) {
  return { type: 'chunk', attemptId, revision, index, time, chunk }
}

function endFrame(
  attemptId: string, revision: number, index: number,
  outcome: unknown,
) {
  return { type: 'end', attemptId, revision, index, outcome }
}

/** A live attempt's running chronology, so specs need not hand-number frames. */
function stream(reg: InFlightActivityRegistry, attemptId = 's:1') {
  let revision = 1
  let index = 0
  const agent = AGENT
  return {
    open(turn = 1, step = 1) {
      reg.accept('s1', agent, agent, startFrame(attemptId, revision, turn, step))
      return this
    },
    push(chunk: unknown) {
      revision += 1
      const effect = reg.accept('s1', agent, agent,
        chunkFrame(attemptId, revision, index, chunk))
      index += 1
      return effect
    },
    end(outcome: unknown) {
      revision += 1
      const effect = reg.accept('s1', agent, agent, endFrame(attemptId, revision, index, outcome))
      index += 1
      return effect
    },
  }
}

// -- The reducer -------------------------------------------------------------

describe('InFlightActivityRegistry accumulation', () => {
  it('accumulates fragmented deltas and dense reasoning ordinals across block kinds', () => {
    const reg = registry()
    const st = stream(reg).open()
    st.push({ type: 'reasoning-delta', index: 0, text: 'Hel' })
    st.push({ type: 'reasoning-delta', index: 0, text: 'lo' })
    st.push({ type: 'text-delta', index: 1, text: 'ignored' })
    st.push({ type: 'reasoning-delta', index: 2, text: 'Second' })

    const entries = reg.entries('s1')
    expect(entries.map(entry => entry.ord)).toEqual([0, 1])
    expect(entries.map(entry => entry.summary)).toEqual(['Hello', 'Second'])
    expect(entries[0]).toMatchObject({ inFlight: true, turn: 1, step: 1, revision: 5 })
    expect(entries[0]).not.toHaveProperty('seq')

    const live = reg.select('s1', entries[0]!.inFlightId, 1, 0)
    expect(live).toMatchObject({ ok: true, kind: 'live', text: 'Hello', truncated: false })
  })

  it('supports delta-only and block-end-only reasoning without duplicating text', () => {
    const blockEndOnly = registry()
    const one = stream(blockEndOnly).open()
    one.push({ type: 'block-end', index: 0, block: { type: 'reasoning', text: 'End only' } })
    expect(blockEndOnly.entries('s1').map(entry => entry.summary)).toEqual(['End only'])

    const deltaOnly = registry()
    const two = stream(deltaOnly).open()
    two.push({ type: 'reasoning-delta', index: 0, text: 'No start' })
    expect(deltaOnly.entries('s1').map(entry => entry.summary)).toEqual(['No start'])

    const both = registry()
    const three = stream(both).open()
    three.push({ type: 'reasoning-delta', index: 0, text: 'Authoritative prefix' })
    three.push({ type: 'block-end', index: 0, block: { type: 'reasoning', text: 'Authoritative prefix and more' } })
    expect(both.entries('s1').map(entry => entry.summary)).toEqual(['Authoritative prefix'])

    // Deltas after a block-end are stragglers, exactly as the assembler drops them.
    three.push({ type: 'reasoning-delta', index: 0, text: 'LATE' })
    expect(both.entries('s1').map(entry => entry.summary)).toEqual(['Authoritative prefix'])
  })

  it('allocates an ordinal for an empty reasoning block without producing a line', () => {
    const reg = registry()
    const st = stream(reg).open()
    st.push({ type: 'block-start', index: 0, blockType: 'reasoning' })
    st.push({ type: 'block-end', index: 0, block: { type: 'reasoning', text: '   ' } })
    st.push({ type: 'reasoning-delta', index: 1, text: 'later' })
    expect(reg.entries('s1').map(entry => ({ ord: entry.ord, summary: entry.summary })))
      .toEqual([{ ord: 1, summary: 'later' }])

    // The committed fold counts the empty block too, so the live ordinal 1
    // matches the committed ordinal 1.
    const events = [
      { time: 1, type: 'turn/start', data: { turn: 1 }, seq: 0 },
      {
        time: 2,
        type: 'assistant/message',
        data: {
          turn: 1,
          step: 1,
          message: { role: 'assistant', content: [{ type: 'reasoning', text: '' }, { type: 'reasoning', text: 'later' }] },
        },
        surfaceOp: 'append',
        seq: 1,
      },
    ] as SessionEventLike[]
    expect(turnActivity(events).get(1)!.entries.map(entry => entry.ord)).toEqual([1])
  })
})

// -- Nudges and acceptance ---------------------------------------------------

describe('InFlightActivityRegistry nudges', () => {
  it('nudges on the first summary and once on first-line completion only', () => {
    const reg = registry()
    const st = stream(reg).open()
    expect(st.push({ type: 'reasoning-delta', index: 0, text: 'H' }).nudge).toBe(true)
    expect(st.push({ type: 'reasoning-delta', index: 0, text: 'i' }).nudge).toBe(false)
    expect(st.push({ type: 'reasoning-delta', index: 0, text: ' there\n' }).nudge).toBe(true)
    expect(st.push({ type: 'reasoning-delta', index: 0, text: 'more' }).nudge).toBe(false)
  })

  it('nudges when a visible attempt settles, is replaced, is abandoned, or closes', () => {
    const settled = registry()
    const one = stream(settled).open()
    one.push({ type: 'reasoning-delta', index: 0, text: 'visible' })
    expect(one.end({ kind: 'committed', eventType: 'assistant/message', seq: 9 }).nudge).toBe(true)

    const abandoned = registry()
    const two = stream(abandoned).open()
    two.push({ type: 'reasoning-delta', index: 0, text: 'visible' })
    expect(two.end({ kind: 'abandoned' }).nudge).toBe(true)

    const replaced = registry()
    const three = stream(replaced).open()
    three.push({ type: 'reasoning-delta', index: 0, text: 'visible' })
    const oldId = replaced.entries('s1')[0]!.inFlightId
    const replacement = { type: 'start', attemptId: 's:1', revision: 1, turn: 1, step: 1 }
    expect(replaced.accept('s1', AGENT, AGENT, replacement).nudge).toBe(true)
    expect(replaced.select('s1', oldId, 1, 0))
      .toMatchObject({ ok: false, status: 409, reason: 'not-visible' })

    const closed = registry()
    const four = stream(closed).open()
    four.push({ type: 'reasoning-delta', index: 0, text: 'visible' })
    expect(closed.turnEnded('s1', 1).nudge).toBe(true)
  })

  it('ignores a non-owner agent, a wrong attempt, and non-dense ordering', () => {
    const reg = registry()
    const st = stream(reg).open()
    st.push({ type: 'reasoning-delta', index: 0, text: 'one' })
    const other = { name: 'other' }
    // A start from a non-owner never steals an established record.
    reg.accept('s1', other, other, startFrame('s:2', 1, 1, 1))
    expect(reg.entries('s1')).toHaveLength(1)
    // A chunk from a non-owner is ignored.
    reg.accept('s1', other, AGENT, chunkFrame('s:1', 3, 1,
      { type: 'reasoning-delta', index: 0, text: 'stolen' }))
    expect(reg.select('s1', reg.entries('s1')[0]!.inFlightId, 1, 0)).toMatchObject({ text: 'one' })
    // A wrong attempt id is ignored as well.
    reg.accept('s1', AGENT, AGENT, chunkFrame('s:9', 3, 1,
      { type: 'reasoning-delta', index: 0, text: 'wrong' }))
    expect(reg.select('s1', reg.entries('s1')[0]!.inFlightId, 1, 0)).toMatchObject({ text: 'one' })
    // A dense-index gap abandons the attempt and records a known non-visible handoff.
    const id = reg.entries('s1')[0]!.inFlightId
    expect(reg.accept('s1', AGENT, AGENT, chunkFrame('s:1', 4, 5,
      { type: 'reasoning-delta', index: 0, text: 'gap' })).nudge).toBe(true)
    expect(reg.entries('s1')).toEqual([])
    expect(reg.select('s1', id, 1, 0)).toMatchObject({ ok: false, status: 409, reason: 'not-visible' })
  })

  it('ignores a start from an agent the host has not registered', () => {
    const reg = registry()
    const effect = reg.accept('s1', AGENT, undefined, startFrame())
    expect(effect.nudge).toBe(false)
    expect(reg.entries('s1')).toEqual([])
  })

  it('drops a disposed agent while retaining its metadata handoffs', () => {
    const reg = registry()
    const st = stream(reg).open()
    st.push({ type: 'reasoning-delta', index: 0, text: 'visible' })
    const id = reg.entries('s1')[0]!.inFlightId
    st.end({ kind: 'committed', eventType: 'assistant/message', seq: 4 })
    // A disposal after replacement must not clear the replacement's state.
    const replacement = { name: 'replacement' }
    reg.agentDisposed('s1', AGENT)
    expect(reg.select('s1', id, 1, 0)).toMatchObject({ ok: true, kind: 'committed', seq: 4 })
    expect(reg.accept('s1', replacement, replacement, startFrame('s:2', 1, 1, 1)).nudge).toBe(false)
    reg.accept('s1', replacement, replacement, chunkFrame('s:2', 2, 0,
      { type: 'reasoning-delta', index: 0, text: 'replacement text' }))
    // A disposal of the replaced agent must not clear the new owner's state.
    reg.agentDisposed('s1', AGENT)
    expect(reg.entries('s1')).toHaveLength(1)
  })
})

// -- Bounds ------------------------------------------------------------------

describe('InFlightActivityRegistry bounds', () => {
  it('versions every accepted snapshot within one bridge instance', () => {
    const reg = registry()
    expect(reg.revision('s1')).toBe(0)
    expect(reg.activityEpoch).toMatch(/^[0-9a-f-]{36}$/)
    const st = stream(reg).open()
    expect(reg.revision('s1')).toBe(1)
    st.push({ type: 'reasoning-delta', index: 0, text: 'visible' })
    expect(reg.revision('s1')).toBe(2)
    st.end({ kind: 'abandoned' })
    expect(reg.revision('s1')).toBe(3)
    expect(reg.entries('s1')).toEqual([])
    reg.sessionDisposed('s1')
    expect(reg.revision('s1')).toBe(0)
  })

  it('caps retained bytes per attempt, reports per-block truncation, and leaves later budget', () => {
    const reg = registry()
    const st = stream(reg).open()
    const prefix = 'a'.repeat(MAX_INFLIGHT_REASONING_BYTES - 4)
    st.push({ type: 'reasoning-delta', index: 0, text: prefix })
    // This delta does not fit: the block is capped, not the attempt.
    st.push({ type: 'reasoning-delta', index: 0, text: 'bbbbb' })
    expect(reg.select('s1', reg.entries('s1')[0]!.inFlightId, 1, 0))
      .toMatchObject({ ok: true, truncated: true, retainedBytes: MAX_INFLIGHT_REASONING_BYTES - 4 })
    // Four more bytes fit in the attempt's remaining budget.
    st.push({ type: 'reasoning-delta', index: 1, text: 'cccc' })
    const second = reg.entries('s1').find(entry => entry.ord === 1)!
    expect(reg.select('s1', second.inFlightId, 1, 1))
      .toMatchObject({ ok: true, text: 'cccc', truncated: false })
    // The attempt budget is now spent.
    st.push({ type: 'reasoning-delta', index: 2, text: 'd' })
    expect(reg.entries('s1').find(entry => entry.ord === 2)).toBeUndefined()
  })

  it('coalesces pieces so one-character deltas stay bounded', () => {
    const reg = registry()
    const st = stream(reg).open()
    for (let index = 0; index < MAX_INFLIGHT_PIECES_PER_BLOCK * 3; index += 1) {
      st.push({ type: 'reasoning-delta', index: 0, text: 'x' })
    }
    expect(reg.retainedPieces('s1', 0)).toBeLessThanOrEqual(MAX_INFLIGHT_PIECES_PER_BLOCK)
    expect(reg.select('s1', reg.entries('s1')[0]!.inFlightId, 1, 0))
      .toMatchObject({ text: 'x'.repeat(MAX_INFLIGHT_PIECES_PER_BLOCK * 3) })
  })

  it('bounds the handoff list and evicts the oldest session record', () => {
    const reg = registry()
    const ids: string[] = []
    for (let attempt = 0; attempt < MAX_INFLIGHT_HANDOFFS_PER_SESSION + 2; attempt += 1) {
      const st = stream(reg, `s:${attempt}`).open()
      st.push({ type: 'reasoning-delta', index: 0, text: `attempt ${attempt}` })
      ids.push(reg.entries('s1')[0]!.inFlightId)
      st.end({ kind: 'committed', eventType: 'assistant/message', seq: attempt })
    }
    expect(reg.select('s1', ids[0]!, 1, 0)).toMatchObject({ ok: false, status: 404 })
    expect(reg.select('s1', ids[1]!, 1, 0)).toMatchObject({ ok: false, status: 404 })
    expect(reg.select('s1', ids[ids.length - 1]!, 1, 0)).toMatchObject({ ok: true, kind: 'committed' })

    // The session LRU evicts the oldest record entirely.
    const agent = { name: 'many' }
    let evicted: { sessionId: string; turn?: number } | undefined
    for (let index = 0; index <= MAX_INFLIGHT_SESSIONS; index += 1) {
      const id = `session-${index}`
      const effect = reg.accept(id, agent, agent, startFrame('s:1', 1, 1, 1))
      reg.accept(id, agent, agent, chunkFrame('s:1', 2, 0,
        { type: 'reasoning-delta', index: 0, text: `summary ${index}` }))
      if (effect.evicted !== undefined) evicted = effect.evicted
    }
    expect(reg.size).toBeLessThanOrEqual(MAX_INFLIGHT_SESSIONS)
    expect(evicted?.sessionId).toBe('session-0')
    expect(reg.entries('s1')).toEqual([])
  })
})

// -- The `/turns` merge ------------------------------------------------------

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

function liveEntry(overrides: Partial<{
  inFlightId: string
  ord: number
  turn: number
  step: number
  time: number
  revision: number
  summary: string
}> = {}) {
  return {
    kind: 'thinking' as const,
    inFlight: true as const,
    inFlightId: overrides.inFlightId ?? 'live-x',
    attemptId: 's:1',
    revision: overrides.revision ?? 3,
    ord: overrides.ord ?? 0,
    time: overrides.time ?? 1000,
    turn: overrides.turn ?? 1,
    step: overrides.step ?? 1,
    summary: overrides.summary ?? 'A live thought',
  }
}

describe('withInFlightActivity', () => {
  it('synthesizes an open, text-less live turn and keeps summaries summary-only', () => {
    const l = log()
    l.add({ time: 1000, type: 'turn/start', data: { turn: 1 } })
    const boundaries = turnBoundaries(l.events)
    const activity = withInFlightActivity(turnActivity(l.events), [liveEntry()], boundaries)
    const merged = withActivityTurns([], activity, boundaries, new Set())
    expect(merged).toHaveLength(1)
    expect(merged[0]).toMatchObject({ turn: 1, startedAt: 1000, segments: [] })
    expect(merged[0]!.endedAt).toBeUndefined()
    const entries = activity.get(1)!.entries
    expect(entries).toHaveLength(1)
    expect(JSON.stringify(entries)).not.toContain('secret')
  })

  it('never offers a live entry for a closed turn', () => {
    const l = log()
    l.add({ time: 1000, type: 'turn/start', data: { turn: 1 } })
    l.add({ time: 2000, type: 'turn/end', data: { turn: 1, reason: { kind: 'completed' } } })
    const boundaries = turnBoundaries(l.events)
    const activity = withInFlightActivity(turnActivity(l.events), [liveEntry()], boundaries)
    expect(activity.size).toBe(0)
    expect(withActivityTurns([], activity, boundaries, new Set())).toEqual([])
  })

  it('applies both retention caps after merging', () => {
    const l = log()
    l.add({ time: 1000, type: 'turn/start', data: { turn: 1 } })
    const activity: Map<number, TurnActivity> = new Map()
    activity.set(1, {
      entries: Array.from({ length: 500 }, (_, index) => ({
        kind: 'tool-call' as const,
        seq: index,
        ord: 0,
        time: 1000 + index,
        turn: 1,
        step: 1,
        callId: `c${index}`,
        name: 'read',
        summary: `p${index}`,
      })),
      messageSeqs: [],
    })
    const merged = withInFlightActivity(activity, [liveEntry()], turnBoundaries(l.events))
    expect(merged.get(1)!.entries).toHaveLength(500)
    expect(merged.get(1)!.entries[499]).toMatchObject({ kind: 'thinking', inFlight: true })
  })
})

// -- Query parsing -----------------------------------------------------------

function params(query: Record<string, string | string[]>): { getAll(name: string): string[] } {
  return {
    getAll(name: string) {
      const value = query[name]
      return value === undefined ? [] : Array.isArray(value) ? value : [value]
    },
  }
}

describe('parseDetailItemQuery live selector', () => {
  it('accepts exactly one of seq and inFlightId for thinking', () => {
    expect(parseDetailItemQuery(params({
      sessionId: 's', turn: '1', kind: 'thinking', inFlightId: 'live-1', ord: '0',
    }))).toMatchObject({ ok: true, request: { kind: 'thinking', inFlightId: 'live-1', ord: 0 } })
    expect(parseDetailItemQuery(params({
      sessionId: 's', turn: '1', kind: 'thinking', seq: '4', ord: '0',
    }))).toMatchObject({ ok: true, request: { kind: 'thinking', seq: 4, ord: 0 } })
    expect(parseDetailItemQuery(params({
      sessionId: 's', turn: '1', kind: 'thinking', seq: '4', inFlightId: 'live-1', ord: '0',
    })).ok).toBe(false)
    expect(parseDetailItemQuery(params({
      sessionId: 's', turn: '1', kind: 'thinking', ord: '0',
    })).ok).toBe(false)
  })

  it('rejects an empty, overlong, or control-bearing inFlightId, and rejects it off thinking', () => {
    const base = { sessionId: 's', turn: '1', kind: 'thinking', ord: '0' }
    for (const value of ['', 'x'.repeat(129), 'bad\u0000id', 'bad\nid']) {
      expect(parseDetailItemQuery(params({ ...base, inFlightId: value })).ok).toBe(false)
    }
    expect(parseDetailItemQuery(params({
      sessionId: 's', turn: '1', kind: 'tool', callId: 'c1', inFlightId: 'live-1',
    })).ok).toBe(false)
    expect(parseDetailItemQuery(params({
      sessionId: 's', turn: '1', kind: 'thinking', inFlightId: ['a', 'b'], ord: '0',
    })).ok).toBe(false)
    expect(parseDetailItemQuery(params({
      sessionId: 's', turn: '1', kind: 'thinking', inFlightId: 'a', ord: ['0', '1'],
    })).ok).toBe(false)
  })
})

// -- Detail selection and the status table ----------------------------------

function assistantLog(content: unknown[], interrupted = false) {
  const l = log()
  l.add({ time: 1000, type: 'turn/start', data: { turn: 1 } })
  l.add({
    time: 2000,
    type: 'assistant/message',
    data: {
      turn: 1,
      step: 1,
      message: { role: 'assistant', content },
      ...interrupted ? { interrupted: true } : {},
    },
    surfaceOp: 'append',
  } as SessionEventLike)
  return l
}

function detailArgs(
  reg: InFlightActivityRegistry,
  events: readonly SessionEventLike[],
  inFlightId: string,
  ord = 0,
  surface?: Set<number>,
) {
  return {
    registry: reg,
    sessionId: 's1',
    turn: 1,
    ord,
    inFlightId,
    events,
    surfaceSeqs: surface ?? new Set(events.map(event => event.seq as number)),
    boundaries: turnBoundaries(events),
  }
}

describe('buildInFlightDetailItem', () => {
  it('returns the selected live snapshot and reports per-block truncation', () => {
    const reg = registry()
    const st = stream(reg).open()
    st.push({ type: 'reasoning-delta', index: 0, text: 'first bit' })
    const l = log()
    l.add({ time: 1000, type: 'turn/start', data: { turn: 1 } })
    const id = reg.entries('s1')[0]!.inFlightId
    const selected = buildInFlightDetailItem(detailArgs(reg, l.events, id))
    expect(selected.ok).toBe(true)
    if (!selected.ok) return
    expect(selected.item).toMatchObject({
      kind: 'thinking', inFlight: true, inFlightId: id, attemptId: 's:1',
      ord: 0, turn: 1, step: 1, text: 'first bit',
    })
    expect(selected.item).not.toHaveProperty('seq')
  })

  it('resolves a normal committed handoff to the same ordinal', () => {
    const reg = registry()
    const st = stream(reg).open()
    st.push({ type: 'reasoning-delta', index: 0, text: 'First thought' })
    st.push({ type: 'reasoning-delta', index: 1, text: 'Second thought' })
    const id = reg.entries('s1')[0]!.inFlightId
    const l = assistantLog([
      { type: 'reasoning', text: 'First thought' },
      { type: 'reasoning', text: 'Second thought' },
    ])
    st.end({ kind: 'committed', eventType: 'assistant/message', seq: 1 })
    const selected = buildInFlightDetailItem(detailArgs(reg, l.events, id, 1))
    expect(selected).toMatchObject({ ok: true, item: { kind: 'thinking', seq: 1, ord: 1, text: 'Second thought' } })
  })

  it('translates the ordinal of an interrupted message through the survivor rule', () => {
    const reg = registry()
    const st = stream(reg).open()
    st.push({ type: 'block-start', index: 0, blockType: 'reasoning' })
    st.push({ type: 'block-end', index: 0, block: { type: 'reasoning', text: '   ' } })
    st.push({ type: 'reasoning-delta', index: 1, text: 'survivor' })
    const id = reg.entries('s1')[0]!.inFlightId
    const l = assistantLog([{ type: 'reasoning', text: 'survivor' }], true)
    st.end({ kind: 'committed', eventType: 'assistant/message', seq: 1 })
    const selected = buildInFlightDetailItem(detailArgs(reg, l.events, id, 1))
    expect(selected).toMatchObject({ ok: true, item: { seq: 1, ord: 0, text: 'survivor' } })
    // The empty leading block has no documented committed item.
    expect(buildInFlightDetailItem(detailArgs(reg, l.events, id, 0)))
      .toMatchObject({ ok: false, status: 409, reason: 'not-visible' })
  })

  it('returns 409 for shadowed, log-only, and abandoned handoffs, and 404 for unknown ids', () => {
    const reg = registry()
    const st = stream(reg).open()
    st.push({ type: 'reasoning-delta', index: 0, text: 'thought' })
    const id = reg.entries('s1')[0]!.inFlightId
    const l = assistantLog([{ type: 'reasoning', text: 'thought' }])
    st.end({ kind: 'committed', eventType: 'assistant/message', seq: 1 })
    // Shadowed by compaction: the message seq is not on the current surface.
    expect(buildInFlightDetailItem(detailArgs(reg, l.events, id, 0, new Set()))).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })

    const logOnly = registry()
    const lo = stream(logOnly).open()
    lo.push({ type: 'reasoning-delta', index: 0, text: 'thought' })
    const loId = logOnly.entries('s1')[0]!.inFlightId
    lo.end({ kind: 'committed', eventType: 'assistant/attempt', seq: 1 })
    expect(buildInFlightDetailItem(detailArgs(logOnly, l.events, loId, 0))).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })

    const abandoned = registry()
    const ab = stream(abandoned).open()
    ab.push({ type: 'reasoning-delta', index: 0, text: 'thought' })
    const abId = abandoned.entries('s1')[0]!.inFlightId
    ab.end({ kind: 'abandoned' })
    expect(buildInFlightDetailItem(detailArgs(abandoned, l.events, abId, 0))).toMatchObject({
      ok: false, status: 409, reason: 'not-visible',
    })

    expect(buildInFlightDetailItem(detailArgs(reg, l.events, 'no-such-id', 0))).toMatchObject({
      ok: false, status: 404, reason: 'unknown-item',
    })
  })

  it('returns 404 for a wrong turn and for a block with no retained text', () => {
    const reg = registry()
    const st = stream(reg).open()
    st.push({ type: 'reasoning-delta', index: 0, text: 'thought' })
    st.push({ type: 'block-start', index: 1, blockType: 'reasoning' })
    const id = reg.entries('s1')[0]!.inFlightId
    const l = log()
    l.add({ time: 1000, type: 'turn/start', data: { turn: 1 } })
    expect(reg.select('s1', id, 2, 0)).toMatchObject({ ok: false, status: 404 })
    expect(reg.select('s1', id, 1, 1)).toMatchObject({ ok: false, status: 404, reason: 'unknown-item' })
    expect(buildInFlightDetailItem({ ...detailArgs(reg, l.events, id), turn: 2 }))
      .toMatchObject({ ok: false, status: 404 })
  })

  it('serializes the live response through the size probe and full-load contract', () => {
    const reg = registry()
    const st = stream(reg).open()
    st.push({ type: 'reasoning-delta', index: 0, text: 'small snapshot' })
    const id = reg.entries('s1')[0]!.inFlightId
    const l = log()
    l.add({ time: 1000, type: 'turn/start', data: { turn: 1 } })
    const selected = buildInFlightDetailItem(detailArgs(reg, l.events, id))
    expect(selected.ok).toBe(true)
    if (!selected.ok) return
    const response = buildDetailItemResponse({
      sessionId: 's1', epoch: 1, cursor: 2, cwd: '/tmp',
      item: selected.item, request: {},
      renderDiff: () => ({ text: '', render: 'none', added: 0, removed: 0, truncated: false }),
    })
    expect(response.ok).toBe(true)
    if (!response.ok) return
    expect(response.response).toMatchObject({
      kind: 'thinking', inFlight: true, inFlightId: id, attemptId: 's:1',
      revision: 2, ord: 0, parts: { reasoning: { text: 'small snapshot' } },
    })
    expect(response.response).not.toHaveProperty('seq')
  })

  it('reports per-block truncation and cannot recover the discarded bytes', () => {
    const reg = registry()
    const st = stream(reg).open()
    st.push({ type: 'reasoning-delta', index: 0, text: 'a'.repeat(MAX_INFLIGHT_REASONING_BYTES) })
    st.push({ type: 'reasoning-delta', index: 0, text: 'discarded' })
    const id = reg.entries('s1')[0]!.inFlightId
    const l = log()
    l.add({ time: 1000, type: 'turn/start', data: { turn: 1 } })
    const selected = buildInFlightDetailItem(detailArgs(reg, l.events, id))
    expect(selected).toMatchObject({ ok: true, item: { truncated: true } })
    if (!selected.ok) return
    const response = buildDetailItemResponse({
      sessionId: 's1', epoch: 1, cursor: 2,
      item: selected.item, request: { full: true },
      renderDiff: () => ({ text: '', render: 'none', added: 0, removed: 0, truncated: false }),
    })
    expect(response).toMatchObject({
      ok: true,
      response: { truncated: true, totalBytes: MAX_INFLIGHT_REASONING_BYTES },
    })
    if (!response.ok) return
    expect(response.response.parts.reasoning?.text)
      .toBe('a'.repeat(MAX_INFLIGHT_REASONING_BYTES))
  })

  it('withholds an over-threshold live snapshot and returns it whole on full=1', () => {
    const reg = registry()
    const st = stream(reg).open()
    const large = 'x'.repeat(DETAIL_FULL_LOAD_BYTES + 1024)
    st.push({ type: 'reasoning-delta', index: 0, text: large })
    const id = reg.entries('s1')[0]!.inFlightId
    const l = log()
    l.add({ time: 1000, type: 'turn/start', data: { turn: 1 } })
    const selected = buildInFlightDetailItem(detailArgs(reg, l.events, id))
    expect(selected.ok).toBe(true)
    if (!selected.ok) return
    const probe = buildDetailItemResponse({
      sessionId: 's1', epoch: 1, cursor: 2,
      item: selected.item, request: {},
      renderDiff: () => ({ text: '', render: 'none', added: 0, removed: 0, truncated: false }),
    })
    expect(probe.ok).toBe(true)
    if (!probe.ok) return
    expect(probe.response).toMatchObject({
      deferred: true,
      totalBytes: DETAIL_FULL_LOAD_BYTES + 1024,
      parts: { reasoning: { text: '', totalBytes: DETAIL_FULL_LOAD_BYTES + 1024 } },
    })
    const full = buildDetailItemResponse({
      sessionId: 's1', epoch: 1, cursor: 2,
      item: selected.item, request: { full: true },
      renderDiff: () => ({ text: '', render: 'none', added: 0, removed: 0, truncated: false }),
    })
    expect(full.ok).toBe(true)
    if (!full.ok) return
    expect(full.response.parts.reasoning?.text).toBe(large)
    expect(full.response).not.toHaveProperty('deferred')
  })
})
