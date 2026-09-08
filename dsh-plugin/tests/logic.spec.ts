import { describe, expect, it } from 'vitest'
import {
  answerMatchesQuestions,
  askUserMessage,
  askUserResolvedMessage,
  assistantMessageHasText,
  assistantMessageText,
  assistantTextForMessage,
  assistantTurns,
  classifySessionId,
  contextMessage,
  contextUsedTokens,
  currentModelSelection,
  draftMessage,
  hostnameOf,
  isLoopbackAddress,
  isLoopbackHostname,
  isLoopbackOrigin,
  isSubagentChild,
  latestAssistantText,
  manifestVersion,
  mergeSessionRows,
  outboxMessage,
  outboxSessionId,
  parseBearerAuthorization,
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

function message(role: string, blocks: Array<{ type: string; text?: string }>): MessageLike {
  return { role, content: blocks }
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
  // (the harness log invariant: events[seq] is the event with that seq).
  return { events: [...events], nodes: events.flatMap((e, i) => (e.type && SURFACE_TYPES.has(e.type) ? [i] : [])) }
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
    expect(turns[0]!.segments).toHaveLength(2)
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
    expect(rpcRequestFrame('session.models', 'rpc-1', { sessionId: 's1' })).toBe(
      '{"type":"client-request","rpcId":"rpc-1","method":"session.models","payload":{"sessionId":"s1"}}',
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

describe('ask-user frame construction and answer validation', () => {
  it('askUserMessage emits one SSE data frame with the question id and payload', () => {
    expect(askUserMessage('rpc-1', 'session-1', [{ id: 'q1', question: 'Go?', options: [{ label: 'Yes' }] }]))
      .toBe('data: {"kind":"ask-user","questionId":"rpc-1","sessionId":"session-1","questions":[{"id":"q1","question":"Go?","options":[{"label":"Yes"}]}]}\n\n')
  })

  it('askUserResolvedMessage emits the outcome frame', () => {
    expect(askUserResolvedMessage('session-1', 'rpc-1', 'answered')).toBe(
      'data: {"kind":"ask-user-resolved","sessionId":"session-1","questionId":"rpc-1","outcome":"answered"}\n\n')
    expect(askUserResolvedMessage('session-1', 'rpc-1', 'cancelled')).toBe(
      'data: {"kind":"ask-user-resolved","sessionId":"session-1","questionId":"rpc-1","outcome":"cancelled"}\n\n')
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
