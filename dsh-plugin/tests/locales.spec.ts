// dsh-emacs-bridge — Vitest specs for the client locale dictionaries.
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
import { en, zh } from '../src/client/locales.ts'

describe('locale dictionaries', () => {
  it('en mirrors the zh key set exactly (zh is the source of truth)', () => {
    // The `satisfies Record<DshBridgeKey, string>` check is type-only and no
    // build/test command runs it, so the mirror invariant is pinned at runtime.
    expect(Object.keys(en).sort()).toEqual(Object.keys(zh).sort())
  })

  it('carries a non-empty string for every key in both dictionaries', () => {
    for (const dictionary of [zh, en]) {
      for (const [key, value] of Object.entries(dictionary)) {
        expect(typeof value, key).toBe('string')
        expect(value.length, key).toBeGreaterThan(0)
      }
    }
  })
})
