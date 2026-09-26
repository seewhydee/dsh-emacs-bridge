// dsh-emacs-bridge — Vitest specs for the turn-activity fold.
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
  activityChangedMessage,
  activityRelevantEvent,
  activityThinkingSummary,
  activityToolDetail,
  assistantTurns,
  MAX_ACTIVITY_DETAIL_CHARS,
  MAX_ACTIVITY_ENTRIES_PER_TURN,
  MAX_ACTIVITY_THINKING_CHARS,
  MAX_ACTIVITY_TURNS,
  turnActivity,
  turnBoundaries,
  withActivityTurns,
  type ActivityEntry,
  type AssistantTurn,
  type SessionEventLike,
} from '../src/logic.ts'

// -- Fixtures ----------------------------------------------------------------

/** A unique event seq per event, assigned in append order. */
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

function turnStart(turn: number, time = turn * 1000): SessionEventLike {
  return { time, type: 'turn/start', data: { turn } }
}

function turnEnd(turn: number, time = turn * 1000 + 500, reason = 'completed'): SessionEventLike {
  return { time, type: 'turn/end', data: { turn, reason: { kind: reason } } }
}

function assistantMessage(
  turn: number,
  step: number,
  blocks: Array<{ type: string; text?: string }>,
  opts: { time?: number; surfaceOp?: unknown } = {},
): SessionEventLike {
  return {
    time: opts.time ?? turn * 1000 + step,
    type: 'assistant/message',
    data: { turn, step, message: { content: blocks, role: 'assistant' } },
    surfaceOp: opts.surfaceOp ?? 'append',
  }
}

function toolCall(
  turn: number,
  step: number,
  callId: string,
  name: string,
  args: unknown,
  opts: { time?: number } = {},
): SessionEventLike {
  return {
    time: opts.time ?? turn * 1000 + step,
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
  opts: { isError?: boolean; time?: number; surfaceOp?: unknown } = {},
): SessionEventLike {
  return {
    time: opts.time ?? turn * 1000 + step,
    type: 'tool/result',
    data: { turn, step, message: { source: { callId }, isError: opts.isError === true } },
    surfaceOp: opts.surfaceOp ?? 'append',
  }
}

/** A turn record shaped like `assistantTurns` output, for `withActivityTurns`. */
function record(turn: number, segments: AssistantTurn['segments'] = []): AssistantTurn {
  return { turn, startedAt: turn * 1000, segments }
}

function summaries(entries: readonly ActivityEntry[]): string[] {
  return entries.map(entry => entry.kind === 'thinking' ? entry.summary : entry.kind)
}

// -- The one-line detail folds ----------------------------------------------

describe('activityToolDetail', () => {
  it('prefers the first present detail key', () => {
    expect(activityToolDetail('read', JSON.stringify({ file_path: 'src/a.ts', content: 'x' })))
      .toBe('src/a.ts')
    expect(activityToolDetail('bash', JSON.stringify({ command: 'ls -la' }))).toBe('ls -la')
  })

  it('honours the key priority order', () => {
    expect(activityToolDetail('x', JSON.stringify({ path: 'p', command: 'c' }))).toBe('c')
  })

  it('collapses whitespace and newlines into one line', () => {
    expect(activityToolDetail('bash', JSON.stringify({ command: 'echo  a\n\tb' }))).toBe('echo a b')
  })

  it('caps at the grapheme bound with an ellipsis', () => {
    const long = 'a'.repeat(MAX_ACTIVITY_DETAIL_CHARS + 40)
    const detail = activityToolDetail('bash', JSON.stringify({ command: long }))
    expect(detail.length).toBe(MAX_ACTIVITY_DETAIL_CHARS)
    expect(detail.endsWith('\u2026')).toBe(true)
  })

  it('does not split a grapheme cluster at the cap', () => {
    const emoji = '\u{1F600}'
    const detail = activityToolDetail('bash', JSON.stringify({ command: emoji.repeat(MAX_ACTIVITY_DETAIL_CHARS + 5) }))
    expect(Array.from(detail)).toHaveLength(MAX_ACTIVITY_DETAIL_CHARS)
    expect(detail).toBe(`${emoji.repeat(MAX_ACTIVITY_DETAIL_CHARS - 1)}\u2026`)
  })

  it('joins an array of strings instead of falling through to the name', () => {
    expect(activityToolDetail('web_search', JSON.stringify({ queries: ['alpha', 'beta'] })))
      .toBe('alpha, beta')
  })

  it('reads the first question text of a questions value', () => {
    expect(activityToolDetail('ask_user_question', JSON.stringify({
      questions: [{ header: 'h', question: 'Which one?' }, { question: 'Second?' }],
    }))).toBe('Which one?')
  })

  it('falls back to the tool name for unusable arguments', () => {
    expect(activityToolDetail('read', 'not json')).toBe('read')
    expect(activityToolDetail('read', '"a string"')).toBe('read')
    expect(activityToolDetail('read', JSON.stringify({ unknown_key: 'x' }))).toBe('read')
    expect(activityToolDetail('read', JSON.stringify({ file_path: 42 }))).toBe('read')
  })

  it('normalizes the bare-name fallback too, like the harness', () => {
    expect(activityToolDetail('my   tool\nname', 'not json')).toBe('my tool name')
  })
})

describe('activityThinkingSummary', () => {
  it('takes the first line of the whole block, not a later paragraph', () => {
    expect(activityThinkingSummary('first thought\n\nsecond thought\n\n'))
      .toBe('first thought')
    expect(activityThinkingSummary('first line\nrest of the paragraph')).toBe('first line')
  })

  it('does not fall through to a later paragraph when the first line is empty', () => {
    expect(activityThinkingSummary('\n\nsecond thought')).toBe('')
  })

  it('strips double-asterisk markers', () => {
    expect(activityThinkingSummary('use **bold** here')).toBe('use bold here')
  })

  it('collapses whitespace within the first line', () => {
    expect(activityThinkingSummary('  one   two  \nthree')).toBe('one two')
  })

  it('caps at the grapheme bound', () => {
    const summary = activityThinkingSummary('x'.repeat(MAX_ACTIVITY_THINKING_CHARS + 20))
    expect(summary.length).toBe(MAX_ACTIVITY_THINKING_CHARS)
    expect(summary.endsWith('\u2026')).toBe(true)
  })

  it('returns the empty string for empty or whitespace-only text', () => {
    expect(activityThinkingSummary('')).toBe('')
    expect(activityThinkingSummary('  \n\n \t ')).toBe('')
    expect(activityThinkingSummary('\n\n\n')).toBe('')
  })
})

// -- The activity fold -------------------------------------------------------

describe('turnActivity', () => {
  it('folds calls, results, and thinking in log order, attributed by their own fields', () => {
    const l = log()
    l.add(turnStart(1))
    l.add(assistantMessage(1, 1, [
      { type: 'reasoning', text: 'The fold should pair call ids.' },
      { type: 'text', text: 'Reading the file.' },
    ], { time: 1001 }))
    l.add(toolCall(1, 1, 'c1', 'read', { file_path: 'src/logic.ts' }, { time: 1002 }))
    l.add(toolResult(1, 1, 'c1', { time: 1003 }))
    l.add(turnEnd(1))

    const activity = turnActivity(l.events)
    const turn = activity.get(1)
    expect(turn).toBeDefined()
    expect(turn!.entries.map(entry => entry.kind)).toEqual(['thinking', 'tool-call', 'tool-result'])
    expect(turn!.entries[0]).toMatchObject({ kind: 'thinking', turn: 1, step: 1, ord: 0 })
    expect(turn!.entries[1]).toMatchObject({
      kind: 'tool-call', turn: 1, step: 1, callId: 'c1', name: 'read', summary: 'src/logic.ts',
    })
    expect(turn!.entries[2]).toMatchObject({
      kind: 'tool-result', turn: 1, step: 1, callId: 'c1', name: 'read', isError: false,
    })
  })

  it('emits one entry per reasoning block with a distinct ordinal', () => {
    const l = log()
    l.add(assistantMessage(1, 1, [
      { type: 'reasoning', text: 'one' },
      { type: 'text', text: 'answer' },
      { type: 'reasoning', text: 'two' },
      { type: 'reasoning', text: '   ' },
    ]))
    const entries = turnActivity(l.events).get(1)!.entries
    expect(entries.map(entry => entry.ord)).toEqual([0, 1])
    expect(summaries(entries)).toEqual(['one', 'two'])
  })

  it('skips compaction replacement copies of surface events', () => {
    const l = log()
    l.add(assistantMessage(1, 1, [{ type: 'reasoning', text: 'original' }]))
    l.add(assistantMessage(1, 1, [{ type: 'reasoning', text: 'replayed' }],
      { surfaceOp: { op: 'replace', startSeq: 0, endSeq: 0 } }))
    l.add(toolResult(1, 1, 'c1', { surfaceOp: 'append' }))
    l.add(toolResult(1, 1, 'c1', { surfaceOp: { op: 'replace', startSeq: 2, endSeq: 2 } }))

    const entries = turnActivity(l.events).get(1)!.entries
    expect(summaries(entries)).toEqual(['original', 'tool-result'])
  })

  it('names an orphan result generically and pairs it from a prior call', () => {
    const l = log()
    l.add(toolCall(1, 1, 'c1', 'grep', { pattern: 'x' }))
    l.add(toolResult(1, 1, 'c1', { isError: true }))
    l.add(toolResult(1, 1, 'orphan'))

    const entries = turnActivity(l.events).get(1)!.entries
    expect(entries[1]).toMatchObject({ kind: 'tool-result', name: 'grep', isError: true })
    expect(entries[2]).toMatchObject({ kind: 'tool-result', name: 'tool', isError: false })
  })

  it('records the assistant-message seqs as surface-visibility evidence', () => {
    const l = log()
    l.add(assistantMessage(1, 1, [{ type: 'text', text: 'no reasoning here' }]))
    l.add(toolCall(1, 1, 'c1', 'read', { path: 'a' }))
    const activity = turnActivity(l.events).get(1)!
    expect(activity.entries).toHaveLength(1)
    expect(activity.messageSeqs).toEqual([0])
  })

  it('drops malformed events', () => {
    const l = log()
    l.add({ time: 1, type: 'tool/call', data: { turn: 1, callId: 'c1', name: 'read' } })
    l.add({ time: 2, type: 'tool/call', data: { turn: 1, step: 1, callId: 'c2', arguments: 'x' } })
    l.add({ time: 3, type: 'tool/result', data: { turn: 1, step: 1 }, surfaceOp: 'append' })
    l.add({ time: 4, type: 'assistant/message', data: { turn: 1, step: 1 }, surfaceOp: 'append' })
    expect(turnActivity(l.events).size).toBe(0)
  })

  it('caps one turn at MAX_ACTIVITY_ENTRIES_PER_TURN, keeping the newest', () => {
    const l = log()
    for (let index = 0; index < MAX_ACTIVITY_ENTRIES_PER_TURN + 5; index += 1) {
      l.add(toolCall(1, 1, `c${index}`, 'read', { path: `p${index}` }))
    }
    const turn = turnActivity(l.events).get(1)!
    expect(turn.entries).toHaveLength(MAX_ACTIVITY_ENTRIES_PER_TURN)
    // The oldest five slid out, so a live turn's newest activity is kept.
    expect(turn.entries[0]).toMatchObject({ callId: 'c5' })
    expect(turn.entries[MAX_ACTIVITY_ENTRIES_PER_TURN - 1]).toMatchObject({
      callId: `c${MAX_ACTIVITY_ENTRIES_PER_TURN + 4}`,
    })
  })

  it('retains only the newest MAX_ACTIVITY_TURNS turns, silently', () => {
    const l = log()
    for (let turn = 1; turn <= MAX_ACTIVITY_TURNS + 3; turn += 1) {
      l.add(toolCall(turn, 1, `c${turn}`, 'read', { path: `p${turn}` }))
    }
    const activity = turnActivity(l.events)
    expect(activity.size).toBe(MAX_ACTIVITY_TURNS)
    expect(activity.has(1)).toBe(false)
    expect(activity.has(MAX_ACTIVITY_TURNS + 3)).toBe(true)
  })
})

// -- Activity-only turn records ---------------------------------------------

describe('withActivityTurns', () => {
  it('synthesizes a record for an activity-only turn that is surface-visible', () => {
    const l = log()
    l.add(turnStart(7, 7000))
    l.add(assistantMessage(7, 1, [{ type: 'reasoning', text: 'thinking' }]))
    l.add(toolCall(7, 1, 'c1', 'read', { path: 'a' }))
    l.add(turnEnd(7, 7500))

    const activity = turnActivity(l.events)
    const boundaries = turnBoundaries(l.events)
    // The turn has no text segment, so `records` is empty; every logged seq
    // is on the surface (nothing shadowed), and the reasoning message's seq
    // is evidence enough for the synthetic record to appear, boundaries
    // included.
    const surface = new Set(l.events.map(event => event.seq!))
    const merged = withActivityTurns([], activity, boundaries, surface)
    expect(merged).toHaveLength(1)
    expect(merged[0]).toMatchObject({ turn: 7, startedAt: 7000, endedAt: 7500, reason: 'completed', segments: [] })
    expect(merged[0]!.endSeq).toBe(3)
  })

  it('does not synthesize for a compaction-shadowed turn', () => {
    const l = log()
    l.add(turnStart(7, 7000))
    l.add(assistantMessage(7, 1, [{ type: 'reasoning', text: 'thinking' }]))
    l.add(toolCall(7, 1, 'c1', 'read', { path: 'a' }))
    l.add(toolResult(7, 1, 'c1'))

    const activity = turnActivity(l.events)
    const boundaries = turnBoundaries(l.events)
    const merged = withActivityTurns([], activity, boundaries, new Set([99]))
    expect(merged).toEqual([])
  })

  it('keeps a text-bearing record and inserts synthetics in ascending order', () => {
    const l = log()
    l.add(turnStart(2, 2000))
    l.add(assistantMessage(2, 1, [{ type: 'reasoning', text: 'two' }]))
    l.add(turnStart(1, 1000))
    l.add(assistantMessage(1, 1, [{ type: 'reasoning', text: 'one' }]))
    // Turn 3 has text, so it is already a record.
    const textRecord = record(3, [{ text: 'reply', time: 3001, step: 1 }])

    const activity = turnActivity(l.events)
    const boundaries = turnBoundaries(l.events)
    const surface = new Set(l.events.map(event => event.seq!))
    const merged = withActivityTurns([textRecord], activity, boundaries, surface)
    expect(merged.map(item => item.turn)).toEqual([1, 2, 3])
    expect(merged[2]).toBe(textRecord)
  })

  it('ignores a turn whose activity is empty', () => {
    const l = log()
    l.add(assistantMessage(1, 1, [{ type: 'text', text: 'text only' }]))
    const activity = turnActivity(l.events)
    const merged = withActivityTurns([], activity, turnBoundaries(l.events), new Set([0]))
    expect(merged).toEqual([])
  })
})

// -- Boundaries and the SSE predicate ---------------------------------------

describe('turnBoundaries', () => {
  it('keeps the first start and the last end, with the end seq as the anchor', () => {
    const l = log()
    l.add(turnStart(1, 100))
    l.add(turnStart(1, 200))
    l.add(turnEnd(1, 300, 'aborted'))
    l.add(turnEnd(1, 400, 'completed'))
    const { starts, ends } = turnBoundaries(l.events)
    expect(starts.get(1)).toBe(100)
    expect(ends.get(1)).toEqual({ time: 400, reason: 'completed', seq: 3 })
  })

  it('falls back to the array position for an end event with no seq', () => {
    const { ends } = turnBoundaries([{ time: 5, type: 'turn/end', data: { turn: 2 } }])
    expect(ends.get(2)).toEqual({ time: 5, seq: 0 })
  })
})

describe('activityRelevantEvent', () => {
  it('accepts tool calls, append results, and reasoning messages', () => {
    expect(activityRelevantEvent(toolCall(1, 1, 'c1', 'read', { path: 'a' }))).toBe(true)
    expect(activityRelevantEvent(toolResult(1, 1, 'c1'))).toBe(true)
    expect(activityRelevantEvent(assistantMessage(1, 1, [{ type: 'reasoning', text: 'x' }]))).toBe(true)
  })

  it('rejects replacement copies, text-only messages, and empty reasoning', () => {
    expect(activityRelevantEvent(toolResult(1, 1, 'c1', { surfaceOp: 'replace' }))).toBe(false)
    expect(activityRelevantEvent(assistantMessage(1, 1, [{ type: 'reasoning', text: 'x' }],
      { surfaceOp: { op: 'replace', startSeq: 0, endSeq: 0 } }))).toBe(false)
    expect(activityRelevantEvent(assistantMessage(1, 1, [{ type: 'text', text: 'reply' }]))).toBe(false)
    expect(activityRelevantEvent(assistantMessage(1, 1, [{ type: 'reasoning', text: '  ' }]))).toBe(false)
    expect(activityRelevantEvent(turnStart(1))).toBe(false)
    expect(activityRelevantEvent(turnEnd(1))).toBe(false)
  })
})

describe('activityChangedMessage', () => {
  it('renders a data frame with and without the informational turn', () => {
    expect(activityChangedMessage('s1')).toBe('data: {"kind":"activity-changed","sessionId":"s1"}\n\n')
    expect(activityChangedMessage('s1', 4))
      .toBe('data: {"kind":"activity-changed","sessionId":"s1","turn":4}\n\n')
  })
})

// The extracted boundary fold must not change assistantTurns' output.
describe('assistantTurns (after the boundary extraction)', () => {
  it('still carries the boundary facts', () => {
    const l = log()
    l.add(turnStart(1, 100))
    l.add(assistantMessage(1, 1, [{ type: 'text', text: 'hello' }], { time: 150 }))
    l.add(turnEnd(1, 200, 'aborted'))
    const turns = assistantTurns({ nodes: [1], events: l.events })
    expect(turns).toHaveLength(1)
    expect(turns[0]).toMatchObject({ turn: 1, startedAt: 100, endedAt: 200, reason: 'aborted' })
    expect(turns[0]!.endSeq).toBe(2)
    expect(turns[0]!.segments).toEqual([{ text: 'hello', time: 150, step: 1 }])
  })
})
