// dsh-emacs-bridge — pure browser-side matching for dismissing the web UI's
// ask-user question panel when the same question was answered in Emacs (or
// cancelled there). No Cordis/browser imports, so Vitest exercises it directly.
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

/** Minimal face of one pending question, enough to match a resolution. */
export interface PendingQuestionLike {
  /** Domain presentation discriminator (`question` / `plan-review`). */
  readonly kind: string
  /** Session whose composer shows this question. */
  readonly sessionId: string
  /** The asker's question batch. */
  readonly questions: readonly { readonly id?: unknown }[]
}

/** One host-broadcast resolution waiting for its web panel to appear. */
export interface DismissRecord {
  /** Session the resolved question belonged to. */
  readonly sessionId: string
  /** The asker's own question ids, echoed by the resolution frame. */
  readonly questionIds: readonly string[]
  /** Epoch ms the resolution was recorded; the caller expires unmatched retries. */
  readonly at?: number
}

/** The string ids of a question batch, skipping malformed entries. */
export function questionIdsOf(questions: readonly { readonly id?: unknown }[] | undefined): string[] {
  if (!Array.isArray(questions)) return []
  const ids: string[] = []
  for (const question of questions) {
    if (question !== null && typeof question === 'object' && typeof question.id === 'string') {
      ids.push(question.id)
    }
  }
  return ids
}

/** Whether two question-id lists name the same set (order- and duplicate-insensitive). */
export function sameQuestionIds(left: readonly string[], right: readonly string[]): boolean {
  if (left.length !== right.length) return false
  const sortedLeft = [...left].sort()
  const sortedRight = [...right].sort()
  return sortedLeft.every((id, index) => id === sortedRight[index])
}

/**
 * The index in RECORDS matching PENDING, or -1 when none does.
 *
 * A match needs the same session, the same question-id set, and a question
 * presentation — the pending-interaction registry also carries non-question
 * domains (approvals), and dismissing one of those would cancel an unrelated
 * wait.
 */
export function matchDismissRecord(
  records: readonly DismissRecord[],
  pending: PendingQuestionLike,
): number {
  if (pending.kind !== 'question' && pending.kind !== 'plan-review') return -1
  const ids = questionIdsOf(pending.questions)
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index]
    if (record !== undefined
      && record.sessionId === pending.sessionId
      && sameQuestionIds(record.questionIds, ids)) {
      return index
    }
  }
  return -1
}
