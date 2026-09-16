// dsh-emacs-bridge — pure browser-side matching for dismissing the web UI's
// approval panel when the same approval was resolved in Emacs (or elsewhere).
// No Cordis/browser imports, so Vitest exercises it directly.
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

/**
 * Minimal face of one pending approval, enough to match a resolution. The
 * bridge's approval frame carries the asker's own tool identity, which the
 * forwarded browser request reproduces on the pending object; there is no
 * bridge-minted id shared with the browser.
 */
export interface PendingApprovalLike {
  /** Domain presentation discriminator (`approval`). */
  readonly kind: string
  /** Session whose composer shows this approval. */
  readonly sessionId: string
  /** Tool requesting the decision. */
  readonly toolName?: unknown
  /** Tool call correlated with the request, when the asker supplied one. */
  readonly callId?: unknown
}

/** One host-broadcast approval resolution waiting for its web panel to appear. */
export interface ApprovalDismissRecord {
  /** Session the resolved approval belonged to. */
  readonly sessionId: string
  /** Tool the resolved approval was about. */
  readonly toolName: string
  /** Correlated tool call, when the asker supplied one. */
  readonly callId?: string
  /** Epoch ms the resolution was recorded; the caller expires unmatched retries. */
  readonly at?: number
}

/**
 * The index in RECORDS matching PENDING, or -1 when none does.
 *
 * A match needs the same session and tool name. When the record carries a
 * tool-call id the pending approval must carry the identical one (a hook-gated
 * ask can carry none, in which case session + tool is the whole identity); at
 * most one interaction is visible per session, so this cannot cancel an
 * unrelated wait. Question domains are dismissed by the question matcher.
 */
export function matchApprovalDismissRecord(
  records: readonly ApprovalDismissRecord[],
  pending: PendingApprovalLike,
): number {
  if (pending.kind !== 'approval') return -1
  const toolName = typeof pending.toolName === 'string' ? pending.toolName : undefined
  if (toolName === undefined) return -1
  const callId = typeof pending.callId === 'string' ? pending.callId : undefined
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index]
    if (record === undefined) continue
    if (record.sessionId !== pending.sessionId) continue
    if (record.toolName !== toolName) continue
    if (record.callId !== undefined && record.callId !== callId) continue
    return index
  }
  return -1
}
