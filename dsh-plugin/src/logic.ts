// dsh-emacs-bridge — pure, dependency-free logic. No Cordis/dsh runtime
// imports live here, so Vitest can exercise this module without booting a host.
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

import { timingSafeEqual } from 'node:crypto'

/** One content block, narrowed to the fields the bridge reads. */
export interface MessageBlockLike {
  type: string
  text?: string
}

/** One derived message, narrowed to the fields the bridge reads. */
export interface MessageLike {
  role: string
  content: readonly MessageBlockLike[]
}

/**
 * Latest assistant text, newest-first. Reads the derived message view so
 * compaction-replaced history stays hidden; assistant turns with no text
 * (tool-call-only steps) fall through to the previous one.
 */
export function latestAssistantText(messages: readonly MessageLike[]): string {
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const message = messages[i]
    if (message.role !== 'assistant') continue
    const text = message.content
      .filter(block => block.type === 'text')
      .map(block => block.text ?? '')
      .join('')
    if (text !== '') return text
  }
  return ''
}

/**
 * The text of every user prompt, oldest first. The mirror image of
 * `latestAssistantText`: reads the derived message view, keeps `user` role
 * messages, joins their text blocks with newlines, and drops whitespace-only
 * entries. Used by the prompt-buffer history.
 */
export function userPrompts(messages: readonly MessageLike[]): string[] {
  const prompts: string[] = []
  for (const message of messages) {
    if (message.role !== 'user') continue
    const text = message.content
      .filter(block => block.type === 'text')
      .map(block => block.text ?? '')
      .join('\n')
    if (text.trim() !== '') prompts.push(text)
  }
  return prompts
}

/**
 * The text of one committed assistant message: its text blocks joined with no
 * separator — exactly how `latestAssistantText` renders a reply, so a turn
 * segment's `text` matches what `GET /output` shows for the same message.
 */
export function assistantMessageText(content: readonly MessageBlockLike[] | undefined): string {
  if (content === undefined) return ''
  return content
    .filter(block => block.type === 'text')
    .map(block => block.text ?? '')
    .join('')
}

/**
 * One committed, text-bearing assistant message inside an agent turn: the
 * turn-grouped counterpart of a reply. Segments are chronological.
 */
export interface AssistantTurnSegment {
  /** The joined text blocks of the step's assistant message. */
  text: string
  /** The `assistant/message` event's ms-epoch `time`. */
  time: number
  /** The step index (1-based on the harness) that committed the message. */
  step: number
}

/**
 * One agent turn that produced at least one text-bearing assistant message.
 * A turn (user prompt → final reply → idle) may commit several such messages
 * between tool calls; the DSH-View shows them as one unit.
 */
export interface AssistantTurn {
  /** The harness turn number. NOT contiguous (an empty/rejected turn still
   * consumes a number, and user messages carry no turn on the wire) — group
   * by this value, never by index arithmetic. */
  turn: number
  /** Ms-epoch `time` of the turn's `turn/start` event; falls back to the
   * first segment's time when the boundary event is absent. */
  startedAt: number
  /** Ms-epoch `time` of the turn's `turn/end` event; absent while open. */
  endedAt?: number
  /** The `turn/end` reason kind (`completed`/`aborted`/...); absent while open. */
  reason?: string
  /** The turn's text-bearing assistant messages, oldest first. */
  segments: readonly AssistantTurnSegment[]
}

/** Structural face of one session log for the turn fold: the surface node
 * seqs plus the log they index into (`Session.surface.nodes` +
 * `Session.events`, where `events[seq]` is the event with that `seq`). */
export interface SessionTurnLogLike {
  nodes: readonly number[]
  events: readonly SessionEventLike[]
}

/**
 * Fold a session log into its text-bearing agent turns, oldest first.
 *
 * Walks the surface (`nodes`, the seqs of message-producing events in
 * model-visible order) and projects each `assistant/message` event at
 * `events[seq]` into a segment of `data.turn`, dropping events with no text
 * (tool-call-only steps, empty content) exactly as the old reply list did.
 * Because the walk is the same surface `Session.deriveMessages()` folds,
 * compaction-replaced history stays hidden — shadowed turns simply vanish
 * from the result, matching what `/replies` used to serve. Turn start/end
 * boundary events are log-only (never surface nodes), so `startedAt`,
 * `endedAt`, and `reason` are folded from a separate pass over the log.
 */
export function assistantTurns(log: SessionTurnLogLike): AssistantTurn[] {
  const byTurn = new Map<number, AssistantTurnSegment[]>()
  const order: number[] = []
  for (const seq of log.nodes) {
    const event = log.events[seq]
    if (event === undefined || event.type !== 'assistant/message') continue
    const data = event.data
    if (typeof data !== 'object' || data === null) continue
    const { turn, step } = data as { turn?: unknown; step?: unknown }
    if (typeof turn !== 'number' || typeof step !== 'number') continue
    const { message } = data as { message?: { content?: readonly MessageBlockLike[] } }
    const text = assistantMessageText(message?.content)
    if (text.trim() === '') continue
    let segments = byTurn.get(turn)
    if (segments === undefined) {
      segments = []
      byTurn.set(turn, segments)
      order.push(turn)
    }
    segments.push({ text, time: event.time, step })
  }

  // Turn boundaries are log-only, so fold start/end facts for the turns that
  // produced text from the events themselves. A turn has one `turn/start`
  // (first wins for the start time) and at most one `turn/end` (last wins).
  const starts = new Map<number, number>()
  const ends = new Map<number, { time: number; reason?: string }>()
  for (const event of log.events) {
    if (event.type === 'turn/start') {
      const data = event.data as { turn?: unknown } | undefined
      const turn = data?.turn
      if (typeof turn === 'number' && !starts.has(turn)) starts.set(turn, event.time)
    } else if (event.type === 'turn/end') {
      const data = event.data as { turn?: unknown; reason?: { kind?: unknown } } | undefined
      const turn = data?.turn
      if (typeof turn === 'number') {
        const kind = data?.reason?.kind
        ends.set(turn, {
          time: event.time,
          ...(typeof kind === 'string' ? { reason: kind } : {}),
        })
      }
    }
  }

  const turns: AssistantTurn[] = []
  for (const turn of order) {
    const segments = byTurn.get(turn)!
    const record: AssistantTurn = {
      turn,
      startedAt: starts.get(turn) ?? segments[0]!.time,
      segments: [...segments],
    }
    const end = ends.get(turn)
    if (end !== undefined) {
      record.endedAt = end.time
      if (end.reason !== undefined) record.reason = end.reason
    }
    turns.push(record)
  }
  return turns
}

/**
 * One `/turns` incremental-fetch request, as raw query params.
 * `since` is inclusive: the response names every visible turn with
 * `turn >= since`, and `epoch` is the replacement generation the client's
 * list was folded under.
 */
export interface TurnsSinceRequest {
  since?: string
  epoch?: string
}

/** One `/turns` response plan: whether it is the incremental suffix, and the turns to serve. */
export interface TurnsSinceResult {
  incremental: boolean
  turns: readonly AssistantTurn[]
}

/** Parse a non-negative decimal integer query param, or undefined when absent or malformed. */
function nonNegativeIntParam(value: string | undefined): number | undefined {
  if (value === undefined) return undefined
  if (!/^\d+$/.test(value)) return undefined
  const number = Number(value)
  return Number.isSafeInteger(number) ? number : undefined
}

/**
 * Decide the `/turns` response for an incremental-fetch request.
 *
 * TURNS is the session's full visible turn list (newest first) and
 * CURRENT_EPOCH its `surface.replaceGeneration`.  An incremental response is
 * served only when the request is well-formed (both `since` and `epoch`
 * present as non-negative integers), the client's EPOCH equals CURRENT_EPOCH,
 * and `since` names a visible turn; otherwise the response is the full list.
 *
 * Epoch equality is the whole safety argument: `replaceGeneration`
 * increments only on surface replaces, so an equal epoch means the client's
 * older snapshot can only have grown (segments appended to existing turns,
 * new turns at the newest end) — never shrunk or been reordered — so keeping
 * the client's turns below `since` is sound.  `since` is inclusive because
 * the boundary turn is exactly the one that changes mid-turn: segments
 * append to it, and a `turn/end` sets its `endedAt`/`reason`.
 */
export function turnsSince(
  turns: readonly AssistantTurn[],
  currentEpoch: number,
  request: TurnsSinceRequest,
): TurnsSinceResult {
  const since = nonNegativeIntParam(request.since)
  const epoch = nonNegativeIntParam(request.epoch)
  if (since === undefined || epoch === undefined) return { incremental: false, turns }
  if (epoch !== currentEpoch) return { incremental: false, turns }
  if (!turns.some(turn => turn.turn === since)) return { incremental: false, turns }
  // Visible turn numbers only grow over time, so the `turn >= since` suffix
  // is a head prefix of the newest-first list.
  const suffix: AssistantTurn[] = []
  for (const turn of turns) {
    if (turn.turn >= since) suffix.push(turn)
    else break
  }
  return { incremental: true, turns: suffix }
}

/**
 * Whether an assistant message carries non-empty text, i.e. whether it adds a
 * segment to its turn in `assistantTurns`. A tool-call-only step (content
 * without a text block) does not. Used to gate the `replies-changed` SSE
 * frame so it fires only when a turn actually gains a text segment.
 */
export function assistantMessageHasText(message: { content?: readonly MessageBlockLike[] } | undefined): boolean {
  return message?.content?.some(block => block.type === 'text' && (block.text ?? '').trim() !== '') ?? false
}

/**
 * Minimal structural face of one logged event, enough to fold a title and
 * last-activity time. `data` is deliberately `unknown`: the real `SessionEvent`
 * union satisfies this shape, and the title fold narrows the payload it reads.
 */
export interface SessionEventLike {
  time: number
  type?: string
  data?: unknown
}

/** Structural view of one live session, enough for targeting and listing. */
export interface LiveSessionLike {
  id: string
  header: { cwd?: string; createdAt: number }
  events: readonly SessionEventLike[]
  /** Whether the live agent is actively processing a turn (not yet quiesced). */
  running: boolean
}

/** Structural view of one persisted session header. */
export interface SessionHeaderLike {
  id: string
  cwd?: string
  createdAt: number
  origin?: string
  title?: string | null
}

/** One entry in the merged session inventory handed to Emacs. */
export interface SessionRow {
  id: string
  title: string | null
  cwd: string | null
  live: boolean
  /** Whether the session's agent is currently running a turn (never for cold). */
  running: boolean
  lastActive?: number
  createdAt: number
  /** Display name of the workspace the session belongs to, when one is known. */
  workspace?: string | null
  /** Id of the workspace the session belongs to, when one is known. */
  workspaceId?: string | null
  /** Whether the workspace registry hides the session from grouping surfaces. */
  archived?: boolean
}

/** The workspace reference a session row displays and targets. */
export interface WorkspaceRef {
  id: string
  title: string
}

/** Minimal structural face of one workspace, enough for a session->ref map. */
export interface WorkspaceLike {
  id: string
  title: string
  path: string
  sessionIds: readonly string[]
}

/**
 * Build a session-id -> workspace-ref map from the registry's workspaces.
 * A session accounted by several workspaces keeps the last one's ref (the
 * registry invariant forbids that overlap in practice). The ref carries both
 * the display title and the id, so a row can name the workspace for rename.
 */
export function workspaceRefsBySession(workspaces: readonly WorkspaceLike[]): Map<string, WorkspaceRef> {
  const map = new Map<string, WorkspaceRef>()
  for (const workspace of workspaces) {
    for (const id of workspace.sessionIds) map.set(id, { id: workspace.id, title: workspace.title })
  }
  return map
}

/**
 * Whether a session must be excluded from targeting and listing: it is a
 * subagent child by origin, or its live parent still owns it (`ownedByParent`
 * is computed by the caller from the live agent registry).
 */
export function isSubagentChild(origin: string | undefined, ownedByParent: boolean): boolean {
  return origin === 'subagent' || ownedByParent
}

/**
 * The latest `session/title` event's title, or null. Last-wins fold of the
 * same event DSH's own session list projects as the display title; titles are
 * normalized non-empty strings, so a malformed or empty payload reads as null.
 */
export function sessionTitle(events: readonly SessionEventLike[]): string | null {
  const event = events.findLast(item => item.type === 'session/title')
  const data = event?.data
  if (typeof data !== 'object' || data === null) return null
  const title = (data as { title?: unknown }).title
  return typeof title === 'string' && title !== '' ? title : null
}

/**
 * Merge live sessions with persisted (cold) headers into one inventory.
 * `live` is already filtered to targetable sessions by the caller; persisted
 * entries are skipped when subagent-owned or already present as live.
 */
export function mergeSessionRows(
  live: readonly LiveSessionLike[],
  persisted: readonly SessionHeaderLike[],
): SessionRow[] {
  const liveIds = new Set<string>()
  const rows: SessionRow[] = []
  for (const session of live) {
    const id = session.id
    liveIds.add(id)
    rows.push({
      id,
      title: sessionTitle(session.events),
      cwd: session.header.cwd ?? null,
      live: true,
      running: session.running,
      lastActive: session.events.at(-1)?.time ?? session.header.createdAt,
      createdAt: session.header.createdAt,
    })
  }
  for (const header of persisted) {
    if (header.origin === 'subagent') continue
    const id = header.id
    if (liveIds.has(id)) continue
    rows.push({
      id,
      title: header.title ?? null,
      cwd: header.cwd ?? null,
      live: false,
      running: false,
      createdAt: header.createdAt,
    })
  }
  return rows
}

/**
 * The outcome of resolving a request's target session id.
 */
export type ResolveTargetResult =
  | { kind: 'target'; id: string }
  | { kind: 'cold'; id: string }
  | { kind: 'error'; status: 404 | 409; message: string }

/** The classification of one session id against a targetable inventory. */
export type SessionClass = 'live' | 'cold' | 'unknown'

/**
 * Classify a session id against a live id set and a persisted id set.
 * A subagent-produced persisted id is still `cold` for classification (the
 * caller's resume guard rejects ownership at the header boundary); this helper
 * only says which tier holds the id, so the wiring can route the resume arm.
 */
export function classifySessionId(
  id: string,
  liveIds: ReadonlySet<string>,
  persistedIds: ReadonlySet<string>,
): SessionClass {
  if (liveIds.has(id)) return 'live'
  if (persistedIds.has(id)) return 'cold'
  return 'unknown'
}

/**
 * Resolve the effective target session id. Precedence: an explicit id, then
 * last-active, then (when nothing is live) the most recent cold session.
 *
 * An explicit id that is live and agent-bearing is a `target`; a live id with
 * no agent is 409; an id that is persisted but not live is `cold` (the wiring
 * resumes it); an id neither live nor persisted is 404. With no explicit id,
 * the most recently active live session wins as before; when nothing is live
 * and agent-bearing, the most recent cold session (by `createdAt`, excluding
 * subagent origin) is returned as `cold` so the wiring resumes it — matching
 * the web UI's invisible-resume model after a `dsh web` restart. No id in
 * either tier is 409. `hasAgent` is supplied by the caller (it consults the
 * live agent registry).
 */
export function resolveTargetId(
  explicitId: string | undefined,
  live: readonly LiveSessionLike[],
  persisted: readonly SessionHeaderLike[],
  hasAgent: (id: string) => boolean,
): ResolveTargetResult {
  // The explicit-id classification keeps subagent-origin ids so the resume arm
  // (and its ownership guard) can answer 409 for them; only the bare fallback,
  // which must never target a subagent on its own, skips that origin.
  const liveIds = new Set(live.map(session => session.id))
  const persistedIds = new Set(persisted.map(header => header.id))
  if (explicitId !== undefined) {
    const cls = classifySessionId(explicitId, liveIds, persistedIds)
    if (cls === 'live') {
      if (!hasAgent(explicitId)) return { kind: 'error', status: 409, message: `session ${explicitId} has no live agent` }
      return { kind: 'target', id: explicitId }
    }
    if (cls === 'cold') return { kind: 'cold', id: explicitId }
    return { kind: 'error', status: 404, message: `session ${explicitId} is not live` }
  }
  let best: string | undefined
  let bestTime = -Infinity
  for (const session of live) {
    if (!hasAgent(session.id)) continue
    const time = session.events.at(-1)?.time ?? session.header.createdAt
    if (time > bestTime) {
      bestTime = time
      best = session.id
    }
  }
  if (best !== undefined) return { kind: 'target', id: best }
  let bestCold: string | undefined
  let bestCreated = -Infinity
  for (const header of persisted) {
    if (header.origin === 'subagent') continue
    if (header.createdAt > bestCreated) {
      bestCreated = header.createdAt
      bestCold = header.id
    }
  }
  if (bestCold !== undefined) return { kind: 'cold', id: bestCold }
  return { kind: 'error', status: 409, message: 'no active session' }
}

/** The bearer token carried by an Authorization header, or undefined. */
export function parseBearerAuthorization(header: string | undefined): string | undefined {
  if (header === undefined) return undefined
  const match = /^Bearer\s+(\S+)$/.exec(header)
  return match?.[1]
}

/**
 * The required session id of a `/outbox` deposit, or null when missing or
 * malformed.  Every DSH→Emacs entry is session-scoped (UX plan 2, Section
 * 1.4): the browser "Send to Emacs" action always knows its session, so the
 * route makes the premise a contract instead of an empirical property.
 */
export function outboxSessionId(body: { sessionId?: unknown } | undefined): string | null {
  const id = body?.sessionId
  return typeof id === 'string' && id !== '' ? id : null
}

/**
 * The `version` field of a package.json manifest TEXT, or null when it is
 * missing, empty, or the manifest is not valid JSON.  Used by the `/status`
 * route to report the running plugin's version, so Emacs can detect a stale
 * installed copy after a package upgrade.
 */
export function manifestVersion(manifest: string | undefined): string | null {
  if (manifest === undefined) return null
  try {
    const data = JSON.parse(manifest) as { version?: unknown }
    return typeof data.version === 'string' && data.version !== '' ? data.version : null
  } catch {
    return null
  }
}

/** Constant-time comparison of two token strings. */
export function tokensEqual(expected: string, provided: string): boolean {
  const a = Buffer.from(expected)
  const b = Buffer.from(provided)
  if (a.length !== b.length) return false
  return timingSafeEqual(a, b)
}

/** The hostname part of a Host header value, handling an IPv6-bracketed port. */
export function hostnameOf(host: string): string {
  if (host.startsWith('[')) {
    const end = host.indexOf(']')
    return end === -1 ? host : host.slice(1, end)
  }
  const colon = host.lastIndexOf(':')
  return colon === -1 ? host : host.slice(0, colon)
}

/** Whether a hostname names the loopback interface. */
export function isLoopbackHostname(name: string): boolean {
  return name === 'localhost' || name === '127.0.0.1' || name === '::1'
}

/**
 * Whether a socket peer address names the loopback interface (IPv4 127/8,
 * `::1`, or IPv4-mapped `::ffff:127/8`). Unlike the Host header, a TCP peer
 * address cannot be forged by a remote client, so this check keeps the
 * token-vend route loopback-only even if the server is configured to bind a
 * non-loopback interface.
 */
export function isLoopbackAddress(address: string | undefined): boolean {
  if (address === undefined) return false
  const unmapped = address.startsWith('::ffff:') ? address.slice('::ffff:'.length) : address
  return unmapped === '::1' || unmapped.startsWith('127.')
}

/** Whether an Origin value belongs to the loopback interface. */
export function isLoopbackOrigin(origin: string): boolean {
  let url: URL
  try {
    url = new URL(origin)
  } catch {
    return false
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return false
  return isLoopbackHostname(url.hostname)
}

/**
 * Whether a token-vend request proves it came from the web UI's own origin:
 * the Host must name loopback (defeating DNS-rebinding), and a present Origin
 * must too (defeating a cross-origin page). The browser legitimately lacks the
 * bearer token on first load, so this fence stands in for it on that one
 * route. Headers alone cannot prove the peer is local (a remote client can
 * forge Host when the server binds a non-loopback interface), so callers must
 * combine this with `isLoopbackAddress(req.socket.remoteAddress)`.
 */
export function tokenRequestsSameOrigin(host: string | undefined, origin: string | undefined): boolean {
  if (host === undefined) return false
  if (!isLoopbackHostname(hostnameOf(host))) return false
  if (origin !== undefined && !isLoopbackOrigin(origin)) return false
  return true
}

/**
 * One SSE `data:` frame for a composer-draft push. The payload names the target
 * session so the browser routes the draft to the right composer scope.
 */
export function draftMessage(sessionId: string, text: string): string {
  return `data: ${JSON.stringify({ kind: 'draft', sessionId, text })}\n\n`
}

/**
 * One SSE `data:` frame signalling that new outbox entries are available (the
 * "Send to Emacs" button deposited a message). A bare notice: consumers pull the
 * outbox themselves, keeping the ack/redelivery semantics in one place.
 */
export function outboxMessage(): string {
  return 'data: {"kind":"outbox"}\n\n'
}

/**
 * One SSE `data:` frame announcing that a session's agent started a turn.
 * Carries the session id, the turn event's ms-epoch `time` (so Emacs can
 * update the `lastActive` recency of the session's row), and the turn number
 * (so the Emacs reply/turn cache knows which turn is opening); the browser
 * ignores the non-`draft` kind.
 */
export function turnStartMessage(sessionId: string, time: number, turn?: number): string {
  return `data: ${JSON.stringify({
    kind: 'turn-start',
    sessionId,
    time,
    ...(turn === undefined ? {} : { turn }),
  })}\n\n`
}

/**
 * One SSE `data:` frame announcing that a session's turn ended. REASON is the
 * turn-end reason kind (`completed` / `aborted` / `blocked` / `error` /
 * `max-tokens`; `interrupted` is only written by persistence repair, never
 * emitted live), so the Emacs `message` variant can phrase a failed turn
 * without echoing "finished". `time` is the event's ms-epoch timestamp, used
 * to refresh the sessions-list recency; the glyph returns to idle regardless
 * of reason. TURN names the ended turn, so Emacs can refill exactly the view
 * whose closing divider it must draw.
 */
export function turnCompleteMessage(sessionId: string, reason: string, time: number, turn?: number): string {
  return `data: ${JSON.stringify({
    kind: 'turn-complete',
    sessionId,
    reason,
    time,
    ...(turn === undefined ? {} : { turn }),
  })}\n\n`
}

/**
 * One SSE `data:` frame announcing that a session's assistant reply list grew
 * (an `assistant/message` surface event carrying non-empty text was committed
 * mid-turn). Unlike the turn-boundary frames, this fires once per segment a
 * multi-step turn produces, so Emacs can refresh its turn list — and the View
 * `(k/n)` counter — while the turn is still running. TURN names the turn that
 * grew (the dirty cache entry). A bare nudge: the consumer re-pulls
 * `GET /turns`; the browser ignores the non-`draft` kind.
 */
export function repliesChangedMessage(sessionId: string, turn?: number): string {
  return `data: ${JSON.stringify({
    kind: 'replies-changed',
    sessionId,
    ...(turn === undefined ? {} : { turn }),
  })}\n\n`
}

/**
 * Whether renaming a workspace to TITLE would collide with an existing
 * workspace (any other workspace already bearing that title). A same-title
 * rename is NOT a conflict — the caller treats it as a no-op — so the named
 * workspace is excluded by id. Mirrors the gateway's uniqueness check.
 */
export function workspaceTitleConflict(
  title: string,
  workspaces: readonly WorkspaceLike[],
  excludeWorkspaceId?: string,
): boolean {
  return workspaces.some(other => other.id !== excludeWorkspaceId && other.title === title)
}

/**
 * One SSE `data:` frame announcing that the session/workspace inventory changed
 * (a session was created, disposed, renamed, resumed, archived, or a workspace
 * was created/renamed/attached). The optional SESSION-ID lets Emacs preserve
 * point across a list refresh; absent, the consumer just refetches. The browser
 * ignores the non-`draft` kind, so this is backward-compatible.
 */
export function sessionsChangedMessage(sessionId?: string): string {
  const payload = sessionId === undefined
    ? { kind: 'sessions-changed' }
    : { kind: 'sessions-changed', sessionId }
  return `data: ${JSON.stringify(payload)}\n\n`
}

/** One client-request RPC envelope: the POST /api/<method> body. RPC-ID is the caller-minted correlation id echoed in the response. */
export function rpcRequestFrame(method: string, rpcId: string, payload: unknown): string {
  return JSON.stringify({ type: 'client-request', rpcId, method, payload })
}

/**
 * Unwrap one server-response RPC body into its business result, or null when
 * the body is not a valid `server-response` (transport/carrier failures are the
 * caller's concern, not this function's). The error branch carries the RPC
 * error code and message; anything unrecognised collapses to `internal`.
 */
export function rpcUnwrapResponse(
  text: string,
): { ok: true; value: unknown } | { ok: false; error: { code: string; message: string } } | null {
  try {
    const parsed = JSON.parse(text) as { type?: unknown; result?: unknown }
    if (parsed.type !== 'server-response') return null
    const result = parsed.result as { ok?: unknown; value?: unknown; error?: unknown } | undefined | null
    if (result === undefined || result === null || typeof result !== 'object') return null
    if (result.ok === true) return { ok: true, value: result.value }
    if (result.ok === false) {
      const error = result.error as { code?: unknown; message?: unknown } | undefined | null
      return {
        ok: false,
        error: {
          code: typeof error?.code === 'string' ? error.code : 'internal',
          message: typeof error?.message === 'string' ? error.message : 'unknown error',
        },
      }
    }
    return null
  } catch {
    return null
  }
}

/**
 * The context-occupancy numerator the web meter uses: the projected
 * next-prompt size when one exists, else the last provider-reported sample.
 * Returns undefined when neither is present (nothing to display).
 */
export function contextUsedTokens(
  pressureTokens: number | undefined,
  projectedTokens: number | undefined,
): number | undefined {
  return projectedTokens ?? pressureTokens
}

/** One SSE `data:` frame carrying a session's context occupancy, matching the web meter. */
export function contextMessage(sessionId: string, usedTokens: number, contextWindow: number): string {
  return `data: ${JSON.stringify({ kind: 'context', sessionId, usedTokens, contextWindow })}\n\n`
}

/**
 * Minimal structural face of one `ask_user_question` item, enough to rebroadcast
 * it to Emacs. Mirrors `@deepseek-ai/dsh-user-questions`'s wire type, which the
 * mux carries verbatim; `intent` is only present for a plan-review decision.
 */
export interface AskUserQuestionOptionLike {
  label: string
  description?: string
}

export interface AskUserQuestionItemLike {
  id: string
  question: string
  detail?: string
  header?: string
  options?: readonly AskUserQuestionOptionLike[]
  multiSelect?: boolean
  intent?: { kind: 'plan-review'; approve: string }
}

/** One answer the human returns for a question. */
export interface AskUserAnswerItemLike {
  id: string
  selected: readonly string[]
  custom?: string
}

/** The payload of a mux `question/requested` frame. */
export interface AskUserPayload {
  sessionId: string
  questions: readonly AskUserQuestionItemLike[]
}

/** The payload of a mux `question/resolved` frame. */
export interface AskUserResolvedPayload {
  sessionId: string
  questionRpcId: string
  outcome: 'answered' | 'cancelled'
}

/** Narrow a mux frame payload to `question/requested`, or null. */
export function questionRequestedPayload(payload: unknown): AskUserPayload | null {
  if (typeof payload !== 'object' || payload === null) return null
  const value = payload as { type?: unknown; sessionId?: unknown; questions?: unknown }
  if (value.type !== 'question/requested') return null
  if (typeof value.sessionId !== 'string') return null
  if (!Array.isArray(value.questions) || value.questions.length === 0) return null
  for (const q of value.questions) {
    if (typeof q !== 'object' || q === null) return null
    const item = q as { id?: unknown; question?: unknown }
    if (typeof item.id !== 'string' || typeof item.question !== 'string') return null
  }
  return {
    sessionId: value.sessionId,
    questions: value.questions as readonly AskUserQuestionItemLike[],
  }
}

/** Narrow a mux frame payload to `question/resolved`, or null. */
export function questionResolvedPayload(payload: unknown): AskUserResolvedPayload | null {
  if (typeof payload !== 'object' || payload === null) return null
  const value = payload as { type?: unknown; sessionId?: unknown; questionRpcId?: unknown; outcome?: unknown }
  if (value.type !== 'question/resolved') return null
  if (typeof value.sessionId !== 'string') return null
  if (typeof value.questionRpcId !== 'string') return null
  if (value.outcome !== 'answered' && value.outcome !== 'cancelled') return null
  return { sessionId: value.sessionId, questionRpcId: value.questionRpcId, outcome: value.outcome }
}

/** One SSE `data:` frame announcing a pending question to Emacs. */
export function askUserMessage(
  questionId: string,
  sessionId: string,
  questions: readonly AskUserQuestionItemLike[],
): string {
  return `data: ${JSON.stringify({ kind: 'ask-user', questionId, sessionId, questions })}\n\n`
}

/** One SSE `data:` frame telling Emacs a question was resolved (answered/cancelled). */
export function askUserResolvedMessage(
  sessionId: string,
  questionId: string,
  outcome: 'answered' | 'cancelled',
): string {
  return `data: ${JSON.stringify({ kind: 'ask-user-resolved', sessionId, questionId, outcome })}\n\n`
}

/** The wire envelope `apiProxy.respond` consumes to settle a pending question. */
export interface QuestionAnswerEnvelope {
  rpcId: string
  result:
    | { ok: true; value: { sessionId: string; answer: { answers: readonly AskUserAnswerItemLike[] } } }
    | { ok: false; error: { code: 'cancelled'; message: string } }
}

/** Build the respond envelope that resolves a pending question with ANSWERS. */
export function questionAnswerEnvelope(
  questionId: string,
  sessionId: string,
  answers: readonly AskUserAnswerItemLike[],
): QuestionAnswerEnvelope {
  return {
    rpcId: questionId,
    result: { ok: true, value: { sessionId, answer: { answers } } },
  }
}

/** Build the respond envelope that cancels a pending question. */
export function questionCancelEnvelope(questionId: string): QuestionAnswerEnvelope {
  return {
    rpcId: questionId,
    result: { ok: false, error: { code: 'cancelled', message: 'the user cancelled ask_user_question' } },
  }
}
