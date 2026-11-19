// dsh-emacs-bridge — pure session-report and goal projection logic.
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

import {
  effectiveCwd,
  recordOf,
  sessionPreset,
  sessionTitle,
  type SessionEventLike,
  type SessionHeaderLike,
} from './logic.ts'

/** One projection wire-value map, as read from an observation snapshot. */
export interface ProjectionValuesLike {
  readonly [key: string]: unknown
}

/** Header facts the report needs beyond the list-row subset. */
export interface SessionReportHeaderLike extends SessionHeaderLike {
  parentSession?: string
  isSeeded?: boolean
  delegationDepth?: number
}

/**
 * Structural face of one observed session, live or prepared (cold). `events`
 * is read only by the title/preset fallback folds, so a caller whose
 * projections already carry those keys never materializes the log.
 */
export interface SessionObservationLike {
  readonly source: 'live' | 'prepared'
  readonly header: SessionReportHeaderLike
  readonly events?: readonly SessionEventLike[]
  readonly projections?: { readonly values: ProjectionValuesLike } | undefined
}

/** Caller-supplied facts the report cannot read from the observation alone. */
export interface SessionReportExtras {
  running?: boolean
  workspace?: string | null
  workspaceId?: string | null
  archived?: boolean
}

/** The durable model selection the session will use next. */
export interface SessionReportModel {
  provider: string
  model: string
  reasoningEffort?: string
}

/** One switchable permission preset as the wire view advertises it. */
export interface SessionReportPermissionOption {
  value: string
  name: string
  description?: string
}

/** The session's permission select (current value + options). */
export interface SessionReportPermissions {
  currentValue: string
  options: SessionReportPermissionOption[]
}

/** Whole-log turn/step counts and wall times (`sessionStats` wire view). */
export interface SessionReportStats {
  turns: number
  steps: number
  llmMs: number
  toolMs: number
  ttftMs: number
  ttftSteps: number
  decodeMs: number
  decodeTokens: number
}

/** Cumulative provider usage (`tokenUsage` wire view). */
export interface SessionReportTokens {
  uncachedInputTokens: number
  outputTokens: number
  cacheReadTokens: number
  cacheWriteTokens: number
}

/** Context occupancy (`contextPressure` wire view); every field optional. */
export interface SessionReportContext {
  pressureTokens?: number
  projectedTokens?: number
  contextWindow?: number
}

/** Heuristic context composition (`contextBreakdown` wire view). */
export interface SessionReportBreakdown {
  systemTokens: number
  toolsTokens: number
  messageTokens: number
}

/**
 * Plan mode state for one session: the `plan` projection plus the wiring's
 * live refinement. The projection's `pending` is direction-less
 * (`wanted !== active`), so it surfaces as `queued`; a live
 * `planMode.get(agent)` read supplies the wanted state itself as `pending`.
 */
export interface SessionReportPlan {
  active: boolean
  /** The wanted state (the toggle's direction): true = queued on, false = queued off. */
  pending?: boolean
  /** A change is pending but its direction is unknown (projection only). */
  queued?: boolean
}

/** One durable goal snapshot (the `goal` projection's `goal` member). */
export interface SessionReportGoalSnapshot {
  id: string
  revision: number
  objective: string
  phase: 'active' | 'paused' | 'blocked' | 'complete'
  blockedReason?: { code: string; message: string }
  maxGoalRounds: number
}

/**
 * The current goal for one session: the `goal` projection's durable view plus
 * the wiring's live `activation`. The string activation (not a boolean) keeps
 * "unknown" (absent) distinct from "disarmed" through both JSON decoders.
 */
export interface SessionReportGoal {
  goal: SessionReportGoalSnapshot
  roundsStarted: number
  createdAt: number
  updatedAt: number
  /** Process-local continuation activation; present only when a live read supplied it. */
  activation?: 'armed' | 'disarmed'
}

/** One live `planMode.get(agent)` read: the logged state plus the wanted direction. */
export interface PlanLiveRead {
  active: boolean
  pending?: boolean
}

/**
 * The live facts the wiring can read for a live session, merged into the
 * durable report by {@link refinePlanGoal}.
 */
export interface PlanGoalLive {
  /** undefined = projection only (cold or no service); null = controller definitively absent. */
  plan?: PlanLiveRead | null
  /** Process-local goal activation, when the goal service supplied one. */
  goalActivation?: 'armed' | 'disarmed'
}

/**
 * One session's read-only report, the `GET /dsh-bridge/session` body. Every
 * numeric/derived section is null when its projection was unavailable, and
 * `missing` names those keys so the Emacs side can say why rather than showing
 * a fake zero. `modelName` is filled by the wiring (catalog RPC), not here.
 */
export interface SessionReport {
  sessionId: string
  live: boolean
  running: boolean
  basis: 'observation' | 'header'
  missing: string[]
  title: string | null
  cwd: string | null
  workspace: string | null
  workspaceId: string | null
  archived: boolean
  createdAt: number
  lastActive: number | null
  lastPromptAt: number | null
  parentSession: string | null
  isSeeded: boolean
  origin: string | null
  delegationDepth: number | null
  agentPreset: string | null
  model: SessionReportModel | null
  modelName: string | null
  permissions: SessionReportPermissions | null
  stats: SessionReportStats | null
  tokens: SessionReportTokens | null
  context: SessionReportContext | null
  breakdown: SessionReportBreakdown | null
  plan: SessionReportPlan | null
  goal: SessionReportGoal | null
}

function asNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function numericReport<K extends string>(value: unknown, keys: readonly K[]): Record<K, number> | null {
  const source = recordOf(value)
  if (source === undefined) return null
  const result: Partial<Record<K, number>> = {}
  for (const key of keys) {
    const number = asNumber(source[key])
    if (number === null) return null
    result[key] = number
  }
  return result as Record<K, number>
}

function reportStats(value: unknown): SessionReportStats | null {
  return numericReport(value,
    ['turns', 'steps', 'llmMs', 'toolMs', 'ttftMs', 'ttftSteps', 'decodeMs', 'decodeTokens'])
}

function reportTokens(value: unknown): SessionReportTokens | null {
  return numericReport(value, ['uncachedInputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens'])
}

function reportBreakdown(value: unknown): SessionReportBreakdown | null {
  return numericReport(value, ['systemTokens', 'toolsTokens', 'messageTokens'])
}

function reportContext(value: unknown): SessionReportContext | null {
  const source = recordOf(value)
  if (source === undefined) return null
  const context: SessionReportContext = {}
  const pressure = asNumber(source.pressureTokens)
  const projected = asNumber(source.projectedTokens)
  const window = asNumber(source.contextWindow)
  if (pressure !== null) context.pressureTokens = pressure
  if (projected !== null) context.projectedTokens = projected
  if (window !== null) context.contextWindow = window
  return context.pressureTokens === undefined
    && context.projectedTokens === undefined
    && context.contextWindow === undefined
    ? null
    : context
}

/**
 * The model section: the pending selection when present and well-formed, else
 * the last-used one. A null or absent `next` is the normal "no pending switch"
 * state and falls back to `lastUsed`; a present-but-malformed `next` (a
 * non-string provider or model) degrades the whole section to null instead —
 * a corrupt projection is reported, not silently repaired from an older value.
 */
function reportModel(value: unknown): SessionReportModel | null {
  const view = recordOf(value)
  const selection = view?.next == null
    ? recordOf(view?.lastUsed)
    : recordOf(view.next)
  if (selection === undefined) return null
  const provider = selection.provider
  const model = selection.model
  if (typeof provider !== 'string' || typeof model !== 'string') return null
  const effort = selection.reasoningEffort
  return typeof effort === 'string' && effort !== ''
    ? { provider, model, reasoningEffort: effort }
    : { provider, model }
}

function reportPermissions(value: unknown): SessionReportPermissions | null {
  const view = recordOf(value)
  if (view === undefined) return null
  const currentValue = view.currentValue
  const options = view.options
  if (typeof currentValue !== 'string' || !Array.isArray(options)) return null
  const parsed: SessionReportPermissionOption[] = []
  for (const raw of options) {
    const option = recordOf(raw)
    if (option === undefined) continue
    const optionValue = option.value
    const name = option.name
    if (typeof optionValue !== 'string' || typeof name !== 'string') continue
    parsed.push(typeof option.description === 'string'
      ? { value: optionValue, name, description: option.description }
      : { value: optionValue, name })
  }
  return { currentValue, options: parsed }
}

/**
 * The plan section: the projection's `{active, pending}` wire view mapped to
 * `{active, queued}` (its `pending` is direction-less, `wanted !== active`).
 * A present-but-malformed value is null (the caller names it missing); a
 * legitimately inactive plan is `{active: false}`, never null. `pending` (the
 * wanted direction) is filled by the live refinement, never here.
 */
export function reportPlan(value: unknown): SessionReportPlan | null {
  const source = recordOf(value)
  if (source === undefined) return null
  if (typeof source.active !== 'boolean' || typeof source.pending !== 'boolean') return null
  return source.pending ? { active: source.active, queued: true } : { active: source.active }
}

/**
 * The goal section: the projection's current-goal object, or null when no goal
 * is current. A present-but-malformed value is null (the caller names it
 * missing); a legitimate null (no goal) is not. `activation` is filled by the
 * live refinement, never here.
 */
export function reportGoal(value: unknown): SessionReportGoal | null {
  const source = recordOf(value)
  if (source === undefined) return null
  const snapshot = recordOf(source.goal)
  const roundsStarted = asNumber(source.roundsStarted)
  const createdAt = asNumber(source.createdAt)
  const updatedAt = asNumber(source.updatedAt)
  if (snapshot === undefined || roundsStarted === null
    || createdAt === null || updatedAt === null) return null
  const { id, revision, objective, phase, maxGoalRounds } = snapshot
  if (typeof id !== 'string' || id === '') return null
  if (typeof revision !== 'number' || !Number.isInteger(revision) || revision <= 0) return null
  if (typeof objective !== 'string' || objective === '') return null
  if (phase !== 'active' && phase !== 'paused' && phase !== 'blocked' && phase !== 'complete') return null
  if (typeof maxGoalRounds !== 'number' || !Number.isInteger(maxGoalRounds) || maxGoalRounds <= 0) return null
  const goal: SessionReportGoalSnapshot = { id, revision, objective, phase, maxGoalRounds }
  if (Object.hasOwn(snapshot, 'blockedReason') && snapshot.blockedReason !== undefined) {
    const reason = recordOf(snapshot.blockedReason)
    if (reason === undefined
      || typeof reason.code !== 'string' || typeof reason.message !== 'string') return null
    goal.blockedReason = { code: reason.code, message: reason.message }
  }
  return { goal, roundsStarted, createdAt, updatedAt }
}

/**
 * Build one session report from an observation (or a header-only stand-in)
 * and caller-supplied extras. Pure: every projection value is narrowed with
 * local guards and an unexpected shape degrades to null. For the strict-schema
 * sections (stats, tokens, breakdown, plan) null is never a legitimate state,
 * so a present-but-malformed value also earns a `missing` entry; the other
 * sections' null is a real state (untitled, no selection yet, no pressure
 * sample), so they join `missing` only when the key is absent. `goal` is the
 * exception: null (no goal) is legitimate, so only a present-but-malformed
 * value earns `missing`. The live plan/goal refinement is a separate pure
 * pass ({@link refinePlanGoal}). The fallback folds (title, preset) read the
 * log the caller already materialized when it has no projection value to
 * prefer; `cwd` prefers the observation's `workingDirectory` projection (the
 * host's own value for whichever directory event its release records) and
 * folds the log only when the observation carries no projections.
 */
export function sessionReport(
  observation: SessionObservationLike,
  extras: SessionReportExtras = {},
): SessionReport {
  const values = observation.projections?.values
  const has = (key: string): boolean => values !== undefined && Object.hasOwn(values, key)
  const stats = reportStats(values?.sessionStats)
  const tokens = reportTokens(values?.tokenUsage)
  const breakdown = reportBreakdown(values?.contextBreakdown)
  const plan = reportPlan(values?.plan)
  const goal = reportGoal(values?.goal)
  const strict: Record<string, unknown> = { stats, tokens, breakdown, plan }
  const missing: string[] = []
  for (const [key, label] of [
    ['title', 'title'],
    ['agentPreset', 'preset'],
    ['modelSelection', 'model'],
    ['permissions', 'permissions'],
    ['sessionStats', 'stats'],
    ['tokenUsage', 'tokens'],
    ['contextPressure', 'context'],
    ['contextBreakdown', 'breakdown'],
    ['sessionListMetadata', 'lastPromptAt'],
    ['plan', 'plan'],
  ] as const) {
    if (!has(key) || (Object.hasOwn(strict, label) && strict[label] === null)) missing.push(label)
  }
  // `goal` alone has a legitimate null (no goal), so only a present but
  // malformed value earns a `missing` entry.
  if (!has('goal') || (values?.goal !== null && goal === null)) missing.push('goal')

  const rawTitle = values?.title
  const title = has('title')
    ? typeof rawTitle === 'string' && rawTitle !== '' ? rawTitle : null
    : observation.events === undefined ? null : sessionTitle(observation.events)

  const rawPreset = values?.agentPreset
  const agentPreset = has('agentPreset')
    ? typeof rawPreset === 'string' && rawPreset !== '' ? rawPreset : null
    : sessionPreset(observation.header, observation.events ?? []) ?? null

  const metadata = recordOf(values?.sessionListMetadata)

  // The host's `workingDirectory` projection is authoritative and applies
  // whichever directory event its release defines; the raw-log fold is only
  // the fallback for an observation that carries no projections. A present but
  // null value is the host saying "no directory recorded", not a missing key.
  const projectedCwd = values?.workingDirectory
  const cwd = has('workingDirectory')
    ? typeof projectedCwd === 'string' && projectedCwd !== '' ? projectedCwd : null
    : effectiveCwd(observation.header, observation.events ?? []) ?? null

  return {
    sessionId: observation.header.id,
    live: observation.source === 'live',
    running: extras.running === true,
    basis: observation.projections === undefined ? 'header' : 'observation',
    missing,
    title,
    cwd,
    workspace: extras.workspace ?? null,
    workspaceId: extras.workspaceId ?? null,
    archived: extras.archived === true,
    createdAt: observation.header.createdAt,
    lastActive: observation.events?.at(-1)?.time ?? null,
    lastPromptAt: asNumber(metadata?.lastPromptAt),
    parentSession: observation.header.parentSession ?? null,
    isSeeded: observation.header.isSeeded === true,
    origin: observation.header.origin ?? null,
    delegationDepth: asNumber(observation.header.delegationDepth),
    agentPreset,
    model: reportModel(values?.modelSelection),
    modelName: null,
    permissions: reportPermissions(values?.permissions),
    stats,
    tokens,
    context: reportContext(values?.contextPressure),
    breakdown,
    plan,
    goal,
  }
}

/**
 * Merge one live plan read into a durable plan section. `live` undefined leaves
 * DURABLE unchanged (projection only); `live` null means the live controller
 * is definitively absent, so the section is dropped; a read replaces `active`
 * and carries the wanted direction in `pending`, else inherits the
 * projection's direction-less `queued`.
 */
export function refinePlanSection(
  durable: SessionReportPlan | null,
  live: PlanLiveRead | null | undefined,
): SessionReportPlan | null {
  if (live === undefined) return durable
  if (live === null) return null
  const plan: SessionReportPlan = { active: live.active }
  if (live.pending !== undefined) plan.pending = live.pending
  else if (durable?.queued === true) plan.queued = true
  return plan
}

/**
 * Merge the host wiring's live reads into a durable session report. Pure so the
 * merge is unit-testable without a host. A null `live.plan` names `plan`
 * missing; an absent `live.plan` leaves the projection section alone. A live
 * `goalActivation` is attached only when a goal is present.
 */
export function refinePlanGoal(report: SessionReport, live: PlanGoalLive): SessionReport {
  const next: SessionReport = { ...report, missing: [...report.missing] }
  next.plan = refinePlanSection(report.plan, live.plan)
  if (next.plan === null) {
    if (!next.missing.includes('plan')) next.missing.push('plan')
  } else {
    next.missing = next.missing.filter(label => label !== 'plan')
  }
  if (live.goalActivation !== undefined && next.goal !== null) {
    next.goal = { ...next.goal, activation: live.goalActivation }
  }
  return next
}

/** The operation `/goal/set` performs against the current goal state. */
export type GoalSetAction = 'create' | 'edit'

/**
 * Whether `/goal/set` creates or edits: no current goal, or a completed one
 * (the slash grammar replaces a complete goal rather than editing it), creates;
 * every other phase is edited in place, keeping phase and activation.
 */
export function goalSetAction(currentPhase: string | undefined): GoalSetAction {
  return currentPhase === undefined || currentPhase === 'complete' ? 'create' : 'edit'
}

/**
 * The stable `.code` of a `GoalError`-like rejection, or undefined. Identified
 * structurally (the goal package's error carries no Typert marker), and
 * restricted to the `GOAL_` prefix so an unrelated `.code` is not misread.
 */
export function goalErrorCode(error: unknown): string | undefined {
  if (typeof error !== 'object' || error === null) return undefined
  const code = (error as { code?: unknown }).code
  return typeof code === 'string' && code.startsWith('GOAL_') ? code : undefined
}

/**
 * The HTTP status for a goal rejection code: a missing current goal is 404, a
 * compare-and-set conflict, an invalid transition, or an agent that is no
 * longer live is 409, invalid input is 400, and an unknown code is 500.
 */
export function goalErrorStatus(code: string): number {
  switch (code) {
    case 'GOAL_NOT_FOUND':
      return 404
    case 'GOAL_STALE_REVISION':
    case 'GOAL_INVALID_TRANSITION':
    case 'GOAL_ALREADY_EXISTS':
    case 'GOAL_AGENT_NOT_LIVE':
      return 409
    case 'GOAL_INVALID_OBJECTIVE':
    case 'GOAL_INVALID_MAX_ROUNDS':
    case 'GOAL_INVALID_BLOCK_REASON':
    case 'GOAL_INVALID_EDIT':
      return 400
    default:
      return 500
  }
}
