// dsh-emacs-bridge — shared sequential session-event fixture.
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

import type { SessionEventLike } from '../src/logic.ts'

/** A unique event seq per event, assigned in append order. */
export function log(): { events: SessionEventLike[]; add: (event: SessionEventLike) => SessionEventLike } {
  const events: SessionEventLike[] = []
  return {
    events,
    add(event) {
      const withSeq = { ...event, seq: event.seq ?? events.length }
      events.push(withSeq)
      return withSeq
    },
  }
}
