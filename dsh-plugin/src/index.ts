// dsh-emacs-bridge — DSH host-plane function plugin. Cordis id: `dsh-bridge`.
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
// Routes (all require `Authorization: Bearer <token>` — except the token-vend
// and browser-SSE routes; see logic.ts for the pure decision logic).  There is
// no host-side target pin: the host resolves "no sessionId" to last-active
// (see the UX plan, Section 3.2), so `/select` and `/current` do not exist.
//   GET  /dsh-bridge/token                          -> vend the token (loopback-fenced)
//   GET  /dsh-bridge/status                         -> { name, version } (loopback-fenced)
//   GET  /dsh-bridge/events?token=                  -> EventSource (composer-draft push)
//        (?purpose=draft marks the browser's own draft stream; an unmarked
//        connection is Emacs and is eligible to answer ask-user questions,
//        which coexist with the web UI's own question panel)
//   POST /dsh-bridge/send   { text?, sessionId?, attachments?: [{path, name?}] }
//        -> stage host-local absolute paths into the durable attachment store,
//        then Agent.followup() (images sniffed from content and rejected for
//        text-only models; 501 without an attachment store; 413 over the caps)
//   GET  /dsh-bridge/output?sessionId=           -> latest assistant text
//        (kept deliberately: a single-shot "latest text" probe; the Emacs
//        package no longer calls it)
//   GET  /dsh-bridge/sessions                     -> live + persisted sessions
//   GET  /dsh-bridge/session?sessionId=           -> one read-only session report
//        (identity + lineage + sessionStats/tokenUsage/contextPressure/
//        contextBreakdown/modelSelection/permissions/title; observes live and
//        cold sessions without resuming, 404 unknown, 409 subagent-owned)
//   GET  /dsh-bridge/prompts?sessionId=           -> user prompts, newest first
//   GET  /dsh-bridge/turns?sessionId=             -> turn-aggregated assistant
//        replies, newest first (each turn: { turn, startedAt, endedAt?,
//        reason?, endSeq?, segments: [{ text, time, step }] }; endSeq is the
//        turn/end event's seq — the session/fork anchor — and is absent while
//        the turn is open) plus running, epoch, title and cwd.  Optional
//        since=<turn>&epoch=<n> request the incremental suffix: turns with
//        turn >= since when the epoch matches the surface's replaceGeneration,
//        else the full list (incremental: true|false)
//   POST /dsh-bridge/draft { text, sessionId? }   -> push a composer draft (SSE)
//   GET  /dsh-bridge/outbox                       -> collect DSH->Emacs entries
//   POST /dsh-bridge/outbox { text | messageId, sessionId, source? }
//        -> deposit an entry (sessionId required: every entry is session-scoped;
//        a messageId deposit resolves the assistant message's text host-side)
//   POST /dsh-bridge/outbox/ack { ids }           -> clear collected entries
//   POST /dsh-bridge/answer { questionId, sessionId, answers? | cancelled? }
//        -> settle the bridge's pending ask-user waterfall answerer
//   GET  /dsh-bridge/models?sessionId=     -> model catalog + current selection
//   POST /dsh-bridge/model { sessionId?, provider, model, reasoningEffort? }
//        -> change the target session's model (proxies session/selectModel)
//   GET  /dsh-bridge/context?sessionId=    -> context occupancy (204 if none)
//   POST /dsh-bridge/sessions/resume { sessionId }        -> resume a cold session
//   POST /dsh-bridge/sessions/rename { sessionId, title } -> rename (resumes cold)
//   POST /dsh-bridge/sessions/archive { sessionId }       -> archive (one-way)
//   POST /dsh-bridge/sessions/create { workspaceId | path, workspaceTitle? }
//        -> create a session in a workspace (exactly one of the two keys)
//   POST /dsh-bridge/fork { sessionId?, atSeq? } -> branch a completed-turn
//        prefix into a new session (returns the child id; the source may be
//        cold — it is never resumed; 409 session/fork-unavailable or
//        subagent-owned, 501 without a session controller)
//   GET  /dsh-bridge/workspaces                   -> workspace roster
//   POST /dsh-bridge/workspaces/rename { workspaceId, title } -> rename a workspace

import { createReadStream, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { open, readFile, stat } from 'node:fs/promises'
import { randomBytes, randomUUID } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { basename, dirname, isAbsolute, join } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent, AgentOptions, ModelSelection, ModelSelectionRef } from '@deepseek-ai/dsh-agent'
import { installModelSelection } from '@deepseek-ai/dsh-agent'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import { createUserMessage, type ContentBlock } from '@deepseek-ai/dsh-llm'
import type { Session, SessionHeader, SessionId } from '@deepseek-ai/dsh-session'
// Type-only: pulls the `user-questions/request` waterfall declaration (the
// ask-user seam the bridge answers) into the cordis Events merge. Erased at
// build; never a runtime import.
import type {} from '@deepseek-ai/dsh-user-questions'
import type { AskUserQuestionAnswer } from '@deepseek-ai/dsh-user-questions'
// The request-event type itself is exported only from the ./types subpath.
import type { AskUserQuestionRequestEvent } from '@deepseek-ai/dsh-user-questions/types'
import { Outbox } from './outbox.ts'
import {
  answerMatchesQuestions,
  askUserMessage,
  askUserResolvedMessage,
  assistantMessageHasText,
  assistantTextForMessage,
  assistantTurns,
  attachmentErrorHttpStatus,
  catalogModelName,
  classifySessionId,
  contextMessage,
  contextUsedTokens,
  currentModelSelection,
  draftMessage,
  imageInputUnsupported,
  isLoopbackAddress,
  isQuestionCancelRejection,
  isSubagentChild,
  latestAssistantText,
  manifestVersion,
  MAX_ATTACHMENT_FILE_BYTES,
  mergeSessionRows,
  outboxMessage,
  outboxSessionId,
  parseAttachmentRequests,
  parseBearerAuthorization,
  repliesChangedMessage,
  resolveReadTargetId,
  resolveTargetId,
  rpcArgsPayload,
  rpcRequestFrame,
  rpcUnwrapResponse,
  sessionPreset,
  sessionReport,
  sessionTitle,
  sessionsChangedMessage,
  sniffImageMediaType,
  tokenRequestsSameOrigin,
  tokensEqual,
  turnCompleteMessage,
  turnStartMessage,
  turnsSince,
  userPrompts,
  workspaceRefsBySession,
  workspaceTitleConflict,
  type AttachmentRequest,
  type BridgeImageMediaType,
  type LiveSessionLike,
  type AskUserAnswerItemLike,
  type AskUserQuestionItemLike,
  type MessageBlockLike,
  type ReadTargetResult,
  type ResolveTargetResult,
  type SessionEventLike,
  type SessionHeaderLike,
  type SessionObservationLike,
  type SessionReport,
  type SessionReportExtras,
  type SessionRow,
  type WorkspaceLike,
} from './logic.ts'

export const name = 'dsh-bridge'

export const inject = ['agents', 'webServer', 'sessions', 'sessionPersistence']

/** Minimal face of the `webServer` service. */
interface WebServerService {
  register(route: {
    kind: 'exact' | 'prefix'
    path: string
    handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>
  }): () => void
  /** The listening port (the OS-assigned value when config.port is 0). */
  port: number
}

/** Minimal face of the `sessions` service: enumerate live sessions. */
interface SessionService {
  list(): Session[]
}

/**
 * Minimal face of the `sessionPersistence` service. `list` returns
 * header-carrying snapshots (the revision token is opaque to the bridge);
 * `stat` is the cheap existence/header read; `open(id, 'read')` is the full
 * header + event-log read (the removed `inspect`'s replacement).
 */
interface SessionPersistenceService {
  list(options?: { signal?: AbortSignal }): Promise<readonly { header: SessionHeader }[]>
  stat(id: string, options?: { signal?: AbortSignal }): Promise<{ header: SessionHeader } | undefined>
  open(id: string, access: 'read'): Promise<SessionReadHandleLike>
}

/** Minimal face of one open read handle on a stored session. */
interface SessionReadHandleLike {
  readonly header: SessionHeader
  read(): Promise<{ events: readonly SessionEventLike[] }>
  close(): Promise<void>
}

/** Minimal face of one persisted projection-cache snapshot. */
interface ProjectionSnapshotLike {
  asOfSeq: number
  values: Readonly<Record<string, unknown>>
}

/**
 * Minimal face of the optional `sessionProjectionCache` service. Read via
 * `ctx.get` — a profile without the cache simply yields undefined and the
 * bridge falls back to a read-handle log fold for cold titles.
 */
interface ProjectionCacheService {
  cachedSnapshot(meta: SessionHeader): ProjectionSnapshotLike | undefined
}

/**
 * Minimal face of the optional `sessionProjections` registry (the live change
 * feed + snapshot read). Read via `ctx.get`; a profile without the registry
 * simply yields undefined and the bridge serves no context frames.
 */
interface SessionProjectionRegistryService {
  onChanged(listener: (session: Session, key: string, value: unknown, seq: number) => void): () => void
  snapshot(session: Session): ProjectionSnapshotLike
  stateOf(session: Session, key: string): unknown
}

/** Minimal face of one `sessionQuery.observeSession` lease. */
interface SessionObservationLease extends SessionObservationLike {
  [Symbol.dispose](): void
}

/**
 * Minimal face of the optional `sessionQuery` service: one atomic, live-
 * preferred, never-publishing observation of a session (cold ids are restored
 * in memory and folded, never resumed). Read via `ctx.get`; a profile without
 * the service degrades to live projection-registry reads or a header-only
 * report.
 */
interface SessionQueryService {
  observeSession(
    id: string,
    options?: { signal?: AbortSignal; projectionMode?: 'all' | 'none' },
  ): Promise<SessionObservationLease>
}

/**
 * Minimal face of the optional `workspaceRegistry` service. Read via `ctx.get`;
 * a profile without the registry leaves workspace titles unset, and Emacs falls
 * back to the cwd basename.
 */
interface WorkspaceRegistryService {
  list(): WorkspaceLike[]
  archivedSessionIds: readonly string[]
  get(id: string): WorkspaceEntityService | undefined
  create(path: string, title?: string): Promise<WorkspaceEntityService>
  resolveByPath(path: string): Promise<WorkspaceEntityService | undefined>
  archiveSession(id: string): Promise<void>
}

/** Minimal face of one workspace entity, enough for display and rename. */
interface WorkspaceEntityService {
  id: string
  path: string
  title: string
  setTitle(title: string): Promise<void>
  attachSession(id: string): Promise<void>
}

/** Minimal face of the optional `agentDefaultModel` service (a static snapshot). */
interface AgentDefaultModelService {
  currentSelection(): ModelSelection
}

/** Minimal face of the optional `agentPresets` service (composition roster). */
interface AgentPresetsService {
  resolve(id?: string): Promise<{ id: string }>
  mount(agentCtx: Context, id?: string): Promise<unknown>
}

/** Minimal face of the optional `sessionTitle` service (explicit user rename). */
interface SessionTitleService {
  rename(session: Session, title: string): { title: string }
}

/**
 * Minimal face of the optional `sessionController` service (fork). Read via
 * `ctx.get`; a profile without the service answers `/fork` with 501 and the
 * rest of the bridge is unaffected. Call `fork` as a method on the service
 * (its prototype method needs the receiver), never destructured.
 */
interface SessionControllerService {
  fork(request: { sessionId: SessionId; atSeq?: number }): Promise<{ sessionId: SessionId }>
}

/**
 * Minimal face of the optional `attachments` service (`AttachmentStore`).
 * Read via `ctx.get`; a profile without it answers an attachment-bearing
 * `/send` with 501 while plain text sends are unaffected. The store is part
 * of the harness base bundle, so the `web` profile carries it.
 */
interface AttachmentStoreService {
  /** Deployment-resolved image admission limits (source bytes and pixels). */
  readonly imageLimits: {
    maxImageBytes: number
    maxImagesPerMessage: number
    maxMessageImageBytes: number
    maxImagePixels: number
    maxImageDimension: number
  }
  /** Validate every member before committing any; reject with an AttachmentError. */
  saveImages(inputs: readonly {
    data: Uint8Array
    mediaType: BridgeImageMediaType
    name?: string
  }[]): Promise<readonly {
    attachmentId: string
    mediaType: BridgeImageMediaType
    bytes: number
    width: number
    height: number
    name?: string
  }[]>
  /** Streaming verbatim commit; `data` is consumed once, in bounded chunks. */
  saveFileStream(input: { data: AsyncIterable<Uint8Array>; signal?: AbortSignal; name?: string }): Promise<{
    attachmentId: string
    name: string
    bytes: number
  }>
  /** Stable-code membership test over the store's own failure taxonomy. */
  isAttachmentError(error: unknown): boolean
}

/**
 * Minimal face of the optional `llm` service, used only for the image
 * modality pre-check. Read via `ctx.get`; without it the check is skipped
 * and the harness's own text-model image projection takes over.
 */
interface LlmServiceLike {
  resolveModelInfo(provider: string, model: string, signal?: AbortSignal):
    Promise<{ inputModalities?: readonly string[] }>
}

/** A bridge-scoped error carrying the HTTP status Emacs maps to. */
class BridgeError extends Error {
  constructor(readonly status: number, message: string) {
    super(message)
    this.name = 'BridgeError'
  }
}

/** Whether an error is the session-title service's invalid-title rejection. */
function isSessionTitleInvalidError(error: unknown): error is Error {
  return error instanceof Error && error.name === 'SessionTitleInvalidError'
}

/** Whether an error is the workspace registry's unknown-session rejection. */
function isWorkspaceUnknownSessionError(error: unknown): error is Error {
  return error instanceof Error && error.name === 'WorkspaceUnknownSessionError'
}

/** The HTTP status for a propagated bridge/transport error: BridgeError → its status, an oversize body → 413, else 500. */
function bridgeErrorStatus(error: unknown): number {
  if (error instanceof BridgeError) return error.status
  if (error instanceof PayloadTooLargeError) return 413
  return 500
}

/**
 * Whether an error is a Typert `RemoteError` carrying CODE. Identified by its
 * structural marker (never `instanceof`): the error may cross a bundle/realm
 * boundary, and the harness's own rule is that the marker is the identity.
 * A plain `Error` escaping a service seam (e.g. `presetForObservation` with no
 * `sessionProjections` mounted) carries no marker and is deliberately not
 * matched — it falls through to the caller's 500.
 */
function isRemoteErrorCode(error: unknown, code: string): boolean {
  return typeof error === 'object' && error !== null
    && (error as { isDSHRemoteError?: unknown }).isDSHRemoteError === true
    && (error as { code?: unknown }).code === code
}

/**
 * The HTTP status for a `/fork` failure: bridge errors keep their status, the
 * fork seam's taxonomy maps to the route's conventions, and anything else
 * (including the unwrapped plain errors noted on `isRemoteErrorCode`) is 500.
 */
function forkErrorStatus(error: unknown): number {
  if (error instanceof BridgeError) return error.status
  if (isRemoteErrorCode(error, 'session/fork-unavailable')) return 409
  if (isRemoteErrorCode(error, 'session/not-found')) return 404
  if (isRemoteErrorCode(error, 'gateway/bad-request')) return 400
  if (isRemoteErrorCode(error, 'session/workspace-attach-failed')) return 502
  return 500
}

/**
 * The HTTP status and reason for an attachment-store failure. The store's
 * stable code decides (pure `attachmentErrorHttpStatus`: caller-correctable
 * limits 400/413, a file-incapable backend 501, storage faults 500); a value
 * the store does not recognize falls through to the caller's 500.
 */
function attachmentFailure(
  error: unknown,
  store: AttachmentStoreService,
): { status: number; reason: string } | undefined {
  if (!store.isAttachmentError(error)) return undefined
  const code = (error as { code?: unknown }).code
  if (typeof code !== 'string') return undefined
  return { status: attachmentErrorHttpStatus(code), reason: code }
}

/** The target of a bridge operation: a live session plus its live agent. */
interface BridgeTarget {
  session: Session
  agent: Agent
}

/**
 * Resolve the shared token file: `$DSH_HOME/dsh-bridge-token`, defaulting to
 * `~/.dsh/dsh-bridge-token`. Delegates to `resolveDshHome` so the tilde
 * expansion, whitespace handling, and relative-path resolution match the
 * harness itself (a relative `$DSH_HOME` resolves against the `dsh` process
 * working directory); the Emacs side mirrors the same rules.
 */
function resolveTokenFilePath(): string {
  return join(resolveDshHome(), 'dsh-bridge-token')
}

/** Read the shared token, or generate one and write it mode 0600. */
function loadOrCreateToken(path: string): string {
  if (existsSync(path)) {
    const existing = readFileSync(path, 'utf8').trim()
    if (existing !== '') return existing
  }
  const token = randomBytes(32).toString('hex')
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, token + '\n', { mode: 0o600 })
  return token
}

const MAX_BODY_BYTES = 1024 * 1024

/** Thrown by `readJson` when the body exceeds `MAX_BODY_BYTES`; reported as 413. */
class PayloadTooLargeError extends Error {
  constructor() {
    super('request body too large')
    this.name = 'PayloadTooLargeError'
  }
}

/** Read a bounded JSON request body; rejects on oversize or malformed input. */
function readJson(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let body = ''
    req.setEncoding('utf8')
    req.on('data', (chunk: string) => {
      body += chunk
      if (Buffer.byteLength(body) > MAX_BODY_BYTES) {
        reject(new PayloadTooLargeError())
        req.destroy()
      }
    })
    req.on('end', () => {
      try {
        resolve(body === '' ? undefined : JSON.parse(body))
      } catch (error: unknown) {
        reject(new Error(`invalid JSON: ${error instanceof Error ? error.message : String(error)}`))
      }
    })
    req.on('error', reject)
  })
}

/** Write one JSON response. */
function sendJson(res: ServerResponse, status: number, value: unknown): void {
  const payload = JSON.stringify(value)
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(payload)
}

/** One attachment request after `stat` and content sniffing. */
interface PreparedAttachment {
  request: AttachmentRequest
  /** Exact byte length from `stat`. */
  bytes: number
  /** Sniffed image type, or undefined for the verbatim file arm. */
  mediaType?: BridgeImageMediaType
}

/** One staged attachment, echoed back to the client. */
interface StagedAttachment {
  name: string
  kind: 'image' | 'file'
  bytes: number
  mediaType?: BridgeImageMediaType
  attachmentId: string
}

/** The leading bytes read for content sniffing; any accepted signature fits. */
const SNIFF_BYTES = 32

/**
 * Sniff PATH's image type from its leading bytes. The caller has already
 * `stat`ed the path; a race that empties or removes it surfaces as a read or
 * store failure, never as a misdeclared image.
 */
async function sniffPathImageType(path: string, size: number): Promise<BridgeImageMediaType | undefined> {
  const handle = await open(path, 'r')
  try {
    const length = Math.min(size, SNIFF_BYTES)
    if (length === 0) return undefined
    const buffer = Buffer.alloc(length)
    const { bytesRead } = await handle.read(buffer, 0, length, 0)
    return sniffImageMediaType(buffer.subarray(0, bytesRead))
  } finally {
    await handle.close()
  }
}

/**
 * Stage every prepared attachment into the durable store and return the
 * ordered content blocks plus the client echo. Images are one `saveImages`
 * batch (all-or-nothing validation); files stream from disk one at a time.
 * Both arms keep the exact ref objects the store returned.
 */
async function stageAttachments(
  store: AttachmentStoreService,
  prepared: readonly PreparedAttachment[],
): Promise<{ blocks: unknown[]; echo: StagedAttachment[] }> {
  const refByIndex = new Map<number, unknown>()
  const imageIndexes = prepared
    .map((item, index) => (item.mediaType === undefined ? -1 : index))
    .filter(index => index >= 0)
  if (imageIndexes.length > 0) {
    const inputs = await Promise.all(imageIndexes.map(async (index) => {
      const item = prepared[index] as PreparedAttachment
      return {
        data: await readFile(item.request.path),
        mediaType: item.mediaType as BridgeImageMediaType,
        name: item.request.name ?? basename(item.request.path),
      }
    }))
    const refs = await store.saveImages(inputs)
    imageIndexes.forEach((index, position) => { refByIndex.set(index, refs[position]) })
  }
  for (let index = 0; index < prepared.length; index += 1) {
    const item = prepared[index] as PreparedAttachment
    if (item.mediaType !== undefined) continue
    const stream = createReadStream(item.request.path)
    try {
      const ref = await store.saveFileStream({
        data: stream,
        name: item.request.name ?? basename(item.request.path),
      })
      refByIndex.set(index, ref)
    } finally {
      // A store that rejects before consuming the iterable never closes the
      // eagerly-opened fd; a consumed stream is already destroyed.
      stream.destroy()
    }
  }
  const blocks: unknown[] = []
  const echo: StagedAttachment[] = []
  for (let index = 0; index < prepared.length; index += 1) {
    const item = prepared[index] as PreparedAttachment
    const ref = refByIndex.get(index) as {
      attachmentId: string
      name?: string
      bytes: number
      mediaType?: BridgeImageMediaType
    }
    if (item.mediaType !== undefined) {
      blocks.push({ type: 'image', attachment: ref })
      echo.push({
        name: ref.name ?? basename(item.request.path),
        kind: 'image',
        bytes: ref.bytes,
        mediaType: ref.mediaType ?? item.mediaType,
        attachmentId: ref.attachmentId,
      })
    } else {
      blocks.push({ type: 'file', attachment: ref })
      echo.push({
        name: ref.name ?? basename(item.request.path),
        kind: 'file',
        bytes: ref.bytes,
        attachmentId: ref.attachmentId,
      })
    }
  }
  return { blocks, echo }
}

/**
 * The plugin's own version, read lazily from its installed package.json.
 * Deliberately defensive: the `/status` route is a diagnostic nicety, and a
 * read failure here must never fail the boot (a broken bundle entry fails
 * the *entire* `dsh web` start).  `lib/index.js` sits one level below the
 * package root, so `../package.json` resolves to it.
 */
function pluginVersion(): string | null {
  try {
    return manifestVersion(
      readFileSync(new URL('../package.json', import.meta.url), 'utf8'),
    )
  } catch {
    return null
  }
}

export function apply(ctx: Context): void {
  const webServer = ctx.get('webServer') as WebServerService
  const sessions = ctx.get('sessions') as SessionService
  const sessionPersistence = ctx.get('sessionPersistence') as SessionPersistenceService
  const token = loadOrCreateToken(resolveTokenFilePath())

  /** DSH→Emacs inbox, bounded and acked by Emacs after a successful insert. */
  const outbox = new Outbox()

  /**
   * The browser's draft-push EventSource clients: `/events` connections that
   * identified themselves with `?purpose=draft` (the browser plugin's own
   * stream, which exists whenever the web UI is open). They receive every
   * broadcast frame and ignore the kinds they do not recognise, but they
   * never answer ask-user questions.
   */
  const browserSseClients = new Set<ServerResponse>()

  /**
   * Emacs's SSE clients: unmarked `/events` connections (Emacs's notification
   * stream). These alone may own an ask-user question — counting the
   * browser's always-on draft stream would strand questions no UI can see.
   */
  const emacsSseClients = new Set<ServerResponse>()

  /** The settlement one pending question waits on: an answer set, or a cancel. */
  type QuestionSettlement =
    | { ok: true; answers: AskUserAnswerItemLike[] }
    | { ok: false }

  /**
   * One pending ask-user question offered to Emacs, keyed by the
   * bridge-minted question id. `settle` is first-call-wins: it resolves the
   * waterfall listener's wait and removes the entry, so a late `/answer`
   * (after an abort or a duplicate POST) reads `not-pending`.
   */
  interface PendingQuestion {
    sessionId: string
    questions: readonly AskUserQuestionItemLike[]
    settle(result: QuestionSettlement): void
  }

  /** Pending ask-user questions offered to Emacs, keyed by question id. */
  const pendingQuestions = new Map<string, PendingQuestion>()

  /** Write one SSE frame to every subscribed client, dropping dead ones. */
  function broadcast(frame: string): void {
    for (const client of [...browserSseClients, ...emacsSseClients]) {
      try { client.write(frame) } catch { dropSseClient(client) }
    }
  }

  /** Forget one SSE client, whichever set holds it. */
  function dropSseClient(client: ServerResponse): void {
    browserSseClients.delete(client)
    emacsSseClients.delete(client)
  }

  /** The turn number carried by a turn-boundary / assistant-message event payload, or undefined. */
  function turnNumberOf(data: unknown): number | undefined {
    const turn = (data as { turn?: unknown } | undefined)?.turn
    return typeof turn === 'number' ? turn : undefined
  }

  /**
   * The bridge's `user-questions/request` answerer: surface the pending
   * question to Emacs over SSE and settle the waterfall from `/answer`.
   *
   * Registered with `prepend` so it runs OUTSIDE the api-remotes browser
   * forwarder. When an Emacs SSE client is connected the bridge registers its
   * own pending entry, and when the web UI is also open (`browserSseClients`
   * non-empty) it still calls `next()` so the same request reaches the browser
   * forwarder and the web UI's own question panel opens. The two presentations
   * coexist and race: whichever answers first settles the waterfall, and the
   * `ask-user-resolved` frame broadcast on settlement lets the browser plugin
   * dismiss the panel it no longer owns (and lets Emacs banner its buffer as
   * answered elsewhere). A browser-side rejection — no answerer, no session
   * loaded, or a transport failure — is swallowed into a never-settling branch
   * rather than ending the race, so Emacs (already registered above) remains
   * the deciding answerer; the one exception is the web UI's own cancel
   * (`ASK_CANCELLED`, the panel's close button), which settles the ask as
   * cancelled rather than parking the turn on Emacs. The browser's own
   * draft-push connection (marked `purpose=draft`) is not an Emacs client and
   * never answers. With no Emacs client the listener delegates via `next()`
   * and the browser flow is untouched. An agent-less request likewise
   * delegates. Cancel rejects the wait, which the asker surfaces as the
   * tool-call failure (the old cancel-envelope semantics); delegating to the
   * browser on cancel is a deferred idea.
   */
  async function onUserQuestionsRequest(
    request: AskUserQuestionRequestEvent,
    next: () => Promise<AskUserQuestionAnswer>,
  ): Promise<AskUserQuestionAnswer> {
    const sessionId = request.agent === undefined ? undefined : String(request.agent.id)
    if (sessionId === undefined || emacsSseClients.size === 0) return next()
    const questions = request.questions
    const questionId = randomUUID()
    let settled = false
    let outcome: 'answered' | 'cancelled' = 'cancelled'
    let resolveWait!: (result: QuestionSettlement) => void
    const wait = new Promise<QuestionSettlement>((resolve) => { resolveWait = resolve })
    pendingQuestions.set(questionId, {
      sessionId,
      questions,
      settle: (result) => {
        if (settled) return
        settled = true
        pendingQuestions.delete(questionId)
        resolveWait(result)
      },
    })
    broadcast(askUserMessage(questionId, sessionId, questions))
    const onAbort = (): void => pendingQuestions.get(questionId)?.settle({ ok: false })
    request.signal?.addEventListener('abort', onAbort, { once: true })
    // Also offer the request to the web UI, but only when the web UI is
    // actually open (its draft SSE stream is the host-side signal for that):
    // queueing a browser dispatch with no browser attached would strand it
    // until one connects and then show an already-resolved question. Most
    // browser-side rejections (no answerer, no loaded session) must not end
    // the race — Emacs stays the deciding answerer — but the web UI's own
    // cancel (the panel's close button) settles the ask as cancelled, matching
    // the harness's semantics rather than parking the turn on Emacs.
    const browserWait: Promise<QuestionSettlement> = browserSseClients.size === 0
      ? new Promise<QuestionSettlement>(() => {})
      : next().then(
        answer => ({ ok: true as const, answers: answer.answers }),
        (error: unknown) => {
          if (isQuestionCancelRejection(error)) {
            pendingQuestions.get(questionId)?.settle({ ok: false })
          }
          return new Promise<QuestionSettlement>(() => {})
        },
      )
    try {
      const result = await Promise.race([wait, browserWait])
      if (!result.ok) throw new Error('the user cancelled ask_user_question')
      outcome = 'answered'
      return { answers: result.answers }
    } finally {
      request.signal?.removeEventListener('abort', onAbort)
      pendingQuestions.delete(questionId)
      broadcast(askUserResolvedMessage(sessionId, questionId, outcome,
        questions.map(question => question.id)))
    }
  }

  /** Loopback base URL of the web server the plugin is mounted on (the /api RPC carrier). */
  const webBaseUrl = `http://127.0.0.1:${webServer.port}`

  /** The business result of one host RPC self-call. */
  type RpcResult = { ok: true; value: unknown } | { ok: false; error: { code: string; message: string } }

  /**
   * Minimal face of the optional `connection` service: mint the launch-token
   * URL whose 303 response carries the signed browser cookie. The /api
   * channel is browser-authenticated (Host/Origin fence + authority-bound
   * cookie), so an in-process caller must mint the same cookie a browser
   * would; a profile without the service degrades RPC proxying to an error.
   */
  interface ConnectionService {
    authenticatedUrl(baseUrl: string): string
  }

  /** The minted browser cookie for /api self-calls, cached per plugin instance. */
  let rpcCookie: string | undefined

  /**
   * Mint (once) the browser-auth cookie for /api self-calls: fetch the
   * launch-token URL without following its redirect and lift the authority-bound
   * cookie pair out of the `set-cookie` header — the same exchange a browser
   * performs on first load. Returns undefined when the exchange succeeds but
   * carries no cookie; a transport failure propagates to the caller.
   */
  async function ensureRpcCookie(connection: ConnectionService): Promise<string | undefined> {
    if (rpcCookie !== undefined) return rpcCookie
    const response = await fetch(connection.authenticatedUrl(webBaseUrl), { redirect: 'manual' })
    const cookies = typeof response.headers.getSetCookie === 'function'
      ? response.headers.getSetCookie()
      : [response.headers.get('set-cookie') ?? '']
    const pair = cookies[0]?.split(';', 1)[0]
    if (pair === undefined || pair === '') return undefined
    rpcCookie = pair
    return pair
  }

  /**
   * Self-call one host RPC over loopback HTTP and unwrap its result. The
   * bridge proxies `session/modelCatalog`/`session/selectModel` through the
   * genuine Typert Remote handlers, so selection state and validation stay
   * host-owned and parity with the web UI is exact. METHOD is the slash-form
   * endpoint (`namespace/method`); PAYLOAD must already be the `{ args }`
   * named-argument wrapper (see rpcArgsPayload). Returns an error branch for
   * carrier/unreachable failures, and null only for a well-formed HTTP
   * response whose body is not a valid server-response. A 401 means the
   * minted cookie went stale (secret rotation): re-mint once.
   */
  async function rpcCall(method: string, payload: unknown, allowRefresh = true): Promise<RpcResult | null> {
    const rpcId = randomUUID()
    const connection = ctx.get('connection') as ConnectionService | undefined
    if (connection === undefined) {
      return {
        ok: false,
        error: { code: 'internal', message: `RPC ${method} unavailable: profile lacks the connection service` },
      }
    }
    let cookie: string | undefined
    try {
      cookie = await ensureRpcCookie(connection)
    } catch (error: unknown) {
      return {
        ok: false,
        error: {
          code: 'internal',
          message: `RPC ${method} unavailable: browser-auth cookie mint failed: ${error instanceof Error ? error.message : String(error)}`,
        },
      }
    }
    if (cookie === undefined) {
      return {
        ok: false,
        error: { code: 'internal', message: `RPC ${method} unavailable: browser-auth cookie exchange carried no cookie` },
      }
    }
    let response: Response
    try {
      response = await fetch(`${webBaseUrl}/api/${method}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', cookie },
        body: rpcRequestFrame(method, rpcId, payload),
      })
    } catch (error: unknown) {
      return {
        ok: false,
        error: {
          code: 'internal',
          message: `RPC ${method} unreachable: ${error instanceof Error ? error.message : String(error)}`,
        },
      }
    }
    const text = await response.text()
    if (!response.ok) {
      if (response.status === 401 && allowRefresh) {
        rpcCookie = undefined
        return rpcCall(method, payload, false)
      }
      return {
        ok: false,
        error: { code: 'internal', message: `RPC ${method} failed: HTTP ${response.status}` },
      }
    }
    return rpcUnwrapResponse(text)
  }

  /** Map a host RPC error code onto the bridge's HTTP status conventions. */
  function rpcErrorStatus(code: string): number {
    switch (code) {
      case 'session/model-unavailable': return 400
      case 'session/not-found': return 404
      case 'session/agent-busy': return 409
      default: return 502
    }
  }

  /** Read the session's live context occupancy from the projection registry, or undefined when unknown. */
  function readContextPressure(session: Session): { usedTokens: number; contextWindow: number } | undefined {
    const registry = ctx.get('sessionProjections') as SessionProjectionRegistryService | undefined
    const pressure = registry?.snapshot(session).values.contextPressure as
      { pressureTokens?: unknown; projectedTokens?: unknown; contextWindow?: unknown } | undefined
    if (pressure === undefined) return undefined
    const used = contextUsedTokens(
      typeof pressure.pressureTokens === 'number' ? pressure.pressureTokens : undefined,
      typeof pressure.projectedTokens === 'number' ? pressure.projectedTokens : undefined,
    )
    const window = typeof pressure.contextWindow === 'number' ? pressure.contextWindow : undefined
    if (used === undefined || window === undefined) return undefined
    return { usedTokens: used, contextWindow: window }
  }

  /** Whether a live session is owned by its live parent agent. */
  function ownedByLiveParent(session: Session): boolean {
    const parentId = session.header.parentSession
    if (parentId === undefined) return false
    const agent = ctx.agents.get(session.id)
    if (agent === undefined) return false
    const parent = ctx.agents.get(parentId)
    return parent !== undefined && ctx.agents.isOwnedBy(agent.id, parent)
  }

  /** Live sessions the bridge may target, shaped for the pure logic. */
  function targetableSessions(): LiveSessionLike[] {
    return sessions.list()
      .filter(session => !isSubagentChild(session.header.origin, ownedByLiveParent(session)))
      .map((session): LiveSessionLike => ({
        id: String(session.id),
        header: { cwd: session.header.cwd, createdAt: session.header.createdAt },
        events: session.snapshotEvents(),
        running: ctx.agents.get(session.id)?.status === 'running',
      }))
  }

  /** Whether a live, targetable session id has a live agent. */
  function hasAgent(id: string): boolean {
    const session = sessions.list().find(s => String(s.id) === id)
    return session !== undefined && ctx.agents.get(session.id) !== undefined
  }

  /** Resolve a resolved target id back to its live session + agent. */
  function targetById(id: string): BridgeTarget | undefined {
    const session = sessions.list().find(s => String(s.id) === id)
    if (session === undefined) return undefined
    const agent = ctx.agents.get(session.id)
    return agent === undefined ? undefined : { session, agent }
  }

  /**
   * List persisted session headers as lightweight rows for the pure targeting
   * logic: only classification fields (id, createdAt, origin) are needed, so
   * this skips the per-header title fold that `/sessions` pays. A persistence
   * backend failure yields no cold rows — targeting degrades to live-only.
   */
  async function persistedHeaders(): Promise<SessionHeaderLike[]> {
    try {
      const snapshots = await sessionPersistence.list()
      return snapshots.map(({ header }) => ({
        id: String(header.id),
        cwd: header.cwd,
        createdAt: header.createdAt,
        origin: header.origin,
      }))
    } catch {
      return []
    }
  }

  /**
   * The selection ref installed into a bridge-composed agent. The tiers mirror
   * the session controller's own ref, read LIVE from the durable
   * `modelSelection` projection state so a mid-session switch (the
   * `model/selection` event `session/selectModel` appends) takes effect on the
   * agent's next step: the pending pick, else the last used route, else the
   * install-time default. A profile without the projection registry serves the
   * static default snapshot.
   */
  function bridgeSelectionRef(agent: Agent, fallback: ModelSelection): ModelSelectionRef {
    return {
      get current(): ModelSelection | undefined {
        const registry = ctx.get('sessionProjections') as SessionProjectionRegistryService | undefined
        const state = registry?.stateOf(agent.session, 'modelSelection') as
          { pending?: ModelSelection | null; lastUsed?: ModelSelection | null } | undefined
        return state?.pending ?? state?.lastUsed ?? fallback
      },
      assembled: undefined,
    }
  }

  /**
   * Compose an agent for resume/create: the install-time default selection as
   * the ref's fallback tier (the live tiers ride the durable projection), then
   * selection-install-then-preset-mount, matching the gateway's
   * `composeAgent` ordering. For a resumed cold session the preset is resolved
   * from its log; for a created session it is the deployment default.
   *
   * The setup callback follows the harness `AgentSetup` contract exactly:
   * `(agentCtx, agent)`. Read the agent from the second argument — the scoped
   * context does not expose an `agent` service, so `agentCtx.agent` throws
   * "cannot get property \"agent\" without inject".
   */
  async function composeBridgeAgent(presetId: string | undefined): Promise<{
    agentOptions: AgentOptions
    agentPreset?: string
    setup: (agentCtx: Context, agent: Agent) => Promise<void>
  }> {
    const selection = (ctx.get('agentDefaultModel') as AgentDefaultModelService | undefined)?.currentSelection()
    if (selection === undefined) {
      throw new BridgeError(501, 'profile lacks an agent default model; cannot compose an agent')
    }
    const agentOptions: AgentOptions = { provider: selection.provider, model: selection.model }
    const presets = ctx.get('agentPresets') as AgentPresetsService | undefined
    if (presets === undefined) {
      return {
        agentOptions,
        setup: (agentCtx: Context, agent: Agent) => {
          installModelSelection(agent.ctx, bridgeSelectionRef(agent, selection))
          return Promise.resolve()
        },
      }
    }
    const resolvedId = (await presets.resolve(presetId)).id
    return {
      agentOptions,
      agentPreset: resolvedId,
      setup: async (agentCtx: Context, agent: Agent) => {
        installModelSelection(agent.ctx, bridgeSelectionRef(agent, selection))
        await presets.mount(agentCtx, resolvedId)
      },
    }
  }

  /** In-flight resume/create per session id, deduplicating concurrent requests. */
  const sessionCreations = new Map<string, Promise<Agent>>()

  /** Whether a persisted or live header marks a session subagent-owned. */
  function subagentOwnedHeader(header: { origin?: string } | undefined): boolean {
    return header?.origin === 'subagent'
  }

  /**
   * Ensure target id is live: adopt an already-live agent, else resume the
   * persisted session. Subagent-owned ids are rejected (409). The agent handle
   * is deliberately dropped after publication — the agent belongs to the host,
   * so a config hot-reload must not kill live bridge sessions.
   * @throws {BridgeError} 404 unknown id, 409 subagent-owned, 500 composition failure.
   */
  async function ensureLive(id: string): Promise<BridgeTarget> {
    let op = sessionCreations.get(id)
    if (op === undefined) {
      op = (async () => {
        const live = ctx.agents.get(id as SessionId)
        if (live !== undefined) {
          // Adopting a live agent needs the same ownership guard as the cold
          // arm: a live subagent child is as off-limits as a persisted one.
          const session = sessions.list().find(s => String(s.id) === id)
          if (session !== undefined
            && isSubagentChild(session.header.origin, ownedByLiveParent(session))) {
            throw new BridgeError(409, `session ${id} is owned by a subagent`)
          }
          return live
        }
        const snapshot = await sessionPersistence.stat(id)
        if (snapshot === undefined) throw new BridgeError(404, `session ${id} is not live`)
        if (subagentOwnedHeader(snapshot.header)) {
          throw new BridgeError(409, `session ${id} is owned by a subagent`)
        }
        // The preset a cold session runs is a log fact: read the full log once
        // through a read handle (the removed `inspect`'s replacement) and fold
        // it with the in-repo replica of the `agentPreset` projection.
        const readHandle = await sessionPersistence.open(id, 'read')
        let presetId: string | undefined
        try {
          if (subagentOwnedHeader(readHandle.header)) {
            throw new BridgeError(409, `session ${id} is owned by a subagent`)
          }
          presetId = sessionPreset(readHandle.header, (await readHandle.read()).events)
        } finally {
          await readHandle.close()
        }
        const composition = await composeBridgeAgent(presetId)
        const handle = await ctx.agents.resume({
          resumeSessionId: id as SessionId,
          agentOptions: composition.agentOptions,
          setup: composition.setup,
        })
        return handle.agent
      })().catch((error: unknown) => {
        // A concurrent Host path may have published the same identity while we
        // crossed an await; adopt it rather than propagating a false conflict.
        // Our own BridgeErrors (404 unknown, 409 subagent-owned) are deliberate
        // verdicts — adopting past them would resurrect the subagent bypass.
        if (!(error instanceof BridgeError)) {
          const live = ctx.agents.get(id as SessionId)
          if (live !== undefined) return live
        }
        throw error
      }).finally(() => { sessionCreations.delete(id) })
      sessionCreations.set(id, op)
    }
    const agent = await op
    const target = targetById(String(agent.id))
    if (target === undefined) throw new BridgeError(500, `session ${id} published but is not targetable`)
    return target
  }

  /**
   * Resolve a request's effective target, resuming a cold session on demand.
   * A cold result routes through `ensureLive` so an explicit cold id or the
   * bare most-recent-cold fallback both resume before the route proceeds.
   * An explicit id that is already live and agent-bearing is adopted directly,
   * without the persisted-header round-trip the full classification pays.
   * @throws {BridgeError} 404 unknown, 409 no active/subagent, 500 composition.
   */
  async function resolveTarget(explicitId: string | undefined): Promise<BridgeTarget> {
    const live = targetableSessions()
    if (explicitId !== undefined
      && classifySessionId(explicitId, new Set(live.map(session => session.id)), new Set<string>()) === 'live'
      && hasAgent(explicitId)) {
      const target = targetById(explicitId)
      if (target !== undefined) return target
    }
    const result: ResolveTargetResult = resolveTargetId(
      explicitId,
      live,
      await persistedHeaders(),
      hasAgent,
    )
    if (result.kind === 'error') throw new BridgeError(result.status, result.message)
    if (result.kind === 'target') {
      const target = targetById(result.id)
      if (target === undefined) throw new BridgeError(409, 'no active session')
      return target
    }
    return ensureLive(result.id)
  }

  /** Broadcast a `sessions-changed` frame, optionally naming the changed id. */
  function broadcastSessionsChanged(sessionId?: string): void {
    broadcast(sessionsChangedMessage(sessionId))
  }

  /**
   * Whether the target session's current model explicitly refuses image
   * input, mirroring the web UI's pre-check. Best-effort: an absent `llm`
   * service, an unresolved selection, or a resolve failure returns `false`
   * and leaves the harness's own text-model image projection in charge.
   */
  async function imageModelUnsupported(target: BridgeTarget): Promise<boolean> {
    const llm = ctx.get('llm') as LlmServiceLike | undefined
    if (llm === undefined) return false
    const registry = ctx.get('sessionProjections') as SessionProjectionRegistryService | undefined
    const view = registry?.snapshot(target.session).values.modelSelection as
      { lastUsed?: unknown; next?: unknown } | undefined
    const selection = ((view?.next ?? view?.lastUsed)
      ?? (ctx.get('agentDefaultModel') as AgentDefaultModelService | undefined)?.currentSelection()
    ) as ModelSelection | undefined
    if (selection === undefined || selection === null) return false
    try {
      const info = await llm.resolveModelInfo(selection.provider, selection.model)
      return imageInputUnsupported(info.inputModalities)
    } catch {
      return false
    }
  }

  // Push turn lifecycle and title changes onto the SSE stream for the Emacs
  // status tracker and sessions-list auto-refresh. Emitted only for targetable
  // (non-subagent) sessions; the browser ignores any kind it does not
  // recognise, so this is backward-compatible. The frames carry the event's
  // `turn` number so Emacs can key its turn-level reply cache (mid-turn
  // segments, the ending turn's closing divider).
  ctx.on('session/event', (session, event) => {
    if (isSubagentChild(session.header.origin, ownedByLiveParent(session))) return
    const id = String(session.id)
    if (event.type === 'turn/start') {
      broadcast(turnStartMessage(id, event.time, turnNumberOf(event.data)))
      return
    }
    if (event.type === 'turn/end') {
      const data = event.data as { reason?: unknown } | undefined
      const reason = data?.reason as { kind?: unknown } | undefined
      broadcast(turnCompleteMessage(
        id,
        typeof reason?.kind === 'string' ? reason.kind : 'unrecognized',
        event.time,
        turnNumberOf(event.data),
      ))
      return
    }
    if (event.type === 'assistant/message') {
      // A reply segment is committed mid-turn. Nudge Emacs to refresh its turn
      // list (and the View (k/n) counter) while the turn is still running; gate
      // on text so tool-call-only steps do not fire a spurious refresh.
      const data = event.data as { message?: { content?: readonly MessageBlockLike[] } } | undefined
      if (assistantMessageHasText(data?.message)) {
        broadcast(repliesChangedMessage(id, turnNumberOf(event.data)))
      }
      return
    }
    if (event.type === 'session/title') {
      broadcast(sessionsChangedMessage(id))
    }
  })

  // Push live context occupancy onto the SSE stream. The token-meter projection
  // registry owns the change feed; when the deployment mounts it, every
  // `contextPressure` update for a targetable session becomes a `context` frame
  // (matching the web meter's projected value). A profile without the registry
  // never activates this child, so Emacs simply sees no context frames.
  ctx.inject(['sessionProjections'], (projectionCtx) => {
    const registry = projectionCtx.get('sessionProjections') as SessionProjectionRegistryService
    registry.onChanged((session, key, value) => {
      if (key !== 'contextPressure') return
      if (isSubagentChild(session.header.origin, ownedByLiveParent(session))) return
      const pressure = value as
        { pressureTokens?: unknown; projectedTokens?: unknown; contextWindow?: unknown } | undefined
      if (pressure === undefined) return
      const used = contextUsedTokens(
        typeof pressure.pressureTokens === 'number' ? pressure.pressureTokens : undefined,
        typeof pressure.projectedTokens === 'number' ? pressure.projectedTokens : undefined,
      )
      const window = typeof pressure.contextWindow === 'number' ? pressure.contextWindow : undefined
      if (used === undefined || window === undefined) return
      broadcast(contextMessage(String(session.id), used, window))
    })
  })

  // Announce inventory changes: create/dispose and workspace domain mutations
  // (archive set, workspace create/rename/attach) all shift what `/sessions`
  // returns, so Emacs refreshes its list. Workspace domain events are chatty
  // (one per write); the Emacs consumer debounces, so a plain frame suffices.
  ctx.on('session/created', (session) => {
    if (!isSubagentChild(session.header.origin, ownedByLiveParent(session))) {
      broadcastSessionsChanged(String(session.id))
    }
  })
  ctx.on('session/disposed', (session) => {
    if (!isSubagentChild(session.header.origin, ownedByLiveParent(session))) {
      broadcastSessionsChanged(String(session.id))
    }
  })
  ctx.on('domain/changed', (change) => {
    if (change.domain === 'workspace') broadcastSessionsChanged()
  })

  /**
   * The durable text of one assistant message, addressed by its message id,
   * WITHOUT resuming anything: a live session serves its event snapshot, and
   * a cold (persisted-only) session is read once through a read handle — a
   * deposit is a read, not a targeting operation, so it must not spawn an
   * agent. Returns undefined when the session is unknown or no logged
   * assistant message carries the id.
   */
  async function resolveMessageText(sessionId: string, messageId: string): Promise<string | undefined> {
    const live = sessions.list().find(s => String(s.id) === sessionId)
    if (live !== undefined) {
      return assistantTextForMessage(live.snapshotEvents() as readonly SessionEventLike[], messageId)
    }
    try {
      const handle = await sessionPersistence.open(sessionId, 'read')
      try {
        return assistantTextForMessage((await handle.read()).events, messageId)
      } finally {
        await handle.close()
      }
    } catch {
      return undefined
    }
  }

  /**
   * Fold a cold session's title. The persisted projection cache serves the
   * title with zero log reads (mirroring the harness's own session list); when
   * the cache is absent, or its row lacks the title key, read the log through
   * a read handle and fold `session/title` events directly. Fail-soft: a
   * title is a display nicety and must never hide the session row.
   */  async function coldSessionTitle(
    cache: ProjectionCacheService | undefined,
    persistence: SessionPersistenceService,
    header: SessionHeader,
  ): Promise<string | null> {
    const snapshot = cache?.cachedSnapshot(header)
    if (snapshot !== undefined) {
      const title = snapshot.values.title
      if (typeof title === 'string' && title !== '') return title
      // The title key is present with a null value: the session has no title
      // yet, and a cold log is immutable, so it cannot acquire one. No read.
      if (Object.hasOwn(snapshot.values, 'title')) return null
    }
    try {
      const handle = await persistence.open(String(header.id), 'read')
      try {
        return sessionTitle((await handle.read()).events)
      } finally {
        await handle.close()
      }
    } catch {
      return null
    }
  }

  /** Merge live sessions with persisted headers via the pure merge logic. */
  async function listSessions(): Promise<SessionRow[]> {
    const cache = ctx.get('sessionProjectionCache') as ProjectionCacheService | undefined
    let persisted: SessionHeaderLike[] = []
    try {
      const snapshots = await sessionPersistence.list()
      persisted = await Promise.all(snapshots.map(async ({ header }): Promise<SessionHeaderLike> => ({
        id: String(header.id),
        cwd: header.cwd,
        createdAt: header.createdAt,
        origin: header.origin,
        title: header.origin === 'subagent' ? null : await coldSessionTitle(cache, sessionPersistence, header),
      })))
    } catch {
      // Persistence listing is auxiliary to the live view; a backend failure
      // must not hide the sessions that are actually running now.
    }
    const rows = mergeSessionRows(targetableSessions(), persisted)
    const workspaceRegistry = ctx.get('workspaceRegistry') as WorkspaceRegistryService | undefined
    const workspaceBySession = workspaceRefsBySession(workspaceRegistry?.list() ?? [])
    const archivedIds = new Set((workspaceRegistry?.archivedSessionIds ?? []).map(id => String(id)))
    return rows.map(row => ({
      ...row,
      workspace: workspaceBySession.get(row.id)?.title ?? null,
      workspaceId: workspaceBySession.get(row.id)?.id ?? null,
      archived: archivedIds.has(row.id),
    }))
  }

  /** Whether an observation error is the session-query "not found" taxonomy. */
  function isSessionQueryNotFound(error: unknown): boolean {
    return error instanceof Error
      && (error as { code?: unknown }).code === 'SESSION_QUERY_SESSION_NOT_FOUND'
  }

  /**
   * Resolve the id a read-only report should observe. An explicit id is used
   * as given (the observation reports 404/409); a missing one follows the
   * read-target precedence. Never resumes.
   */
  async function resolveReadId(explicitId: string | undefined): Promise<string> {
    if (explicitId !== undefined) return explicitId
    const result: ReadTargetResult = resolveReadTargetId(
      undefined,
      targetableSessions(),
      await persistedHeaders(),
    )
    if (result.kind === 'error') throw new BridgeError(result.status, result.message)
    return result.id
  }

  /** The non-observation facts a session report needs: run state and workspace. */
  function sessionReportExtras(id: string): SessionReportExtras {
    const live = sessions.list().find(session => String(session.id) === id)
    const registry = ctx.get('workspaceRegistry') as WorkspaceRegistryService | undefined
    const workspaceBySession = workspaceRefsBySession(registry?.list() ?? [])
    const archivedIds = new Set((registry?.archivedSessionIds ?? []).map(value => String(value)))
    const workspace = workspaceBySession.get(id)
    return {
      running: live !== undefined && ctx.agents.get(live.id)?.status === 'running',
      workspace: workspace?.title ?? null,
      workspaceId: workspace?.id ?? null,
      archived: archivedIds.has(id),
    }
  }

  /**
   * The degraded report used when `sessionQuery` is absent: live sessions read
   * the projection registry directly, cold ones contribute header facts only.
   * Still read-only — `stat` never resumes.
   */
  async function fallbackSessionReport(
    id: string,
    extras: SessionReportExtras,
  ): Promise<SessionReport> {
    const live = sessions.list().find(session => String(session.id) === id)
    if (live !== undefined) {
      if (live.header.origin === 'subagent') {
        throw new BridgeError(409, `session ${id} is owned by a subagent`)
      }
      const registry = ctx.get('sessionProjections') as SessionProjectionRegistryService | undefined
      const values = registry?.snapshot(live).values
      const observation: SessionObservationLike = {
        source: 'live',
        header: live.header,
        events: live.snapshotEvents() as readonly SessionEventLike[],
        ...values === undefined ? {} : { projections: { values } },
      }
      return sessionReport(observation, extras)
    }
    const snapshot = await sessionPersistence.stat(id)
    if (snapshot === undefined || snapshot.header.cwd === undefined) {
      throw new BridgeError(404, `session ${id} is not live`)
    }
    if (snapshot.header.origin === 'subagent') {
      throw new BridgeError(409, `session ${id} is owned by a subagent`)
    }
    return sessionReport({ source: 'prepared', header: snapshot.header }, extras)
  }

  /** Resolve the catalog display name for a selection, best-effort. */
  async function resolveModelName(provider: string, model: string): Promise<string | null> {
    const result = await rpcCall('session/modelCatalog', rpcArgsPayload({}))
    if (result === null || !result.ok) return null
    return catalogModelName(result.value, provider, model)
  }

  /**
   * Build one read-only session report. Never resumes: the id is observed
   * through the optional `sessionQuery` service (live or prepared/cold), with
   * the projection-registry and persistence-header fallbacks when it is
   * absent. 404 unknown, 409 subagent-owned.
   */
  async function readSessionReport(explicitId: string | undefined): Promise<SessionReport> {
    const id = await resolveReadId(explicitId)
    const extras = sessionReportExtras(id)
    const sessionQuery = ctx.get('sessionQuery') as SessionQueryService | undefined
    let report: SessionReport
    if (sessionQuery === undefined) {
      report = await fallbackSessionReport(id, extras)
    } else {
      let observation: SessionObservationLease
      try {
        observation = await sessionQuery.observeSession(id, { projectionMode: 'all' })
      } catch (error: unknown) {
        if (isSessionQueryNotFound(error)) throw new BridgeError(404, `session ${id} is not live`)
        throw error
      }
      try {
        if (observation.header.cwd === undefined) {
          throw new BridgeError(404, `session ${id} is not live`)
        }
        if (observation.header.origin === 'subagent') {
          throw new BridgeError(409, `session ${id} is owned by a subagent`)
        }
        report = sessionReport(observation, extras)
      } finally {
        observation[Symbol.dispose]()
      }
    }
    if (report.model !== null) {
      report.modelName = await resolveModelName(report.model.provider, report.model.model)
    }
    return report
  }

  /** Whether a request carries the shared token as a bearer credential. */
  function authorized(req: IncomingMessage): boolean {
    const provided = parseBearerAuthorization(req.headers.authorization)
    return provided !== undefined && tokensEqual(token, provided)
  }

  // Answer ask-user requests from Emacs. Prepended so the bridge runs outside
  // the api-remotes browser forwarder regardless of plugin load order; the
  // listener delegates via next() whenever no Emacs SSE client is connected,
  // and otherwise races Emacs against a browser presentation it also opens.
  // A profile without the user-questions capability simply never dispatches
  // the event, so the ask-user path degrades to a no-op there.
  ctx.effect(
    () => ctx.on('user-questions/request', (request, next) =>
      onUserQuestionsRequest(request, next), { prepend: true }),
    'dsh-bridge: ask-user answerer',
  )

  // Registered inside an effect so a config hot-reload disposes the route
  // before re-applying — a duplicate (kind, path) registration throws.
  ctx.effect(() => webServer.register({
    kind: 'prefix',
    path: '/dsh-bridge',
    handler: async (req, res) => {
      const url = new URL(req.url ?? '/', 'http://localhost')
      const pathname = url.pathname

      // The browser legitimately has no bearer token on first load, so this ONE
      // route is fenced by peer address and origin instead: it hands out the
      // token only to a loopback peer (unforgeable, unlike headers) whose
      // Host/Origin also name loopback (see tokenRequestsSameOrigin).
      if (req.method === 'GET' && pathname === '/dsh-bridge/token') {
        if (!isLoopbackAddress(req.socket.remoteAddress)
          || !tokenRequestsSameOrigin(req.headers.host, req.headers.origin)) {
          sendJson(res, 403, { error: 'forbidden' })
          return
        }
        sendJson(res, 200, { token })
        return
      }

      // Identity/version probe, for Emacs's staleness detection.  Read-only
      // and loopback-fenced like `/token` (the version is not sensitive):
      // Emacs queries it before it necessarily holds a bearer token, and the
      // response lets it distinguish a stale installed copy from a fresh one.
      if (req.method === 'GET' && pathname === '/dsh-bridge/status') {
        if (!isLoopbackAddress(req.socket.remoteAddress)
          || !tokenRequestsSameOrigin(req.headers.host, req.headers.origin)) {
          sendJson(res, 403, { error: 'forbidden' })
          return
        }
        sendJson(res, 200, { name: 'dsh-emacs-bridge', version: pluginVersion() })
        return
      }

      // Browser-facing SSE for the composer-draft push. EventSource cannot set
      // headers, so it authenticates with the vended token as a query param.
      // The browser's own draft stream identifies itself with `purpose=draft`
      // (so it never owns an ask-user question); an unmarked connection is
      // Emacs.
      if (req.method === 'GET' && pathname === '/dsh-bridge/events') {
        const queryToken = url.searchParams.get('token')
        if (!(queryToken !== null && tokensEqual(token, queryToken))) {
          sendJson(res, 401, { error: 'unauthorized' })
          return
        }
        res.writeHead(200, {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          connection: 'keep-alive',
        })
        res.write('retry: 5000\n\n')
        const isBrowser = url.searchParams.get('purpose') === 'draft'
        ;(isBrowser ? browserSseClients : emacsSseClients).add(res)
        if (!isBrowser) {
          // Replay still-pending questions so a reconnecting Emacs re-learns
          // an ask it may have missed. The browser never answers questions,
          // so it needs no replay.
          for (const [questionId, pending] of pendingQuestions) {
            try {
              res.write(askUserMessage(questionId, pending.sessionId, pending.questions))
            } catch { dropSseClient(res); break }
          }
        }
        req.on('close', () => { dropSseClient(res) })
        return
      }

      if (!authorized(req)) {
        sendJson(res, 401, { error: 'unauthorized' })
        return
      }

      if (req.method === 'GET' && pathname === '/dsh-bridge/sessions') {
        try {
          sendJson(res, 200, { sessions: await listSessions() })
        } catch (error: unknown) {
          sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      // One read-only session report. The id is optional (last-active live,
      // else the most recent cold session); a cold id is observed through
      // `sessionQuery`, never resumed. A repeated or empty `sessionId` is a
      // malformed request, not a target.
      if (req.method === 'GET' && pathname === '/dsh-bridge/session') {
        try {
          const ids = url.searchParams.getAll('sessionId')
          if (ids.length > 1 || (ids.length === 1 && ids[0] === '')) {
            sendJson(res, 400, { error: 'sessionId must be a single non-empty string' })
            return
          }
          sendJson(res, 200, await readSessionReport(ids[0]))
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), {
            error: error instanceof Error ? error.message : String(error),
          })
        }
        return
      }

      // Answer (or decline) a pending ask-user question the bridge surfaced to
      // Emacs. Settles the waterfall listener's wait directly: an answer set
      // becomes the listener's return value, a cancel rejects it (the old
      // cancel-envelope semantics — the asker sees the tool call fail). First
      // settlement wins; a late/duplicate POST reads 404 `not-pending`.
      if (req.method === 'POST' && pathname === '/dsh-bridge/answer') {
        try {
          const body = (await readJson(req)) as {
            questionId?: unknown; sessionId?: unknown; answers?: unknown; cancelled?: unknown
          } | undefined
          const questionId = typeof body?.questionId === 'string' ? body.questionId : undefined
          const sessionId = typeof body?.sessionId === 'string' ? body.sessionId : undefined
          if (questionId === undefined || sessionId === undefined) {
            sendJson(res, 400, { accepted: false, reason: 'bad-response' })
            return
          }
          const pending = pendingQuestions.get(questionId)
          if (pending === undefined || pending.sessionId !== sessionId) {
            sendJson(res, 404, { accepted: false, reason: 'not-pending' })
            return
          }
          const isCancel = body?.cancelled === true || body?.cancelled === 'true'
          if (isCancel) {
            pending.settle({ ok: false })
            sendJson(res, 200, { accepted: true })
            return
          }
          const answers = body?.answers
          if (!answerMatchesQuestions(pending.questions, answers)) {
            sendJson(res, 400, { accepted: false, reason: 'bad-response' })
            return
          }
          pending.settle({ ok: true, answers })
          sendJson(res, 200, { accepted: true })
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/draft') {
        try {
          const body = (await readJson(req)) as { sessionId?: unknown; text?: unknown } | undefined
          const text = typeof body?.text === 'string' ? body.text : ''
          if (text.trim() === '') {
            sendJson(res, 400, { error: 'text is required' })
            return
          }
          let explicitId: string | undefined
          if (body?.sessionId !== undefined && body.sessionId !== null) {
            if (typeof body.sessionId !== 'string') {
              sendJson(res, 400, { error: 'sessionId must be a string' })
              return
            }
            explicitId = body.sessionId
          }
          // The draft push targets the browser's composer, so it needs a
          // browser draft stream subscribed (an Emacs-only connection cannot
          // consume drafts).
          if (browserSseClients.size === 0) {
            sendJson(res, 409, { error: 'no browser client connected' })
            return
          }
          const target = await resolveTarget(explicitId)
          broadcast(draftMessage(String(target.session.id), text))
          sendJson(res, 200, {
            ok: true,
            sessionId: String(target.session.id),
            title: sessionTitle(target.session.snapshotEvents()),
            cwd: target.session.header.cwd ?? null,
          })
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'GET' && pathname === '/dsh-bridge/outbox') {
        const { entries, overflowed } = outbox.collect()
        sendJson(res, 200, { entries, overflowed })
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/outbox') {
        try {
          const body = (await readJson(req)) as
            { sessionId?: unknown; source?: unknown; text?: unknown; messageId?: unknown } | undefined
          // Every entry is session-scoped (UX plan 2, Section 1.4): a deposit
          // without a sessionId is a contract violation, not a bridge message.
          const sessionId = outboxSessionId(body)
          if (sessionId === null) {
            sendJson(res, 400, { error: 'sessionId is required' })
            return
          }
          // Two deposit shapes: a literal `text`, or a durable `messageId` the
          // host resolves against the session log (the "Send to Emacs" action —
          // the chat node tree no longer rides the client session snapshot, so
          // the browser addresses the message and the host owns its text).
          // Resolution is a pure read: a cold session's log is read through a
          // persistence handle, never resumed.
          let text = typeof body?.text === 'string' ? body.text : ''
          if (typeof body?.messageId === 'string' && body.messageId !== '') {
            const resolved = await resolveMessageText(sessionId, body.messageId)
            if (resolved === undefined) {
              sendJson(res, 404, { error: `no assistant message ${body.messageId}` })
              return
            }
            text = resolved
          }
          if (text.trim() === '') {
            sendJson(res, 400, { error: 'text is required' })
            return
          }
          const evicted = outbox.deposit({
            id: randomUUID(),
            sessionId,
            source: typeof body?.source === 'string' ? body.source : 'bridge',
            text,
            ts: Date.now(),
          })
          // Notify every subscribed client (the browser and Emacs) that new
          // inbox entries are ready.
          const notice = outboxMessage()
          broadcast(notice)
          sendJson(res, 200, { ok: true, evicted })
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/outbox/ack') {
        try {
          const body = (await readJson(req)) as { ids?: unknown } | undefined
          const ids = Array.isArray(body?.ids)
            ? body.ids.filter((id): id is string => typeof id === 'string')
            : []
          outbox.ack(ids)
          sendJson(res, 200, { ok: true, acked: ids.length })
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/send') {
        const store = ctx.get('attachments') as AttachmentStoreService | undefined
        try {
          const body = (await readJson(req)) as
            { text?: unknown; sessionId?: unknown; attachments?: unknown } | undefined
          const text = typeof body?.text === 'string' ? body.text : ''
          const parsed = parseAttachmentRequests(body?.attachments)
          if (!parsed.ok) {
            sendJson(res, 400, { error: parsed.error })
            return
          }
          const requests = parsed.items
          if (text.trim() === '' && requests.length === 0) {
            sendJson(res, 400, {
              error: 'prompt content must include non-whitespace text or an attachment',
            })
            return
          }
          if (requests.length > 0 && store === undefined) {
            sendJson(res, 501, { error: 'profile lacks an attachment store; cannot send attachments' })
            return
          }
          let explicitId: string | undefined
          if (body?.sessionId !== undefined && body.sessionId !== null) {
            if (typeof body.sessionId !== 'string') {
              sendJson(res, 400, { error: 'sessionId must be a string' })
              return
            }
            explicitId = body.sessionId
          }
          // Validate every path before resolving the target, so a doomed
          // request never resumes a cold session as a side effect.
          const prepared: PreparedAttachment[] = []
          for (const request of requests) {
            let info
            try {
              info = await stat(request.path)
            } catch {
              throw new BridgeError(400, `cannot read attachment: ${request.path}`)
            }
            if (!info.isFile()) {
              throw new BridgeError(400, `attachment is not a regular file: ${request.path}`)
            }
            const mediaType = await sniffPathImageType(request.path, info.size)
            if (mediaType !== undefined && store !== undefined
              && info.size > store.imageLimits.maxImageBytes) {
              throw new BridgeError(413, `image exceeds the ${store.imageLimits.maxImageBytes}-byte limit: ${request.path}`)
            }
            if (mediaType === undefined && info.size > MAX_ATTACHMENT_FILE_BYTES) {
              throw new BridgeError(413, `file exceeds the ${MAX_ATTACHMENT_FILE_BYTES}-byte limit: ${request.path}`)
            }
            prepared.push({
              request,
              bytes: info.size,
              ...(mediaType === undefined ? {} : { mediaType }),
            })
          }
          const target = await resolveTarget(explicitId)
          if (prepared.some(item => item.mediaType !== undefined)
            && await imageModelUnsupported(target)) {
            sendJson(res, 400, {
              error: "the session's model does not support image input",
              reason: 'MODEL_DOES_NOT_SUPPORT_IMAGES',
            })
            return
          }
          let blocks: unknown[] = []
          let echo: StagedAttachment[] = []
          if (prepared.length > 0 && store !== undefined) {
            const staged = await stageAttachments(store, prepared)
            blocks = staged.blocks
            echo = staged.echo
          }
          const content = [
            ...blocks,
            ...(text === '' ? [] : [{ type: 'text', text }]),
          ] as unknown as ContentBlock[]
          target.agent.followup(createUserMessage({ content, source: { kind: 'user' } }))
          sendJson(res, 200, {
            ok: true,
            sessionId: String(target.session.id),
            title: sessionTitle(target.session.snapshotEvents()),
            cwd: target.session.header.cwd ?? null,
            ...(echo.length === 0 ? {} : { attachments: echo }),
          })
        } catch (error: unknown) {
          const failure = store === undefined ? undefined : attachmentFailure(error, store)
          if (failure !== undefined) {
            sendJson(res, failure.status, {
              error: error instanceof Error ? error.message : String(error),
              reason: failure.reason,
            })
            return
          }
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'GET' && pathname === '/dsh-bridge/output') {
        try {
          const target = await resolveTarget(url.searchParams.get('sessionId') ?? undefined)
          sendJson(res, 200, {
            sessionId: String(target.session.id),
            title: sessionTitle(target.session.snapshotEvents()),
            cwd: target.session.header.cwd ?? null,
            text: latestAssistantText(target.agent.session.deriveMessages()),
            running: ctx.agents.get(String(target.session.id))?.status === 'running',
          })
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      // The prompt buffer's history: the session's user prompts, newest first.
      if (req.method === 'GET' && pathname === '/dsh-bridge/prompts') {
        try {
          const target = await resolveTarget(url.searchParams.get('sessionId') ?? undefined)
          sendJson(res, 200, {
            sessionId: String(target.session.id),
            prompts: userPrompts(target.agent.session.deriveMessages()).reverse(),
          })
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      // The output buffer's turn navigation: the session's turn-aggregated
      // assistant replies, newest first (the mirror of /prompts, grouped by
      // harness turn).  Each turn carries its committed text segments plus the
      // turn's start/end facts (including the `turn/end` event's seq as
      // `endSeq`, the anchor `POST /fork` cuts after), so Emacs can render a
      // whole turn with divider lines and walk M-p/M-n turn-by-turn.  The fold
      // walks the session's own
      // surface (`Session.surface.nodes` + `Session.snapshotEvents()[seq]` — the same
      // surface `deriveMessages()` folds), so compaction-replaced history stays
      // hidden exactly as the reply list it replaces did.  EPOCH is the
      // surface's `replaceGeneration` (the harness's monotonic replacement
      // count), which lets Emacs detect a compacted history cheaply.
      //
      // Optional `since` (a turn number) + `epoch` query params request the
      // incremental suffix: when the client's epoch matches the current
      // `replaceGeneration` and `since` names a visible turn, the response
      // carries only the turns with `turn >= since` (inclusive) and
      // `incremental: true`; otherwise it is the full list with
      // `incremental: false` (see `turnsSince` in logic.ts).
      if (req.method === 'GET' && pathname === '/dsh-bridge/turns') {
        try {
          const target = await resolveTarget(url.searchParams.get('sessionId') ?? undefined)
          const session = target.session
          const epoch = session.surface.replaceGeneration
          const { incremental, turns } = turnsSince(
            assistantTurns({ nodes: session.surface.nodes, events: session.snapshotEvents() }).reverse(),
            epoch,
            { since: url.searchParams.get('since') ?? undefined, epoch: url.searchParams.get('epoch') ?? undefined },
          )
          sendJson(res, 200, {
            sessionId: String(session.id),
            title: sessionTitle(session.snapshotEvents()),
            cwd: session.header.cwd ?? null,
            turns,
            incremental,
            running: ctx.agents.get(String(session.id))?.status === 'running',
            epoch,
          })
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      // The prompt buffer's model catalog: the host's genuine
      // `session/modelCatalog` Remote for the groups, plus the session's
      // durable `modelSelection` projection for the current pick (the same
      // `next ?? lastUsed ?? catalog.default` fold the web UI's model
      // directory computes). The catalog is forwarded verbatim, with `current`
      // added.
      if (req.method === 'GET' && pathname === '/dsh-bridge/models') {
        try {
          const target = await resolveTarget(url.searchParams.get('sessionId') ?? undefined)
          const result = await rpcCall('session/modelCatalog', rpcArgsPayload({}))
          if (result === null) {
            sendJson(res, 502, { error: 'model catalog RPC returned a malformed response' })
            return
          }
          if (!result.ok) {
            sendJson(res, rpcErrorStatus(result.error.code), { error: result.error.message })
            return
          }
          const catalog = result.value as { default?: unknown } & Record<string, unknown>
          const registry = ctx.get('sessionProjections') as SessionProjectionRegistryService | undefined
          const view = registry?.snapshot(target.session).values.modelSelection as
            { lastUsed?: unknown; next?: unknown } | undefined
          sendJson(res, 200, { ...catalog, current: currentModelSelection(catalog.default, view) })
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      // Change the target session's model: proxy `session/selectModel` (which
      // validates, sets the session-local pick, and persists the default).
      if (req.method === 'POST' && pathname === '/dsh-bridge/model') {
        try {
          const body = (await readJson(req)) as
            { sessionId?: unknown; provider?: unknown; model?: unknown; reasoningEffort?: unknown } | undefined
          const provider = typeof body?.provider === 'string' ? body.provider : ''
          const model = typeof body?.model === 'string' ? body.model : ''
          if (provider === '' || model === '') {
            sendJson(res, 400, { error: 'provider and model are required' })
            return
          }
          let explicitId: string | undefined
          if (body?.sessionId !== undefined && body.sessionId !== null) {
            if (typeof body.sessionId !== 'string') {
              sendJson(res, 400, { error: 'sessionId must be a string' })
              return
            }
            explicitId = body.sessionId
          }
          const target = await resolveTarget(explicitId)
          const payload: { sessionId: string; provider: string; model: string; reasoningEffort?: string } = {
            sessionId: String(target.session.id),
            provider,
            model,
            ...(typeof body?.reasoningEffort === 'string' && body.reasoningEffort !== ''
              ? { reasoningEffort: body.reasoningEffort }
              : {}),
          }
          const result = await rpcCall('session/selectModel', rpcArgsPayload({ request: payload }))
          if (result === null) {
            sendJson(res, 502, { error: 'select-model RPC returned a malformed response' })
            return
          }
          if (!result.ok) {
            sendJson(res, rpcErrorStatus(result.error.code), { error: result.error.message })
            return
          }
          const selected = (result.value as { selected?: unknown } | undefined)?.selected
          sendJson(res, 200, { ok: true, sessionId: payload.sessionId, selected })
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      // The prompt buffer's context occupancy: the live projection registry's
      // current value, or 204 when no sample/capacity exists yet.
      if (req.method === 'GET' && pathname === '/dsh-bridge/context') {
        try {
          const target = await resolveTarget(url.searchParams.get('sessionId') ?? undefined)
          const context = readContextPressure(target.session)
          if (context === undefined) {
            sendJson(res, 204, {})
            return
          }
          sendJson(res, 200, { sessionId: String(target.session.id), ...context })
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/sessions/resume') {
        try {
          const body = (await readJson(req)) as { sessionId?: unknown } | undefined
          const id = typeof body?.sessionId === 'string' && body.sessionId !== '' ? body.sessionId : null
          if (id === null) {
            sendJson(res, 400, { error: 'sessionId is required' })
            return
          }
          const target = await ensureLive(id)
          sendJson(res, 200, {
            ok: true,
            sessionId: String(target.session.id),
            title: sessionTitle(target.session.snapshotEvents()),
            cwd: target.session.header.cwd ?? null,
          })
          broadcastSessionsChanged(String(target.session.id))
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/sessions/rename') {
        try {
          const body = (await readJson(req)) as { sessionId?: unknown; title?: unknown } | undefined
          const id = typeof body?.sessionId === 'string' && body.sessionId !== '' ? body.sessionId : null
          const title = typeof body?.title === 'string' ? body.title : undefined
          if (id === null || title === undefined) {
            sendJson(res, 400, { error: 'sessionId and title are required' })
            return
          }
          const sessionTitleService = ctx.get('sessionTitle') as SessionTitleService | undefined
          if (sessionTitleService === undefined) {
            sendJson(res, 501, { error: 'profile lacks a session title service' })
            return
          }
          const target = await ensureLive(id)
          const snapshot = sessionTitleService.rename(target.session, title)
          sendJson(res, 200, { ok: true, sessionId: id, title: snapshot.title })
          broadcastSessionsChanged(id)
        } catch (error: unknown) {
          const status = isSessionTitleInvalidError(error) ? 400 : bridgeErrorStatus(error)
          sendJson(res, status, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/sessions/archive') {
        try {
          const body = (await readJson(req)) as { sessionId?: unknown } | undefined
          const id = typeof body?.sessionId === 'string' && body.sessionId !== '' ? body.sessionId : null
          if (id === null) {
            sendJson(res, 400, { error: 'sessionId is required' })
            return
          }
          const workspaceRegistry = ctx.get('workspaceRegistry') as WorkspaceRegistryService | undefined
          if (workspaceRegistry === undefined) {
            sendJson(res, 501, { error: 'profile lacks a workspace registry (no archive support)' })
            return
          }
          await workspaceRegistry.archiveSession(id)
          sendJson(res, 200, { ok: true, sessionId: id })
          broadcastSessionsChanged(id)
        } catch (error: unknown) {
          const status = isWorkspaceUnknownSessionError(error) ? 404 : bridgeErrorStatus(error)
          sendJson(res, status, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'GET' && pathname === '/dsh-bridge/workspaces') {
        const workspaceRegistry = ctx.get('workspaceRegistry') as WorkspaceRegistryService | undefined
        if (workspaceRegistry === undefined) {
          sendJson(res, 501, { error: 'profile lacks a workspace registry' })
          return
        }
        try {
          const workspaces = workspaceRegistry.list().map(w => ({ id: w.id, title: w.title, path: w.path }))
          sendJson(res, 200, { workspaces })
        } catch (error: unknown) {
          sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/workspaces/rename') {
        try {
          const body = (await readJson(req)) as { workspaceId?: unknown; title?: unknown } | undefined
          const workspaceId = typeof body?.workspaceId === 'string' && body.workspaceId !== '' ? body.workspaceId : null
          const title = typeof body?.title === 'string' ? body.title : undefined
          if (workspaceId === null || title === undefined) {
            sendJson(res, 400, { error: 'workspaceId and title are required' })
            return
          }
          const workspaceRegistry = ctx.get('workspaceRegistry') as WorkspaceRegistryService | undefined
          if (workspaceRegistry === undefined) {
            sendJson(res, 501, { error: 'profile lacks a workspace registry' })
            return
          }
          const workspace = workspaceRegistry.get(workspaceId)
          if (workspace === undefined) {
            sendJson(res, 404, { error: `workspace ${workspaceId} is not known` })
            return
          }
          const normalized = title.trim()
          if (normalized === '') {
            sendJson(res, 400, { error: 'workspace title must contain visible characters' })
            return
          }
          if (normalized === workspace.title) {
            sendJson(res, 200, { ok: true, workspaceId, title: workspace.title })
            return
          }
          if (workspaceTitleConflict(normalized, workspaceRegistry.list(), workspaceId)) {
            sendJson(res, 409, { error: `workspace named ${normalized} exists` })
            return
          }
          await workspace.setTitle(normalized)
          sendJson(res, 200, { ok: true, workspaceId, title: normalized })
          broadcastSessionsChanged()
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/sessions/create') {
        try {
          const body = (await readJson(req)) as {
            workspaceId?: unknown
            path?: unknown
            workspaceTitle?: unknown
          } | undefined
          const workspaceId = typeof body?.workspaceId === 'string' && body.workspaceId !== '' ? body.workspaceId : undefined
          const path = typeof body?.path === 'string' && body.path !== '' ? body.path : undefined
          const workspaceTitle = typeof body?.workspaceTitle === 'string' ? body.workspaceTitle : undefined
          if ((workspaceId === undefined) === (path === undefined)) {
            sendJson(res, 400, { error: 'exactly one of workspaceId or path is required' })
            return
          }
          const workspaceRegistry = ctx.get('workspaceRegistry') as WorkspaceRegistryService | undefined
          if (workspaceRegistry === undefined) {
            sendJson(res, 501, { error: 'profile lacks a workspace registry' })
            return
          }
          let workspace: WorkspaceEntityService
          if (workspaceId !== undefined) {
            const existing = workspaceRegistry.get(workspaceId)
            if (existing === undefined) {
              sendJson(res, 404, { error: `workspace ${workspaceId} is not known` })
              return
            }
            workspace = existing
          } else {
            const existing = await workspaceRegistry.resolveByPath(path as string)
            if (existing !== undefined) {
              workspace = existing
            } else {
              workspace = await workspaceRegistry.create(path as string, workspaceTitle)
            }
          }
          const sessionId = `session-${randomUUID()}` as SessionId
          const composition = await composeBridgeAgent(undefined)
          const handle = await ctx.agents.create({
            sessionId,
            meta: {
              cwd: workspace.path,
              ...composition.agentPreset === undefined ? {} : { agentPreset: composition.agentPreset },
            },
            agentOptions: composition.agentOptions,
            setup: composition.setup,
          })
          try {
            await workspace.attachSession(String(sessionId))
          } catch (attachError: unknown) {
            await handle.dispose()
            throw attachError
          }
          sendJson(res, 201, {
            ok: true,
            sessionId: String(sessionId),
            workspaceId: String(workspace.id),
            cwd: workspace.path,
          })
          broadcastSessionsChanged(String(sessionId))
        } catch (error: unknown) {
          sendJson(res, bridgeErrorStatus(error), { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      // Branch a completed-turn prefix of a session into a new one. The source
      // id is resolved read-only (never resumed — the fork seam observes the
      // source cold-safe), so a cold source forks without spawning its agent.
      // The subagent fence is the stricter targeting-route form, not a literal
      // mirror of `/session` (which checks `header.origin` alone): forking is a
      // mutation, so a subagent child whose parent is merely cold is refused
      // too. The new session is announced by the harness's own `session/created`
      // event, which the listener above already broadcasts.
      if (req.method === 'POST' && pathname === '/dsh-bridge/fork') {
        try {
          const body = (await readJson(req)) as { sessionId?: unknown; atSeq?: unknown } | undefined
          let explicitId: string | undefined
          if (body?.sessionId !== undefined && body.sessionId !== null) {
            if (typeof body.sessionId !== 'string') {
              sendJson(res, 400, { error: 'sessionId must be a string' })
              return
            }
            explicitId = body.sessionId
          }
          let atSeq: number | undefined
          if (body?.atSeq !== undefined && body.atSeq !== null) {
            if (typeof body.atSeq !== 'number' || !Number.isSafeInteger(body.atSeq) || body.atSeq < 0) {
              sendJson(res, 400, { error: 'atSeq must be a non-negative safe integer' })
              return
            }
            atSeq = body.atSeq
          }
          const sessionController = ctx.get('sessionController') as SessionControllerService | undefined
          if (sessionController === undefined) {
            sendJson(res, 501, { error: 'profile lacks a session controller (no fork support)' })
            return
          }
          const id = await resolveReadId(explicitId)
          const live = sessions.list().find(session => String(session.id) === id)
          if (live !== undefined) {
            if (isSubagentChild(live.header.origin, ownedByLiveParent(live))) {
              sendJson(res, 409, { error: `session ${id} is owned by a subagent` })
              return
            }
          } else {
            // A persistence backend failure degrades the fence rather than
            // failing the route: the fork seam observes the source itself and
            // surfaces its own error (the same tolerance `persistedHeaders`
            // applies).
            try {
              if ((await sessionPersistence.stat(id))?.header.origin === 'subagent') {
                sendJson(res, 409, { error: `session ${id} is owned by a subagent` })
                return
              }
            } catch {
              // degraded: no cold header to check
            }
          }
          const child = await sessionController.fork({
            sessionId: id as SessionId,
            ...(atSeq === undefined ? {} : { atSeq }),
          })
          sendJson(res, 201, {
            ok: true,
            sessionId: String(child.sessionId),
            parentSessionId: id,
            atSeq: atSeq ?? null,
          })
        } catch (error: unknown) {
          const status = forkErrorStatus(error)
          // A workspace-attach failure happens AFTER the child exists; surface
          // its id so a caller can still reach the (orphaned) child.
          const details = (error as { details?: { sessionId?: unknown } } | null)?.details
          const childId = isRemoteErrorCode(error, 'session/workspace-attach-failed')
            && typeof details?.sessionId === 'string'
            ? { sessionId: details.sessionId }
            : {}
          sendJson(res, status, {
            error: error instanceof Error ? error.message : String(error),
            ...childId,
          })
        }
        return
      }

      sendJson(res, 404, { error: 'not found' })
    },
  }))
}
