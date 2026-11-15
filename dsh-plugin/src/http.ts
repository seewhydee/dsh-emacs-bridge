// dsh-emacs-bridge — bounded HTTP and bridge-error adapters.
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

import type { IncomingMessage, ServerResponse } from 'node:http'
import { BridgeError, errorMessage } from './errors.ts'

/** The HTTP status for a propagated bridge/transport error: BridgeError → its status, an oversize body → 413, else 500. */
export function bridgeErrorStatus(error: unknown): number {
  if (error instanceof BridgeError) return error.status
  if (error instanceof PayloadTooLargeError) return 413
  return 500
}

const MAX_BODY_BYTES = 1024 * 1024

/** Thrown by `readJson` when the body exceeds `MAX_BODY_BYTES`; reported as 413. */
class PayloadTooLargeError extends Error {
  constructor() {
    super('request body too large')
    this.name = 'PayloadTooLargeError'
  }
}

/**
 * Read a bounded JSON request body; rejects malformed input as 400 and
 * oversize input as 413. An oversize body is NOT socket-destroyed: the
 * remaining bytes are drained and discarded so the caller can still write
 * the 413 response on the same
 * connection.
 */
export function readJson(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let body = ''
    let oversize = false
    req.setEncoding('utf8')
    req.on('data', (chunk: string) => {
      if (oversize) return
      body += chunk
      if (Buffer.byteLength(body) > MAX_BODY_BYTES) {
        oversize = true
        body = ''
        reject(new PayloadTooLargeError())
      }
    })
    req.on('end', () => {
      try {
        resolve(body === '' ? undefined : JSON.parse(body))
      } catch (error: unknown) {
        reject(new BridgeError(400, `invalid JSON: ${errorMessage(error)}`))
      }
    })
    req.on('error', reject)
  })
}

/** Write one JSON response. */
export function sendJson(res: ServerResponse, status: number, value: unknown): void {
  const payload = JSON.stringify(value)
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(payload)
}

export function sendError(
  res: ServerResponse,
  status: number,
  error: unknown,
  details: Record<string, unknown> = {},
): void {
  sendJson(res, status, { ...details, error: errorMessage(error) })
}

export function sendBridgeError(res: ServerResponse, error: unknown): void {
  sendError(res, bridgeErrorStatus(error), error)
}

/** Read an optional session id, rejecting a present value of the wrong type. */
export function optionalSessionId(
  body: { sessionId?: unknown } | undefined,
  nonEmpty = false,
): string | undefined {
  const value = body?.sessionId
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'string' || (nonEmpty && value === '')) {
    throw new BridgeError(400, nonEmpty ? 'sessionId must be a non-empty string' : 'sessionId must be a string')
  }
  return value
}
