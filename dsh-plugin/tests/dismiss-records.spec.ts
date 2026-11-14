// dsh-emacs-bridge — Vitest specs for bounded browser-dismissal retries.
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

import { describe, expect, it } from 'vitest'
import { appendDismissRecord, expireDismissRecords } from '../src/client/dismiss-records.ts'

describe('dismissal retry-list maintenance', () => {
  it('expires old records while retaining recent and timeless ones', () => {
    const records = [{ at: 10 }, { at: 90 }, {}, { at: 1 }]
    expireDismissRecords(records, 100, 50)
    expect(records).toEqual([{ at: 90 }, {}])
  })

  it('evicts the oldest record beyond the cap', () => {
    const records = [1, 2]
    appendDismissRecord(records, 3, 2)
    expect(records).toEqual([2, 3])
  })
})
