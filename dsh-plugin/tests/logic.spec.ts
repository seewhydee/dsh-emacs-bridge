// dsh-emacs-bridge — Vitest specs for the pure bridge logic.
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
  answerMatchesQuestions,
  approvalDecisionValid,
  approvalMessage,
  approvalResolvedMessage,
  askUserMessage,
  askUserResolvedMessage,
  assistantMessageHasText,
  assistantMessageText,
  assistantTextForMessage,
  assistantTurns,
  cachedTitleValue,
  changedFiles,
  classifySessionId,
  contextMessage,
  contextUsedTokens,
  currentModelSelection,
  draftMessage,
  goalActivationChangedMessage,
  goalChangedMessage,
  goalErrorCode,
  goalErrorStatus,
  goalSetAction,
  hostnameOf,
  isCompletedTurnAnchor,
  isLoopbackAddress,
  isLoopbackHostname,
  isLoopbackOrigin,
  isQuestionCancelRejection,
  isSubagentChild,
  latestAssistantText,
  manifestVersion,
  mergeSessionRows,
  outboxMessage,
  outboxSessionId,
  parseBearerAuthorization,
  parseSendMode,
  planChangedMessage,
  queueCounts,
  repliesChangedMessage,
  resolveTargetId,
  rpcArgsPayload,
  rpcRequestFrame,
  rpcUnwrapResponse,
  sessionPreset,
  sessionTitle,
  sessionsChangedMessage,
  tokenRequestsSameOrigin,
  tokensEqual,
  turnCompleteMessage,
  turnStartMessage,
  turnsSince,
  userPrompts,
  workspaceRefsBySession,
  workspaceTitleConflict,
  attachmentErrorHttpStatus,
  imageInputUnsupported,
  KeyedSerial,
  MAX_ATTACHMENTS,
  MAX_APPROVAL_DETAIL_CHARS,
  MAX_CHANGED_FILES,
  MAX_CHANGED_FILES_PER_TURN,
  parseAttachmentRequests,
  sniffImageMediaType,
  toolCallForId,
  truncateApprovalArguments,
  type LiveSessionLike,
  type AssistantTurn,
  type MessageLike,
  type SessionEventLike,
  type SessionHeaderLike,
  type SessionTurnLogLike,
  type WorkspaceLike,
} from '../src/logic.ts'

function liveSession(id: string, opts: { cwd?: string; createdAt?: number; eventTimes?: number[]; events?: SessionEventLike[]; running?: boolean } = {}): LiveSessionLike {
  return {
    id,
    header: { cwd: opts.cwd, createdAt: opts.createdAt ?? 0 },
    events: opts.events ?? (opts.eventTimes ?? []).map(time => ({ time })),
    running: opts.running ?? false,
  }
}

function header(id: string, opts: { cwd?: string; createdAt?: number; origin?: string; title?: string | null } = {}): SessionHeaderLike {
  return { id, cwd: opts.cwd, createdAt: opts.createdAt ?? 0, origin: opts.origin, title: opts.title }
}

function workspace(id: string, title: string, sessionIds: readonly string[]): WorkspaceLike {
  return { id, title, path: `/${id}`, sessionIds }
}

function message(
  role: string,
  blocks: Array<{ type: string; text?: string }>,
  source?: { kind?: string },
): MessageLike {
  return source === undefined ? { role, content: blocks } : { role, content: blocks, source }
}

function titleEvent(title: string): SessionEventLike {
  return { time: 1, type: 'session/title', data: { title } }
}

describe('latestAssistantText', () => {
  it('returns the empty string when there are no messages', () => {
    expect(latestAssistantText([])).toBe('')
  })

  it('ignores non-assistant messages', () => {
    expect(latestAssistantText([message('user', [{ type: 'text', text: 'hello' }])])).toBe('')
  })

  it('returns the newest assistant text', () => {
    const messages = [
      message('assistant', [{ type: 'text', text: 'first' }]),
      message('assistant', [{ type: 'text', text: 'second' }]),
    ]
    expect(latestAssistantText(messages)).toBe('second')
  })

  it('joins multiple text blocks in one assistant message', () => {
    const messages = [
      message('assistant', [{ type: 'text', text: 'a' }, { type: 'text', text: 'b' }]),
    ]
    expect(latestAssistantText(messages)).toBe('ab')
  })

  it('falls through tool-call-only assistant turns to the previous text', () => {
    const messages = [
      message('assistant', [{ type: 'text', text: 'real answer' }]),
      message('assistant', [{ type: 'tool-call' }]),
    ]
    expect(latestAssistantText(messages)).toBe('real answer')
  })
})

describe('userPrompts', () => {
  it('returns user text blocks in order, skipping other roles', () => {
    const messages = [
      message('user', [{ type: 'text', text: 'first' }]),
      message('assistant', [{ type: 'text', text: 'reply' }]),
      message('user', [{ type: 'text', text: 'second' }]),
    ]
    expect(userPrompts(messages)).toEqual(['first', 'second'])
  })

  it('joins multiple text blocks with newlines and drops whitespace-only prompts', () => {
    const messages = [
      message('user', [{ type: 'text', text: 'a' }, { type: 'text', text: 'b' }]),
      message('user', [{ type: 'text', text: '   ' }]),
    ]
    expect(userPrompts(messages)).toEqual(['a\nb'])
  })

  it('returns an empty list with no messages', () => {
    expect(userPrompts([])).toEqual([])
  })

  it('excludes injected user-role context, which is not a prompt', () => {
    const messages = [
      message('user', [{ type: 'text', text: 'real prompt' }], { kind: 'user' }),
      message('user', [{ type: 'text', text: '<system-reminder>' }], { kind: 'agent-instructions' }),
      message('user', [{ type: 'text', text: 'background job bash-11 finished' }], { kind: 'plugin' }),
      message('user', [{ type: 'text', text: 'tool output' }], { kind: 'tool' }),
    ]
    expect(userPrompts(messages)).toEqual(['real prompt'])
  })

  it('keeps a user-role message that carries no source', () => {
    expect(userPrompts([message('user', [{ type: 'text', text: 'legacy' }])])).toEqual(['legacy'])
  })
})

describe('assistantMessageHasText', () => {
  it('is true only for a message with a non-whitespace text block', () => {
    expect(assistantMessageHasText({ content: [{ type: 'text', text: 'hello' }] })).toBe(true)
    expect(assistantMessageHasText({ content: [{ type: 'text', text: '   ' }] })).toBe(false)
    expect(assistantMessageHasText({ content: [{ type: 'tool-call' }] })).toBe(false)
    expect(assistantMessageHasText({ content: [] })).toBe(false)
    expect(assistantMessageHasText(undefined)).toBe(false)
  })
})

describe('assistantMessageText', () => {
  it('joins text blocks with no separator and skips non-text blocks', () => {
    expect(assistantMessageText([{ type: 'text', text: 'a' }, { type: 'text', text: 'b' }])).toBe('ab')
    expect(assistantMessageText([{ type: 'tool-call' }, { type: 'text', text: 'x' }])).toBe('x')
  })

  it('returns the empty string for an undefined, empty, or text-less content', () => {
    expect(assistantMessageText(undefined)).toBe('')
    expect(assistantMessageText([])).toBe('')
    expect(assistantMessageText([{ type: 'tool-call' }])).toBe('')
  })
})

// -- assistantTurns fixtures -------------------------------------------------
// The turn fold consumes the session's surface + log as (seq-indexed) event
// tuples.  These builders mirror the harness shapes the wiring passes in.

function turnStart(turn: number, time: number): SessionEventLike {
  return { time, type: 'turn/start', data: { turn } }
}

function turnEnd(turn: number, time: number, reason = 'completed'): SessionEventLike {
  return { time, type: 'turn/end', data: { turn, reason: { kind: reason } } }
}

function userMessage(time: number): SessionEventLike {
  return {
    time,
    type: 'user/message',
    data: { role: 'user', content: [{ type: 'text', text: 'prompt' }] },
  }
}

function assistantMessage(
  turn: number,
  step: number,
  time: number,
  content: Array<{ type: string; text?: string }>,
  opts: { interrupted?: boolean } = {},
): SessionEventLike {
  return {
    time,
    type: 'assistant/message',
    data: { turn, step, message: { content }, ...(opts.interrupted ? { interrupted: true } : {}) },
  }
}

function toolResult(time: number): SessionEventLike {
  return {
    time,
    type: 'tool/result',
    data: { turn: 0, step: 0, message: { role: 'tool', content: [{ type: 'text', text: 'ok' }] } },
  }
}

const SURFACE_TYPES = new Set(['user/message', 'assistant/message', 'tool/result'])

function turnLog(events: readonly SessionEventLike[]): SessionTurnLogLike {
  // Nodes are the seqs of message-producing events, index-aligned with events
  // (the harness log invariant: events[seq] is the event with that seq). Real
  // logs carry `seq` on every event; stamp it here so the fold's primary path
  // (not just the index fallback) is exercised.
  const seqd = events.map((event, index) => ({ ...event, seq: index }))
  return { events: seqd, nodes: seqd.flatMap((e, i) => (e.type && SURFACE_TYPES.has(e.type) ? [i] : [])) }
}

function text(...parts: string[]): Array<{ type: string; text?: string }> {
  return parts.map(part => ({ type: 'text', text: part }))
}

describe('assistantTurns', () => {
  it('groups a multi-step turn and carries its boundary facts', () => {
    const log = turnLog([
      turnStart(7, 1000),
      userMessage(1010),
      assistantMessage(7, 1, 1100, text('Let me look at the files.')),
      toolResult(1150),
      assistantMessage(7, 2, 1300, text('I see the change; applying it.')),
      toolResult(1350),
      assistantMessage(7, 3, 2000, text('Done.')),
      turnEnd(7, 2500),
    ])
    expect(assistantTurns(log)).toEqual([
      {
        turn: 7,
        startedAt: 1000,
        endedAt: 2500,
        reason: 'completed',
        endSeq: 7,
        segments: [
          { text: 'Let me look at the files.', time: 1100, step: 1 },
          { text: 'I see the change; applying it.', time: 1300, step: 2 },
          { text: 'Done.', time: 2000, step: 3 },
        ],
      },
    ])
  })

  it('returns several turns oldest first, mirroring surface order', () => {
    const log = turnLog([
      turnStart(1, 1000), userMessage(1010),
      assistantMessage(1, 1, 1100, text('first answer')),
      turnEnd(1, 1500),
      turnStart(2, 2000), userMessage(2010),
      assistantMessage(2, 1, 2100, text('second answer')),
      turnEnd(2, 2500),
    ])
    expect(assistantTurns(log).map(turn => turn.turn)).toEqual([1, 2])
    expect(assistantTurns(log)[1]!.segments[0]!.text).toBe('second answer')
  })

  it('skips assistant messages without text (tool-call-only or empty steps)', () => {
    const log = turnLog([
      turnStart(3, 1000), userMessage(1010),
      assistantMessage(3, 1, 1100, text('   ')), // whitespace-only: not a reply
      assistantMessage(3, 2, 1200, [{ type: 'tool-call' }]), // no text block
      assistantMessage(3, 3, 1300, []), // empty content
      assistantMessage(3, 4, 1400, text('real answer')),
      turnEnd(3, 1500),
    ])
    expect(assistantTurns(log)).toEqual([
      {
        turn: 3,
        startedAt: 1000,
        endedAt: 1500,
        reason: 'completed',
        endSeq: 6,
        segments: [{ text: 'real answer', time: 1400, step: 4 }],
      },
    ])
  })

  it('keeps non-contiguous turn numbers: an empty turn consumes its number', () => {
    // Turn 9 produces no text (rejected/empty input) — turn 10's segments must
    // be reported under 10, never shifted to 9.
    const log = turnLog([
      turnStart(9, 1000), userMessage(1010), turnEnd(9, 1100),
      turnStart(10, 2000), userMessage(2010),
      assistantMessage(10, 1, 2100, text('recovery')),
      turnEnd(10, 2500),
    ])
    expect(assistantTurns(log).map(turn => turn.turn)).toEqual([10])
    expect(assistantTurns(log)[0]!.startedAt).toBe(2000)
  })

  it('reports an open turn without endedAt or reason', () => {
    const log = turnLog([
      turnStart(5, 1000), userMessage(1010),
      assistantMessage(5, 1, 1100, text('still working')),
      assistantMessage(5, 2, 1300, text('another segment')),
      // No turn/end: the turn is still running.
    ])
    const turns = assistantTurns(log)
    expect(turns).toHaveLength(1)
    expect(turns[0]).toMatchObject({ turn: 5, startedAt: 1000 })
    expect(turns[0]!.endedAt).toBeUndefined()
    expect(turns[0]!.reason).toBeUndefined()
    // An open turn has no fork anchor: the key is absent, not undefined-valued.
    expect(Object.hasOwn(turns[0]!, 'endSeq')).toBe(false)
    expect(turns[0]!.segments).toHaveLength(2)
  })

  it('carries the turn/end seq as endSeq (the fork anchor)', () => {
    const log = turnLog([
      turnStart(1, 1000), userMessage(1010),
      assistantMessage(1, 1, 1100, text('done')),
      turnEnd(1, 1500),
    ])
    expect(assistantTurns(log)[0]!.endSeq).toBe(3)
  })

  it('falls back to the log index when a turn/end event carries no seq', () => {
    // Structural fixtures need not stamp `seq`; the fold then uses the event's
    // position, which the harness log invariant makes equal to the seq.
    const events: SessionEventLike[] = [
      turnStart(1, 1000),
      userMessage(1010),
      assistantMessage(1, 1, 1100, text('done')),
      turnEnd(1, 1500),
    ]
    const log: SessionTurnLogLike = { events, nodes: [1, 2] }
    expect(assistantTurns(log)[0]!.endSeq).toBe(3)
  })

  it('marks an interrupted (aborted) turn with its reason and partial segment', () => {
    const log = turnLog([
      turnStart(6, 1000), userMessage(1010),
      assistantMessage(6, 1, 1100, text('partial reply'), { interrupted: true }),
      turnEnd(6, 1200, 'aborted'),
    ])
    expect(assistantTurns(log)).toEqual([
      {
        turn: 6,
        startedAt: 1000,
        endedAt: 1200,
        reason: 'aborted',
        endSeq: 3,
        segments: [{ text: 'partial reply', time: 1100, step: 1 }],
      },
    ])
  })

  it('falls back to the first segment time when the turn/start event is absent', () => {
    const log = turnLog([
      userMessage(1010),
      assistantMessage(4, 1, 1100, text('orphan')),
    ])
    expect(assistantTurns(log)[0]!.startedAt).toBe(1100)
  })

  it('hides compaction-shadowed turns, exactly like the derived reply list', () => {
    const events = [
      turnStart(1, 1000), userMessage(1010),
      assistantMessage(1, 1, 1100, text('shadowed old turn')),
      turnEnd(1, 1500),
      turnStart(2, 2000), userMessage(2010),
      assistantMessage(2, 1, 2100, text('the compacted turn')),
      turnEnd(2, 2500),
    ]
    // A replace wiped turn 1's message-producing nodes from the surface; the
    // boundary events remain in the log but no node references turn 1's
    // message any more.
    const log: SessionTurnLogLike = {
      events,
      nodes: [6], // only the seq of turn 2's assistant message survives
    }
    expect(assistantTurns(log).map(turn => turn.turn)).toEqual([2])
  })

  it('tolerates a node seq beyond the log (defensive) and never mis-indexes', () => {
    const events = [
      turnStart(1, 1000),
      assistantMessage(1, 1, 1100, text('kept')),
      turnEnd(1, 1500),
    ]
    const log: SessionTurnLogLike = { events, nodes: [1, 99] }
    expect(assistantTurns(log).map(turn => turn.turn)).toEqual([1])
  })

  it('keeps the first turn/start time when a turn start is logged twice', () => {
    const log = turnLog([
      turnStart(1, 1000),
      turnStart(1, 1050), // duplicate: first wins
      assistantMessage(1, 1, 1100, text('done')),
    ])
    expect(assistantTurns(log)[0]!.startedAt).toBe(1000)
  })

  it('records a turn/end with a non-string reason kind without a reason', () => {
    const log = turnLog([
      turnStart(1, 1000), userMessage(1010),
      assistantMessage(1, 1, 1100, text('done')),
      { time: 1500, type: 'turn/end', data: { turn: 1, reason: { kind: 7 } } },
    ])
    const turn = assistantTurns(log)[0]!
    expect(turn.endedAt).toBe(1500)
    expect(turn.reason).toBeUndefined()
    expect(turn.endSeq).toBe(3)
  })
})

// -- turnsSince fixtures ----------------------------------------------------
// Newest-first visible turn lists as `/turns` serves them (turn numbers
// strictly grow over time, so newest-first is descending by turn number, but
// the numbers are NOT contiguous).

function openTurn(turn: number, startedAt = turn * 1000): AssistantTurn {
  return { turn, startedAt, segments: [{ text: `turn ${turn}`, time: startedAt + 100, step: 1 }] }
}

describe('turnsSince', () => {
  // Newest first: 40 (open), 30 completed, 20 completed.  Turn 35 was empty
  // (consumed a number, no segments) and does not appear.
  const turns = [
    openTurn(40, 40000),
    { turn: 30, startedAt: 30000, endedAt: 30100, reason: 'completed',
      segments: [{ text: 'a', time: 30010, step: 1 }, { text: 'b', time: 30050, step: 2 }] },
    openTurn(20, 20000),
  ] satisfies AssistantTurn[]

  it('serves the full list when the request is absent or malformed', () => {
    expect(turnsSince(turns, 7, {})).toEqual({ incremental: false, turns })
    expect(turnsSince(turns, 7, { since: '30' })).toEqual({ incremental: false, turns })
    expect(turnsSince(turns, 7, { epoch: '7' })).toEqual({ incremental: false, turns })
    expect(turnsSince(turns, 7, { since: '', epoch: '7' })).toEqual({ incremental: false, turns })
    expect(turnsSince(turns, 7, { since: 'abc', epoch: '7' })).toEqual({ incremental: false, turns })
    expect(turnsSince(turns, 7, { since: '-1', epoch: '7' })).toEqual({ incremental: false, turns })
    expect(turnsSince(turns, 7, { since: '1.5', epoch: '7' })).toEqual({ incremental: false, turns })
    expect(turnsSince(turns, 7, { since: '20', epoch: 'x' })).toEqual({ incremental: false, turns })
    expect(turnsSince(turns, 7, { since: '20', epoch: '-1' })).toEqual({ incremental: false, turns })
    expect(turnsSince(turns, 7, { since: '20', epoch: '' })).toEqual({ incremental: false, turns })
    expect(turnsSince(turns, 7, { since: '99999999999999999999', epoch: '7' }))
      .toEqual({ incremental: false, turns })
  })

  it('serves the full list when the client epoch is stale (a replace happened)', () => {
    expect(turnsSince(turns, 7, { since: '20', epoch: '6' })).toEqual({ incremental: false, turns })
  })

  it('serves the full list when `since` names no visible turn', () => {
    // 35 was consumed by an empty turn: not visible, so no incremental answer.
    expect(turnsSince(turns, 7, { since: '35', epoch: '7' })).toEqual({ incremental: false, turns })
    // A since above the newest visible turn is likewise unknown.
    expect(turnsSince(turns, 7, { since: '41', epoch: '7' })).toEqual({ incremental: false, turns })
  })

  it('serves the full list for an empty (fully compacted) session', () => {
    // The known-empty shape: no params, and a `since` that can name no
    // visible turn, both fall back to the full (empty) list.
    expect(turnsSince([], 1, {})).toEqual({ incremental: false, turns: [] })
    expect(turnsSince([], 1, { since: '5', epoch: '1' })).toEqual({ incremental: false, turns: [] })
  })

  it('is inclusive at the boundary turn and includes every newer turn', () => {
    // since = newest: just the boundary turn (resent in full — it is the one
    // that grows mid-turn).
    expect(turnsSince(turns, 7, { since: '40', epoch: '7' })).toEqual({
      incremental: true,
      turns: [turns[0]!],
    })
    // since = a middle turn: the boundary plus every newer visible turn.
    expect(turnsSince(turns, 7, { since: '30', epoch: '7' })).toEqual({
      incremental: true,
      turns: [turns[0]!, turns[1]!],
    })
    expect(turnsSince(turns, 7, { since: '20', epoch: '7' })).toEqual({
      incremental: true,
      turns,
    })
  })
})

describe('isSubagentChild', () => {
  it('treats subagent origin as a child', () => {
    expect(isSubagentChild('subagent', false)).toBe(true)
  })

  it('treats parent ownership as a child regardless of origin', () => {
    expect(isSubagentChild(undefined, true)).toBe(true)
  })

  it('treats a top-level, unowned session as targetable', () => {
    expect(isSubagentChild(undefined, false)).toBe(false)
  })
})

describe('mergeSessionRows', () => {
  it('marks live sessions and computes lastActive from the newest event', () => {
    const rows = mergeSessionRows(
      [liveSession('a', { createdAt: 10, eventTimes: [20, 30] })],
      [],
    )
    expect(rows).toEqual([{ id: 'a', title: null, cwd: null, live: true, running: false, lastActive: 30, createdAt: 10 }])
  })

  it('passes through the live running flag', () => {
    const rows = mergeSessionRows([liveSession('a', { createdAt: 10, running: true })], [])
    expect(rows[0]!.running).toBe(true)
  })

  it('folds the live title from the latest session/title event', () => {
    const rows = mergeSessionRows(
      [liveSession('a', { createdAt: 10, events: [titleEvent('first'), titleEvent('latest')] })],
      [],
    )
    expect(rows[0]!.title).toBe('latest')
  })

  it('falls back to createdAt when a live session has no events', () => {
    const rows = mergeSessionRows([liveSession('a', { createdAt: 10 })], [])
    expect(rows[0]!.lastActive).toBe(10)
  })

  it('marks persisted sessions as not running and skips subagent headers', () => {
    const rows = mergeSessionRows(
      [],
      [header('a', { createdAt: 1 }), header('sub', { origin: 'subagent' })],
    )
    expect(rows).toEqual([{ id: 'a', title: null, cwd: null, live: false, running: false, createdAt: 1 }])
  })

  it('passes through a persisted title', () => {
    const rows = mergeSessionRows([], [header('a', { createdAt: 1, title: 'saved title' })])
    expect(rows[0]!.title).toBe('saved title')
  })

  it('dedupes persisted sessions that are already live', () => {
    const rows = mergeSessionRows([liveSession('a', { createdAt: 1 })], [header('a', { createdAt: 1 })])
    expect(rows).toHaveLength(1)
    expect(rows[0]!.live).toBe(true)
  })
})

describe('sessionTitle', () => {
  it('returns null when there are no events', () => {
    expect(sessionTitle([])).toBeNull()
  })

  it('returns null when no session/title event exists', () => {
    expect(sessionTitle([{ time: 1, type: 'user/message', data: {} }])).toBeNull()
  })

  it('returns the latest title (last-wins)', () => {
    expect(sessionTitle([titleEvent('old'), titleEvent('new')])).toBe('new')
  })

  it('ignores non-title events interleaved with titles', () => {
    expect(sessionTitle([
      titleEvent('a'),
      { time: 2, type: 'user/message', data: {} },
      titleEvent('b'),
    ])).toBe('b')
  })

  it('returns null for a malformed or empty title payload', () => {
    expect(sessionTitle([{ time: 1, type: 'session/title' }])).toBeNull()
    expect(sessionTitle([{ time: 1, type: 'session/title', data: null }])).toBeNull()
    expect(sessionTitle([{ time: 1, type: 'session/title', data: { title: '' } }])).toBeNull()
    expect(sessionTitle([{ time: 1, type: 'session/title', data: { title: 42 } }])).toBeNull()
  })
})

describe('cachedTitleValue', () => {
  it('serves a non-empty cached title', () => {
    expect(cachedTitleValue({ values: { title: 'Cached title' } })).toBe('Cached title')
  })

  it('does not serve a missing block (the caller folds the log)', () => {
    expect(cachedTitleValue(undefined)).toBeUndefined()
  })

  it('does not serve a null or empty title, so a lagging checkpoint folds', () => {
    expect(cachedTitleValue({ values: { title: null } })).toBeUndefined()
    expect(cachedTitleValue({ values: { title: '' } })).toBeUndefined()
  })

  it('does not serve a non-string or absent title value', () => {
    expect(cachedTitleValue({ values: { title: 42 } })).toBeUndefined()
    expect(cachedTitleValue({ values: {} })).toBeUndefined()
    expect(cachedTitleValue({})).toBeUndefined()
  })
})

describe('workspaceRefsBySession', () => {
  it('maps session ids to their workspace refs (id + title)', () => {
    const map = workspaceRefsBySession([
      workspace('w1', 'alpha', ['s1', 's2']),
      workspace('w2', 'beta', ['s3']),
    ])
    expect(map.get('s1')).toEqual({ id: 'w1', title: 'alpha' })
    expect(map.get('s2')).toEqual({ id: 'w1', title: 'alpha' })
    expect(map.get('s3')).toEqual({ id: 'w2', title: 'beta' })
    expect(map.get('s4')).toBeUndefined()
  })

  it('returns an empty map for no workspaces', () => {
    expect(workspaceRefsBySession([]).size).toBe(0)
  })

  it('keeps the last workspace ref when a session id overlaps (defensive)', () => {
    const map = workspaceRefsBySession([
      workspace('w1', 'alpha', ['s1']),
      workspace('w2', 'beta', ['s1']),
    ])
    expect(map.get('s1')).toEqual({ id: 'w2', title: 'beta' })
  })
})

describe('classifySessionId', () => {
  it('classifies live, cold, and unknown ids', () => {
    expect(classifySessionId('a', new Set(['a']), new Set(['b']))).toBe('live')
    expect(classifySessionId('b', new Set(['a']), new Set(['b']))).toBe('cold')
    expect(classifySessionId('c', new Set(['a']), new Set(['b']))).toBe('unknown')
  })

  it('treats a persisted id in both tiers as live (live wins)', () => {
    expect(classifySessionId('a', new Set(['a']), new Set(['a']))).toBe('live')
  })
})

describe('workspaceTitleConflict', () => {
  it('flags a title held by another workspace', () => {
    const workspaces = [workspace('w1', 'alpha', []), workspace('w2', 'beta', [])]
    expect(workspaceTitleConflict('alpha', workspaces)).toBe(true)
  })

  it('does not flag the same-title rename of the excluded workspace', () => {
    const workspaces = [workspace('w1', 'alpha', []), workspace('w2', 'beta', [])]
    expect(workspaceTitleConflict('alpha', workspaces, 'w1')).toBe(false)
  })

  it('does not flag a title no workspace holds', () => {
    const workspaces = [workspace('w1', 'alpha', []), workspace('w2', 'beta', [])]
    expect(workspaceTitleConflict('gamma', workspaces)).toBe(false)
  })

  it('returns false for an empty roster', () => {
    expect(workspaceTitleConflict('alpha', [])).toBe(false)
  })
})

describe('resolveTargetId', () => {
  const live = [liveSession('a', { createdAt: 10, eventTimes: [40] }), liveSession('b', { createdAt: 20, eventTimes: [50] })]
  const persisted = [header('c', { createdAt: 30 }), header('d', { createdAt: 25, origin: 'subagent' })]

  it('honors an explicit live id', () => {
    const result = resolveTargetId('a', live, [], () => true)
    expect(result).toEqual({ kind: 'target', id: 'a' })
  })

  it('rejects an explicit id that is neither live nor persisted with 404', () => {
    const result = resolveTargetId('nope', live, persisted, () => true)
    expect(result).toEqual({ kind: 'error', status: 404, message: 'session nope is not live' })
  })

  it('rejects a live id with no agent with 409', () => {
    const result = resolveTargetId('a', live, persisted, id => id !== 'a')
    expect(result).toEqual({ kind: 'error', status: 409, message: 'session a has no live agent' })
  })

  it('returns a cold result for an explicit persisted id', () => {
    const result = resolveTargetId('c', live, persisted, () => true)
    expect(result).toEqual({ kind: 'cold', id: 'c' })
  })

  it('treats an explicit subagent-origin persisted id as cold (resume guard rejects it)', () => {
    const result = resolveTargetId('d', live, persisted, () => true)
    expect(result).toEqual({ kind: 'cold', id: 'd' })
  })

  it('picks the most recently active live session with no explicit id', () => {
    const result = resolveTargetId(undefined, live, persisted, () => true)
    expect(result).toEqual({ kind: 'target', id: 'b' })
  })

  it('skips sessions without a live agent when picking last-active', () => {
    const result = resolveTargetId(undefined, live, persisted, id => id !== 'b')
    expect(result).toEqual({ kind: 'target', id: 'a' })
  })

  it('falls back to the most recent cold session when nothing is live', () => {
    const liveNoAgent = [liveSession('b', { createdAt: 20, eventTimes: [50] })]
    const result = resolveTargetId(undefined, liveNoAgent, persisted, () => false)
    expect(result).toEqual({ kind: 'cold', id: 'c' })
  })

  it('skips subagent-origin sessions when picking the cold fallback', () => {
    const persistedWithSubagent = [header('c', { createdAt: 30 }), header('sub', { createdAt: 40, origin: 'subagent' })]
    const result = resolveTargetId(undefined, [], persistedWithSubagent, () => true)
    expect(result).toEqual({ kind: 'cold', id: 'c' })
  })

  it('reports no active session with 409 when nothing is live or persisted', () => {
    const result = resolveTargetId(undefined, [], [], () => true)
    expect(result).toEqual({ kind: 'error', status: 409, message: 'no active session' })
  })
})

describe('parseBearerAuthorization', () => {
  it('extracts a bearer token', () => {
    expect(parseBearerAuthorization('Bearer abc123')).toBe('abc123')
  })

  it('returns undefined for a missing header', () => {
    expect(parseBearerAuthorization(undefined)).toBeUndefined()
  })

  it('returns undefined for a non-bearer scheme', () => {
    expect(parseBearerAuthorization('Basic abc123')).toBeUndefined()
  })

  it('returns undefined for an empty token', () => {
    expect(parseBearerAuthorization('Bearer ')).toBeUndefined()
  })
})

describe('outboxSessionId', () => {
  it('accepts a non-empty string session id', () => {
    expect(outboxSessionId({ sessionId: 's1' })).toBe('s1')
  })

  it('rejects missing, non-string, and empty session ids', () => {
    expect(outboxSessionId(undefined)).toBeNull()
    expect(outboxSessionId({})).toBeNull()
    expect(outboxSessionId({ sessionId: 42 })).toBeNull()
    expect(outboxSessionId({ sessionId: '' })).toBeNull()
  })
})

describe('manifestVersion', () => {
  it('returns the version from a valid manifest', () => {
    expect(manifestVersion('{"version":"0.1.0"}')).toBe('0.1.0')
  })

  it('returns null for missing, empty, or non-string versions', () => {
    expect(manifestVersion('{"name":"x"}')).toBeNull()
    expect(manifestVersion('{"version":""}')).toBeNull()
    expect(manifestVersion('{"version":42}')).toBeNull()
  })

  it('returns null for malformed or missing manifests', () => {
    expect(manifestVersion('not json')).toBeNull()
    expect(manifestVersion(undefined)).toBeNull()
  })
})

describe('tokensEqual', () => {
  it('matches identical tokens', () => {
    expect(tokensEqual('secret', 'secret')).toBe(true)
  })

  it('rejects differing tokens of the same length', () => {
    expect(tokensEqual('secret', 'sekret')).toBe(false)
  })

  it('rejects differing lengths without throwing', () => {
    expect(tokensEqual('secret', 'x')).toBe(false)
  })
})

describe('token-vend origin fence', () => {
  it('strips the port from a Host header, handling IPv6 brackets', () => {
    expect(hostnameOf('localhost:3080')).toBe('localhost')
    expect(hostnameOf('127.0.0.1:3080')).toBe('127.0.0.1')
    expect(hostnameOf('[::1]:3080')).toBe('::1')
    expect(hostnameOf('localhost')).toBe('localhost')
  })

  it('recognises loopback hostnames', () => {
    expect(isLoopbackHostname('localhost')).toBe(true)
    expect(isLoopbackHostname('127.0.0.1')).toBe(true)
    expect(isLoopbackHostname('::1')).toBe(true)
    expect(isLoopbackHostname('192.168.1.5')).toBe(false)
  })

  it('recognises loopback origins', () => {
    expect(isLoopbackOrigin('http://localhost:3080')).toBe(true)
    expect(isLoopbackOrigin('http://127.0.0.1:3080')).toBe(true)
    expect(isLoopbackOrigin('https://evil.com')).toBe(false)
  })

  it('rejects an unparseable origin and non-http(s) schemes', () => {
    expect(isLoopbackOrigin('not a url')).toBe(false)
    expect(isLoopbackOrigin('file:///etc/passwd')).toBe(false)
    expect(isLoopbackOrigin('ftp://127.0.0.1')).toBe(false)
  })

  it('accepts a same-origin request', () => {
    expect(tokenRequestsSameOrigin('localhost:3080', undefined)).toBe(true)
    expect(tokenRequestsSameOrigin('127.0.0.1:8080', 'http://127.0.0.1:8080')).toBe(true)
  })

  it('rejects a DNS-rebinding Host and a cross-origin page', () => {
    expect(tokenRequestsSameOrigin('evil.com', undefined)).toBe(false)
    expect(tokenRequestsSameOrigin('localhost:3080', 'http://evil.com')).toBe(false)
  })

  it('rejects a missing Host', () => {
    expect(tokenRequestsSameOrigin(undefined, undefined)).toBe(false)
  })

  it('recognises loopback socket peer addresses, including IPv4-mapped', () => {
    expect(isLoopbackAddress('127.0.0.1')).toBe(true)
    expect(isLoopbackAddress('127.0.0.2')).toBe(true)
    expect(isLoopbackAddress('::1')).toBe(true)
    expect(isLoopbackAddress('::ffff:127.0.0.1')).toBe(true)
  })

  it('rejects non-loopback and missing peer addresses', () => {
    expect(isLoopbackAddress('192.168.1.5')).toBe(false)
    expect(isLoopbackAddress('::ffff:192.168.1.5')).toBe(false)
    expect(isLoopbackAddress('2001:db8::1')).toBe(false)
    expect(isLoopbackAddress(undefined)).toBe(false)
  })
})

describe('draftMessage', () => {
  it('emits one SSE data frame with the draft payload', () => {
    expect(draftMessage('session-1', 'hello')).toBe(
      'data: {"kind":"draft","sessionId":"session-1","text":"hello"}\n\n',
    )
  })
})

describe('outboxMessage', () => {
  it('emits one SSE data frame signalling new outbox entries', () => {
    expect(outboxMessage()).toBe('data: {"kind":"outbox"}\n\n')
  })
})

describe('turnStartMessage', () => {
  it('emits one SSE data frame carrying the session id, event time, and turn', () => {
    expect(turnStartMessage('session-1', 1234, 7)).toBe(
      'data: {"kind":"turn-start","sessionId":"session-1","time":1234,"turn":7}\n\n',
    )
  })

  it('omits the turn when the event payload lacks one (defensive)', () => {
    expect(turnStartMessage('session-1', 1234)).toBe(
      'data: {"kind":"turn-start","sessionId":"session-1","time":1234}\n\n',
    )
  })
})

describe('turnCompleteMessage', () => {
  it('emits one SSE data frame carrying the reason kind, event time, and turn', () => {
    expect(turnCompleteMessage('session-1', 'completed', 1234, 7)).toBe(
      'data: {"kind":"turn-complete","sessionId":"session-1","reason":"completed","time":1234,"turn":7}\n\n',
    )
  })

  it('omits the turn when the event payload lacks one (defensive)', () => {
    expect(turnCompleteMessage('session-1', 'aborted', 1234)).toBe(
      'data: {"kind":"turn-complete","sessionId":"session-1","reason":"aborted","time":1234}\n\n',
    )
  })
})

describe('repliesChangedMessage', () => {
  it('emits one SSE data frame carrying the session id and the turn that grew', () => {
    expect(repliesChangedMessage('session-1', 7)).toBe(
      'data: {"kind":"replies-changed","sessionId":"session-1","turn":7}\n\n',
    )
  })

  it('omits the turn when the event payload lacks one (defensive)', () => {
    expect(repliesChangedMessage('session-1')).toBe(
      'data: {"kind":"replies-changed","sessionId":"session-1"}\n\n',
    )
  })
})

describe('sessionsChangedMessage', () => {
  it('emits a bare inventory-change frame without a session id', () => {
    expect(sessionsChangedMessage()).toBe('data: {"kind":"sessions-changed"}\n\n')
  })

  it('emits a frame naming the changed session when one is given', () => {
    expect(sessionsChangedMessage('session-1')).toBe(
      'data: {"kind":"sessions-changed","sessionId":"session-1"}\n\n',
    )
  })
})

describe('rpcRequestFrame', () => {
  it('emits a client-request envelope with the method, id, and payload', () => {
    expect(rpcRequestFrame('session/modelCatalog', 'rpc-1', { sessionId: 's1' })).toBe(
      '{"type":"client-request","rpcId":"rpc-1","method":"session/modelCatalog","payload":{"sessionId":"s1"}}',
    )
  })
})

describe('rpcUnwrapResponse', () => {
  it('unwraps an ok result', () => {
    expect(rpcUnwrapResponse('{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"a":1}}}'))
      .toEqual({ ok: true, value: { a: 1 } })
  })

  it('unwraps an error result with its code and message', () => {
    expect(rpcUnwrapResponse('{"type":"server-response","rpcId":"r","result":{"ok":false,"error":{"code":"model-unavailable","message":"nope","details":{}}}}'))
      .toEqual({ ok: false, error: { code: 'model-unavailable', message: 'nope' } })
  })

  it('collapses a malformed error into the internal code', () => {
    expect(rpcUnwrapResponse('{"type":"server-response","rpcId":"r","result":{"ok":false}}'))
      .toEqual({ ok: false, error: { code: 'internal', message: 'unknown error' } })
  })

  it('collapses a non-string error message into unknown error', () => {
    expect(rpcUnwrapResponse('{"type":"server-response","rpcId":"r","result":{"ok":false,"error":{"code":"bad","message":42}}}'))
      .toEqual({ ok: false, error: { code: 'bad', message: 'unknown error' } })
  })

  it('returns null when the result member is absent or not an object', () => {
    expect(rpcUnwrapResponse('{"type":"server-response","rpcId":"r"}')).toBeNull()
    expect(rpcUnwrapResponse('{"type":"server-response","result":null}')).toBeNull()
    expect(rpcUnwrapResponse('{"type":"server-response","result":42}')).toBeNull()
  })

  it('returns null when result.ok is neither true nor false', () => {
    expect(rpcUnwrapResponse('{"type":"server-response","result":{"value":{"a":1}}}')).toBeNull()
    expect(rpcUnwrapResponse('{"type":"server-response","result":{"ok":"true","value":1}}')).toBeNull()
  })

  it('returns null for a non-server-response or invalid body', () => {
    expect(rpcUnwrapResponse('{"type":"client-request"}')).toBeNull()
    expect(rpcUnwrapResponse('not json')).toBeNull()
  })
})

describe('contextUsedTokens', () => {
  it('prefers the projected value over the pressure sample', () => {
    expect(contextUsedTokens(12000, 11500)).toBe(11500)
    expect(contextUsedTokens(12000, undefined)).toBe(12000)
    expect(contextUsedTokens(undefined, 11500)).toBe(11500)
    expect(contextUsedTokens(undefined, undefined)).toBeUndefined()
  })
})

describe('contextMessage', () => {
  it('emits one SSE data frame with the occupancy figures', () => {
    expect(contextMessage('session-1', 45000, 100000)).toBe(
      'data: {"kind":"context","sessionId":"session-1","usedTokens":45000,"contextWindow":100000}\n\n',
    )
  })
})

describe('planChangedMessage', () => {
  it('carries active plus the live wanted direction', () => {
    expect(planChangedMessage('session-1', { active: false, pending: true })).toBe(
      'data: {"kind":"plan","sessionId":"session-1","plan":{"active":false,"pending":true}}\n\n',
    )
  })

  it('carries the direction-less queued bit', () => {
    expect(planChangedMessage('session-1', { active: true, queued: true })).toBe(
      'data: {"kind":"plan","sessionId":"session-1","plan":{"active":true,"queued":true}}\n\n',
    )
  })
})

describe('goalChangedMessage', () => {
  it('carries the full goal section with its activation', () => {
    expect(goalChangedMessage('session-1', {
      goal: { id: 'g1', revision: 2, objective: 'ship', phase: 'active', maxGoalRounds: 9 },
      roundsStarted: 1,
      createdAt: 10,
      updatedAt: 20,
      activation: 'disarmed',
    })).toBe(
      'data: {"kind":"goal","sessionId":"session-1","goal":{"goal":{"id":"g1","revision":2,"objective":"ship","phase":"active","maxGoalRounds":9},"roundsStarted":1,"createdAt":10,"updatedAt":20,"activation":"disarmed"}}\n\n',
    )
  })

  it('carries null to clear a cleared goal', () => {
    expect(goalChangedMessage('session-1', null)).toBe(
      'data: {"kind":"goal","sessionId":"session-1","goal":null}\n\n',
    )
  })
})

describe('goalSetAction', () => {
  it('creates when no goal exists or the current goal is complete', () => {
    expect(goalSetAction(undefined)).toBe('create')
    expect(goalSetAction('complete')).toBe('create')
  })

  it('edits every other phase in place', () => {
    expect(goalSetAction('active')).toBe('edit')
    expect(goalSetAction('paused')).toBe('edit')
    expect(goalSetAction('blocked')).toBe('edit')
  })
})

describe('goalErrorCode', () => {
  it('reads the stable code off a GoalError-like object', () => {
    expect(goalErrorCode(Object.assign(new Error('stale'), { code: 'GOAL_STALE_REVISION' })))
      .toBe('GOAL_STALE_REVISION')
  })

  it('ignores a non-goal code, a missing code, and non-objects', () => {
    expect(goalErrorCode(Object.assign(new Error('x'), { code: 'session/not-found' }))).toBeUndefined()
    expect(goalErrorCode(new Error('x'))).toBeUndefined()
    expect(goalErrorCode(undefined)).toBeUndefined()
    expect(goalErrorCode('GOAL_NOT_FOUND')).toBeUndefined()
  })
})

describe('goalErrorStatus', () => {
  it('maps the goal taxonomy to HTTP statuses', () => {
    expect(goalErrorStatus('GOAL_NOT_FOUND')).toBe(404)
    expect(goalErrorStatus('GOAL_STALE_REVISION')).toBe(409)
    expect(goalErrorStatus('GOAL_INVALID_TRANSITION')).toBe(409)
    expect(goalErrorStatus('GOAL_ALREADY_EXISTS')).toBe(409)
    expect(goalErrorStatus('GOAL_AGENT_NOT_LIVE')).toBe(409)
    expect(goalErrorStatus('GOAL_INVALID_OBJECTIVE')).toBe(400)
    expect(goalErrorStatus('GOAL_INVALID_MAX_ROUNDS')).toBe(400)
    expect(goalErrorStatus('GOAL_INVALID_BLOCK_REASON')).toBe(400)
    expect(goalErrorStatus('GOAL_INVALID_EDIT')).toBe(400)
    expect(goalErrorStatus('GOAL_WHAT')).toBe(500)
  })
})

describe('goalActivationChangedMessage', () => {
  it('carries the activation and the exact goal identity', () => {
    expect(goalActivationChangedMessage('session-1', 'armed', 'g1', 2)).toBe(
      'data: {"kind":"goal-activation","sessionId":"session-1","activation":"armed","goalId":"g1","revision":2}\n\n',
    )
  })

  it('omits an unknown goal identity', () => {
    expect(goalActivationChangedMessage('session-1', 'disarmed')).toBe(
      'data: {"kind":"goal-activation","sessionId":"session-1","activation":"disarmed"}\n\n',
    )
  })
})

describe('ask-user frame construction and answer validation', () => {
  it('askUserMessage emits one SSE data frame with the question id and payload', () => {
    expect(askUserMessage('rpc-1', 'session-1', [{ id: 'q1', question: 'Go?', options: [{ label: 'Yes' }] }]))
      .toBe('data: {"kind":"ask-user","questionId":"rpc-1","sessionId":"session-1","questions":[{"id":"q1","question":"Go?","options":[{"label":"Yes"}]}]}\n\n')
  })

  it('askUserResolvedMessage emits the outcome frame with the asker question ids', () => {
    expect(askUserResolvedMessage('session-1', 'rpc-1', 'answered', ['q1', 'q2'])).toBe(
      'data: {"kind":"ask-user-resolved","sessionId":"session-1","questionId":"rpc-1","outcome":"answered","questionIds":["q1","q2"]}\n\n')
    expect(askUserResolvedMessage('session-1', 'rpc-1', 'cancelled')).toBe(
      'data: {"kind":"ask-user-resolved","sessionId":"session-1","questionId":"rpc-1","outcome":"cancelled","questionIds":[]}\n\n')
  })

  it('isQuestionCancelRejection recognizes only the web UI cancel code', () => {
    expect(isQuestionCancelRejection(Object.assign(new Error('cancelled'), { code: 'ASK_CANCELLED' }))).toBe(true)
    // Any other browser failure must leave Emacs deciding, not cancel the ask.
    expect(isQuestionCancelRejection(Object.assign(new Error('aborted'), { code: 'ASK_ABORTED' }))).toBe(false)
    expect(isQuestionCancelRejection(new Error('no answerer'))).toBe(false)
    expect(isQuestionCancelRejection(undefined)).toBe(false)
    expect(isQuestionCancelRejection('ASK_CANCELLED')).toBe(false)
  })

  it('answerMatchesQuestions accepts answers naming pending question ids', () => {
    const questions = [{ id: 'q1', question: 'go?' }, { id: 'q2', question: 'really?' }]
    expect(answerMatchesQuestions(questions, [{ id: 'q1', selected: ['Yes'] }])).toBe(true)
    expect(answerMatchesQuestions(questions, [
      { id: 'q1', selected: ['Yes'] },
      { id: 'q2', selected: ['No'], custom: 'maybe' },
    ])).toBe(true)
  })

  it('answerMatchesQuestions rejects unknown ids and malformed entries', () => {
    const questions = [{ id: 'q1', question: 'go?' }]
    expect(answerMatchesQuestions(questions, [])).toBe(false)
    expect(answerMatchesQuestions(questions, 'yes')).toBe(false)
    expect(answerMatchesQuestions(questions, [{ id: 'q9', selected: ['Yes'] }])).toBe(false)
    expect(answerMatchesQuestions(questions, [{ id: 'q1' }])).toBe(false)
    expect(answerMatchesQuestions(questions, [{ id: 'q1', selected: 'Yes' }])).toBe(false)
    expect(answerMatchesQuestions(questions, [{ id: 'q1', selected: ['Yes'], custom: 3 }])).toBe(false)
  })
})

describe('approval frame construction, decision validation, and tool-call detail', () => {
  it('approvalMessage emits one SSE data frame, omitting absent optional fields', () => {
    expect(approvalMessage('appr-1', 'session-1', 'bash', 'call-1', 'escalate sandbox to danger-full-access: need /etc',
      { name: 'bash', arguments: '{"command":"cat /etc/passwd"}' })).toBe(
      'data: {"kind":"approval","approvalId":"appr-1","sessionId":"session-1","toolName":"bash",'
      + '"callId":"call-1","reason":"escalate sandbox to danger-full-access: need /etc",'
      + '"detail":{"name":"bash","arguments":"{\\"command\\":\\"cat /etc/passwd\\"}"}}\n\n')
    // A hook-gated ask may carry no callId/reason/detail: the frame stays lean.
    expect(approvalMessage('appr-2', 'session-1', 'write', undefined, undefined, undefined)).toBe(
      'data: {"kind":"approval","approvalId":"appr-2","sessionId":"session-1","toolName":"write"}\n\n')
  })

  it('approvalResolvedMessage emits the outcome frame with the decision and call identity', () => {
    expect(approvalResolvedMessage('appr-1', 'session-1', 'allowed-once', 'bash', 'call-1')).toBe(
      'data: {"kind":"approval-resolved","approvalId":"appr-1","sessionId":"session-1",'
      + '"outcome":"allowed-once","toolName":"bash","callId":"call-1"}\n\n')
    // A request delegated to the web UI for a notify-only Emacs can resolve as
    // the fail-closed `unavailable`.
    expect(approvalResolvedMessage('appr-2', 'session-1', 'unavailable', 'bash', undefined)).toBe(
      'data: {"kind":"approval-resolved","approvalId":"appr-2","sessionId":"session-1",'
      + '"outcome":"unavailable","toolName":"bash"}\n\n')
  })

  it('approvalDecisionValid accepts exactly the three answerable outcomes', () => {
    expect(approvalDecisionValid('allowed-once')).toBe(true)
    expect(approvalDecisionValid('rejected')).toBe(true)
    expect(approvalDecisionValid('cancelled')).toBe(true)
    // `unavailable` is the service's fail-closed answerer absence, never a
    // decision Emacs may submit.
    expect(approvalDecisionValid('unavailable')).toBe(false)
    expect(approvalDecisionValid('ALLOWED-ONCE')).toBe(false)
    expect(approvalDecisionValid(undefined)).toBe(false)
    expect(approvalDecisionValid(1)).toBe(false)
  })

  it('toolCallForId folds the matching tool/call event from the log', () => {
    const events: SessionEventLike[] = [
      { time: 1, type: 'tool/call', data: { callId: 'call-0', name: 'read', arguments: '{"path":"/a"}' } },
      { time: 2, type: 'tool/call', data: { callId: 'call-1', name: 'bash', arguments: '{"command":"true"}' } },
    ]
    expect(toolCallForId(events, 'call-1')).toEqual({ name: 'bash', arguments: '{"command":"true"}' })
    // A missing call id (hook-gated ask) or an unknown id omits detail.
    expect(toolCallForId(events, undefined)).toBeUndefined()
    expect(toolCallForId(events, '')).toBeUndefined()
    expect(toolCallForId(events, 'call-nope')).toBeUndefined()
    // A matching event with no usable name omits detail rather than lying.
    expect(toolCallForId([{ time: 1, type: 'tool/call', data: { callId: 'c', arguments: '{}' } }], 'c')).toBeUndefined()
  })

  it('truncateApprovalArguments leaves short text untouched', () => {
    expect(truncateApprovalArguments('{"a":1}', 100)).toBe('{"a":1}')
    expect(truncateApprovalArguments('', 8)).toBe('')
  })

  it('truncateApprovalArguments caps long text and marks the cut', () => {
    const long = `{"command":"${'x'.repeat(200)}"}`
    const cut = truncateApprovalArguments(long, 32)
    expect(cut.startsWith(long.slice(0, 32))).toBe(true)
    expect(cut.endsWith('\u2026[truncated]')).toBe(true)
    expect(cut.length).toBeLessThanOrEqual(32 + '\u2026[truncated]'.length)
  })

  it('truncateApprovalArguments never cuts inside a JSON escape', () => {
    // A `\uXXXX` escape straddling the cap: the cut backs off to before it,
    // so the prefix never ends on a lone backslash or partial hex digits.
    const text = '{"a":"\\u0041\\u0042\\u0043"}'
    const cut = truncateApprovalArguments(text, 12)
    const prefix = cut.slice(0, cut.indexOf('\u2026[truncated]'))
    expect(prefix.endsWith('\\')).toBe(false)
    expect(/\\u[0-9a-fA-F]{0,3}$/.test(prefix)).toBe(false)
    // The cut is a genuine prefix of the input.
    expect(text.startsWith(prefix)).toBe(true)
  })

  it('toolCallForId truncates an oversized arguments string at the cap', () => {
    const huge = `{"content":"${'y'.repeat(MAX_APPROVAL_DETAIL_CHARS * 2)}"}`
    const detail = toolCallForId(
      [{ time: 1, type: 'tool/call', data: { callId: 'c', name: 'write', arguments: huge } }],
      'c',
    )
    expect(detail?.name).toBe('write')
    expect(detail?.arguments.endsWith('\u2026[truncated]')).toBe(true)
    expect(detail?.arguments.length).toBeLessThan(huge.length)
  })
})

describe('sessionPreset', () => {
  it('returns the header preset when no selection event exists', () => {
    expect(sessionPreset({ agentPreset: 'default' }, [])).toBe('default')
  })

  it('lets the newest agent-preset/selected event win', () => {
    const events: SessionEventLike[] = [
      { time: 1, type: 'agent-preset/selected', data: { agentPreset: 'minimal' } },
      { time: 2, type: 'user/message', data: {} },
      { time: 3, type: 'agent-preset/selected', data: { agentPreset: 'cordis' } },
    ]
    expect(sessionPreset({ agentPreset: 'default' }, events)).toBe('cordis')
  })

  it('returns undefined when neither header nor events name a preset', () => {
    expect(sessionPreset({}, [])).toBeUndefined()
    expect(sessionPreset({}, [{ time: 1, type: 'agent-preset/selected', data: {} }])).toBeUndefined()
  })

  it('skips a selection event whose preset is not a string', () => {
    const events: SessionEventLike[] = [
      { time: 1, type: 'agent-preset/selected', data: { agentPreset: 'valid' } },
      { time: 2, type: 'agent-preset/selected', data: { agentPreset: 42 } },
    ]
    expect(sessionPreset({}, events)).toBe('valid')
    expect(sessionPreset({ agentPreset: 'header' }, [
      { time: 1, type: 'agent-preset/selected', data: { agentPreset: null } },
    ])).toBe('header')
  })
})

describe('isCompletedTurnAnchor', () => {
  it('accepts a completed turn end seq', () => {
    const events: SessionEventLike[] = [
      { time: 1, seq: 0, type: 'turn/start' },
      { time: 2, seq: 1, type: 'turn/end' },
    ]
    expect(isCompletedTurnAnchor(events, 1)).toBe(true)
  })

  it('rejects every seq inside a still-open turn', () => {
    // DSH 0.1.7 would cut at any of these and close the turn synthetically;
    // the bridge's contract only accepts a turn/end boundary.
    const events: SessionEventLike[] = [
      { time: 1, seq: 0, type: 'turn/start' },
      { time: 2, seq: 1, type: 'step/start' },
      { time: 3, seq: 2, type: 'assistant/message' },
    ]
    expect(isCompletedTurnAnchor(events, 0)).toBe(false)
    expect(isCompletedTurnAnchor(events, 1)).toBe(false)
    expect(isCompletedTurnAnchor(events, 2)).toBe(false)
  })

  it('rejects a seq the log does not contain', () => {
    expect(isCompletedTurnAnchor([{ time: 1, seq: 0, type: 'turn/start' }], 99)).toBe(false)
    expect(isCompletedTurnAnchor([], 0)).toBe(false)
  })
})

describe('assistantTextForMessage', () => {
  const events: SessionEventLike[] = [
    {
      time: 1,
      type: 'assistant/message',
      data: { message: { id: 'm1', content: [{ type: 'text', text: 'hello ' }, { type: 'tool-call' }, { type: 'text', text: 'world' }] } },
    },
    { time: 2, type: 'user/message', data: { message: { id: 'm2', content: [{ type: 'text', text: 'hi' }] } } },
  ]

  it('joins the text blocks of the addressed assistant message', () => {
    expect(assistantTextForMessage(events, 'm1')).toBe('hello world')
  })

  it('returns undefined for an unknown id or a non-assistant event', () => {
    expect(assistantTextForMessage(events, 'm9')).toBeUndefined()
    expect(assistantTextForMessage(events, 'm2')).toBeUndefined()
  })
})

describe('currentModelSelection', () => {
  const fallback = { provider: 'deepseek', model: 'deepseek-chat' }

  it('prefers the projection next, then lastUsed, then the catalog default', () => {
    expect(currentModelSelection(fallback, { next: { provider: 'p', model: 'm' }, lastUsed: { provider: 'a', model: 'b' } }))
      .toEqual({ provider: 'p', model: 'm' })
    expect(currentModelSelection(fallback, { next: null, lastUsed: { provider: 'a', model: 'b' } }))
      .toEqual({ provider: 'a', model: 'b' })
    expect(currentModelSelection(fallback, { next: null, lastUsed: null })).toBe(fallback)
    expect(currentModelSelection(fallback, undefined)).toBe(fallback)
  })
})

describe('rpcArgsPayload', () => {
  it('wraps named args into the gateway payload', () => {
    expect(rpcArgsPayload({ request: { sessionId: 's1' } })).toEqual({ args: { request: { sessionId: 's1' } } })
    expect(rpcArgsPayload({})).toEqual({ args: {} })
  })
})

describe('sniffImageMediaType', () => {
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0])
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0])
  const gif = new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
  const webp = new Uint8Array([0x52, 0x49, 0x46, 0x46, 0x20, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])

  it('recognizes the four accepted signatures', () => {
    expect(sniffImageMediaType(png)).toBe('image/png')
    expect(sniffImageMediaType(jpeg)).toBe('image/jpeg')
    expect(sniffImageMediaType(gif)).toBe('image/gif')
    expect(sniffImageMediaType(webp)).toBe('image/webp')
  })

  it('returns undefined for short, text, or RIFF-but-not-WEBP headers', () => {
    expect(sniffImageMediaType(new Uint8Array([]))).toBeUndefined()
    expect(sniffImageMediaType(new Uint8Array([0x89, 0x50]))).toBeUndefined()
    expect(sniffImageMediaType(new TextEncoder().encode('not an image'))).toBeUndefined()
    const riffWave = new Uint8Array([0x52, 0x49, 0x46, 0x46, 0x20, 0, 0, 0, 0x57, 0x41, 0x56, 0x45])
    expect(sniffImageMediaType(riffWave)).toBeUndefined()
  })

  it('does not trust a file extension over content (the store rejects mismatch)', () => {
    // A file named .png whose bytes are text is a verbatim file, not an image.
    expect(sniffImageMediaType(new TextEncoder().encode('#!/bin/sh\n'))).toBeUndefined()
  })
})

describe('parseAttachmentRequests', () => {
  it('treats absent and null as an empty list', () => {
    expect(parseAttachmentRequests(undefined)).toEqual({ ok: true, items: [] })
    expect(parseAttachmentRequests(null)).toEqual({ ok: true, items: [] })
    expect(parseAttachmentRequests([])).toEqual({ ok: true, items: [] })
  })

  it('keeps order and optional names', () => {
    expect(parseAttachmentRequests([
      { path: '/tmp/a.png' },
      { path: '/tmp/b.rs', name: 'b.rs' },
      { path: '/tmp/c', name: null },
    ])).toEqual({
      ok: true,
      items: [{ path: '/tmp/a.png' }, { path: '/tmp/b.rs', name: 'b.rs' }, { path: '/tmp/c' }],
    })
  })

  it('drops an empty-string name like an absent one', () => {
    expect(parseAttachmentRequests([{ path: '/tmp/a.png', name: '' }]))
      .toEqual({ ok: true, items: [{ path: '/tmp/a.png' }] })
  })

  it('rejects malformed members with the offending index', () => {
    const cases: Array<[unknown, string]> = [
      ['not-an-array', 'attachments must be an array'],
      [[null], 'attachments[0] must be an object'],
      [[[]], 'attachments[0] must be an object'],
      [[{}], 'attachments[0].path is required'],
      [[{ path: '' }], 'attachments[0].path is required'],
      [[{ path: 'relative/x' }], 'attachments[0].path must be absolute'],
      [[{ path: `/tmp/a${String.fromCharCode(0)}b` }], 'attachments[0].path must not contain NUL'],
      [[{ path: '/tmp/a', name: 7 }], 'attachments[0].name must be a string'],
      [[{ path: '/tmp/a' }, { path: 'b' }], 'attachments[1].path must be absolute'],
    ]
    for (const [value, error] of cases) {
      expect(parseAttachmentRequests(value)).toEqual({ ok: false, error })
    }
  })

  it('rejects more than the count cap', () => {
    const items = Array.from({ length: MAX_ATTACHMENTS + 1 }, (_v, i) => ({ path: `/tmp/${i}` }))
    expect(parseAttachmentRequests(items)).toEqual({
      ok: false,
      error: `too many attachments (max ${MAX_ATTACHMENTS})`,
    })
    // At the cap every item survives parsing, order intact.
    expect(parseAttachmentRequests(items.slice(0, MAX_ATTACHMENTS)))
      .toEqual({ ok: true, items: items.slice(0, MAX_ATTACHMENTS) })
  })
})

describe('imageInputUnsupported', () => {
  it('only refuses when a list is stated and omits image', () => {
    expect(imageInputUnsupported(undefined)).toBe(false)
    expect(imageInputUnsupported(['text'])).toBe(true)
    expect(imageInputUnsupported(['text', 'image'])).toBe(false)
    expect(imageInputUnsupported(['image'])).toBe(false)
  })
})

describe('attachmentErrorHttpStatus', () => {
  it('maps size limits to 413 and content/count problems to 400', () => {
    for (const code of ['IMAGES_TOO_LARGE', 'IMAGE_TOO_LARGE', 'IMAGE_TOO_MANY_PIXELS', 'IMAGE_DIMENSION_TOO_LARGE']) {
      expect(attachmentErrorHttpStatus(code)).toBe(413)
    }
    for (const code of [
      'TOO_MANY_IMAGES',
      'UNSUPPORTED_IMAGE_TYPE',
      'INVALID_IMAGE_BASE64',
      'INVALID_IMAGE',
      'IMAGE_TYPE_MISMATCH',
      'INVALID_FILE_BASE64',
      'ATTACHMENT_PROJECTION_UNSUPPORTED',
    ]) {
      expect(attachmentErrorHttpStatus(code)).toBe(400)
    }
  })

  it('maps a file-incapable backend to 501 and storage faults to 500', () => {
    expect(attachmentErrorHttpStatus('ATTACHMENT_FILES_UNSUPPORTED')).toBe(501)
    for (const code of ['ATTACHMENT_WRITE_FAILED', 'ATTACHMENT_CORRUPT', 'ATTACHMENT_NOT_FOUND', 'SOMETHING_ELSE']) {
      expect(attachmentErrorHttpStatus(code)).toBe(500)
    }
  })
})

describe('parseSendMode', () => {
  it('treats absent and null as an ordinary send, and accepts only steer', () => {
    expect(parseSendMode(undefined)).toEqual({ ok: true, mode: undefined })
    expect(parseSendMode(null)).toEqual({ ok: true, mode: undefined })
    expect(parseSendMode('steer')).toEqual({ ok: true, mode: 'steer' })
  })

  it('rejects any other mode rather than degrading to a queued send', () => {
    for (const value of ['queue', 'STEER', '', 0, true, ['steer'], { mode: 'steer' }]) {
      const parsed = parseSendMode(value)
      expect(parsed.ok).toBe(false)
      if (!parsed.ok) expect(parsed.error).toContain('steer')
    }
  })
})

describe('queueCounts', () => {
  const user = { source: { kind: 'user' } }
  const context = { source: { kind: 'plugin' } }

  it('counts every next-turn item as queued', () => {
    expect(queueCounts({ nextTurn: [user, user], nextStep: [] }))
      .toEqual({ queued: 2, steering: 0 })
  })

  it('counts only user-sourced next-step items as steering', () => {
    expect(queueCounts({ nextTurn: [], nextStep: [context, user, context, user] }))
      .toEqual({ queued: 0, steering: 2 })
  })

  it('reports zeros for an empty inbox', () => {
    expect(queueCounts({ nextTurn: [], nextStep: [] })).toEqual({ queued: 0, steering: 0 })
  })
})

describe('KeyedSerial', () => {
  it('runs same-key sections strictly one after another', async () => {
    const serial = new KeyedSerial()
    const order: string[] = []
    let releaseFirst: (() => void) | undefined
    const gate = new Promise<void>((resolve) => { releaseFirst = resolve })

    const first = serial.runExclusive('k', async () => {
      order.push('first:start')
      await gate
      order.push('first:end')
      return 'first'
    })
    const second = serial.runExclusive('k', async () => {
      order.push('second:start')
      return 'second'
    })

    // The second section has not begun while the first holds the key.
    await Promise.resolve()
    expect(order).toEqual(['first:start'])
    releaseFirst?.()
    await expect(Promise.all([first, second])).resolves.toEqual(['first', 'second'])
    // No interleaving: the first section completed before the second started.
    expect(order).toEqual(['first:start', 'first:end', 'second:start'])
  })

  it('runs different keys concurrently', async () => {
    const serial = new KeyedSerial()
    let release: (() => void) | undefined
    const gate = new Promise<void>((resolve) => { release = resolve })
    let bStarted = false

    const a = serial.runExclusive('a', async () => {
      await gate
      return 'a'
    })
    const b = serial.runExclusive('b', async () => {
      bStarted = true
      return 'b'
    })

    // Key 'b' is not blocked behind key 'a'.
    await expect(b).resolves.toBe('b')
    expect(bStarted).toBe(true)
    release?.()
    await expect(a).resolves.toBe('a')
  })

  it('releases the key when a section rejects and still isolates callers', async () => {
    const serial = new KeyedSerial()
    const boom = serial.runExclusive('k', async () => {
      throw new Error('boom')
    })
    const after = serial.runExclusive('k', async () => 'ok')

    await expect(boom).rejects.toThrow('boom')
    await expect(after).resolves.toBe('ok')
  })

  it('serializes a check-then-act pair so the second sees the first write', async () => {
    const serial = new KeyedSerial()
    // Stands in for "read the roster, then create a workspace title".
    let title: string | undefined
    const claim = async (name: string): Promise<'claimed' | 'taken'> =>
      await serial.runExclusive('workspace-titles', async () => {
        if (title !== undefined) return 'taken'
        // Yield inside the section: without the lock the second claim would
        // observe the still-unset title and also succeed.
        await new Promise<void>((resolve) => setTimeout(resolve, 0))
        title = name
        return 'claimed'
      })

    const results = await Promise.all([claim('dup'), claim('dup')])
    expect(results.filter(result => result === 'claimed')).toHaveLength(1)
    expect(results.filter(result => result === 'taken')).toHaveLength(1)
    expect(title).toBe('dup')
  })
})

// -- changed-files fold ------------------------------------------------------
// The fold walks the raw log, pairing `tool/call` (log-only, never a surface
// node) with a successful append-surface `tool/result`. These builders mirror
// the harness shapes the wiring passes in.

/** One `tool/call` log event. ARGS is an object, or a raw string for malformed JSON. */
function toolCall(
  turn: number,
  step: number,
  callId: string,
  name: string,
  args: unknown,
): SessionEventLike {
  return {
    time: 1000,
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

/** A `tool/result` for CALL-ID; append-surface and successful unless overridden. */
function mutatingResult(
  turn: number,
  step: number,
  callId: string,
  opts: { failed?: boolean; meta?: unknown; surfaceOp?: unknown } = {},
): SessionEventLike {
  return {
    time: 1000,
    type: 'tool/result',
    surfaceOp: opts.surfaceOp ?? 'append',
    data: {
      turn,
      step,
      message: {
        role: 'tool',
        content: [{ type: 'text', text: 'ok' }],
        source: { kind: 'tool', callId },
        toolCallId: callId,
        ...(opts.failed ? { isError: true } : {}),
      },
      ...(opts.meta === undefined ? {} : { meta: opts.meta }),
    },
  }
}

/** A `deliverables/presented` event naming FILES. */
function presented(turn: number, files: string[]): SessionEventLike {
  return { time: 1000, type: 'deliverables/presented', data: { turn, callId: 'c1', files: files.map(path => ({ path })) } }
}

/** A settled `write` call for PATH with CONTENT. */
function writeCall(turn: number, callId: string, path: string, content: string): SessionEventLike[] {
  return [
    toolCall(turn, 1, callId, 'write', { file_path: path, content }),
    mutatingResult(turn, 1, callId),
  ]
}

describe('changedFiles', () => {
  it('records successful write/edit mutations with per-turn attribution', () => {
    const result = changedFiles([
      toolCall(1, 1, 'c1', 'write', { file_path: 'src/a.ts', content: 'one' }),
      mutatingResult(1, 1, 'c1', { meta: { diffs: [{ path: 'src/a.ts', oldText: null, newText: 'one' }] } }),
      toolCall(1, 2, 'c2', 'edit', { file_path: 'src/b.ts', old_string: 'x', new_string: 'y' }),
      mutatingResult(1, 2, 'c2'),
      toolCall(2, 1, 'c3', 'edit', { file_path: 'src/a.ts', old_string: 'one', new_string: 'two' }),
      mutatingResult(2, 1, 'c3'),
    ], '/w')
    expect(result.files).toEqual([
      {
        path: 'src/a.ts', absolute: '/w/src/a.ts', op: 'write',
        firstTurn: 1, lastTurn: 2, turns: [1, 2],
      },
      {
        path: 'src/b.ts', absolute: '/w/src/b.ts', op: 'edit',
        firstTurn: 1, lastTurn: 1, turns: [1],
      },
    ])
    expect(result.byTurn.get(1)?.map(file => file.path)).toEqual(['src/a.ts', 'src/b.ts'])
    expect(result.byTurn.get(2)?.map(file => file.path)).toEqual(['src/a.ts'])
    expect(result.truncated).toBe(false)
  })

  it('ignores reads, failures, replacement-surface results, unknown call ids, and malformed calls', () => {
    const result = changedFiles([
      // A read never names a mutation.
      toolCall(1, 1, 'r1', 'read', { file_path: 'src/read.ts' }),
      mutatingResult(1, 1, 'r1'),
      // A failed write contributes nothing.
      toolCall(1, 2, 'f1', 'write', { file_path: 'src/fail.ts', content: 'x' }),
      mutatingResult(1, 2, 'f1', { failed: true }),
      // A compaction replacement copy must not settle the call.
      toolCall(1, 3, 'f2', 'write', { file_path: 'src/replaced.ts', content: 'x' }),
      mutatingResult(1, 3, 'f2', { surfaceOp: { op: 'replace', startSeq: 1, endSeq: 2 } }),
      // A result whose call was never seen contributes nothing.
      mutatingResult(1, 4, 'ghost'),
      // Malformed arguments JSON.
      toolCall(1, 5, 'm1', 'write', '{not json'),
      mutatingResult(1, 5, 'm1'),
      // An incomplete edit (identical strings) contributes nothing.
      toolCall(1, 6, 'm2', 'edit', { file_path: 'src/same.ts', old_string: 'x', new_string: 'x' }),
      mutatingResult(1, 6, 'm2'),
      // An empty path contributes nothing.
      toolCall(1, 7, 'm3', 'write', { file_path: '  ', content: 'x' }),
      mutatingResult(1, 7, 'm3'),
      // An unsupported tool contributes nothing.
      toolCall(1, 8, 'm4', 'bash', { command: 'rm src/x' }),
      mutatingResult(1, 8, 'm4'),
    ], '/w')
    expect(result.files).toEqual([])
    expect(result.byTurn.size).toBe(0)
  })

  it('pairs a result through the message toolCallId when the source carries none', () => {
    const result = changedFiles([
      toolCall(1, 1, 'c1', 'write', { file_path: 'src/a.ts', content: 'one' }),
      {
        time: 1000,
        type: 'tool/result',
        surfaceOp: 'append',
        data: {
          turn: 1,
          step: 1,
          message: { role: 'tool', content: [], source: { kind: 'tool' }, toolCallId: 'c1' },
        },
      },
    ], '/w')
    expect(result.files.map(file => file.path)).toEqual(['src/a.ts'])
  })

  it('accepts exactly the mutating str_replace_editor commands', () => {
    const result = changedFiles([
      toolCall(1, 1, 'e1', 'str_replace_editor', { command: 'create', path: '/w/new.ts', file_text: 'hi' }),
      mutatingResult(1, 1, 'e1'),
      toolCall(1, 2, 'e2', 'str_replace_editor', { command: 'str_replace', path: '/w/ed.ts', old_str: 'a', new_str: 'b' }),
      mutatingResult(1, 2, 'e2'),
      // A `str_replace` may omit `new_str` (deletion).
      toolCall(1, 3, 'e3', 'str_replace_editor', { command: 'str_replace', path: '/w/del.ts', old_str: 'a' }),
      mutatingResult(1, 3, 'e3'),
      toolCall(1, 4, 'e4', 'str_replace_editor', { command: 'insert', path: '/w/ins.ts', insert_line: 0, new_str: 'x' }),
      mutatingResult(1, 4, 'e4'),
      // Non-mutating or incomplete commands contribute nothing.
      toolCall(1, 5, 'v1', 'str_replace_editor', { command: 'view', path: '/w/view.ts' }),
      mutatingResult(1, 5, 'v1'),
      toolCall(1, 6, 'v2', 'str_replace_editor', { command: 'create', path: '/w/bad.ts' }),
      mutatingResult(1, 6, 'v2'),
      toolCall(1, 7, 'v3', 'str_replace_editor', { command: 'str_replace', path: '/w/bad2.ts', old_str: '' }),
      mutatingResult(1, 7, 'v3'),
      toolCall(1, 8, 'v4', 'str_replace_editor', { command: 'insert', path: '/w/bad3.ts', insert_line: -1, new_str: 'x' }),
      mutatingResult(1, 8, 'v4'),
    ], '/w')
    expect(result.files.map(file => [file.path, file.op])).toEqual([
      ['/w/new.ts', 'str_replace_editor:create'],
      ['/w/ed.ts', 'str_replace_editor:str_replace'],
      ['/w/del.ts', 'str_replace_editor:str_replace'],
      ['/w/ins.ts', 'str_replace_editor:insert'],
    ])
  })

  it('deduplicates within a turn and keeps the exact path spelling', () => {
    const result = changedFiles([
      ...writeCall(1, 'c1', './src/a.ts', 'one'),
      toolCall(1, 2, 'c2', 'edit', { file_path: './src/a.ts', old_string: 'one', new_string: 'two' }),
      mutatingResult(1, 2, 'c2'),
    ], '/w')
    expect(result.files).toHaveLength(1)
    expect(result.files[0]!.path).toBe('./src/a.ts')
    expect(result.files[0]!.absolute).toBe('/w/src/a.ts')
    expect(result.files[0]!.turns).toEqual([1])
    expect(result.byTurn.get(1)).toHaveLength(1)
  })

  it('marks a delivered file from deliverables/presented, matching the resolved path', () => {
    const result = changedFiles([
      ...writeCall(1, 'c1', 'src/a.ts', 'one'),
      presented(1, ['src/a.ts']),
      ...writeCall(1, 'c2', 'src/b.ts', 'two'),
      // A presented absolute path still matches a relative mutation path.
      presented(1, ['/w/src/b.ts']),
    ], '/w')
    expect(result.files.map(file => [file.path, file.delivered])).toEqual([
      ['src/a.ts', true],
      ['src/b.ts', true],
    ])
  })

  it('falls back to the logged spelling when no cwd is known', () => {
    const result = changedFiles(writeCall(1, 'c1', '/abs/a.ts', 'one'))
    expect(result.files[0]!.absolute).toBe('/abs/a.ts')
  })

  it('bounds the total and per-turn files, reporting truncation', () => {
    const events: SessionEventLike[] = []
    for (let i = 0; i < MAX_CHANGED_FILES_PER_TURN + 1; i += 1) {
      events.push(...writeCall(1, `p${i}`, `src/turn-${i}.ts`, 'x'))
    }
    const perTurn = changedFiles(events, '/w')
    expect(perTurn.files).toHaveLength(MAX_CHANGED_FILES_PER_TURN)
    expect(perTurn.truncated).toBe(true)

    const many: SessionEventLike[] = []
    for (let i = 0; i < MAX_CHANGED_FILES + 1; i += 1) {
      many.push(...writeCall(i + 1, `t${i}`, `src/total-${i}.ts`, 'x'))
    }
    const total = changedFiles(many, '/w')
    expect(total.files).toHaveLength(MAX_CHANGED_FILES)
    expect(total.truncated).toBe(true)
  })
})
