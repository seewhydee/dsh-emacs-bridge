// dsh-emacs-bridge — pure, dependency-free bounded outbox carrying DSH-side
// turn references to Emacs. Kept import-free so Vitest exercises it directly.
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

/** One DSH→Emacs turn reference. */
export interface OutboxEntry {
  id: string
  sessionId: string
  source: string
  turn: number
  ts: number
}

/** The result of a collect: pending entries plus whether anything was evicted. */
export interface OutboxCollect {
  entries: OutboxEntry[]
  overflowed: boolean
}

export const OUTBOX_DEFAULT_CAP = 100

/**
 * A bounded FIFO of DSH→Emacs messages. `deposit` appends and evicts the
 * oldest entry at capacity; `collect` returns a detached copy of everything
 * not yet acked; `ack` removes by id. Emacs acks only after a successful
 * insert, so a crash between collect and ack redelivers on the next pull
 * (acceptable duplicates), never silently drops.
 */
export class Outbox {
  private pending: OutboxEntry[] = []
  private evictedSinceCollect = false

  constructor(private readonly cap = OUTBOX_DEFAULT_CAP) {}

  /** Append an entry, evicting the oldest when at capacity. Returns whether one was evicted. */
  deposit(entry: OutboxEntry): boolean {
    let evicted = false
    if (this.pending.length >= this.cap) {
      this.pending.shift()
      evicted = true
      this.evictedSinceCollect = true
    }
    this.pending.push(entry)
    return evicted
  }

  /** Pending (deposited, not acked) entries, oldest-first, as a detached copy. */
  collect(): OutboxCollect {
    const overflowed = this.evictedSinceCollect
    this.evictedSinceCollect = false
    return { entries: this.pending.map(entry => ({ ...entry })), overflowed }
  }

  /** Remove the named pending entries; unknown ids are ignored. */
  ack(ids: readonly string[]): void {
    const idSet = new Set(ids)
    this.pending = this.pending.filter(entry => !idSet.has(entry.id))
  }

  get size(): number {
    return this.pending.length
  }
}
