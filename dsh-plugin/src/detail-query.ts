// dsh-emacs-bridge — single-item inspector query parsing.
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

import { MAX_INFLIGHT_ID_CHARS } from './logic.ts'

/** The three direct item selectors exposed by `/details/item`. */
export type DetailItemKind = 'thinking' | 'tool' | 'tool-result'

/** A validated item read.  FULL asks for the complete content without the
 * size probe's confirmation threshold. */
export interface DetailItemRequest {
  sessionId: string
  turn: number
  kind: DetailItemKind
  /** A committed reasoning message's seq; mutually exclusive with inFlightId. */
  seq?: number
  /** A live-attempt selector, minted by the host for one accepted start. */
  inFlightId?: string
  ord?: number
  callId?: string
  full?: true
}

/** The minimal query accessor shared by URLSearchParams and test fixtures. */
export interface DetailQueryParams {
  getAll(name: string): string[]
}

/** A successful or failed query parse. */
export type DetailQueryParse<T> =
  | { ok: true; request: T }
  | { ok: false; error: string }

type QueryValue<T> =
  | { ok: true; value: T }
  | { ok: false; error: string }

/** One query parameter, rejecting a repeated name. */
function singleQueryParam(params: DetailQueryParams, name: string): QueryValue<string | undefined> {
  const values = params.getAll(name)
  if (values.length > 1) return { ok: false, error: `${name} must be a single value` }
  return { ok: true, value: values[0] }
}

/** Parse a non-negative safe integer, or null. */
function queryInteger(value: string | undefined): number | null {
  if (value === undefined || !/^\d+$/.test(value)) return null
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) ? parsed : null
}

/** Parse a required non-negative-integer parameter. */
function requiredInteger(params: DetailQueryParams, name: string): QueryValue<number> {
  const single = singleQueryParam(params, name)
  if (!single.ok) return single
  if (single.value === undefined) return { ok: false, error: `${name} is required` }
  const value = queryInteger(single.value)
  return value === null
    ? { ok: false, error: `${name} must be a non-negative integer` }
    : { ok: true, value }
}

/** Parse the mandatory session id: one non-empty string. */
function requiredSessionId(params: DetailQueryParams): QueryValue<string> {
  const single = singleQueryParam(params, 'sessionId')
  if (!single.ok) return single
  if (single.value === undefined || single.value === '') {
    return { ok: false, error: 'sessionId must be a single non-empty string' }
  }
  return { ok: true, value: single.value }
}

/**
 * Parse `GET /details/item`.  The request carries a concrete item selector and
 * optionally `full=1` to fetch content above the confirmation threshold.  The
 * former continuation parameters are rejected rather than ignored, so a stale
 * client cannot silently read a different item.
 */
export function parseDetailItemQuery(params: DetailQueryParams): DetailQueryParse<DetailItemRequest> {
  const session = requiredSessionId(params)
  if (!session.ok) return session
  const turn = requiredInteger(params, 'turn')
  if (!turn.ok) return turn
  const kindSingle = singleQueryParam(params, 'kind')
  if (!kindSingle.ok) return kindSingle
  const kind = kindSingle.value
  if (kind !== 'thinking' && kind !== 'tool' && kind !== 'tool-result') {
    return { ok: false, error: 'kind must be thinking, tool, or tool-result' }
  }

  const seqSingle = singleQueryParam(params, 'seq')
  if (!seqSingle.ok) return seqSingle
  const ordSingle = singleQueryParam(params, 'ord')
  if (!ordSingle.ok) return ordSingle
  const callSingle = singleQueryParam(params, 'callId')
  if (!callSingle.ok) return callSingle
  const inFlightSingle = singleQueryParam(params, 'inFlightId')
  if (!inFlightSingle.ok) return inFlightSingle
  let seq: number | undefined
  let inFlightId: string | undefined
  let ord: number | undefined
  let callId: string | undefined
  if (kind === 'thinking') {
    if (callSingle.value !== undefined) return { ok: false, error: 'callId is not valid for thinking' }
    if (ordSingle.value === undefined) return { ok: false, error: 'ord is required for thinking' }
    if (seqSingle.value !== undefined && inFlightSingle.value !== undefined) {
      return { ok: false, error: 'seq and inFlightId are mutually exclusive' }
    }
    if (seqSingle.value === undefined && inFlightSingle.value === undefined) {
      return { ok: false, error: 'one of seq or inFlightId is required for thinking' }
    }
    const parsedOrd = queryInteger(ordSingle.value)
    if (parsedOrd === null) return { ok: false, error: 'ord must be a non-negative integer' }
    ord = parsedOrd
    if (inFlightSingle.value !== undefined) {
      if (inFlightSingle.value === ''
        || inFlightSingle.value.length > MAX_INFLIGHT_ID_CHARS
        || /[\u0000-\u001f\u007f]/.test(inFlightSingle.value)) {
        return { ok: false, error: `inFlightId must be a single non-empty string of at most ${MAX_INFLIGHT_ID_CHARS} characters` }
      }
      inFlightId = inFlightSingle.value
    } else {
      const parsedSeq = queryInteger(seqSingle.value)
      if (parsedSeq === null) return { ok: false, error: 'seq must be a non-negative integer' }
      seq = parsedSeq
    }
  } else {
    if (seqSingle.value !== undefined) return { ok: false, error: 'seq is only valid for thinking' }
    if (inFlightSingle.value !== undefined) return { ok: false, error: 'inFlightId is only valid for thinking' }
    if (ordSingle.value !== undefined) return { ok: false, error: 'ord is only valid for thinking' }
    if (callSingle.value === undefined || callSingle.value === '') {
      return { ok: false, error: 'callId must be a single non-empty string' }
    }
    callId = callSingle.value
  }

  const fullSingle = singleQueryParam(params, 'full')
  if (!fullSingle.ok) return fullSingle
  if (fullSingle.value !== undefined && fullSingle.value !== '1' && fullSingle.value !== 'true') {
    return { ok: false, error: 'full must be 1 or true' }
  }
  for (const name of ['epoch', 'cursor', 'part', 'byteOffset', 'fileIndex']) {
    const legacy = singleQueryParam(params, name)
    if (!legacy.ok) return legacy
    if (legacy.value !== undefined) {
      return { ok: false, error: `${name} is not supported; the item route returns one complete response` }
    }
  }

  return {
    ok: true,
    request: {
      sessionId: session.value,
      turn: turn.value,
      kind,
      ...seq === undefined ? {} : { seq },
      ...inFlightId === undefined ? {} : { inFlightId },
      ...ord === undefined ? {} : { ord },
      ...callId === undefined ? {} : { callId },
      ...fullSingle.value === undefined ? {} : { full: true as const },
    },
  }
}
