// dsh-emacs-bridge — Vitest specs for the bounded DSH→Emacs outbox.
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
import { Outbox, OUTBOX_DEFAULT_CAP, type OutboxEntry } from '../src/outbox.ts'

let counter = 0
function entry(overrides: Partial<OutboxEntry> = {}): OutboxEntry {
  counter += 1
  return { id: `id-${counter}`, source: 'bridge', text: `text ${counter}`, ts: counter, ...overrides }
}

describe('Outbox', () => {
  it('returns a deposited entry on collect, oldest-first', () => {
    const outbox = new Outbox()
    const first = entry({ id: 'a', ts: 1 })
    const second = entry({ id: 'b', ts: 2 })
    outbox.deposit(first)
    outbox.deposit(second)
    const { entries } = outbox.collect()
    expect(entries.map(e => e.id)).toEqual(['a', 'b'])
  })

  it('collect returns a detached copy', () => {
    const outbox = new Outbox()
    outbox.deposit(entry({ id: 'a' }))
    const collected = outbox.collect().entries
    collected[0]!.text = 'mutated'
    expect(outbox.collect().entries[0]!.text).not.toBe('mutated')
  })

  it('evicts the oldest entry at capacity and reports the overflow', () => {
    const outbox = new Outbox(2)
    outbox.deposit(entry({ id: 'a' }))
    outbox.deposit(entry({ id: 'b' }))
    const evicted = outbox.deposit(entry({ id: 'c' }))
    expect(evicted).toBe(true)
    const { entries, overflowed } = outbox.collect()
    expect(entries.map(e => e.id)).toEqual(['b', 'c'])
    expect(overflowed).toBe(true)
    // The overflow latch clears after one collect.
    expect(outbox.collect().overflowed).toBe(false)
  })

  it('does not evict when below capacity', () => {
    const outbox = new Outbox(2)
    outbox.deposit(entry({ id: 'a' }))
    expect(outbox.deposit(entry({ id: 'b' }))).toBe(false)
  })

  it('admits OUTBOX_DEFAULT_CAP entries by default and evicts on the next', () => {
    const outbox = new Outbox()
    for (let index = 1; index <= OUTBOX_DEFAULT_CAP; index += 1) {
      expect(outbox.deposit(entry({ id: `e${index}` }))).toBe(false)
    }
    expect(outbox.size).toBe(OUTBOX_DEFAULT_CAP)
    expect(outbox.deposit(entry({ id: `e${OUTBOX_DEFAULT_CAP + 1}` }))).toBe(true)
    const { entries, overflowed } = outbox.collect()
    expect(entries).toHaveLength(OUTBOX_DEFAULT_CAP)
    expect(entries[0]!.id).toBe('e2')
    expect(entries.at(-1)!.id).toBe(`e${OUTBOX_DEFAULT_CAP + 1}`)
    expect(overflowed).toBe(true)
  })

  it('ack removes the named entries and leaves the rest', () => {
    const outbox = new Outbox()
    outbox.deposit(entry({ id: 'a' }))
    outbox.deposit(entry({ id: 'b' }))
    outbox.deposit(entry({ id: 'c' }))
    outbox.ack(['a', 'c'])
    expect(outbox.collect().entries.map(e => e.id)).toEqual(['b'])
    expect(outbox.size).toBe(1)
  })

  it('ignores unknown ids in ack', () => {
    const outbox = new Outbox()
    outbox.deposit(entry({ id: 'a' }))
    outbox.ack(['nope'])
    expect(outbox.collect().entries.map(e => e.id)).toEqual(['a'])
  })

  it('collect after ack returns empty', () => {
    const outbox = new Outbox()
    outbox.deposit(entry({ id: 'a' }))
    outbox.ack(['a'])
    expect(outbox.collect().entries).toEqual([])
  })
})
