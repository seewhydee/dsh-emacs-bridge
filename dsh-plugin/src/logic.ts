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

import { randomUUID, timingSafeEqual } from 'node:crypto'
import { isAbsolute, resolve } from 'node:path'
import type { SessionReportGoal, SessionReportPlan } from './session-report.ts'
import type { DetailItemKind, DetailItemRequest } from './detail-query.ts'

/** One content block, narrowed to the fields the bridge reads. */
export interface MessageBlockLike {
  type: string
  text?: string
}

/** One derived message, narrowed to the fields the bridge reads. */
export interface MessageLike {
  role: string
  content: readonly MessageBlockLike[]
  /** Producer of the message; only a `user` source is a human prompt. Absent on messages from older logs. */
  source?: { readonly kind?: string }
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
 *
 * Injected context (agent instructions, plugin notices, runtime snapshots)
 * also projects in the `user` role with text blocks, so the role alone does
 * not make a prompt: only `source.kind === 'user'` does, the same split
 * `queueCounts` applies to the steering inbox. A message with no source (an
 * older log) is kept.
 */
export function userPrompts(messages: readonly MessageLike[]): string[] {
  const prompts: string[] = []
  for (const message of messages) {
    if (message.role !== 'user') continue
    if (message.source !== undefined && message.source.kind !== 'user') continue
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
 * A turn's sanitized terminal failure, mirroring the web's `displayFailure`
 * projection exactly: the stable provider `code` (when present) plus a
 * UI-safe `message`. For `code === 'AUTH'` the message is blanked — provider
 * AUTH diagnostics may echo a masked or partially preserved credential, so
 * nothing credential-bearing crosses the bridge. Localization of known codes
 * (e.g. `AUTH` → "API key is invalid") is Emacs's job, not the host's.
 */
export interface TurnFailure {
  /** The stable failure code (`AUTH` / `QUOTA` / `ACCOUNT_SIGNED_OUT`/...). */
  code?: string
  /** The sanitized failure message; empty when the code blanks it (`AUTH`). */
  message: string
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
  /** The `seq` of the turn's `turn/end` event: the fork anchor that cuts after
   * this turn (the harness's `session/fork` boundary). Absent while the turn
   * is open, which is what makes an unfinished turn un-forkable. */
  endSeq?: number
  /** The turn's sanitized terminal failure, carried when the `turn/end`
   * reason was `error` (or a signed-out abort). Present even when the turn
   * has no text and no activity, so a first-request failure still reaches the
   * view. */
  failure?: TurnFailure
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

/** The turn-boundary facts of one session log, keyed by turn number. */
export interface TurnBoundaries {
  /** Ms-epoch `turn/start` time; first wins. */
  starts: Map<number, number>
  /** `turn/end` facts; last wins. `seq` is the fork anchor. */
  ends: Map<number, { time: number; reason?: string; seq: number; failure?: TurnFailure }>
}

/** Sanitize a raw turn failure to bridge-safe fields, mirroring the web's
 * `displayFailure` projection exactly: `AUTH` blanks the message (provider
 * AUTH diagnostics may echo a masked or partially preserved credential), and
 * every other code passes the message through unchanged. The bridge stores no
 * credentials; this keeps it that way. */
function sanitizeFailure(failure: unknown): TurnFailure {
  if (failure === null || typeof failure !== 'object') return { message: String(failure) }
  const record = failure as { code?: unknown; message?: unknown }
  const code = typeof record.code === 'string' ? record.code : undefined
  if (code === 'AUTH') return { code, message: '' }
  return {
    ...(code === undefined ? {} : { code }),
    message: typeof record.message === 'string' ? record.message : JSON.stringify(failure),
  }
}

/** The sanitized terminal failure of a `turn/end` event's data, or undefined.
 * Mirrors the web's `turn-error` node match: a reason of `kind === 'error'`
 * carries its `error` (an `LlmFailure`), and a `kind === 'aborted'` with a
 * `deepseek-account/signed-out` hook reason is synthesized as a failure so
 * `/turns` and the SSE stream report it with exactly the web's semantics. */
export function turnEndFailure(data: unknown): TurnFailure | undefined {
  if (!isRecord(data)) return undefined
  const reason = data.reason
  if (!isRecord(reason)) return undefined
  if (reason.kind === 'error') return sanitizeFailure(reason.error)
  if (reason.kind === 'aborted'
    && isRecord(reason.reason)
    && reason.reason.kind === 'hook'
    && reason.reason.reason === 'deepseek-account/signed-out') {
    return sanitizeFailure({
      message: 'Stopped because you signed out of DeepSeek.',
      code: 'ACCOUNT_SIGNED_OUT',
    })
  }
  return undefined
}

/** Project a turn's `turn/end` facts onto RECORD: its end time, reason kind,
 * fork-anchor `endSeq`, and sanitized terminal failure (when the turn failed). */
function applyTurnEnd(record: AssistantTurn, end: { time: number; reason?: string; seq: number; failure?: TurnFailure }): void {
  record.endedAt = end.time
  if (end.reason !== undefined) record.reason = end.reason
  record.endSeq = end.seq
  if (end.failure !== undefined) record.failure = end.failure
}

/**
 * Fold the log-only turn boundary events (`turn/start` / `turn/end`) of one
 * session log, keyed by turn number. A turn has one `turn/start` (first wins
 * for the start time) and at most one `turn/end` (last wins). The walk is
 * indexed rather than `for...of` so a sparse log can fall back to the array
 * position for `endSeq`.
 */
export function turnBoundaries(events: readonly SessionEventLike[]): TurnBoundaries {
  const starts = new Map<number, number>()
  const ends = new Map<number, { time: number; reason?: string; seq: number }>()
  for (let index = 0; index < events.length; index += 1) {
    const event = events[index]
    if (event === undefined) continue
    if (event.type === 'turn/start') {
      const data = event.data as { turn?: unknown } | undefined
      const turn = data?.turn
      if (typeof turn === 'number' && !starts.has(turn)) starts.set(turn, event.time)
    } else if (event.type === 'turn/end') {
      const data = event.data as { turn?: unknown; reason?: { kind?: unknown } } | undefined
      const turn = data?.turn
      if (typeof turn === 'number') {
        const kind = data?.reason?.kind
        const failure = turnEndFailure(event.data)
        ends.set(turn, {
          time: event.time,
          ...(typeof kind === 'string' ? { reason: kind } : {}),
          seq: typeof event.seq === 'number' ? event.seq : index,
          ...(failure === undefined ? {} : { failure }),
        })
      }
    }
  }
  return { starts, ends }
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
 * `endedAt`, `reason`, and the `turn/end`'s `endSeq` (the fork anchor) are
 * folded from a separate pass over the log.
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

  // Turn boundaries are log-only, so fold start/end facts from the events
  // themselves; the fold is shared with the activity-only turn synthesis.
  const { starts, ends } = turnBoundaries(log.events)

  const turns: AssistantTurn[] = []
  for (const turn of order) {
    const segments = byTurn.get(turn)!
    const record: AssistantTurn = {
      turn,
      startedAt: starts.get(turn) ?? segments[0]!.time,
      segments: [...segments],
    }
    const end = ends.get(turn)
    if (end !== undefined) applyTurnEnd(record, end)
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
 *
 * The record list keeps that property, but a turn's *activity* entries do
 * not: `MAX_ACTIVITY_TURNS` can drop an older turn's entries between fetches,
 * and turns below `since` are never re-sent, so an Emacs client can hold
 * phantom activity for them until a full (non-incremental) refetch.  A live
 * activity entry additionally *shrinks* at settlement: the transient entry is
 * removed and replaced by the committed one, so an equal epoch does not mean
 * the boundary turn's activity can only have grown.  That is sound anyway
 * because `since` is inclusive and the boundary turn is re-sent in full; a
 * turn below `since` only loses phantom activity, a bounded display lag, not a
 * correctness hole — `/turns` remains the authority whenever it is refetched
 * in full.
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
  /** The event's log position. Present on real session events (the log is
   * seq-indexed, so it also equals the array index); optional here so
   * structural fixtures need not carry it. */
  seq?: number
  /**
   * How a message-producing event entered the surface: `'append'` or a
   * replacement descriptor. The changed-files fold reads it to ignore
   * compaction replacement copies (the harness check is `isAppendSurfaceEvent`
   * in `@deepseek-ai/dsh-session/surface`; this module carries its own
   * structural guard of the same name).
   */
  surfaceOp?: unknown
}

/** Structural view of one live session, enough for targeting and listing. */
export interface LiveSessionLike {
  id: string
  header: { cwd?: string; createdAt: number }
  events: readonly SessionEventLike[]
  /** Whether the live agent is actively processing a turn (not yet quiesced). */
  running: boolean
  /**
   * The host's own `workingDirectory` projection value, when the caller can
   * read it: a string, or null for "no directory recorded". Optional so a
   * caller that only has a header and a log still gets the folded fallback;
   * an explicit null is authoritative and does not fall through.
   */
  cwd?: string | null
}

/** Structural view of one persisted session header. */
export interface SessionHeaderLike {
  id: string
  cwd?: string
  createdAt: number
  origin?: string
  title?: string | null
  /** The preset the session was created with (creation fact, deep-frozen). */
  agentPreset?: string
}

/**
 * The preset a session actually runs, newest selection winning. The header
 * supplies the creation-time value; every later switch is a logged
 * `agent-preset/selected` event, so the last one is the answer. This is the
 * in-repo replica of the harness's `agentPreset` session-projection fold
 * (init from `header.agentPreset`, last selection event wins) — the harness
 * removed its standalone `resolveSessionPreset` helper in favor of that
 * projection, and the bridge reads cold logs, not live projections.
 */
export function sessionPreset(
  header: { agentPreset?: string },
  events: readonly SessionEventLike[],
): string | undefined {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event?.type !== 'agent-preset/selected') continue
    const preset = (event.data as { agentPreset?: unknown } | undefined)?.agentPreset
    if (typeof preset === 'string') return preset
  }
  return header.agentPreset
}

/**
 * The session's effective working directory, folded from its raw log: the
 * last well-formed directory-move event's cwd, else the header's cwd.
 *
 * This is the **fallback** for callers that hold only a header and a log. The
 * host's own `workingDirectory` session projection is the authoritative read
 * wherever the bridge has a live Session (see `sessionCwd` in `index.ts`) or an
 * observation (see `sessionReport`), and it applies whichever directory event
 * the running host applies. The two spellings are both honored here because
 * this fallback must serve the compatibility target (`0.2.2-rc.4`, which
 * records only `working-directory/change`) and master (which records
 * `workspace-root/change`); newest event wins. On a host that ignores the
 * deprecated spelling, a stored log whose only moves are legacy reads as its
 * header project — the one divergence this fallback accepts, and only where no
 * host projection is available.
 *
 * @param header - a session header carrying the original project directory.
 * @param events - the session's raw event log.
 * @returns the effective directory, or undefined when neither source names one.
 */
export function effectiveCwd(
  header: { cwd?: string },
  events: readonly SessionEventLike[],
): string | undefined {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (!movesWorkingDirectory(event?.type)) continue
    const cwd = (event.data as { cwd?: unknown } | undefined)?.cwd
    if (typeof cwd === 'string' && cwd !== '') return cwd
  }
  return header.cwd
}

/**
 * Whether a session event `type` is a directory move: the current
 * `workspace-root/change`, or the deprecated `working-directory/change` a
 * pre-move release recorded.
 *
 * Every raw-log fold uses this: the current-directory fallback
 * (`effectiveCwd`) because it must serve both the compatibility target and
 * master, and the historical folds (changed files, turn detail) because they
 * resolve each recorded path against the directory in effect *when it was
 * written*.
 *
 * @param type - a session event's `type`.
 * @returns whether the event data carries the directory from that point on.
 */
function movesWorkingDirectory(type: unknown): boolean {
  return type === 'workspace-root/change' || type === 'working-directory/change'
}

/**
 * Whether SEQ is the seq of a `turn/end` event in EVENTS — the completed-turn
 * boundary `POST /fork` accepts as an explicit anchor.
 *
 * DSH 0.1.7 widened the fork seam: an explicit `atSeq` is now an exact
 * inclusive event cut, and a cut inside an open turn is closed with synthetic
 * "forked" results instead of being refused. The bridge keeps its own
 * completed-turn-only contract (Emacs branches a shown, completed turn and
 * quotes the anchor in its docs), so the route validates the anchor against the
 * source log rather than inheriting a mid-turn cut.
 *
 * @param events - the source session's raw event log.
 * @param seq - the requested fork anchor.
 * @returns whether the anchor names a completed turn's `turn/end` seq.
 */
export function isCompletedTurnAnchor(events: readonly SessionEventLike[], seq: number): boolean {
  return events.some(event => event.seq === seq && event.type === 'turn/end')
}

// -- Changed files (the DSH-View footer's attribution) -----------------------
//
// The fold walks the *raw log*, not the session surface: `tool/call` is
// log-only (it never becomes a surface node), so a surface walk could never see
// the arguments that name a mutated file. This is a deliberate difference from
// `assistantTurns`, which walks the surface.
//
// The mutation vocabulary replicated below lives in the web client's
// turn-deliverables fold
// (`packages/client/ui-deliverables/src/client/turn-deliverables.ts`) — it is
// client-side, not a host contract, so it is mirrored here rather than
// imported. Re-verify it (and the `tool/result.meta.diffs` shape) on every DSH
// version bump; see AGENTS.md.
//
// Relative paths resolve against the directory current *when the call ran*, not
// the header's original project: each `workspace-root/change` (or, in an old
// log, the deprecated `working-directory/change`) moves it for the calls that
// follow (see `movesWorkingDirectory`). The header cwd is only the starting
// point.

/** Maximum changed files named by one session's fold. */
export const MAX_CHANGED_FILES = 200

/** Maximum changed files attributed to one turn by the fold. */
export const MAX_CHANGED_FILES_PER_TURN = 50

/**
 * One file a session's `write` / `edit` / mutating `str_replace_editor` calls
 * successfully modified. Paths keep first-seen order and appear once, so a file
 * written and then edited in the same turn is one entry.
 */
export interface ChangedFile {
  /** The exact path spelling the tool call carried. */
  path: string
  /** `resolve(cwd, path)` against the directory in effect at the call, or the
   * logged spelling when no directory was known. */
  absolute: string
  /** The mutation operation that first named the file, e.g. `write`,
   * `edit`, `str_replace_editor:create`. */
  op: string
  /** The first turn in which the file was changed. */
  firstTurn: number
  /** The last turn in which the file was changed. */
  lastTurn: number
  /** Every turn in which the file was changed, ascending. */
  turns: number[]
  /** Whether a `deliverables/presented` event names the file. */
  delivered?: boolean
}

/** The bounded result of the changed-files fold. */
export interface ChangedFilesResult {
  /** Changed files in first-seen order. */
  files: ChangedFile[]
  /** Per-turn attribution: turn number -> the files changed in it. */
  byTurn: Map<number, ChangedFile[]>
  /** Whether a cap dropped part of the result. */
  truncated: boolean
}

/** One supported mutation call's path and operation label. */
interface MutationCall {
  path: string
  op: string
}

/** One `tool/call` event's pairing facts, or null when malformed. */
interface ToolCallFact {
  callId: string
  name: string
  arguments: string
  turn: number
}

/** One `tool/result` event's pairing facts, or null when malformed. */
interface ToolResultFact {
  callId: string
  failed: boolean
}

/** Whether VALUE is a plain (non-array) object. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function recordOf(value: unknown): Record<string, unknown> | undefined {
  return isRecord(value) ? value : undefined
}

/** The pairing facts of one `tool/call` event, or null. */
function toolCallFact(event: SessionEventLike): ToolCallFact | null {
  if (event.type !== 'tool/call') return null
  const data = event.data
  if (!isRecord(data)) return null
  const { callId, name, turn } = data
  const argsRaw = data.arguments
  if (typeof callId !== 'string' || typeof name !== 'string'
    || typeof argsRaw !== 'string' || typeof turn !== 'number') return null
  return { callId, name, arguments: argsRaw, turn }
}

/**
 * The pairing facts of one `tool/result` event, or null. Only an append-origin
 * result counts: a compaction replacement copy must not settle a mutation call
 * a second time (the harness's `isAppendSurfaceEvent`). The call id is read from
 * `message.source.callId`, falling back to the message's own `toolCallId`.
 *
 * The failure flag is read from the tool-role message itself. DSH 0.1.7
 * flattened tool results into first-class `role: 'tool'` messages, moving
 * `isError` off the first content block onto the message (the same read the web
 * client's turn-deliverables fold makes); reading the block would mark every
 * failed mutation as a change.
 */
function toolResultFact(event: SessionEventLike): ToolResultFact | null {
  if (event.type !== 'tool/result' || event.surfaceOp !== 'append') return null
  const data = event.data
  if (!isRecord(data)) return null
  const message = data.message
  if (!isRecord(message)) return null
  const failed = message.isError === true
  const source = message.source
  const callId = isRecord(source) && typeof source.callId === 'string'
    ? source.callId
    : typeof message.toolCallId === 'string' ? message.toolCallId : null
  return callId === null ? null : { callId, failed }
}

/** A non-blank path preserves the exact spelling supplied to the tool. */
function pathValue(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value : null
}

/** Validate the fields an `edit` execution requires. */
function validEditArgs(args: Record<string, unknown>): boolean {
  return typeof args.old_string === 'string'
    && args.old_string.length > 0
    && typeof args.new_string === 'string'
    && args.old_string !== args.new_string
    && (args.replace_all === undefined || typeof args.replace_all === 'boolean')
}

/** Extract a path only from a complete mutating editor command. */
function editorMutationCall(args: Record<string, unknown>): MutationCall | null {
  const path = pathValue(args.path)
  if (path === null) return null
  switch (args.command) {
    case 'create':
      return typeof args.file_text === 'string'
        ? { path, op: 'str_replace_editor:create' } : null
    case 'str_replace':
      return typeof args.old_str === 'string'
        && args.old_str.length > 0
        && (args.new_str === undefined || typeof args.new_str === 'string')
        ? { path, op: 'str_replace_editor:str_replace' } : null
    case 'insert':
      return typeof args.insert_line === 'number'
        && Number.isInteger(args.insert_line)
        && args.insert_line >= 0
        && typeof args.new_str === 'string'
        ? { path, op: 'str_replace_editor:insert' } : null
    default:
      return null
  }
}

/**
 * Extract the path and operation from a supported first-party mutation call,
 * replicating the web client's `mutationPath`. Reads, malformed calls,
 * unsupported tools, and incomplete commands contribute nothing.
 */
function mutationCall(name: string, argsRaw: string): MutationCall | null {
  let args: unknown
  try {
    args = JSON.parse(argsRaw) as unknown
  } catch {
    return null
  }
  if (!isRecord(args)) return null
  switch (name) {
    case 'write': {
      const path = typeof args.content === 'string' ? pathValue(args.file_path) : null
      return path === null ? null : { path, op: 'write' }
    }
    case 'edit': {
      if (!validEditArgs(args)) return null
      const path = pathValue(args.file_path)
      return path === null ? null : { path, op: 'edit' }
    }
    case 'str_replace_editor':
      return editorMutationCall(args)
    default:
      return null
  }
}

/**
 * Fold a session log into the files its tool calls successfully changed.
 *
 * Walks `events` in log order, pairing each `tool/call` that names a mutation
 * with a later successful, append-surface `tool/result` for the same call id.
 * A file is recorded once per turn (first-seen order) and once in `files`
 * (first-seen order), with every turn that touched it. `deliverables/presented`
 * marks a file `delivered` when its path (or its resolution against CWD)
 * matches. Bounded by `MAX_CHANGED_FILES` and `MAX_CHANGED_FILES_PER_TURN`;
 * `truncated` reports a dropped entry rather than growing without limit.
 *
 * @param events - the session's raw event log (log-only events included).
 * @param cwd - the session's original project directory (the header cwd), the
 *   starting point for the `absolute` resolution: each directory-move event
 *   (`workspace-root/change`, or the deprecated `working-directory/change` in
 *   an old log) moves it for the calls that follow.
 *   Absent (a header without a cwd) keeps the logged path verbatim.
 */
export function changedFiles(
  events: readonly SessionEventLike[],
  cwd?: string,
): ChangedFilesResult {
  const resolveAgainst = (base: string | undefined, path: string): string =>
    base === undefined ? path : resolve(base, path)
  // The directory in effect as the walk advances: the original project until a
  // change moves it, then that directory's spelling. A mutation records the
  // directory current at its call, not its result, so a `cd` between the two
  // cannot re-resolve an already-issued call.
  let currentCwd = cwd
  const pending = new Map<string, MutationCall & { turn: number; cwd?: string }>()
  const files: ChangedFile[] = []
  const byPath = new Map<string, ChangedFile>()
  const byTurn = new Map<number, ChangedFile[]>()
  const seenPerTurn = new Map<number, Set<string>>()
  let truncated = false

  for (const event of events) {
    if (movesWorkingDirectory(event.type)) {
      const next = (event.data as { cwd?: unknown } | undefined)?.cwd
      if (typeof next === 'string' && next !== '') currentCwd = next
      continue
    }
    if (event.type === 'tool/call') {
      const call = toolCallFact(event)
      if (call !== null) {
        const mutation = mutationCall(call.name, call.arguments)
        if (mutation !== null) pending.set(call.callId, { ...mutation, turn: call.turn, cwd: currentCwd })
      }
      continue
    }
    if (event.type === 'tool/result') {
      const result = toolResultFact(event)
      if (result === null || result.failed) continue
      const call = pending.get(result.callId)
      if (call === undefined) continue
      let seen = seenPerTurn.get(call.turn)
      if (seen === undefined) {
        seen = new Set()
        seenPerTurn.set(call.turn, seen)
      }
      if (seen.has(call.path)) continue
      if (seen.size >= MAX_CHANGED_FILES_PER_TURN) {
        truncated = true
        continue
      }
      let file = byPath.get(call.path)
      if (file === undefined) {
        if (files.length >= MAX_CHANGED_FILES) {
          truncated = true
          continue
        }
        file = {
          path: call.path,
          absolute: resolveAgainst(call.cwd, call.path),
          op: call.op,
          firstTurn: call.turn,
          lastTurn: call.turn,
          turns: [call.turn],
        }
        files.push(file)
        byPath.set(call.path, file)
      } else if (!file.turns.includes(call.turn)) {
        file.turns.push(call.turn)
        file.lastTurn = call.turn
      }
      seen.add(call.path)
      const attributed = byTurn.get(call.turn)
      if (attributed === undefined) byTurn.set(call.turn, [file])
      else if (!attributed.includes(file)) attributed.push(file)
      continue
    }
    if (event.type === 'deliverables/presented') {
      const data = event.data
      if (!isRecord(data) || !Array.isArray(data.files)) continue
      for (const entry of data.files) {
        if (!isRecord(entry) || typeof entry.path !== 'string') continue
        const file = byPath.get(entry.path)
          ?? files.find(candidate => candidate.absolute === resolveAgainst(currentCwd, entry.path as string))
        if (file !== undefined) file.delivered = true
      }
    }
  }
  return { files, byTurn, truncated }
}

// -- Turn activity (the DSH-View process stream) -----------------------------
//
// The fold walks the *raw log* like the changed-files fold above (`tool/call`
// is log-only), so it sees call arguments and reasoning blocks that never
// become surface nodes. Two log facts drive the guards:
//
// - `tool/result` and `assistant/message` are surface events; a compaction
//   replacement copy must be skipped (`isAppendSurfaceEvent`), or reasoning
//   would be reported twice. `tool/call` is never a surface event.
// - A fully compaction-shadowed turn still has raw-log activity (its
//   `tool/call` events survive, and so do the original 'append' message
//   events, which the surface replace shadows by seq), so `withActivityTurns`
//   synthesizes a record only for a turn that still owns a surface node.
//
// The summary folds mirror web-client previews: the tool-call detail mirrors
// the process-detail fold
// (`packages/client/ui-chat/src/client/conversation-nodes/process-activity.ts`)
// and the thinking summary mirrors `ReasoningRow`'s settled firstLine. Both
// are client-side, not a host contract, so they are mirrored here rather than
// imported. Re-verify them on every DSH version bump; see AGENTS.md.

/** Maximum activity entries retained for one turn. Once the cap is reached the
 * oldest entries are dropped, so the newest activity — the part a view
 * following a live turn is watching — always remains. */
export const MAX_ACTIVITY_ENTRIES_PER_TURN = 500

/** Maximum activity-bearing turns retained, newest first. Older turns get no
 * activity (a retention window, deliberately silent rather than reported). */
export const MAX_ACTIVITY_TURNS = 40

/** Cap on a tool-call summary, in graphemes. */
export const MAX_ACTIVITY_DETAIL_CHARS = 160

/** Cap on a thinking summary, in graphemes. */
export const MAX_ACTIVITY_THINKING_CHARS = 160

/** Argument keys, in priority order, whose value names a tool call's one-line
 * task detail. Mirrors the web client's `LIVE_TOOL_DETAIL_KEYS`. */
const ACTIVITY_DETAIL_KEYS = [
  'title', 'description', 'objective', 'task', 'task_name', 'name', 'question',
  'questions', 'prompt', 'message', 'command', 'cmd', 'queries', 'query',
  'pattern', 'url', 'uri', 'file_path', 'path', 'target', 'action', 'status',
] as const

/** Grapheme segmenter for the summary caps: the harness caps graphemes, not
 * code units, so a cap never splits an emoji or a combining sequence. */
const ACTIVITY_SEGMENTER = new Intl.Segmenter(undefined, { granularity: 'grapheme' })

/** The fields every activity entry carries. */
export interface ActivityEntryBase {
  /** The source event's log seq (the array position when the log is sparse). */
  seq: number
  /** Disambiguates entries derived from one event: the 0-based reasoning-block
   * index for `thinking`, 0 for tool entries. */
  ord: number
  /** The source event's ms-epoch time. */
  time: number
  /** The harness turn and step the entry belongs to. */
  turn: number
  step: number
}

/** One tool call the agent dispatched. */
export interface ActivityToolCall extends ActivityEntryBase {
  kind: 'tool-call'
  callId: string
  name: string
  /** One-line task detail folded from the call's arguments. */
  summary: string
}

/** One tool call's result, as a status line. */
export interface ActivityToolResult extends ActivityEntryBase {
  kind: 'tool-result'
  callId: string
  name: string
  isError: boolean
}

/** One reasoning block, reduced to a one-line summary. The full reasoning text
 * is deliberately never part of the fold's output. */
export interface ActivityThinking extends ActivityEntryBase {
  kind: 'thinking'
  summary: string
  /** A committed entry always has a log seq; the explicit false keeps the
   * live variant's `inFlight: true` discriminant narrowable. */
  inFlight?: false
}

/**
 * The active assistant attempt's reasoning block, reduced to a one-line
 * summary.  It has no `seq`: log-sequence identity belongs to committed
 * events, so the transient identity is the bridge-minted `inFlightId` plus
 * the committed-style `ord`.  Never returned by `turnActivity`; the host's
 * process-local registry supplies it to the `/turns` merge.
 */
export interface ActivityInFlightThinking {
  kind: 'thinking'
  inFlight: true
  /** The bridge's opaque selector for this attempt, minted per accepted start. */
  inFlightId: string
  /** The harness attempt id (`session-id:attempt-counter`). */
  attemptId: string
  /** The attempt's latest stream revision. */
  revision: number
  ord: number
  time: number
  turn: number
  step: number
  summary: string
}

export type ActivityEntry = ActivityToolCall | ActivityToolResult | ActivityThinking | ActivityInFlightThinking

/** One turn's bounded activity stream. */
export interface TurnActivity {
  /** Entries in log order, which is also the render order: a step's reasoning
   * precedes its tool entries, because the step's assistant message is
   * appended before the calls dispatch. */
  entries: ActivityEntry[]
  /** Seqs of this turn's append `assistant/message` events: the surface
   * visibility evidence `withActivityTurns` tests. Never serialized. */
  messageSeqs: number[]
}

/** Whether EVENT entered the surface at its own log position. A compaction
 * replacement copy (a `replace` surfaceOp) must not be folded a second time;
 * this is the same guard `toolResultFact` applies to tool results. */
function isAppendSurfaceEvent(event: SessionEventLike): boolean {
  return event.surfaceOp === 'append'
}

/** The graphemes of TEXT, for the summary caps. */
function graphemes(text: string): string[] {
  return Array.from(ACTIVITY_SEGMENTER.segment(text), part => part.segment)
}

/**
 * One summary line from an arbitrary argument value: a string passes through,
 * an array all of whose items are strings joins with `", "`, anything else is
 * empty. Whitespace collapses to single spaces and the result is capped at CAP
 * graphemes with an ellipsis — the web client's `normalizeLiveToolDetail`,
 * including its array arm (a bare string-typed helper would drop
 * `queries`-style values and fall through to the tool name).
 */
function normalizeActivityDetail(value: unknown, cap: number): string {
  const text = typeof value === 'string'
    ? value
    : Array.isArray(value) && value.every(item => typeof item === 'string')
      ? (value as readonly string[]).join(', ')
      : ''
  const normalized = text.replace(/\s+/g, ' ').trim()
  if (normalized === '') return ''
  const chars = graphemes(normalized)
  return chars.length <= cap ? normalized : `${chars.slice(0, cap - 1).join('').trimEnd()}\u2026`
}

/** The first question text of an `ask_user_question`-style `questions` value. */
function activityQuestionDetail(value: unknown): string {
  if (!Array.isArray(value)) return ''
  for (const item of value) {
    if (!isRecord(item)) continue
    const detail = normalizeActivityDetail(item.question, MAX_ACTIVITY_DETAIL_CHARS)
    if (detail !== '') return detail
  }
  return ''
}

/**
 * One tool call's one-line detail, folded from its serialized arguments: the
 * first present key of the activity detail vocabulary whose normalized value
 * is non-empty, else the normalized NAME. Mirrors the web client's
 * `liveToolDetail`, which wraps even the bare-name fallback in
 * `normalizeLiveToolDetail`.
 */
export function activityToolDetail(name: string, argumentsRaw: string): string {
  let args: unknown
  try {
    args = JSON.parse(argumentsRaw) as unknown
  } catch {
    return normalizeActivityDetail(name, MAX_ACTIVITY_DETAIL_CHARS)
  }
  if (!isRecord(args)) return normalizeActivityDetail(name, MAX_ACTIVITY_DETAIL_CHARS)
  for (const key of ACTIVITY_DETAIL_KEYS) {
    if (!(key in args)) continue
    const detail = key === 'questions'
      ? activityQuestionDetail(args[key])
      : normalizeActivityDetail(args[key], MAX_ACTIVITY_DETAIL_CHARS)
    if (detail !== '') return detail
  }
  return normalizeActivityDetail(name, MAX_ACTIVITY_DETAIL_CHARS)
}

/**
 * One reasoning block's one-line summary: the block's first line, `**`
 * markers stripped, whitespace collapsed, capped at
 * {@link MAX_ACTIVITY_THINKING_CHARS} graphemes. This is parity with the web
 * client's settled `ReasoningRow` preview (`firstLine`): the fold only ever
 * sees committed blocks, so the streaming "latest completed paragraph"
 * preview does not apply. Returns '' when the first line normalizes to
 * nothing, which the fold drops.
 */
export function activityThinkingSummary(text: string): string {
  const newline = text.indexOf('\n')
  const line = newline === -1 ? text : text.slice(0, newline)
  return normalizeActivityDetail(line.replaceAll('**', ''), MAX_ACTIVITY_THINKING_CHARS)
}

function appendActivityEntry(activity: TurnActivity, entry: ActivityEntry): void {
  if (activity.entries.length >= MAX_ACTIVITY_ENTRIES_PER_TURN) activity.entries.shift()
  activity.entries.push(entry)
}

function retainActivityTurns(activity: Map<number, TurnActivity>): void {
  if (activity.size <= MAX_ACTIVITY_TURNS) return
  const keep = new Set([...activity.keys()].sort((a, b) => a - b).slice(-MAX_ACTIVITY_TURNS))
  for (const turn of [...activity.keys()]) {
    if (!keep.has(turn)) activity.delete(turn)
  }
}

/**
 * Fold a session log into its turn activity: the tool calls dispatched, their
 * results, and one-line reasoning summaries, grouped by turn and in log order.
 *
 * Each entry is attributed from its own `data.turn`/`data.step` (never a
 * tracked "current turn", which would misfile a compaction replay under the
 * turn that re-logged it), and non-append surface copies are skipped. Bounded
 * by {@link MAX_ACTIVITY_ENTRIES_PER_TURN} per turn — a sliding window that
 * drops the oldest entries, so a live turn's newest activity always streams —
 * and by {@link MAX_ACTIVITY_TURNS} turns (the oldest dropped silently, so the
 * newest turn is always kept). The full reasoning text never enters the
 * result.
 */
export function turnActivity(events: readonly SessionEventLike[]): Map<number, TurnActivity> {
  const byTurn = new Map<number, TurnActivity>()
  const messageSeqsByTurn = new Map<number, number[]>()
  const callNames = new Map<string, string>()

  const activityFor = (turn: number): TurnActivity => {
    let activity = byTurn.get(turn)
    if (activity === undefined) {
      activity = { entries: [], messageSeqs: [] }
      byTurn.set(turn, activity)
    }
    return activity
  }

  const push = (entry: ActivityEntry): void => {
    appendActivityEntry(activityFor(entry.turn), entry)
  }

  for (let index = 0; index < events.length; index += 1) {
    const event = events[index]
    if (event === undefined) continue
    const seq = typeof event.seq === 'number' ? event.seq : index
    if (event.type === 'tool/call') {
      const call = toolCallFact(event)
      const step = isRecord(event.data) ? event.data.step : undefined
      if (call === null || typeof step !== 'number') continue
      callNames.set(call.callId, call.name)
      push({
        kind: 'tool-call',
        seq,
        ord: 0,
        time: event.time,
        turn: call.turn,
        step,
        callId: call.callId,
        name: call.name,
        summary: activityToolDetail(call.name, call.arguments),
      })
      continue
    }
    if (event.type === 'tool/result') {
      if (!isAppendSurfaceEvent(event)) continue
      const result = toolResultFact(event)
      const data = isRecord(event.data) ? event.data : undefined
      const turn = data?.turn
      const step = data?.step
      if (result === null || typeof turn !== 'number' || typeof step !== 'number') continue
      push({
        kind: 'tool-result',
        seq,
        ord: 0,
        time: event.time,
        turn,
        step,
        callId: result.callId,
        name: callNames.get(result.callId) ?? 'tool',
        isError: result.failed,
      })
      continue
    }
    if (event.type !== 'assistant/message') continue
    if (!isAppendSurfaceEvent(event)) continue
    const data = isRecord(event.data) ? event.data : undefined
    const turn = data?.turn
    const step = data?.step
    if (typeof turn !== 'number' || typeof step !== 'number') continue
    // Recorded even when the message carries no reasoning: the seq is the
    // surface-visibility evidence for a turn whose only activity is a pending
    // tool call (no text segment, no thinking block).
    const seqs = messageSeqsByTurn.get(turn)
    if (seqs === undefined) messageSeqsByTurn.set(turn, [seq])
    else seqs.push(seq)
    const message = data?.message
    const content = isRecord(message) && Array.isArray(message.content) ? message.content : undefined
    if (content === undefined) continue
    let ord = 0
    for (const block of content) {
      if (!isRecord(block) || block.type !== 'reasoning') continue
      const summary = typeof block.text === 'string' ? activityThinkingSummary(block.text) : ''
      if (summary !== '') {
        push({ kind: 'thinking', seq, ord, time: event.time, turn, step, summary })
      }
      ord += 1
    }
  }

  for (const [turn, activity] of byTurn) {
    const seqs = messageSeqsByTurn.get(turn)
    if (seqs !== undefined) activity.messageSeqs = seqs
  }

  // The retention window is applied last, newest turn first, so the live turn
  // is never the one dropped. Turns dropped here simply have no activity, like
  // a turn whose per-turn window has slid past its start.
  retainActivityTurns(byTurn)
  return byTurn
}

/**
 * Insert a synthetic record for every activity-bearing turn that has no
 * text-bearing record, so activity is visible from a turn's first tool call or
 * reasoning block rather than only from its first reply. A turn that also
 * failed carries its failure detail on that record.
 *
 * SURFACE-SEQS is the set of seqs currently on the model-visible surface
 * (`Session.surface.nodes`). A turn whose append assistant messages are all
 * shadowed by a compaction replacement is deliberately not resurrected from
 * its surviving raw-log events, matching the surface walk's "shadowed turns
 * simply vanish" rule (`assistantTurns`). Records come back in ascending turn
 * order, as `assistantTurns` produces them; `/turns` reverses once.
 *
 * A text-less, activity-less turn that ended in failure is synthesized too: a
 * first-request auth/network failure emits no assistant message, tool call, or
 * reasoning, so neither the text fold nor the activity fold can host it, yet
 * the web still renders its terminal error row. These failure-only records are
 * keyed off the `turn/end` boundary facts (a log fact the web also retains),
 * so they survive a compaction that shadows a failed turn's partial text.
 */
export function withActivityTurns(
  turns: readonly AssistantTurn[],
  activity: ReadonlyMap<number, TurnActivity>,
  boundaries: TurnBoundaries,
  surfaceSeqs: ReadonlySet<number>,
): AssistantTurn[] {
  const records = [...turns].sort((a, b) => a.turn - b.turn)
  const present = new Set(records.map(record => record.turn))
  const synthetic = new Map<number, AssistantTurn>()
  for (const [turn, act] of activity) {
    if (present.has(turn) || act.entries.length === 0) continue
    const visible = act.messageSeqs.some(seq => surfaceSeqs.has(seq))
      || act.entries.some(entry => entry.kind === 'thinking' && entry.inFlight === true
        ? !boundaries.ends.has(entry.turn)
        : (entry.kind === 'tool-result' || entry.kind === 'thinking') && surfaceSeqs.has(entry.seq))
    if (!visible) continue
    const start = boundaries.starts.get(turn) ?? act.entries[0]?.time
    if (start === undefined) continue
    const record: AssistantTurn = { turn, startedAt: start, segments: [] }
    const end = boundaries.ends.get(turn)
    if (end !== undefined) applyTurnEnd(record, end)
    synthetic.set(turn, record)
  }
  // Failure-only synthesis: every failed `turn/end` that no text or activity
  // record already covers gets its own text-less record, so a failed turn with
  // zero output still reaches the view with its failure detail. Keyed off the
  // boundary facts, so a compacted failed turn survives as a failure record.
  for (const [turn, end] of boundaries.ends) {
    if (present.has(turn) || synthetic.has(turn) || end.failure === undefined) continue
    const record: AssistantTurn = {
      turn,
      startedAt: boundaries.starts.get(turn) ?? end.time,
      segments: [],
    }
    applyTurnEnd(record, end)
    synthetic.set(turn, record)
  }
  if (synthetic.size === 0) return records
  const list = [...synthetic.values()].sort((a, b) => a.turn - b.turn)
  const merged: AssistantTurn[] = []
  let next = 0
  for (const record of records) {
    while (next < list.length && list[next]!.turn < record.turn) {
      merged.push(list[next]!)
      next += 1
    }
    merged.push(record)
  }
  while (next < list.length) {
    merged.push(list[next]!)
    next += 1
  }
  return merged
}

/**
 * Whether EVENT may add turn activity, i.e. whether the host should nudge
 * Emacs to refetch `/turns`. Pure so the SSE side carries no fold decisions
 * of its own. This is a conservative over-approximation of `turnActivity`,
 * not an exact mirror: a `tool/call` passes unconditionally (the fold may
 * still drop it as malformed), and a reasoning block of `"**"`-only text
 * nudges although its summary normalizes to nothing. Over-nudging is
 * harmless — Emacs refetches and folds the same activity.
 */
export function activityRelevantEvent(event: SessionEventLike): boolean {
  if (event.type === 'tool/call') return true
  if (event.type === 'tool/result') return isAppendSurfaceEvent(event)
  if (event.type !== 'assistant/message' || !isAppendSurfaceEvent(event)) return false
  const data = event.data
  if (!isRecord(data)) return false
  const message = data.message
  if (!isRecord(message) || !Array.isArray(message.content)) return false
  return message.content.some(block => isRecord(block)
    && block.type === 'reasoning'
    && typeof block.text === 'string'
    && block.text.trim() !== '')
}

// -- In-flight reasoning (process-local assistant streams) -------------------
//
// The durable log carries no text until an assistant attempt settles, so the
// host accumulates the harness's transient `agent/assistant-stream` frames
// itself.  This section is the whole bounded model: a per-session record with
// one active attempt, bounded reasoning text per attempt, and a small
// metadata-only handoff list that lets a selector opened before
// settlement resolve to the committed item afterwards.
//
// The live path exposes reasoning only.  Streaming tool-call blocks are
// not-yet-executed proposals with incomplete arguments, and assistant text is
// not turn activity; both stay out.  Nothing here produces full text for
// `/turns` or SSE: `entries` is summary-only, and the retained prefix leaves
// the process only through the explicit `/details/item` read.

/** Total reasoning bytes retained for one active attempt, across its blocks. */
export const MAX_INFLIGHT_REASONING_BYTES = 1024 * 1024

/** Cap on one block's retained pieces; a full block is coalesced into one. */
export const MAX_INFLIGHT_PIECES_PER_BLOCK = 64

/** Session records (active text plus handoffs) retained process-wide, LRU. */
export const MAX_INFLIGHT_SESSIONS = 8

/** Settled-attempt handoffs retained per session, oldest evicted. */
export const MAX_INFLIGHT_HANDOFFS_PER_SESSION = 8

/** Settled survivor ordinals retained per handoff (interrupted translation). */
export const MAX_INFLIGHT_HANDOFF_SURVIVORS = 256

/** Maximum accepted `inFlightId` length, in characters. */
export const MAX_INFLIGHT_ID_CHARS = 128

/** The bounded first-line buffer used only to detect summary transitions. */
const MAX_INFLIGHT_FIRST_LINE_CHARS = 512

/** One reasoning block of the active attempt. */
interface InFlightReasoningBlock {
  /** Zero-based reasoning ordinal, matching the committed fold. */
  ord: number
  firstTime: number
  /** Retained text pieces; joined only on a read, never on every delta. */
  pieces: string[]
  bytes: number
  /** Whether any non-whitespace text was observed, retained or discarded. */
  hasNonWhitespace: boolean
  /** This block's retained prefix hit the attempt's byte cap. */
  truncated: boolean
  closed: boolean
  sawDelta: boolean
  /** Bounded first line, for summary and first-line-completion transitions. */
  firstLine: string
  firstLineDone: boolean
  summaryNotified: boolean
  newlineNotified: boolean
}

/** One active assistant attempt. */
interface InFlightAttempt {
  /** Bridge-minted selector, independent of the harness attempt id. */
  inFlightId: string
  attemptId: string
  revision: number
  turn: number
  step: number
  /** The next expected dense chunk index. */
  nextIndex: number
  /** Total bytes retained by every block of this attempt. */
  retainedBytes: number
  blocks: Map<number, InFlightReasoningBlock>
  /** Raw indexes a `block-start` declared non-reasoning. */
  otherBlocks: Set<number>
  ordCounter: number
}

/** One settled attempt's metadata; never contains settled text. */
export interface InFlightHandoff {
  inFlightId: string
  turn: number
  eventType?: 'assistant/message' | 'assistant/attempt'
  seq?: number
  abandoned: boolean
  /** Live reasoning ordinals that observed non-whitespace text. */
  survivors: number[]
}

/** One session's process-local in-flight state. */
interface InFlightSessionRecord {
  /** The agent that established this record; a replaced agent cannot borrow it. */
  owner?: unknown
  active?: InFlightAttempt
  handoffs: InFlightHandoff[]
}

/** One registry operation's notification decision. */
export interface InFlightEffect {
  /** Refetch the named session's `/turns` (summary changed, or entry removed). */
  nudge: boolean
  /** The affected attempt's turn, informational to the nudge. */
  turn?: number
  /** A record evicted by the session LRU whose visible entry disappeared. */
  evicted?: { sessionId: string; turn?: number }
}

const NO_INFLIGHT_EFFECT: InFlightEffect = { nudge: false }

/** The latest retained text of one live block. */
function inFlightBlockText(block: InFlightReasoningBlock): string {
  return block.pieces.join('')
}

/** The attempt's visible (summary-producing) entry exists. */
function inFlightAttemptVisible(attempt: InFlightAttempt): boolean {
  for (const block of attempt.blocks.values()) {
    if (activityThinkingSummary(inFlightBlockText(block)) !== '') return true
  }
  return false
}

/** The survivor ordinals of an attempt, bounded and sorted. */
function inFlightSurvivors(attempt: InFlightAttempt): number[] {
  return [...attempt.blocks.values()]
    .filter(block => block.hasNonWhitespace)
    .map(block => block.ord)
    .sort((a, b) => a - b)
    .slice(0, MAX_INFLIGHT_HANDOFF_SURVIVORS)
}

/** A safe non-negative integer. */
function isSafeCount(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
}

/** One live block snapshot selected for `/details/item`. */
export interface InFlightLiveItem {
  kind: 'live'
  inFlightId: string
  attemptId: string
  revision: number
  turn: number
  step: number
  ord: number
  time: number
  /** The retained prefix at read time, not a continuation. */
  text: string
  /** The host's retention cap discarded later text from this block. */
  truncated: boolean
  /** Retained UTF-8 bytes (the known size; the full stream size is unknown). */
  retainedBytes: number
}

/** One selective lookup result for a transient `inFlightId`. */
export type InFlightSelection =
  | ({ ok: true } & InFlightLiveItem)
  | {
    ok: true
    kind: 'committed'
    turn: number
    seq: number
    /** The live ordinal the caller asked for. */
    liveOrd: number
    /** Live ordinals that survived an interrupted assembly, for translation. */
    survivors: readonly number[]
  }
  | { ok: false; status: 404 | 409; reason: string; message: string }

/**
 * The bounded process-local in-flight store.  One instance lives in the host
 * plugin; tests drive it directly.  Every decision (acceptance, retention,
 * ordinal allocation, nudge, eviction) is here so `index.ts` stays wiring.
 */
export class InFlightActivityRegistry {
  /** Identifies this bridge instance in activity snapshot versions. */
  readonly activityEpoch = randomUUID()
  private readonly records = new Map<string, InFlightSessionRecord>()
  private readonly revisions = new Map<string, number>()

  /** @param mintId - selector factory; overridable for deterministic tests. */
  constructor(private readonly mintId: () => string = randomUUID) {}

  /** The session's monotonically increasing activity snapshot revision. */
  revision(sessionId: string): number {
    return this.revisions.get(sessionId) ?? 0
  }

  /** The number of session records retained (tests and diagnostics). */
  get size(): number {
    return this.records.size
  }

  /** Whether a session record is retained. */
  has(sessionId: string): boolean {
    return this.records.has(sessionId)
  }

  /** The active attempt's summary entries, in reasoning-ordinal order. */
  entries(sessionId: string): ActivityInFlightThinking[] {
    const attempt = this.records.get(sessionId)?.active
    if (attempt === undefined) return []
    const entries: ActivityInFlightThinking[] = []
    const blocks = [...attempt.blocks.values()].sort((a, b) => a.ord - b.ord)
    for (const block of blocks) {
      const summary = activityThinkingSummary(inFlightBlockText(block))
      if (summary === '') continue
      entries.push({
        kind: 'thinking',
        inFlight: true,
        inFlightId: attempt.inFlightId,
        attemptId: attempt.attemptId,
        revision: attempt.revision,
        ord: block.ord,
        time: block.firstTime,
        turn: attempt.turn,
        step: attempt.step,
        summary,
      })
    }
    return entries
  }

  /**
   * The retained piece count of one live block (diagnostics/tests).  The
   * append path coalesces pieces at {@link MAX_INFLIGHT_PIECES_PER_BLOCK}, so
   * one-character deltas cannot create unbounded per-delta overhead.
   */
  retainedPieces(sessionId: string, ord: number): number {
    const attempt = this.records.get(sessionId)?.active
    if (attempt === undefined) return 0
    for (const block of attempt.blocks.values()) {
      if (block.ord === ord) return block.pieces.length
    }
    return 0
  }

  /**
   * Feed one `agent/assistant-stream` frame.  AGENT is the frame's agent,
   * REGISTERED the session's currently registered agent.  A start is accepted
   * only from REGISTERED; every accepted frame moves the session to the LRU
   * front.  Returns the nudge/eviction decision.
   */
  accept(sessionId: string, agent: unknown, registeredAgent: unknown, frame: unknown): InFlightEffect {
    if (!isRecord(frame)) return NO_INFLIGHT_EFFECT
    const type = frame.type
    const attemptId = frame.attemptId
    if (typeof attemptId !== 'string' || attemptId === '') return NO_INFLIGHT_EFFECT
    if (type === 'start') return this.acceptStart(sessionId, agent, registeredAgent, frame, attemptId)
    if (type !== 'chunk' && type !== 'end') return NO_INFLIGHT_EFFECT
    const record = this.records.get(sessionId)
    if (record === undefined || record.owner !== agent) return NO_INFLIGHT_EFFECT
    const attempt = record.active
    if (attempt === undefined || attempt.attemptId !== attemptId) return NO_INFLIGHT_EFFECT
    if (type === 'chunk') return this.acceptChunk(sessionId, record, attempt, frame)
    return this.acceptEnd(sessionId, record, attempt, frame)
  }

  private acceptStart(
    sessionId: string,
    agent: unknown,
    registeredAgent: unknown,
    frame: Record<string, unknown>,
    attemptId: string,
  ): InFlightEffect {
    // The registry is the authority for replacement: a late start from a
    // disposed agent must not steal the session, and a first start must be the
    // currently registered agent, not merely some agent.
    if (registeredAgent === undefined || agent !== registeredAgent) return NO_INFLIGHT_EFFECT
    let record = this.records.get(sessionId)
    if (record !== undefined && record.owner !== undefined && record.owner !== agent) {
      return NO_INFLIGHT_EFFECT
    }
    const turn = frame.turn
    const step = frame.step
    const revision = frame.revision
    if (!isSafeCount(turn) || !isSafeCount(step) || !isSafeCount(revision) || revision < 1) {
      return NO_INFLIGHT_EFFECT
    }
    if (record === undefined) record = { handoffs: [] }
    record.owner = agent
    const previous = record.active
    const effect: InFlightEffect = previous !== undefined && inFlightAttemptVisible(previous)
      ? { nudge: true, turn: previous.turn }
      : { nudge: false }
    // A replaced attempt is a known abandonment, not an unknown selector: an
    // inspector still holding its id sees 409 rather than 404.
    if (previous !== undefined) {
      this.pushHandoff(record, {
        inFlightId: previous.inFlightId,
        turn: previous.turn,
        abandoned: true,
        survivors: [],
      })
    }
    record.active = {
      inFlightId: this.mintId(),
      attemptId,
      revision,
      turn,
      step,
      nextIndex: 0,
      retainedBytes: 0,
      blocks: new Map(),
      otherBlocks: new Set(),
      ordCounter: 0,
    }
    this.touch(sessionId, record, effect)
    return effect
  }

  private acceptChunk(
    sessionId: string,
    record: InFlightSessionRecord,
    attempt: InFlightAttempt,
    frame: Record<string, unknown>,
  ): InFlightEffect {
    const revision = frame.revision
    const index = frame.index
    const time = frame.time
    const chunk = frame.chunk
    if (!isSafeCount(revision) || !isSafeCount(index) || !isSafeCount(time) || !isRecord(chunk)) {
      return this.invalidate(sessionId, record)
    }
    if (revision !== attempt.revision + 1 || index !== attempt.nextIndex) {
      return this.invalidate(sessionId, record)
    }
    attempt.revision = revision
    attempt.nextIndex = index + 1
    const nudge = this.applyChunk(attempt, chunk, time)
    const effect: InFlightEffect = { nudge, turn: attempt.turn }
    this.touch(sessionId, record, effect)
    return effect
  }

  private acceptEnd(
    sessionId: string,
    record: InFlightSessionRecord,
    attempt: InFlightAttempt,
    frame: Record<string, unknown>,
  ): InFlightEffect {
    const revision = frame.revision
    const index = frame.index
    if (!isSafeCount(revision) || !isSafeCount(index)) return this.invalidate(sessionId, record)
    if (revision !== attempt.revision + 1 || index !== attempt.nextIndex) {
      return this.invalidate(sessionId, record)
    }
    const outcome = isRecord(frame.outcome) ? frame.outcome : undefined
    if (outcome === undefined) return this.invalidate(sessionId, record)
    if (outcome.kind === 'committed') {
      const eventType = outcome.eventType
      const seq = outcome.seq
      if ((eventType !== 'assistant/message' && eventType !== 'assistant/attempt')
        || !isSafeCount(seq)) {
        return this.invalidate(sessionId, record)
      }
      const visible = inFlightAttemptVisible(attempt)
      record.active = undefined
      this.pushHandoff(record, {
        inFlightId: attempt.inFlightId,
        turn: attempt.turn,
        eventType,
        seq,
        abandoned: false,
        survivors: inFlightSurvivors(attempt),
      })
      const effect: InFlightEffect = { nudge: visible, turn: attempt.turn }
      this.touch(sessionId, record, effect)
      return effect
    }
    if (outcome.kind !== 'abandoned') return this.invalidate(sessionId, record)
    const visible = inFlightAttemptVisible(attempt)
    record.active = undefined
    this.pushHandoff(record, {
      inFlightId: attempt.inFlightId,
      turn: attempt.turn,
      abandoned: true,
      survivors: [],
    })
    const effect: InFlightEffect = { nudge: visible, turn: attempt.turn }
    this.touch(sessionId, record, effect)
    return effect
  }

  /** The attempt closed at `turn/end` without a stream end. */
  turnEnded(sessionId: string, turn: number): InFlightEffect {
    const record = this.records.get(sessionId)
    if (record === undefined || record.active?.turn !== turn) return NO_INFLIGHT_EFFECT
    return this.invalidate(sessionId, record)
  }

  /**
   * The agent was disposed.  Its active text is dropped and its owner cleared,
   * but the metadata-only handoffs survive so a just-opened inspector can still
   * follow a recent settlement.  A disposal for a replaced agent is ignored.
   */
  agentDisposed(sessionId: string, agent: unknown): InFlightEffect {
    const record = this.records.get(sessionId)
    if (record === undefined || record.owner !== agent) return NO_INFLIGHT_EFFECT
    const effect = this.invalidate(sessionId, record)
    record.owner = undefined
    return effect
  }

  /** Drop a disposed session's whole record (active text and handoffs). */
  sessionDisposed(sessionId: string): void {
    this.records.delete(sessionId)
    this.revisions.delete(sessionId)
  }

  /** Drop every record (plugin effect disposal / hot reload). */
  clear(): void {
    this.records.clear()
    this.revisions.clear()
  }

  /**
   * Resolve an explicit `inFlightId + ord` selector.  A committed handoff
   * reports its committed seq and survivor metadata; the caller translates the
   * ordinal for an interrupted message.
   */
  select(sessionId: string, inFlightId: string, turn: number, ord: number): InFlightSelection {
    const record = this.records.get(sessionId)
    if (record === undefined) return unknownInFlightItem(inFlightId)
    const attempt = record.active
    if (attempt !== undefined && attempt.inFlightId === inFlightId) {
      if (attempt.turn !== turn) return wrongInFlightTurn(inFlightId, turn)
      const block = [...attempt.blocks.values()].find(candidate => candidate.ord === ord)
      const text = block === undefined ? '' : inFlightBlockText(block)
      if (block === undefined || text.trim() === '') {
        return {
          ok: false,
          status: 404,
          reason: 'unknown-item',
          message: `in-flight thinking block ${ord} has no retained text`,
        }
      }
      return {
        ok: true,
        kind: 'live',
        inFlightId,
        attemptId: attempt.attemptId,
        revision: attempt.revision,
        turn: attempt.turn,
        step: attempt.step,
        ord,
        time: block.firstTime,
        text,
        truncated: block.truncated,
        retainedBytes: block.bytes,
      }
    }
    const handoff = record.handoffs.find(candidate => candidate.inFlightId === inFlightId)
    if (handoff === undefined) return unknownInFlightItem(inFlightId)
    if (handoff.turn !== turn) return wrongInFlightTurn(inFlightId, turn)
    if (handoff.abandoned || handoff.eventType === 'assistant/attempt' || handoff.seq === undefined) {
      return {
        ok: false,
        status: 409,
        reason: 'not-visible',
        message: `in-flight thinking ${inFlightId} has no visible committed item`,
      }
    }
    return {
      ok: true,
      kind: 'committed',
      turn: handoff.turn,
      seq: handoff.seq,
      liveOrd: ord,
      survivors: handoff.survivors,
    }
  }

  /** Drop the active attempt and record an abandoned handoff. */
  private invalidate(sessionId: string, record: InFlightSessionRecord): InFlightEffect {
    const attempt = record.active
    if (attempt === undefined) return NO_INFLIGHT_EFFECT
    const visible = inFlightAttemptVisible(attempt)
    record.active = undefined
    this.pushHandoff(record, {
      inFlightId: attempt.inFlightId,
      turn: attempt.turn,
      abandoned: true,
      survivors: [],
    })
    const effect: InFlightEffect = { nudge: visible, turn: attempt.turn }
    this.touch(sessionId, record, effect)
    return effect
  }

  /** Move SESSION-ID to the LRU front, evicting the oldest record when over cap. */
  private touch(sessionId: string, record: InFlightSessionRecord, effect: InFlightEffect): void {
    this.revisions.set(sessionId, this.revision(sessionId) + 1)
    this.records.delete(sessionId)
    this.records.set(sessionId, record)
    while (this.records.size > MAX_INFLIGHT_SESSIONS) {
      const oldest = this.records.keys().next().value
      if (oldest === undefined || oldest === sessionId) break
      const evicted = this.records.get(oldest)
      this.records.delete(oldest)
      if (evicted?.active !== undefined) {
        this.revisions.set(oldest, this.revision(oldest) + 1)
        if (inFlightAttemptVisible(evicted.active)) {
          effect.evicted = { sessionId: oldest, turn: evicted.active.turn }
        }
      }
    }
  }

  /** Append one handoff, evicting the oldest beyond the per-session cap. */
  private pushHandoff(record: InFlightSessionRecord, handoff: InFlightHandoff): void {
    record.handoffs.push(handoff)
    while (record.handoffs.length > MAX_INFLIGHT_HANDOFFS_PER_SESSION) record.handoffs.shift()
  }

  /** Allocate the reasoning ordinal for INDEX on first observation. */
  private ensureBlock(attempt: InFlightAttempt, index: number, time: number): InFlightReasoningBlock {
    const existing = attempt.blocks.get(index)
    if (existing !== undefined) return existing
    const block: InFlightReasoningBlock = {
      ord: attempt.ordCounter,
      firstTime: time,
      pieces: [],
      bytes: 0,
      hasNonWhitespace: false,
      truncated: false,
      closed: false,
      sawDelta: false,
      firstLine: '',
      firstLineDone: false,
      summaryNotified: false,
      newlineNotified: false,
    }
    attempt.ordCounter += 1
    attempt.blocks.set(index, block)
    return block
  }

  /** Apply one accepted stream chunk; returns whether Emacs should refetch. */
  private applyChunk(attempt: InFlightAttempt, chunk: Record<string, unknown>, time: number): boolean {
    const index = chunk.index
    if (!isSafeCount(index)) return false
    if (chunk.type === 'block-start') {
      if (typeof chunk.blockType !== 'string') return false
      if (chunk.blockType === 'reasoning') this.ensureBlock(attempt, index, time)
      else attempt.otherBlocks.add(index)
      return false
    }
    if (chunk.type === 'reasoning-delta') {
      if (typeof chunk.text !== 'string' || attempt.otherBlocks.has(index)) return false
      const block = this.ensureBlock(attempt, index, time)
      if (block.closed) return false
      block.sawDelta = true
      return this.appendBlockText(attempt, block, chunk.text)
    }
    if (chunk.type === 'block-end') {
      if (attempt.otherBlocks.has(index)) return false
      const payload = isRecord(chunk.block) ? chunk.block : undefined
      if (payload?.type !== 'reasoning') return false
      const block = this.ensureBlock(attempt, index, time)
      if (block.closed) return false
      block.closed = true
      const text = typeof payload.text === 'string' ? payload.text : ''
      if (block.sawDelta) {
        if (text.trim() !== '') block.hasNonWhitespace = true
        return false
      }
      return this.appendBlockText(attempt, block, text)
    }
    return false
  }

  /**
   * Retain TEXT for BLOCK within the attempt budget, track the coarsely
   * summarized first line, and report the two coarse transitions: the first
   * non-empty summary, and (once more) the first completed first line.
   */
  private appendBlockText(
    attempt: InFlightAttempt,
    block: InFlightReasoningBlock,
    text: string,
  ): boolean {
    let newlineNow = false
    if (!block.firstLineDone) {
      const newline = text.indexOf('\n')
      if (newline === -1) {
        block.firstLine = (block.firstLine + text).slice(0, MAX_INFLIGHT_FIRST_LINE_CHARS)
      } else {
        block.firstLine = (block.firstLine + text.slice(0, newline))
          .slice(0, MAX_INFLIGHT_FIRST_LINE_CHARS)
        block.firstLineDone = true
        newlineNow = true
      }
    }
    if (text.trim() !== '') block.hasNonWhitespace = true
    if (!block.truncated) {
      const bytes = Buffer.byteLength(text, 'utf8')
      if (attempt.retainedBytes + bytes > MAX_INFLIGHT_REASONING_BYTES) {
        block.truncated = true
      } else {
        if (block.pieces.length >= MAX_INFLIGHT_PIECES_PER_BLOCK) {
          block.pieces = [block.pieces.join('')]
        }
        block.pieces.push(text)
        block.bytes += bytes
        attempt.retainedBytes += bytes
      }
    }
    const hasSummary = activityThinkingSummary(block.firstLine) !== ''
    let nudge = false
    if (hasSummary && !block.summaryNotified) {
      block.summaryNotified = true
      nudge = true
    }
    if (hasSummary && newlineNow && !block.newlineNotified) {
      block.newlineNotified = true
      nudge = true
    }
    return nudge
  }
}

function unknownInFlightItem(inFlightId: string): InFlightSelection {
  return {
    ok: false,
    status: 404,
    reason: 'unknown-item',
    message: `no in-flight thinking item ${inFlightId}`,
  }
}

function wrongInFlightTurn(inFlightId: string, turn: number): InFlightSelection {
  return {
    ok: false,
    status: 404,
    reason: 'unknown-item',
    message: `in-flight thinking ${inFlightId} is not in turn ${turn}`,
  }
}

/**
 * Merge the active attempt's live summary entries into the committed activity
 * fold.  A live entry is offered only for a turn with no `turn/end` (live
 * state never resurrects, synthesizes, or extends a closed turn), and both
 * admission bounds are applied after the merge.  Entries keep log order: the
 * attempt is the open turn's tail, so its blocks append in ordinal order.
 */
export function withInFlightActivity(
  activity: ReadonlyMap<number, TurnActivity>,
  live: readonly ActivityInFlightThinking[],
  boundaries: TurnBoundaries,
): Map<number, TurnActivity> {
  const merged = new Map<number, TurnActivity>()
  for (const [turn, value] of activity) {
    merged.set(turn, { entries: [...value.entries], messageSeqs: [...value.messageSeqs] })
  }
  for (const entry of live) {
    if (boundaries.ends.has(entry.turn)) continue
    let value = merged.get(entry.turn)
    if (value === undefined) {
      value = { entries: [], messageSeqs: [] }
      merged.set(entry.turn, value)
    }
    appendActivityEntry(value, entry)
  }
  retainActivityTurns(merged)
  return merged
}

/** One entry in the merged session inventory handed to Emacs. */
export interface SessionRow {
  id: string
  title: string | null
  /** Effective working directory for a live row (folded from the log); a
   * persisted row serves the header's original project. */
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
 * Whether a session must be excluded from targeting and listing. DSH marks a
 * subagent-created session with `origin: 'subagent'`; ordinary forks and
 * resumed sessions carry no runtime parent ownership, and a historical fork's
 * `parentSession` lineage is not subagent ownership.
 */
export function isSubagentChild(origin: string | undefined): boolean {
  return origin === 'subagent'
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

/** The viewed values of one persisted projection-cache block (a listing hint). */
export interface ProjectionBlockLike {
  readonly values?: Readonly<Record<string, unknown>>
}

/**
 * The title a persisted projection-cache block serves, or undefined when the
 * caller must fold the log instead.
 *
 * A cache block is a zero-I/O listing hint, never an authority: only a
 * non-empty string counts. An absent block, or a missing/non-string/empty
 * value — including the deliberate null a lagging write-behind checkpoint
 * leaves after an uncheckpointed rename — reads as "no cached title", which is
 * what makes `coldSessionTitle` fall through to the authoritative log fold.
 */
export function cachedTitleValue(block: ProjectionBlockLike | undefined): string | undefined {
  const title = block?.values?.title
  return typeof title === 'string' && title !== '' ? title : undefined
}

/**
 * Merge live sessions with persisted (cold) headers into one inventory.
 * `live` is already filtered to targetable sessions by the caller; persisted
 * entries are skipped when subagent-owned or already present as live. A live
 * row's cwd is the host's projection when the caller supplies it, else the
 * effective directory folded from its log; a persisted row carries only a
 * header, so it serves the original project.
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
      // An explicit cwd is the host's projection and wins even when null; the
      // fold is the fallback for callers that carry only a header and a log.
      cwd: session.cwd !== undefined ? session.cwd : effectiveCwd(session.header, session.events) ?? null,
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
 *
 * `archivedIds` names sessions the workspace registry has archived. Archiving
 * does not dispose a live session's agent, so an archived session can appear in
 * either tier; it is never a run target, so both fallback arms skip it. An
 * explicit archived id still resolves (as target or cold) so the route's own
 * archived fence answers with its specific 409.
 */
export function resolveTargetId(
  explicitId: string | undefined,
  live: readonly LiveSessionLike[],
  persisted: readonly SessionHeaderLike[],
  hasAgent: (id: string) => boolean,
  archivedIds: ReadonlySet<string>,
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
    if (archivedIds.has(session.id)) continue
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
    if (archivedIds.has(header.id)) continue
    if (header.createdAt > bestCreated) {
      bestCreated = header.createdAt
      bestCold = header.id
    }
  }
  if (bestCold !== undefined) return { kind: 'cold', id: bestCold }
  return { kind: 'error', status: 409, message: 'no active session' }
}

/** The read-only target selection for the session report. */
export type ReadTargetResult =
  | { kind: 'target'; id: string; live: boolean }
  | { kind: 'error'; status: 404 | 409; message: string }

/**
 * Resolve the session id a read-only report should observe. Same precedence as
 * `resolveTargetId` — an explicit id, then last-active live, then the most
 * recent cold session (skipping subagent origin) — but deliberately WITHOUT
 * the live-agent requirement: describing a live session whose agent is not
 * attached is still a read, so it must not 409 the way a write target does.
 * Nothing is resumed here; the caller only observes the returned id.
 */
export function resolveReadTargetId(
  explicitId: string | undefined,
  live: readonly LiveSessionLike[],
  persisted: readonly SessionHeaderLike[],
): ReadTargetResult {
  if (explicitId !== undefined) {
    const cls = classifySessionId(
      explicitId,
      new Set(live.map(session => session.id)),
      new Set(persisted.map(header => header.id)),
    )
    if (cls === 'live') return { kind: 'target', id: explicitId, live: true }
    if (cls === 'cold') return { kind: 'target', id: explicitId, live: false }
    return { kind: 'error', status: 404, message: `session ${explicitId} is not live` }
  }
  let best: string | undefined
  let bestTime = -Infinity
  for (const session of live) {
    const time = session.events.at(-1)?.time ?? session.header.createdAt
    if (time > bestTime) {
      bestTime = time
      best = session.id
    }
  }
  if (best !== undefined) return { kind: 'target', id: best, live: true }
  let bestCold: string | undefined
  let bestCreated = -Infinity
  for (const header of persisted) {
    if (header.origin === 'subagent') continue
    if (header.createdAt > bestCreated) {
      bestCreated = header.createdAt
      bestCold = header.id
    }
  }
  if (bestCold !== undefined) return { kind: 'target', id: bestCold, live: false }
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

function sseMessage(payload: unknown): string {
  return `data: ${JSON.stringify(payload)}\n\n`
}

/**
 * One SSE `data:` frame for a composer-draft push. The payload names the target
 * session so the browser routes the draft to the right composer scope.
 */
export function draftMessage(sessionId: string, text: string): string {
  return sseMessage({ kind: 'draft', sessionId, text })
}

/**
 * One SSE `data:` frame signalling that new outbox entries are available (the
 * "Send to Emacs" button deposited a message). A bare notice: consumers pull the
 * outbox themselves, keeping the ack/redelivery semantics in one place.
 */
export function outboxMessage(): string {
  return sseMessage({ kind: 'outbox' })
}

/**
 * One SSE `data:` frame announcing that a session's agent started a turn.
 * Carries the session id, the turn event's ms-epoch `time` (so Emacs can
 * update the `lastActive` recency of the session's row), and the turn number
 * (so the Emacs reply/turn cache knows which turn is opening); the browser
 * ignores the non-`draft` kind.
 */
export function turnStartMessage(sessionId: string, time: number, turn?: number): string {
  return sseMessage({
    kind: 'turn-start',
    sessionId,
    time,
    ...(turn === undefined ? {} : { turn }),
  })
}

/**
 * One SSE `data:` frame announcing that a session's turn ended. REASON is the
 * turn-end reason kind (`completed` / `aborted` / `blocked` / `error` /
 * `max-tokens`; `interrupted` is only written by persistence repair, never
 * emitted live), so the Emacs `message` variant can phrase a failed turn
 * without echoing "finished". `time` is the event's ms-epoch timestamp, used
 * to refresh the sessions-list recency; the glyph returns to idle regardless
 * of reason. TURN names the ended turn, so Emacs can refill exactly the view
 * whose closing divider it must draw. FAILURE, when the turn failed (an
 * `error` reason, or a signed-out abort), is the sanitized
 * `{ code?, message }` — see `TurnFailure` — so Emacs can phrase
 * "failed — <message>" promptly, ahead of any `/turns` refetch.
 */
export function turnCompleteMessage(sessionId: string, reason: string, time: number, turn?: number, failure?: TurnFailure): string {
  return sseMessage({
    kind: 'turn-complete',
    sessionId,
    reason,
    time,
    ...(turn === undefined ? {} : { turn }),
    ...(failure === undefined ? {} : { failure }),
  })
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
  return sseMessage({
    kind: 'replies-changed',
    sessionId,
    ...(turn === undefined ? {} : { turn }),
  })
}

/**
 * One SSE `data:` frame announcing that a session's turn activity changed (a
 * `tool/call`, an append `tool/result`, or an `assistant/message` carrying
 * reasoning was committed mid-turn, or a live reasoning attempt gained,
 * replaced, or lost its transient summary entry). Emitted at most once per
 * debounce window per session: activity arrives in bursts, and the frame is
 * only a nudge to re-pull `GET /turns`. TURN names the affected turn; it is
 * informational (Emacs refreshes the session's turn cache, not a turn-specific
 * entry), and the browser ignores the non-`draft` kind. The payload never
 * carries reasoning text or a live selector.
 */
export function activityChangedMessage(sessionId: string, turn?: number): string {
  return sseMessage({
    kind: 'activity-changed',
    sessionId,
    ...(turn === undefined ? {} : { turn }),
  })
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
  return sseMessage(payload)
}

/**
 * One SSE `data:` frame announcing that a session's pending-prompt counts
 * changed (an inbox splice: insert, claim, remove, edit, or clear). Counts
 * only — prompt text and attachment details never travel on SSE; the prompt
 * buffer fetches them through `GET /prompts` when it needs them. A same-count
 * change still emits, because the pending list itself may have changed (an
 * edit, or one item replaced by another).
 */
export function queueChangedMessage(sessionId: string, counts: QueueCounts): string {
  return sseMessage({
    kind: 'queue-changed',
    sessionId,
    queued: counts.queued,
    steering: counts.steering,
  })
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

/** Narrow a context-pressure projection into displayable occupancy, or undefined when incomplete. */
export function contextOccupancy(value: unknown): { usedTokens: number; contextWindow: number } | undefined {
  const pressure = recordOf(value)
  if (pressure === undefined) return undefined
  const usedTokens = contextUsedTokens(
    typeof pressure.pressureTokens === 'number' ? pressure.pressureTokens : undefined,
    typeof pressure.projectedTokens === 'number' ? pressure.projectedTokens : undefined,
  )
  const contextWindow = typeof pressure.contextWindow === 'number' ? pressure.contextWindow : undefined
  return usedTokens === undefined || contextWindow === undefined
    ? undefined
    : { usedTokens, contextWindow }
}

/** One SSE `data:` frame carrying a session's context occupancy, matching the web meter. */
export function contextMessage(sessionId: string, usedTokens: number, contextWindow: number): string {
  return sseMessage({ kind: 'context', sessionId, usedTokens, contextWindow })
}

/**
 * One SSE `data:` frame carrying a session's full refined plan section
 * (`{active, pending?, queued?}`). A live read supplies the wanted `pending`;
 * a projection-only section carries the direction-less `queued`.
 */
export function planChangedMessage(sessionId: string, plan: SessionReportPlan): string {
  return sseMessage({ kind: 'plan', sessionId, plan })
}

/**
 * One SSE `data:` frame carrying a session's full goal section, or `null` when
 * the goal was cleared. `activation` is present only when the live read
 * supplied it (absent means unknown, never `null`).
 */
export function goalChangedMessage(sessionId: string, goal: SessionReportGoal | null): string {
  return sseMessage({ kind: 'goal', sessionId, goal })
}

/**
 * One SSE `data:` frame carrying a process-local goal-activation change. The
 * durable `goal` frame on the same commit carries the goal itself; this frame
 * exists for activation edges with no `goal/change`. `goalId`/`revision` let
 * the consumer reject a frame that arrives after the goal changed again.
 */
export function goalActivationChangedMessage(
  sessionId: string,
  activation: 'armed' | 'disarmed',
  goalId?: string,
  revision?: number,
): string {
  return sseMessage({
    kind: 'goal-activation',
    sessionId,
    activation,
    ...(goalId === undefined ? {} : { goalId }),
    ...(revision === undefined ? {} : { revision }),
  })
}

/**
 * One SSE `data:` frame reporting a compaction lifecycle edge for a session.
 * PHASE is `start` or `end`. SOURCE-COMMAND-ID is present exactly when the
 * compaction was manual (a `/compact` invocation through the command
 * registry) and absent for an automatic one; Emacs uses it to pick its
 * feedback channel — the manual 200/409 echo is the completion message, so it
 * suppresses this frame's end message. ERROR is present only on an `end` for
 * a failed/cancelled transaction; TOKENS-RECLAIMED is the summary's
 * `shadowedTokenCount`, present only when a `compaction/summary` preceded the
 * end — so an end may carry an error with no count, or a count with no error.
 */
export function compactionFrame(args: {
  sessionId: string
  phase: 'start' | 'end'
  sourceCommandId?: string
  error?: string
  tokensReclaimed?: number
}): string {
  const { sessionId, phase, sourceCommandId, error, tokensReclaimed } = args
  return sseMessage({
    kind: 'compaction',
    sessionId,
    phase,
    ...(sourceCommandId === undefined ? {} : { sourceCommandId }),
    ...(error === undefined ? {} : { error }),
    ...(tokensReclaimed === undefined ? {} : { tokensReclaimed }),
  })
}

/**
 * Minimal structural face of one `ask_user_question` item, enough to rebroadcast
 * it to Emacs. Mirrors `@deepseek-ai/dsh-user-questions`'s wire type, which the
 * `user-questions/request` waterfall carries verbatim. An `intent` marks a
 * structured question whose answer is a fixed action label: `plan-review` for a
 * plan approval, `approval` for a fixed permission decision. The frame forwards
 * the whole intent verbatim; Emacs decides how much of it to present.
 */
export interface AskUserQuestionOptionLike {
  label: string
  description?: string
}

/**
 * The structured-question markers the bridge recognizes. This is the minimal
 * face the frame builder needs; any further fields the harness attaches are
 * forwarded verbatim with the rest of the question.
 */
export type AskUserQuestionIntentLike =
  | { kind: 'plan-review'; approve: string }
  | { kind: 'approval'; approve: string; reject: string; always?: string }

export interface AskUserQuestionItemLike {
  id: string
  question: string
  detail?: string
  header?: string
  options?: readonly AskUserQuestionOptionLike[]
  multiSelect?: boolean
  intent?: AskUserQuestionIntentLike
}

/** One answer the human returns for a question. */
export interface AskUserAnswerItemLike {
  id: string
  selected: string[]
  custom?: string
}

/**
 * Whether ANSWERS is a well-formed answer set for QUESTIONS: every entry names
 * a pending question by id and carries a string-array `selected`. The old
 * gateway validated this inside `apiProxy.respond`; the waterfall hands the
 * listener's return value straight to the asker, so the bridge validates at
 * its own `/answer` boundary instead. The asserted type is mutable-array
 * (`AskUserQuestionAnswer.answers` is `AskUserQuestionAnswerItem[]` on the
 * harness side).
 */
export function answerMatchesQuestions(
  questions: readonly AskUserQuestionItemLike[],
  answers: unknown,
): answers is AskUserAnswerItemLike[] {
  if (!Array.isArray(answers) || answers.length === 0) return false
  const ids = new Set(questions.map(q => q.id))
  for (const entry of answers) {
    if (typeof entry !== 'object' || entry === null) return false
    const answer = entry as { id?: unknown; selected?: unknown; custom?: unknown }
    if (typeof answer.id !== 'string' || !ids.has(answer.id)) return false
    if (!Array.isArray(answer.selected) || answer.selected.some(s => typeof s !== 'string')) return false
    if (answer.custom !== undefined && typeof answer.custom !== 'string') return false
  }
  return true
}

/**
 * Whether a browser-side waterfall rejection is the web UI's own question
 * cancel (the panel's close button). The client rejects with the harness's
 * `ASK_CANCELLED` code; any other rejection (no answerer, no loaded session,
 * transport failure) means the browser could not present the question and must
 * leave Emacs deciding.
 */
export function isQuestionCancelRejection(error: unknown): boolean {
  return typeof error === 'object' && error !== null
    && (error as { code?: unknown }).code === 'ASK_CANCELLED'
}

/** One SSE `data:` frame announcing a pending question to Emacs. */
export function askUserMessage(
  questionId: string,
  sessionId: string,
  questions: readonly AskUserQuestionItemLike[],
): string {
  return sseMessage({ kind: 'ask-user', questionId, sessionId, questions })
}

/**
 * One SSE `data:` frame telling Emacs a question was resolved
 * (answered/cancelled). `questionIds` carries the asker's own question ids, so
 * the browser plugin can match the resolution to the web UI's pending question
 * panel and dismiss it when Emacs answered first.
 */
export function askUserResolvedMessage(
  sessionId: string,
  questionId: string,
  outcome: 'answered' | 'cancelled',
  questionIds: readonly string[] = [],
): string {
  return sseMessage({ kind: 'ask-user-resolved', sessionId, questionId, outcome, questionIds })
}

/**
 * One decision Emacs may return for a pending approval. A subset of the
 * harness's `ApprovalOutcome` (`'unavailable'` is the fail-closed answerer
 * absence, which the bridge never produces as an Emacs decision).
 */
export type ApprovalDecision = 'allowed-once' | 'rejected' | 'cancelled'

/**
 * The outcome an `approval-resolved` frame may report. The bridge's own
 * answerer only ever settles the three {@link ApprovalDecision} values, but a
 * request delegated to the web UI for a notify-only Emacs can resolve as the
 * fail-closed `'unavailable'` too.
 */
export type ApprovalResolution = ApprovalDecision | 'unavailable'

/** Whether VALUE is one of the three decisions the bridge accepts. */
export function approvalDecisionValid(value: unknown): value is ApprovalDecision {
  return value === 'allowed-once' || value === 'rejected' || value === 'cancelled'
}

/** Cap on the tool-arguments text embedded in an `approval` frame. */
export const MAX_APPROVAL_DETAIL_CHARS = 8192

/** Appended to a tool-arguments string cut at the cap. */
const APPROVAL_TRUNCATION_MARKER = '\u2026[truncated]'

/**
 * Truncate an `arguments` JSON string to at most CAP characters without
 * cutting inside a JSON escape. The prefix is not parseable JSON either way
 * (it is a prefix), but ending on a lone backslash or a partial `\uXXXX` would
 * hand a client raw broken text; this walks the prefix once so the cut lands
 * on a token boundary (outside a string every character is a token; inside
 * one, `\X` is two and `\uXXXX` is six). Truncation appends a marker, so the
 * result can exceed CAP by the marker's length.
 */
export function truncateApprovalArguments(
  text: string,
  cap: number = MAX_APPROVAL_DETAIL_CHARS,
): string {
  if (text.length <= cap) return text
  let safe = 0
  let index = 0
  let inString = false
  while (index < cap) {
    const char = text[index]!
    if (!inString) {
      index += 1
      safe = index
      if (char === '"') inString = true
      continue
    }
    if (char === '\\') {
      const next = text[index + 1]
      if (next === undefined) break
      if (next === 'u') {
        if (index + 6 > cap) break
        index += 6
      } else {
        index += 2
      }
      safe = index
      continue
    }
    index += 1
    safe = index
    if (char === '"') inString = false
  }
  return `${text.slice(0, safe)}${APPROVAL_TRUNCATION_MARKER}`
}

/** The bounded tool-call detail an `approval` frame carries. */
export interface ApprovalToolCallDetail {
  name: string
  arguments: string
}

/**
 * The tool-call detail for CALLID, folded from a session's event log: the last
 * `tool/call` event whose `callId` matches, with its arguments truncated to
 * {@link MAX_APPROVAL_DETAIL_CHARS}. Returns undefined when CALLID is absent
 * (a hook-gated ask may carry none) or no matching event is found — the frame
 * then omits `detail` rather than showing a bogus one.
 */
export function toolCallForId(
  events: readonly SessionEventLike[],
  callId: string | undefined,
): ApprovalToolCallDetail | undefined {
  if (callId === undefined || callId === '') return undefined
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event?.type !== 'tool/call') continue
    const data = event.data as
      { callId?: unknown; name?: unknown; arguments?: unknown } | undefined
    if (data?.callId !== callId) continue
    if (typeof data.name !== 'string') return undefined
    return {
      name: data.name,
      arguments: truncateApprovalArguments(typeof data.arguments === 'string' ? data.arguments : ''),
    }
  }
  return undefined
}

/**
 * One SSE `data:` frame announcing a pending approval to Emacs. `detail` is the
 * bounded tool-call lookup (omitted when the host could not resolve it), so
 * the Emacs side can show what is actually being approved.
 */
export function approvalMessage(
  approvalId: string,
  sessionId: string,
  toolName: string,
  callId: string | undefined,
  reason: string | undefined,
  detail: ApprovalToolCallDetail | undefined,
): string {
  return sseMessage({ kind: 'approval', approvalId, sessionId, toolName, callId, reason, detail })
}

/**
 * One SSE `data:` frame telling Emacs a pending approval was resolved.
 * `toolName`/`callId` ride along so the browser plugin can dismiss its own
 * panel (matched on session + tool, plus the call id when present) and so a
 * stale Emacs buffer can banner itself.
 */
export function approvalResolvedMessage(
  approvalId: string,
  sessionId: string,
  outcome: ApprovalResolution,
  toolName: string,
  callId: string | undefined,
): string {
  return sseMessage({ kind: 'approval-resolved', approvalId, sessionId, outcome, toolName, callId })
}

/**
 * The turn of one visible durable assistant message, addressed by its message
 * id. Walks the same current surface as `assistantTurns`, so a raw-log message
 * hidden by compaction does not resolve to a turn `/turns` cannot serve.
 * Returns undefined when no visible assistant message carries that id or the
 * matching event has no numeric turn. This is the host-side translation the
 * "Send to Emacs" action needs now that the chat tree left `SessionSnapshot`.
 */
export function assistantTurnForMessage(
  log: SessionTurnLogLike,
  messageId: string,
): number | undefined {
  for (const seq of log.nodes) {
    const event = log.events[seq]
    if (event?.type !== 'assistant/message') continue
    const data = event.data as { turn?: unknown; message?: unknown } | undefined
    const message = data?.message as { id?: unknown } | undefined
    if (message?.id !== messageId) continue
    return typeof data?.turn === 'number' ? data.turn : undefined
  }
  return undefined
}

/**
 * The session's current model selection for the `/models` response: the
 * `modelSelection` projection's wire view (`next` already falls back to
 * `lastUsed`), else the catalog's deployment default — the same fold the web
 * UI's model directory computes (`projected.next ?? catalog.default`).
 */
export function currentModelSelection(
  catalogDefault: unknown,
  view: { lastUsed?: unknown; next?: unknown } | undefined,
): unknown {
  return view?.next ?? view?.lastUsed ?? catalogDefault
}

/**
 * The catalog display name of PROVIDER/MODEL, or null. The pure half of the
 * host's `modelName` enrichment for the session report; mirrors the elisp
 * `dsh-bridge--model-display-name` walk of `groups[].models[]`.
 */
export function catalogModelName(
  catalog: unknown,
  provider: string,
  model: string,
): string | null {
  const groups = recordOf(catalog)?.groups
  if (!Array.isArray(groups)) return null
  for (const rawGroup of groups) {
    const group = recordOf(rawGroup)
    if (group?.id !== provider) continue
    const models = group.models
    if (!Array.isArray(models)) return null
    for (const rawModel of models) {
      const entry = recordOf(rawModel)
      if (entry?.id !== model) continue
      const name = entry.name
      return typeof name === 'string' && name !== '' ? name : null
    }
    return null
  }
  return null
}

/**
 * Wrap named RPC arguments into the `{ args }` payload the Typert gateway
 * requires: a Remote endpoint consumes exactly one plain-object `args` field
 * keyed by parameter name (e.g. `{ request: {...} }` for `session/selectModel`).
 */
export function rpcArgsPayload(args: Record<string, unknown>): { args: Record<string, unknown> } {
  return { args }
}

// ---- Attachments (PLAN.md candidate 11) ----

/** Image media types the version-one attachment path accepts. */
export type BridgeImageMediaType = 'image/png' | 'image/jpeg' | 'image/webp' | 'image/gif'

/** One requested attachment after wire validation. */
export interface AttachmentRequest {
  /** Absolute host-local path the host reads. */
  path: string
  /** Optional display name; the attachment store sanitizes it into the leaf name. */
  name?: string
}

/** The outcome of {@link parseAttachmentRequests}. */
export type AttachmentRequestsResult =
  | { ok: true; items: AttachmentRequest[] }
  | { ok: false; error: string }

/** How a `/send` request deposits its prompt into the target agent. */
export type SendMode = 'steer'

/** The outcome of {@link parseSendMode}. */
export type ParsedSendMode =
  | { ok: true; mode: SendMode | undefined }
  | { ok: false; error: string }

/**
 * Validate the optional `mode` member of a `/send` body. Absent and JSON
 * `null` mean the ordinary follow-up send; the only accepted value is
 * `"steer"`. Anything else is a caller error rather than a silent fallback:
 * an unrecognized mode (the signature of a version-skewed client) must not
 * degrade into queueing, which is exactly the behavior steering exists to
 * avoid.
 */
export function parseSendMode(value: unknown): ParsedSendMode {
  if (value === undefined || value === null) return { ok: true, mode: undefined }
  if (value === 'steer') return { ok: true, mode: 'steer' }
  return { ok: false, error: "mode must be absent or \"steer\"" }
}

/** The only part of a pending inbox message {@link queueCounts} reads. */
export interface PendingMessageLike {
  readonly source: { readonly kind: string }
}

/** One content block, narrowed to the fields the pending-prompt fold reads. */
export interface PendingContentBlockLike {
  readonly type: string
  readonly text?: string
  /** Present on `image`/`file` blocks; only display metadata is read. */
  readonly attachment?: {
    readonly name?: unknown
    readonly bytes?: unknown
  }
}

/** One pending inbox message, narrowed to the fields the prompt history reads. */
export interface PendingPromptMessageLike extends PendingMessageLike {
  readonly id: string
  readonly content: readonly PendingContentBlockLike[]
}

/** One attachment summary carried by a pending prompt. */
export interface PendingPromptAttachment {
  readonly kind: 'file' | 'image'
  readonly name?: string
  readonly bytes?: number
}

/** One pending prompt as `GET /prompts` reports it to the history walk. */
export interface PendingPrompt {
  /** Durable message id, shared with the committed `user/message` once claimed. */
  readonly id: string
  readonly placement: 'queued' | 'steering'
  /** Text blocks joined with newlines; empty for an attachment-only prompt. */
  readonly text: string
  /** Whether the message carries only text blocks (false for attachments or unknown blocks). */
  readonly textOnly: boolean
  readonly attachments: readonly PendingPromptAttachment[]
  /** 1-based FIFO position within the queued group; absent for steering. */
  readonly position?: number
}

/** A live agent's pending user-prompt counts by placement. */
export interface QueueCounts {
  /** Prompts queued for their own later turns. */
  queued: number
  /** User prompts parked for the next step boundary (steering). */
  steering: number
}

/**
 * Count one live agent's pending user prompts by placement. Every `nextTurn`
 * item is a queued prompt. `nextStep` also carries injected model-facing
 * context (`source.kind !== 'user'`), which is not a user prompt and is
 * excluded, matching the harness's own `SessionQueuedItem` fold.
 */
export function queueCounts(inbox: {
  readonly nextTurn: readonly PendingMessageLike[]
  readonly nextStep: readonly PendingMessageLike[]
}): QueueCounts {
  return {
    queued: inbox.nextTurn.length,
    steering: inbox.nextStep.filter(message => message.source.kind === 'user').length,
  }
}

/** One pending message's text: text blocks joined with newlines, matching {@link userPrompts}. */
function pendingPromptText(content: readonly PendingContentBlockLike[]): string {
  return content
    .filter(block => block.type === 'text')
    .map(block => block.text ?? '')
    .join('\n')
}

/** Attachment display metadata in block order; attachment content bytes are never read. */
function pendingPromptAttachments(
  content: readonly PendingContentBlockLike[],
): PendingPromptAttachment[] {
  const attachments: PendingPromptAttachment[] = []
  for (const block of content) {
    if (block.type !== 'file' && block.type !== 'image') continue
    const attachment = block.attachment
    if (attachment === undefined) continue
    const name = typeof attachment.name === 'string' ? attachment.name : undefined
    const bytes = typeof attachment.bytes === 'number' && Number.isFinite(attachment.bytes)
      ? attachment.bytes
      : undefined
    attachments.push({
      kind: block.type,
      ...(name === undefined ? {} : { name }),
      ...(bytes === undefined ? {} : { bytes }),
    })
  }
  return attachments
}

/** One pending message as a history entry, before its placement-specific position. */
function pendingPrompt(
  message: PendingPromptMessageLike,
  placement: PendingPrompt['placement'],
): PendingPrompt {
  return {
    id: String(message.id),
    placement,
    text: pendingPromptText(message.content),
    textOnly: message.content.every(block => block.type === 'text'),
    attachments: pendingPromptAttachments(message.content),
  }
}

/**
 * The live agent's pending prompts in action order: steering items first (they
 * are claimed at the next step boundary), then queued items in FIFO order (the
 * next to run first). Every `nextTurn` item is a queued prompt; only
 * user-sourced `nextStep` items are steering, matching {@link queueCounts}.
 * Attachment content bytes are never read (only size metadata is copied), and
 * `textOnly` is false for any non-text block rather than stringifying it.
 */
export function pendingPrompts(inbox: {
  readonly nextTurn: readonly PendingPromptMessageLike[]
  readonly nextStep: readonly PendingPromptMessageLike[]
}): PendingPrompt[] {
  const pending: PendingPrompt[] = []
  for (const message of inbox.nextStep) {
    if (message.source.kind !== 'user') continue
    pending.push(pendingPrompt(message, 'steering'))
  }
  let position = 0
  for (const message of inbox.nextTurn) {
    position += 1
    pending.push({ ...pendingPrompt(message, 'queued'), position })
  }
  return pending
}

/**
 * Fold the `inbox` session projection's hyphenated wire state into the same
 * counts {@link queueCounts} produces, or undefined for a value that is not
 * the expected `{ 'next-turn', 'next-step' }` object. The projection's wire
 * schema validates the message objects, so the counts only read `source`.
 */
export function queueCountsFromWire(value: unknown): QueueCounts | undefined {
  if (typeof value !== 'object' || value === null) return undefined
  const state = value as { 'next-turn'?: unknown; 'next-step'?: unknown }
  if (!Array.isArray(state['next-turn']) || !Array.isArray(state['next-step'])) return undefined
  return queueCounts({
    nextTurn: state['next-turn'] as readonly PendingMessageLike[],
    nextStep: state['next-step'] as readonly PendingMessageLike[],
  })
}

/**
 * The HTTP status for a `POST /sessions/queue` failure. The session
 * controller's taxonomy maps onto the bridge's conventions; anything
 * unrecognized is 500. A missing or stale item and a turn that no longer
 * accepts steering are both conflicts, not client errors.
 */
export function queueMutationStatus(code: string | undefined): number {
  switch (code) {
    case 'session/queue-item-not-found':
    case 'session/steer-unavailable':
    case 'session/agent-busy':
      return 409
    case 'session/not-found':
      return 404
    case 'gateway/bad-request':
      return 400
    default:
      return 500
  }
}

/**
 * Bridge-imposed bound on one prompt's attachment count. Mirrors the store's
 * default `maxImagesPerMessage`, and also bounds the file arm, which the
 * harness leaves unbounded. Documented in README.
 */
export const MAX_ATTACHMENTS = 20

/**
 * Bridge-imposed per-file byte bound for the verbatim file arm. The image arm
 * is bounded by the store's own `imageLimits`. Documented in README.
 */
export const MAX_ATTACHMENT_FILE_BYTES = 200 * 1024 * 1024

/**
 * Validate the `attachments` member of a `/send` body. Absent/`null` is an
 * empty list; a bad member names the first offending index so Emacs can echo
 * something useful. JSON `null` in `name` is treated as absent (json-encode
 * writes a nil alist value as null).
 */
export function parseAttachmentRequests(value: unknown): AttachmentRequestsResult {
  if (value === undefined || value === null) return { ok: true, items: [] }
  if (!Array.isArray(value)) return { ok: false, error: 'attachments must be an array' }
  if (value.length > MAX_ATTACHMENTS) {
    return { ok: false, error: `too many attachments (max ${MAX_ATTACHMENTS})` }
  }
  const items: AttachmentRequest[] = []
  for (let index = 0; index < value.length; index += 1) {
    const raw = value[index]
    if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
      return { ok: false, error: `attachments[${index}] must be an object` }
    }
    const record = raw as Record<string, unknown>
    const path = record.path
    if (typeof path !== 'string' || path === '') {
      return { ok: false, error: `attachments[${index}].path is required` }
    }
    if (path.includes('\u0000')) {
      return { ok: false, error: `attachments[${index}].path must not contain NUL` }
    }
    if (!isAbsolute(path)) {
      return { ok: false, error: `attachments[${index}].path must be absolute` }
    }
    const name = record.name
    if (name !== undefined && name !== null && typeof name !== 'string') {
      return { ok: false, error: `attachments[${index}].name must be a string` }
    }
    items.push({
      path,
      ...(typeof name === 'string' && name !== '' ? { name } : {}),
    })
  }
  return { ok: true, items }
}

/** Whether BYTES begins with the fixed SIGNATURE. */
function startsWith(bytes: Uint8Array, signature: readonly number[]): boolean {
  if (bytes.length < signature.length) return false
  for (let index = 0; index < signature.length; index += 1) {
    if (bytes[index] !== signature[index]) return false
  }
  return true
}

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] as const
const JPEG_SIGNATURE = [0xff, 0xd8, 0xff] as const
const GIF_SIGNATURE = [0x47, 0x49, 0x46, 0x38] as const
const RIFF_SIGNATURE = [0x52, 0x49, 0x46, 0x46] as const
const WEBP_TAG = [0x57, 0x45, 0x42, 0x50] as const

/**
 * Sniff one accepted image media type from the leading bytes of a file, or
 * `undefined` when it is not one of the four signatures. Content, not the
 * file name, decides: the store rejects a declared type that disagrees with
 * the bytes (`IMAGE_TYPE_MISMATCH`).
 */
export function sniffImageMediaType(header: Uint8Array): BridgeImageMediaType | undefined {
  if (startsWith(header, PNG_SIGNATURE)) return 'image/png'
  if (startsWith(header, JPEG_SIGNATURE)) return 'image/jpeg'
  if (startsWith(header, GIF_SIGNATURE)) return 'image/gif'
  if (startsWith(header, RIFF_SIGNATURE)
    && header.length >= 12
    && startsWith(header.subarray(8), WEBP_TAG)) {
    return 'image/webp'
  }
  return undefined
}

/**
 * Whether a resolved model explicitly refuses image input. An undefined list
 * means "unspecified", which every harness image gate treats as allowed.
 */
export function imageInputUnsupported(inputModalities: readonly string[] | undefined): boolean {
  return inputModalities !== undefined && !inputModalities.includes('image')
}

const ATTACHMENT_SIZE_CODES: ReadonlySet<string> = new Set([
  'IMAGES_TOO_LARGE',
  'IMAGE_TOO_LARGE',
  'IMAGE_TOO_MANY_PIXELS',
  'IMAGE_DIMENSION_TOO_LARGE',
])

const ATTACHMENT_CALLER_CODES: ReadonlySet<string> = new Set([
  'TOO_MANY_IMAGES',
  'UNSUPPORTED_IMAGE_TYPE',
  'INVALID_IMAGE_BASE64',
  'INVALID_IMAGE',
  'IMAGE_TYPE_MISMATCH',
  'INVALID_FILE_BASE64',
  'ATTACHMENT_PROJECTION_UNSUPPORTED',
])

/**
 * HTTP status for an attachment store failure code: caller-correctable size
 * limits are 413, caller-correctable content/count problems are 400, a
 * backend that cannot store files at all is 501, and every other code
 * (storage faults, unrecognized codes) is a server-side 500.
 */
export function attachmentErrorHttpStatus(code: string): 400 | 413 | 500 | 501 {
  if (ATTACHMENT_SIZE_CODES.has(code)) return 413
  if (ATTACHMENT_CALLER_CODES.has(code)) return 400
  if (code === 'ATTACHMENT_FILES_UNSUPPORTED') return 501
  return 500
}

// ---- Compaction ----

/**
 * The settled `result` member of a `CommandExecution`, restricted to the two
 * kinds `/compact` can produce. `error` covers the `ManualCompactionError`
 * codes (busy/cancelled/changed/summary/commit/persistence), already mapped
 * to human text by the command handler; the no-op case ("No compactable
 * history yet.") is a `success` carrying that text, not an error.
 */
export type CompactCommandResultLike =
  | { kind: 'success'; text?: string }
  | { kind: 'error'; text: string }

/**
 * The raw settle of `commands.execute(agent, '/compact', ...)`, before the
 * route maps it to a status. `unknown-command` is `execute` resolving to
 * `undefined` (this preset mounts no compaction command); `command` is the
 * resolved `CommandExecution` wrapper; `rejected` is the promise rejecting
 * (a thrown handler or an aborted signal).
 */
export type CompactExecutionOutcome =
  | { kind: 'unknown-command' }
  | { kind: 'command'; result: CompactCommandResultLike }
  | { kind: 'rejected'; error: unknown }

/** The settled compact outcome: an `ok` success carries the completion text, a failure carries its status and text. */
export type CompactSettled =
  | { ok: true; text: string | undefined }
  | { ok: false; status: 501 | 409 | 500; text: string }

/** A human-worthy message from an arbitrary rejection, or '' when none is recoverable. */
function compactionRejectedText(error: unknown): string {
  if (typeof error === 'object' && error !== null) {
    const message = (error as { message?: unknown }).message
    if (typeof message === 'string' && message !== '') return message
  }
  return typeof error === 'string' ? error : ''
}

/**
 * Map the raw settle of `/compact` to an HTTP-ready outcome. An unknown
 * command is 501 (this preset mounts no compaction), a handled error result
 * is 409 carrying the harness's own text, and a rejected execution is 409
 * (500 only when no message is recoverable); a success passes its text
 * through for the 200 body.
 */
export function compactExecutionSettled(outcome: CompactExecutionOutcome): CompactSettled {
  switch (outcome.kind) {
    case 'unknown-command':
      return { ok: false, status: 501, text: 'this DSH preset mounts no compaction command' }
    case 'rejected': {
      const text = compactionRejectedText(outcome.error)
      return text === ''
        ? { ok: false, status: 500, text: 'compaction request was rejected' }
        : { ok: false, status: 409, text }
    }
    case 'command':
      if (outcome.result.kind === 'error') {
        return { ok: false, status: 409, text: outcome.result.text }
      }
      return { ok: true, text: outcome.result.text }
  }
}

/**
 * A per-key critical section: operations sharing a key run one after another,
 * in the order they were requested, while operations under different keys run
 * concurrently.
 *
 * This exists for check-then-act sequences whose decision is not itself
 * serialized by the service behind it. The workspace title rule is the live
 * example: `/workspaces/rename` and `/sessions/create` both read the roster
 * and then write a title, and the harness's workspace registry allows
 * duplicate titles, so two interleaved requests could each see a free name
 * and both claim it. Holding `runExclusive('workspace-titles', ...)` across
 * the read and the write makes the pair atomic within this process.
 *
 * The section keeps chaining even when an operation throws, so a rejected
 * caller cannot strand the key; each caller still sees its own error.
 */
export class KeyedSerial {
  private readonly tails = new Map<string, Promise<void>>()

  async runExclusive<T>(key: string, operation: () => Promise<T>): Promise<T> {
    const tail = this.tails.get(key) ?? Promise.resolve()
    const critical = tail.then(operation)
    // Chain on the settled section so a throw releases the key.
    const settled = critical.then(() => undefined, () => undefined)
    this.tails.set(key, settled)
    try {
      return await critical
    } finally {
      // Drop the key once its last section drains, so the map stays bounded.
      if (this.tails.get(key) === settled) this.tails.delete(key)
    }
  }
}


// ---- Single-item inspector (the /details/item route) ----------------------
//
// Unlike `/turns` (which reduces every trajectory fact to a one-line summary),
// the item route returns one selector's committed raw material: complete
// reasoning text, exact tool arguments and result content, and the durable
// per-call diff fragments attached by `write` and `edit`. Everything here is
// pure and bounded; `index.ts` only resolves a session, materializes one log,
// and serializes these results.
//
// Visibility is per item, not per turn. A compaction replacement can split a
// turn: one assistant message survives while another is shadowed. The inspector
// exposes only items whose own source seq is on the *current* surface, with two
// log-only rules for tool calls (they never become surface nodes): a call is
// visible when a current result settles it, or when it is still unsettled in an
// open turn. A call whose result was shadowed is not resurrected merely because
// the call event remains in the log.

/** Maximum file changes listed for one tool result. */
export const MAX_DETAIL_FILE_CHANGES = 50

/** Maximum fragments retained for one file change. */
export const MAX_DETAIL_FILE_FRAGMENTS = 200

/**
 * Maximum UTF-8 bytes loaded without confirmation.  A larger item's first
 * response carries sizes only; the inspector asks before fetching the whole
 * item.  The limit is the bridge's own, not the harness's: the session log
 * holds the complete text.
 */
export const DETAIL_FULL_LOAD_BYTES = 256 * 1024

/** One durable applied-diff fragment, exactly as the producing tool recorded
 * it: no original-file line positions and no final-newline marker. */
export interface DetailFileFragment {
  oldText: string | null
  newText: string
}

/** How a recognized mutation's durable diff record classifies. */
export type DetailDiffStatus = 'applied' | 'create' | 'empty' | 'none' | 'unavailable'

/** One file a tool result changed, with its durable fragments. */
export interface DetailFileChange {
  /** Recorded canonical path when the producer supplied one, else the
   * argument-derived path spelling. */
  path: string
  /** Absolute path resolved at the call, or at an orphan result's own event. */
  absolute: string
  /** Whether `path` is producer-recorded or inferred by the bridge. */
  pathSource: 'recorded' | 'inferred'
  /** Effective working directory at that event; absent when the session never
   * named one. */
  cwd?: string
  /** The recorded `write` operation, when the producer recorded one.  Never
   * inferred from the tool name. */
  operation?: 'create' | 'update'
  status: DetailDiffStatus
  /** Retained applied fragments; empty for every status except `applied`. */
  fragments: DetailFileFragment[]
  /** Total durable fragments, including any dropped by the retention bound. */
  totalFragments: number
  /** How many durable fragments the retention bound dropped. */
  droppedFragments: number
}

/** One file-change summary; its rendered text is carried complete. */
export interface DetailFileSummary {
  path: string
  absolute: string
  pathSource: 'recorded' | 'inferred'
  cwd?: string
  operation?: 'create' | 'update'
  status: DetailDiffStatus
  /** Total durable fragments, not merely the retained prefix. */
  fragmentCount: number
  retainedFragmentCount: number
  droppedFragments: number
  fragmentsTruncated: boolean
}

/** One projected non-text result content block.  The projection is a strict
 * allowlist: an image or file block contributes its display metadata, never
 * its opaque attachment id or any bytes. */
export interface DetailResultBlock {
  type: string
  mediaType?: string
  bytes?: number
  width?: number
  height?: number
  name?: string
}

/** Result content: text joined for display, plus non-text blocks. */
export interface DetailResultContent {
  text: string
  blocks: DetailResultBlock[]
  textBlocks: number
  omittedBlocks: number
}

/** Project a tool result's content blocks through the inspector allowlist. */
function projectResultContent(content: unknown): DetailResultContent {
  const texts: string[] = []
  const blocks: DetailResultBlock[] = []
  let textBlocks = 0
  let omittedBlocks = 0
  if (Array.isArray(content)) {
    for (const block of content) {
      if (!isRecord(block)) {
        omittedBlocks += 1
        continue
      }
      if (block.type === 'text' && typeof block.text === 'string') {
        texts.push(block.text)
        textBlocks += 1
        continue
      }
      if (block.type === 'image' || block.type === 'file') {
        const attachment = isRecord(block.attachment) ? block.attachment : undefined
        if (attachment === undefined) {
          omittedBlocks += 1
          continue
        }
        const projected: DetailResultBlock = { type: block.type }
        for (const key of ['mediaType', 'bytes', 'width', 'height', 'name'] as const) {
          const value = attachment[key]
          if (key === 'mediaType' || key === 'name') {
            if (typeof value === 'string' && value !== '') projected[key] = value
          } else if (typeof value === 'number' && Number.isFinite(value)) {
            projected[key] = value
          }
        }
        blocks.push(projected)
        continue
      }
      omittedBlocks += 1
      blocks.push({ type: typeof block.type === 'string' ? block.type : 'unknown' })
    }
  }
  return { text: texts.join('\n'), blocks, textBlocks, omittedBlocks }
}

/** One sanitized structured tool error.  AUTH diagnostics are suppressed
 * exactly as turn failures are: the reason may echo a preserved credential. */
export interface DetailToolError {
  name?: string
  code?: string
  reason?: string
}

/** Project the tool result's optional `error` field. */
function projectToolError(value: unknown): DetailToolError | undefined {
  if (!isRecord(value)) return undefined
  const code = typeof value.code === 'string' ? value.code : undefined
  const name = typeof value.name === 'string' ? value.name : undefined
  const reason = typeof value.reason === 'string' ? value.reason : undefined
  if (code === undefined && name === undefined && reason === undefined) return undefined
  const suppress = code === 'AUTH' || name === 'AUTH'
  return {
    ...name === undefined ? {} : { name },
    ...code === undefined ? {} : { code },
    ...reason === undefined || suppress ? {} : { reason },
  }
}

/** Turn facts that accompany the selected item, never a turn roster. */
interface DetailItemContext {
  turn: number
  open: boolean
  startedAt?: number
  endedAt?: number
  reason?: string
  failure?: TurnFailure
}

/** One visible reasoning block plus its complete committed text. */
export interface DetailThinkingItem extends DetailItemContext {
  kind: 'thinking'
  seq: number
  ord: number
  time: number
  step: number
  text: string
  /** A committed item has no live selector; explicit false for narrowing. */
  inFlight?: false
}

/**
 * One live reasoning block and the prefix retained at read time.  It has no
 * `seq`; the transient identity is the bridge-minted `inFlightId`, and
 * `truncated` means this block's later text was discarded by the host cap.
 */
export interface DetailInFlightThinkingItem extends DetailItemContext {
  kind: 'thinking'
  inFlight: true
  inFlightId: string
  attemptId: string
  revision: number
  ord: number
  time: number
  step: number
  text: string
  truncated?: true
}

/** One tool call fact in the fold, with the directory in effect at the call. */
interface DetailCallFact {
  seq: number
  time: number
  step: number
  callId: string
  name: string
  arguments: string
  cwd?: string
}

/** A result's retained files and their durable retention counts. */
interface DetailResultFiles {
  files: DetailFileChange[]
  totalFiles: number
  droppedFiles: number
}

/** One current tool result fact in the fold. */
interface DetailResultFact extends DetailResultFiles {
  seq: number
  time: number
  step: number
  callId: string
  name: string
  isError: boolean
  content: DetailResultContent
  error?: DetailToolError
  cwd?: string
}

/** One visible logical invocation and, when settled, its current result. */
export interface DetailToolItem extends DetailItemContext {
  kind: 'tool'
  call: DetailCallFact
  settlement: 'settled' | 'pending'
  result?: DetailResultFact
}

/** One current result with no call in the requested turn. */
export interface DetailOrphanResultItem extends DetailItemContext {
  kind: 'tool-result'
  result: DetailResultFact
}

/** The raw selected item, before its parts and diffs are rendered. */
export type DetailItem =
  | DetailThinkingItem
  | DetailInFlightThinkingItem
  | DetailToolItem
  | DetailOrphanResultItem

/** The outcome of one direct item selection. */
export type DetailItemResult =
  | { ok: true; item: DetailItem }
  | { ok: false; status: 404 | 409; reason: string; message: string }

/** One turn's raw detail facts, with no index or entry-retention model. */
interface DetailFold {
  turn: number
  open: boolean
  startedAt?: number
  endedAt?: number
  reason?: string
  failure?: TurnFailure
  thinking: DetailThinkingItem[]
  results: Map<number, DetailResultFact>
  /** Tool calls by call id (target turn only). */
  calls: Map<string, DetailCallFact>
  /** Tool result seqs by call id (target turn only), in log order. */
  resultSeqsByCall: Map<string, number[]>
}

/** The event at SEQ, or undefined when the log is sparse. */
function eventAtSeq(events: readonly SessionEventLike[], seq: number): SessionEventLike | undefined {
  const direct = events[seq] as SessionEventLike | undefined
  if (direct !== undefined && (direct.seq === undefined || direct.seq === seq)) return direct
  return events.find(event => event.seq === seq)
}

/** The event's log seq, falling back to its array position. */
function seqOf(event: SessionEventLike, index: number): number {
  return typeof event.seq === 'number' ? event.seq : index
}

/** The event's numeric turn, if it carries one. */
function eventTurn(event: SessionEventLike): number | undefined {
  if (!isRecord(event.data)) return undefined
  const turn = event.data.turn
  return typeof turn === 'number' && Number.isSafeInteger(turn) ? turn : undefined
}

/** The tool-role message of one `tool/result` event. */
function resultMessage(event: SessionEventLike): Record<string, unknown> | undefined {
  const data = isRecord(event.data) ? event.data : undefined
  const message = data?.message
  return isRecord(message) ? message : undefined
}

/** The result's call id, read exactly as the changed-files fold reads it. */
function resultCallId(event: SessionEventLike): string | undefined {
  const message = resultMessage(event)
  if (message === undefined) return undefined
  const source = message.source
  if (isRecord(source) && typeof source.callId === 'string') return source.callId
  return typeof message.toolCallId === 'string' ? message.toolCallId : undefined
}

/** Whether VALUE is a valid persisted file-diff fragment. */
function validFileDiff(value: unknown): value is DetailFileFragment & { path: string } {
  if (!isRecord(value)) return false
  return typeof value.path === 'string'
    && (value.oldText === null || typeof value.oldText === 'string')
    && typeof value.newText === 'string'
}

/** Resolve a path against a base directory, keeping it verbatim without one. */
function resolvePath(base: string | undefined, path: string): string {
  if (isAbsolute(path)) return path
  return base === undefined || base === '' ? path : resolve(base, path)
}

/**
 * Derive one successful mutation result's file changes from its durable
 * `meta`.  The classification matrix is the route contract:
 *
 * - `applied`: a valid non-empty `diffs` array;
 * - `create`: `operation: 'create'` with an empty `diffs` array;
 * - `empty`: a valid empty `diffs` array without the create classification;
 * - `none`: no durable applied-diff presentation (notably `str_replace_editor`);
 * - `unavailable`: a `diffs` key that is not a valid non-empty fragment list.
 */
function resultFileChanges(
  event: SessionEventLike,
  call: DetailCallFact | undefined,
  resultCwd: string | undefined,
): DetailResultFiles {
  const none: DetailResultFiles = { files: [], totalFiles: 0, droppedFiles: 0 }
  const one = (file: DetailFileChange): DetailResultFiles => ({
    files: [file], totalFiles: 1, droppedFiles: 0,
  })
  // A recognized mutation's call supplies the argument-derived fallback path.
  // An orphan result has no call to recognize, but its producer-recorded
  // `meta.diffs` / `meta.path` is independent evidence and still belongs to the
  // result's seq; expose it rather than hiding a real applied change.
  const mutation = call === undefined ? null : mutationCall(call.name, call.arguments)
  if (call !== undefined && mutation === null) return none
  const message = resultMessage(event)
  if (message?.isError === true) return none
  const data = isRecord(event.data) ? event.data : undefined
  const meta = data?.meta
  const metaRecord = isRecord(meta) ? meta : undefined
  if (call === undefined && metaRecord === undefined) return none
  const recordedPath = typeof metaRecord?.path === 'string' && metaRecord.path !== ''
    ? metaRecord.path
    : undefined
  const operation = metaRecord?.operation === 'create' || metaRecord?.operation === 'update'
    ? metaRecord.operation
    : undefined
  const cwd = call?.cwd ?? resultCwd
  const base = (path: string, recorded: boolean): DetailFileChange => ({
    path,
    absolute: resolvePath(cwd, path),
    pathSource: recorded ? 'recorded' : 'inferred',
    ...cwd === undefined ? {} : { cwd },
    ...operation === undefined ? {} : { operation },
    status: 'none',
    fragments: [],
    totalFragments: 0,
    droppedFragments: 0,
  })

  // A present but non-object `meta` cannot be decoded as the producer's
  // durable diff record; do not silently downgrade it to `none`.
  if (meta !== undefined && metaRecord === undefined) {
    const path = recordedPath ?? mutation?.path
    return path === undefined ? none : one({ ...base(path, recordedPath !== undefined), status: 'unavailable' })
  }
  if (metaRecord !== undefined && 'diffs' in metaRecord) {
    const diffs = metaRecord.diffs
    if (!Array.isArray(diffs) || !diffs.every(validFileDiff)) {
      const firstPath = Array.isArray(diffs)
        ? diffs.find(value => isRecord(value) && typeof value.path === 'string') as { path?: string } | undefined
        : undefined
      const path = recordedPath ?? mutation?.path ?? firstPath?.path
      return path === undefined ? none : one({ ...base(path, recordedPath !== undefined), status: 'unavailable' })
    }
    if (diffs.length === 0) {
      const path = recordedPath ?? mutation?.path
      return path === undefined ? none : one({
        ...base(path, recordedPath !== undefined),
        status: operation === 'create' ? 'create' : 'empty',
      })
    }
    // The producer stamps every hunk with the applied path; group hunks that
    // name the same file while preserving file order.
    const byPath = new Map<string, DetailFileFragment[]>()
    for (const diff of diffs as (DetailFileFragment & { path: string })[]) {
      const path = recordedPath ?? diff.path
      const list = byPath.get(path)
      const fragment = { oldText: diff.oldText, newText: diff.newText }
      if (list === undefined) byPath.set(path, [fragment])
      else list.push(fragment)
    }
    const changes: DetailFileChange[] = []
    for (const [path, fragments] of byPath) {
      const retained = fragments.slice(0, MAX_DETAIL_FILE_FRAGMENTS)
      changes.push({
        ...base(path, true),
        status: 'applied',
        fragments: retained,
        totalFragments: fragments.length,
        droppedFragments: fragments.length - retained.length,
      })
      if (changes.length >= MAX_DETAIL_FILE_CHANGES) break
    }
    return {
      files: changes,
      totalFiles: byPath.size,
      droppedFiles: byPath.size - changes.length,
    }
  }
  // No durable applied-diff presentation.  A recognized mutation can still
  // expose its argument-derived path as `none`; an orphan result with nothing
  // producer-recorded contributes no file entry.
  const path = recordedPath ?? mutation?.path
  return path === undefined ? none : one({ ...base(path, recordedPath !== undefined), status: 'none' })
}

/** A file-change summary projected from a retained record. */
function fileSummary(file: DetailFileChange): DetailFileSummary {
  return {
    path: file.path,
    absolute: file.absolute,
    pathSource: file.pathSource,
    ...file.cwd === undefined ? {} : { cwd: file.cwd },
    ...file.operation === undefined ? {} : { operation: file.operation },
    status: file.status,
    fragmentCount: file.totalFragments,
    retainedFragmentCount: file.fragments.length,
    droppedFragments: file.droppedFragments,
    fragmentsTruncated: file.droppedFragments > 0,
  }
}

/** One immutable turn observation's raw item projection. */
export interface DetailItemProjection {
  fold: DetailFold | null
}

/** Fold one turn once so repeated item reads share visibility and files. */
export function buildDetailItemProjection(args: {
  turn: number
  events: readonly SessionEventLike[]
  surfaceSeqs: ReadonlySet<number>
  boundaries: TurnBoundaries
  headerCwd?: string
}): DetailItemProjection {
  return {
    fold: foldTurnDetail(args.events, args.surfaceSeqs, args.turn, args.boundaries, args.headerCwd),
  }
}

/** Fold one turn's raw item facts, or null when the turn has no events. */
function foldTurnDetail(
  events: readonly SessionEventLike[],
  surfaceSeqs: ReadonlySet<number>,
  turn: number,
  boundaries: TurnBoundaries,
  sessionCwd: string | undefined,
): DetailFold | null {
  const open = !boundaries.ends.has(turn)
  const end = boundaries.ends.get(turn)
  const context: DetailItemContext = {
    turn,
    open,
    ...boundaries.starts.has(turn) ? { startedAt: boundaries.starts.get(turn) } : {},
    ...end === undefined ? {} : { endedAt: end.time },
    ...end?.reason === undefined ? {} : { reason: end.reason },
    ...end?.failure === undefined ? {} : { failure: end.failure },
  }
  const calls = new Map<string, DetailCallFact>()
  const resultSeqsByCall = new Map<string, number[]>()
  const results = new Map<number, DetailResultFact>()
  const thinking: DetailThinkingItem[] = []
  const resultCwds = new Map<number, string | undefined>()
  let currentCwd = sessionCwd
  let sawTurn = false

  // First pass: calls (with the directory in effect at the call) and the
  // result seqs that may settle them.  Log order is the call's order.
  for (let index = 0; index < events.length; index += 1) {
    const event = events[index]
    if (event === undefined) continue
    if (movesWorkingDirectory(event.type)) {
      const next = (event.data as { cwd?: unknown } | undefined)?.cwd
      if (typeof next === 'string' && next !== '') currentCwd = next
      continue
    }
    if (event.type === 'tool/call') {
      const call = toolCallFact(event)
      if (call === null || call.turn !== turn) continue
      sawTurn = true
      const step = isRecord(event.data) && typeof event.data.step === 'number' ? event.data.step : undefined
      if (step === undefined) continue
      calls.set(call.callId, {
        seq: seqOf(event, index),
        time: event.time,
        step,
        callId: call.callId,
        name: call.name,
        arguments: call.arguments,
        ...currentCwd === undefined ? {} : { cwd: currentCwd },
      })
      continue
    }
    if (event.type === 'tool/result') {
      const data = isRecord(event.data) ? event.data : undefined
      const resultTurn = data?.turn
      if (resultTurn !== turn || typeof resultTurn !== 'number') continue
      sawTurn = true
      const seq = seqOf(event, index)
      resultCwds.set(seq, currentCwd)
      const callId = resultCallId(event)
      if (callId === undefined) continue
      const seqs = resultSeqsByCall.get(callId)
      if (seqs === undefined) resultSeqsByCall.set(callId, [seq])
      else seqs.push(seq)
      continue
    }
    if (turn === eventTurn(event)) sawTurn = true
  }
  if (!sawTurn) return null

  // Second pass: only current surface events produce reasoning and results.
  for (let index = 0; index < events.length; index += 1) {
    const event = events[index]
    if (event === undefined) continue
    const seq = seqOf(event, index)
    if (eventTurn(event) !== turn || !surfaceSeqs.has(seq)) continue
    if (event.type === 'assistant/message') {
      const data = isRecord(event.data) ? event.data : undefined
      const step = data?.step
      if (typeof step !== 'number') continue
      const message = data?.message
      const content = isRecord(message) && Array.isArray(message.content) ? message.content : undefined
      if (content === undefined) continue
      let ord = 0
      for (const block of content) {
        if (!isRecord(block) || block.type !== 'reasoning') continue
        const blockOrd = ord
        ord += 1
        const text = typeof block.text === 'string' ? block.text : undefined
        if (text === undefined || text.trim() === '') continue
        thinking.push({ ...context, kind: 'thinking', seq, ord: blockOrd, time: event.time, step, text })
      }
      continue
    }
    if (event.type !== 'tool/result') continue
    const data = isRecord(event.data) ? event.data : undefined
    const step = data?.step
    if (typeof step !== 'number') continue
    const callId = resultCallId(event) ?? ''
    const message = resultMessage(event)
    const call = calls.get(callId)
    const error = projectToolError(data?.error)
    const fileChanges = resultFileChanges(event, call, resultCwds.get(seq))
    const cwd = resultCwds.get(seq)
    results.set(seq, {
      seq,
      time: event.time,
      step,
      callId,
      name: call?.name ?? 'tool',
      isError: message?.isError === true,
      content: projectResultContent(message?.content),
      ...error === undefined ? {} : { error },
      ...fileChanges,
      ...cwd === undefined ? {} : { cwd },
    })
  }

  return { ...context, thinking, results, calls, resultSeqsByCall }
}

/** The current visible result for CALLID, choosing the latest current copy. */
function currentDetailResult(fold: DetailFold, callId: string): DetailResultFact | undefined {
  const seqs = fold.resultSeqsByCall.get(callId)
  if (seqs === undefined) return undefined
  for (let index = seqs.length - 1; index >= 0; index -= 1) {
    const result = fold.results.get(seqs[index] as number)
    if (result !== undefined) return result
  }
  return undefined
}

/** The selected item's boundary/failure metadata. */
function detailItemContext(fold: DetailFold): DetailItemContext {
  return {
    turn: fold.turn,
    open: fold.open,
    ...fold.startedAt === undefined ? {} : { startedAt: fold.startedAt },
    ...fold.endedAt === undefined ? {} : { endedAt: fold.endedAt },
    ...fold.reason === undefined ? {} : { reason: fold.reason },
    ...fold.failure === undefined ? {} : { failure: fold.failure },
  }
}

/**
 * Select exactly one current item.  Its 409s mean the item is no longer
 * visible on the current surface, never a stale-read or retention problem:
 * the route observes the log once and returns the complete item.
 */
export function buildDetailItem(args: {
  turn: number
  events: readonly SessionEventLike[]
  surfaceSeqs: ReadonlySet<number>
  boundaries: TurnBoundaries
  headerCwd?: string
  kind: DetailItemKind
  seq?: number
  ord?: number
  callId?: string
  projection?: DetailItemProjection
}): DetailItemResult {
  const fold = args.projection === undefined
    ? foldTurnDetail(args.events, args.surfaceSeqs, args.turn, args.boundaries, args.headerCwd)
    : args.projection.fold
  if (fold === null) {
    return { ok: false, status: 404, reason: 'unknown-turn', message: `turn ${args.turn} is unknown` }
  }
  const notVisible: DetailItemResult = {
    ok: false, status: 409, reason: 'not-visible', message: `the requested ${args.kind} item is no longer visible`,
  }
  if (args.kind === 'thinking') {
    const seq = args.seq as number
    const ord = args.ord as number
    const selected = fold.thinking.find(item => item.seq === seq && item.ord === ord)
    if (selected !== undefined) return { ok: true, item: selected }
    const event = eventAtSeq(args.events, seq)
    if (event === undefined || eventTurn(event) !== args.turn || event.type !== 'assistant/message') {
      return { ok: false, status: 404, reason: 'unknown-item', message: `no thinking message at seq ${seq} in turn ${args.turn}` }
    }
    if (fold.thinking.some(item => item.seq === seq)) {
      return { ok: false, status: 404, reason: 'unknown-ordinal', message: `no reasoning block ${ord}` }
    }
    return notVisible
  }

  const callId = args.callId as string
  if (args.kind === 'tool') {
    const call = fold.calls.get(callId)
    if (call === undefined) {
      return { ok: false, status: 404, reason: 'unknown-item', message: `no tool call ${callId} in turn ${args.turn}` }
    }
    const result = currentDetailResult(fold, callId)
    if (result !== undefined) {
      return { ok: true, item: { ...detailItemContext(fold), kind: 'tool', call, settlement: 'settled', result } }
    }
    // A call with only shadowed/malformed results is not pending: its original
    // settlement is historical, and another surviving turn item cannot revive it.
    if (!fold.resultSeqsByCall.has(callId) && fold.open) {
      return { ok: true, item: { ...detailItemContext(fold), kind: 'tool', call, settlement: 'pending' } }
    }
    return notVisible
  }

  // Orphan reads deliberately do not resolve through a same-id call.  A paired
  // invocation is the other selector's item, never an orphan-result fallback.
  if (fold.calls.has(callId)) {
    return { ok: false, status: 404, reason: 'not-orphan', message: `tool result ${callId} has a call in turn ${args.turn}` }
  }
  const result = currentDetailResult(fold, callId)
  if (result !== undefined) {
    return { ok: true, item: { ...detailItemContext(fold), kind: 'tool-result', result } }
  }
  if (!fold.resultSeqsByCall.has(callId)) {
    return { ok: false, status: 404, reason: 'unknown-item', message: `no orphan result ${callId} in turn ${args.turn}` }
  }
  return notVisible
}

/** The boundary facts available without folding the turn's items. */
function detailBoundaryContext(turn: number, boundaries: TurnBoundaries): DetailItemContext {
  const end = boundaries.ends.get(turn)
  return {
    turn,
    open: end === undefined,
    ...boundaries.starts.has(turn) ? { startedAt: boundaries.starts.get(turn) } : {},
    ...end === undefined ? {} : { endedAt: end.time },
    ...end?.reason === undefined ? {} : { reason: end.reason },
    ...end?.failure === undefined ? {} : { failure: end.failure },
  }
}

/**
 * Resolve one transient `inFlightId + ord` selector.  A live attempt yields
 * its retained snapshot; a settled one is translated onto the committed
 * item (directly for a normal message, through the survivor rule for an
 * interrupted message) and goes through the ordinary visibility checks.  A
 * log-only or abandoned settlement is 409 `not-visible`.
 */
export function buildInFlightDetailItem(args: {
  registry: InFlightActivityRegistry
  sessionId: string
  turn: number
  ord: number
  inFlightId: string
  events: readonly SessionEventLike[]
  surfaceSeqs: ReadonlySet<number>
  boundaries: TurnBoundaries
  headerCwd?: string
  projection?: DetailItemProjection
}): DetailItemResult {
  const selection = args.registry.select(args.sessionId, args.inFlightId, args.turn, args.ord)
  if (!selection.ok) return selection
  const context = detailBoundaryContext(args.turn, args.boundaries)
  if (selection.kind === 'live') {
    return {
      ok: true,
      item: {
        ...context,
        kind: 'thinking',
        inFlight: true,
        inFlightId: selection.inFlightId,
        attemptId: selection.attemptId,
        revision: selection.revision,
        ord: selection.ord,
        time: selection.time,
        step: selection.step,
        text: selection.text,
        ...selection.truncated ? { truncated: true as const } : {},
      },
    }
  }
  const event = eventAtSeq(args.events, selection.seq)
  if (event === undefined || event.type !== 'assistant/message' || eventTurn(event) !== args.turn) {
    return {
      ok: false,
      status: 409,
      reason: 'not-visible',
      message: `in-flight thinking ${args.inFlightId} has no visible committed item`,
    }
  }
  const data = isRecord(event.data) ? event.data : undefined
  const interrupted = data?.interrupted === true
  if (interrupted && !selection.survivors.includes(selection.liveOrd)) {
    return {
      ok: false,
      status: 409,
      reason: 'not-visible',
      message: `in-flight thinking block ${selection.liveOrd} did not survive the interrupted assembly`,
    }
  }
  const ord = interrupted
    ? selection.survivors.filter(candidate => candidate < selection.liveOrd).length
    : selection.liveOrd
  const result = buildDetailItem({
    turn: args.turn,
    events: args.events,
    surfaceSeqs: args.surfaceSeqs,
    boundaries: args.boundaries,
    ...args.headerCwd === undefined ? {} : { headerCwd: args.headerCwd },
    kind: 'thinking',
    seq: selection.seq,
    ord,
    ...args.projection === undefined ? {} : { projection: args.projection },
  })
  // A translated ordinal that names no committed item is a visibility loss,
  // not a malformed selector: the transient id is known and settled.
  if (!result.ok && result.status === 404) {
    return {
      ok: false,
      status: 409,
      reason: 'not-visible',
      message: `in-flight thinking ${args.inFlightId} is no longer visible`,
    }
  }
  return result
}

/** Bounded display output for one file, supplied by the pure route caller's
 * `detail.ts` adapter without making `logic.ts` import the diff dependency. */
export interface DetailDiffRender {
  text: string
  render: 'ok' | 'coarse' | 'too-large'
  added: number
  removed: number
  truncated: boolean
}

/** One complete text payload and its UTF-8 byte size. */
export interface DetailTextPart {
  text: string
  totalBytes: number
}

/** One complete rendered file diff and its rendering metadata. */
export interface DetailDiffPart extends DetailDiffRender {
  totalBytes: number
}

/** One file summary with its complete diff. */
export interface DetailItemFile extends DetailFileSummary {
  diff: DetailDiffPart
}

/** Result metadata; the potentially large text lives in `parts.result`. */
export interface DetailResultMetadata {
  seq: number
  time: number
  step: number
  isError: boolean
  content: Omit<DetailResultContent, 'text'>
  error?: DetailToolError
}

interface DetailResponseBase extends DetailItemContext {
  sessionId: string
  epoch: number
  cursor: number
  cwd?: string
  /** UTF-8 bytes of every text part and diff in this item. */
  totalBytes: number
  /** True when the first read withheld the text pending confirmation. */
  deferred?: true
}

export interface DetailThinkingResponse extends DetailResponseBase {
  kind: 'thinking'
  seq: number
  ord: number
  time: number
  step: number
  parts: { reasoning?: DetailTextPart }
}

/** One live attempt's selected block: the retained prefix, no committed seq. */
export interface DetailInFlightThinkingResponse extends DetailResponseBase {
  kind: 'thinking'
  inFlight: true
  inFlightId: string
  attemptId: string
  revision: number
  ord: number
  time: number
  step: number
  /** This block's later text was discarded by the host retention cap. */
  truncated?: true
  parts: { reasoning?: DetailTextPart }
}

export interface DetailToolResponse extends DetailResponseBase {
  kind: 'tool'
  seq: number
  time: number
  step: number
  callId: string
  name: string
  callCwd?: string
  settlement: 'settled' | 'pending'
  parts: { arguments?: DetailTextPart; result?: DetailTextPart }
  result?: DetailResultMetadata
  files?: DetailItemFile[]
  totalFiles?: number
  droppedFiles?: number
  filesTruncated?: boolean
}

export interface DetailOrphanResultResponse extends DetailResponseBase {
  kind: 'tool-result'
  seq: number
  time: number
  step: number
  callId: string
  name: string
  resultCwd?: string
  settlement: 'orphan'
  isError: boolean
  content: Omit<DetailResultContent, 'text'>
  error?: DetailToolError
  parts: { result?: DetailTextPart }
  files?: DetailItemFile[]
  totalFiles?: number
  droppedFiles?: number
  filesTruncated?: boolean
}

/** The tagged response union returned by a probe or full read. */
export type DetailItemResponse =
  | DetailThinkingResponse
  | DetailInFlightThinkingResponse
  | DetailToolResponse
  | DetailOrphanResultResponse

/** Project one result's non-text metadata without its text payload. */
function detailResultMetadata(result: DetailResultFact): DetailResultMetadata {
  return {
    seq: result.seq,
    time: result.time,
    step: result.step,
    isError: result.isError,
    content: {
      blocks: result.content.blocks,
      textBlocks: result.content.textBlocks,
      omittedBlocks: result.content.omittedBlocks,
    },
    ...result.error === undefined ? {} : { error: result.error },
  }
}

/** UTF-8 byte length of one text payload. */
function detailBytes(text: string): number {
  return Buffer.byteLength(text, 'utf8')
}

/** Project one complete text payload. */
function detailTextPart(text: string): DetailTextPart {
  return { text, totalBytes: detailBytes(text) }
}

/** Sum the text bytes of one response, including every file diff. */
function detailResponseBytes(response: DetailItemResponse): number {
  let total = 0
  for (const part of Object.values(response.parts)) total += part?.totalBytes ?? 0
  if ('files' in response) {
    for (const file of response.files ?? []) total += file.diff.totalBytes
  }
  return total
}

/** Withhold every text payload, retaining its size and all metadata. */
function deferredDetailResponse(response: DetailItemResponse, totalBytes: number): DetailItemResponse {
  const files = 'files' in response
    ? response.files?.map(file => ({ ...file, diff: { ...file.diff, text: '' } }))
    : undefined
  if (response.kind === 'thinking') {
    const reasoning = response.parts.reasoning
    return {
      ...response,
      totalBytes,
      deferred: true,
      parts: reasoning === undefined ? {} : { reasoning: { ...reasoning, text: '' } },
    }
  }
  if (response.kind === 'tool') {
    const { arguments: args, result } = response.parts
    return {
      ...response,
      totalBytes,
      deferred: true,
      parts: {
        ...args === undefined ? {} : { arguments: { ...args, text: '' } },
        ...result === undefined ? {} : { result: { ...result, text: '' } },
      },
      ...files === undefined ? {} : { files },
    }
  }
  const result = response.parts.result
  return {
    ...response,
    totalBytes,
    deferred: true,
    parts: result === undefined ? {} : { result: { ...result, text: '' } },
    ...files === undefined ? {} : { files },
  }
}

/**
 * Build one selected item's complete response.  The response carries every
 * available part and file diff in one payload.  If the total text exceeds
 * {@link DETAIL_FULL_LOAD_BYTES} and the request did not say `full`, the text is
 * withheld and `deferred` marks the size probe; the inspector then asks the
 * user before requesting the full item.
 */
export function buildDetailItemResponse(args: {
  sessionId: string
  epoch: number
  cursor: number
  cwd?: string
  item: DetailItem
  request: Pick<DetailItemRequest, 'full'>
  renderDiff: (file: DetailFileChange) => DetailDiffRender
}): DetailItemResponse {
  const { item } = args
  const base: DetailResponseBase = {
    sessionId: args.sessionId,
    turn: item.turn,
    epoch: args.epoch,
    cursor: args.cursor,
    ...args.cwd === undefined ? {} : { cwd: args.cwd },
    totalBytes: 0,
    open: item.open,
    ...item.startedAt === undefined ? {} : { startedAt: item.startedAt },
    ...item.endedAt === undefined ? {} : { endedAt: item.endedAt },
    ...item.reason === undefined ? {} : { reason: item.reason },
    ...item.failure === undefined ? {} : { failure: item.failure },
  }
  const filePart = (file: DetailFileChange): DetailItemFile => {
    const rendered = args.renderDiff(file)
    return {
      ...fileSummary(file),
      diff: {
        ...rendered,
        totalBytes: detailBytes(rendered.text),
      },
    }
  }
  const fileBody = (result: DetailResultFact): Pick<DetailToolResponse,
    'files' | 'totalFiles' | 'droppedFiles' | 'filesTruncated'> => {
    const files = result.files.map(file => filePart(file))
    return {
      files,
      totalFiles: result.totalFiles,
      droppedFiles: result.droppedFiles,
      filesTruncated: result.droppedFiles > 0,
    }
  }

  let response: DetailItemResponse
  if (item.kind === 'thinking') {
    if (item.inFlight === true) {
      // The live branch is separate so the committed branch below stays
      // byte-for-byte identical.
      response = {
        ...base,
        kind: 'thinking',
        inFlight: true,
        inFlightId: item.inFlightId,
        attemptId: item.attemptId,
        revision: item.revision,
        ord: item.ord,
        time: item.time,
        step: item.step,
        ...item.truncated === true ? { truncated: true as const } : {},
        parts: { reasoning: detailTextPart(item.text) },
      }
    } else {
      response = {
        ...base,
        kind: 'thinking', seq: item.seq, ord: item.ord, time: item.time, step: item.step,
        parts: { reasoning: detailTextPart(item.text) },
      }
    }
  } else if (item.kind === 'tool') {
    const call = item.call
    response = {
      ...base,
      kind: 'tool',
      seq: call.seq,
      time: call.time,
      step: call.step,
      callId: call.callId,
      name: call.name,
      ...call.cwd === undefined ? {} : { callCwd: call.cwd },
      settlement: item.settlement,
      parts: {
        arguments: detailTextPart(call.arguments),
        ...item.result === undefined ? {} : { result: detailTextPart(item.result.content.text) },
      },
      ...item.result === undefined ? {} : { result: detailResultMetadata(item.result) },
      ...item.result === undefined || item.result.files.length === 0 ? {} : fileBody(item.result),
    }
  } else {
    const result = item.result
    response = {
      ...base,
      kind: 'tool-result',
      seq: result.seq,
      time: result.time,
      step: result.step,
      callId: result.callId,
      name: result.name,
      ...result.cwd === undefined ? {} : { resultCwd: result.cwd },
      settlement: 'orphan',
      isError: result.isError,
      content: {
        blocks: result.content.blocks,
        textBlocks: result.content.textBlocks,
        omittedBlocks: result.content.omittedBlocks,
      },
      ...result.error === undefined ? {} : { error: result.error },
      parts: { result: detailTextPart(result.content.text) },
      ...result.files.length === 0 ? {} : fileBody(result),
    }
  }

  const totalBytes = detailResponseBytes(response)
  const complete = { ...response, totalBytes }
  return args.request.full === true || totalBytes <= DETAIL_FULL_LOAD_BYTES
    ? complete
    : deferredDetailResponse(complete, totalBytes)
}
