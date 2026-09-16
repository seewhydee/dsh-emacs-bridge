// dsh-emacs-bridge — Vitest specs for the web-panel approval-dismiss matching.
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
import { matchApprovalDismissRecord, type ApprovalDismissRecord } from '../src/client/approval-dismiss.ts'

const record = (
  sessionId: string,
  toolName: string,
  callId?: string,
): ApprovalDismissRecord => ({ sessionId, toolName, ...(callId === undefined ? {} : { callId }) })

describe('approval-panel dismissal matching', () => {
  it('matches the same session and tool name', () => {
    const records = [record('s1', 'bash')]
    expect(matchApprovalDismissRecord(records, {
      kind: 'approval', sessionId: 's1', toolName: 'bash',
    })).toBe(0)
  })

  it('refuses a different session or tool', () => {
    const records = [record('s1', 'bash')]
    expect(matchApprovalDismissRecord(records, {
      kind: 'approval', sessionId: 's2', toolName: 'bash',
    })).toBe(-1)
    expect(matchApprovalDismissRecord(records, {
      kind: 'approval', sessionId: 's1', toolName: 'write',
    })).toBe(-1)
  })

  it('uses the call id when the record carries one', () => {
    const records = [record('s1', 'bash', 'c1')]
    expect(matchApprovalDismissRecord(records, {
      kind: 'approval', sessionId: 's1', toolName: 'bash', callId: 'c1',
    })).toBe(0)
    // A different call, or none at all, is a different approval.
    expect(matchApprovalDismissRecord(records, {
      kind: 'approval', sessionId: 's1', toolName: 'bash', callId: 'c2',
    })).toBe(-1)
    expect(matchApprovalDismissRecord(records, {
      kind: 'approval', sessionId: 's1', toolName: 'bash',
    })).toBe(-1)
  })

  it('ignores the pending call id when the record has none', () => {
    // A hook-gated ask can carry no call id at all; session + tool is then the
    // whole identity, which the one-visible-interaction-per-session registry
    // makes unambiguous.
    const records = [record('s1', 'bash')]
    expect(matchApprovalDismissRecord(records, {
      kind: 'approval', sessionId: 's1', toolName: 'bash', callId: 'c1',
    })).toBe(0)
  })

  it('ignores non-approval pending interactions', () => {
    const records = [record('s1', 'bash')]
    // Questions share the pending-interaction registry; aborting one would
    // settle an unrelated wait.
    expect(matchApprovalDismissRecord(records, {
      kind: 'question', sessionId: 's1', toolName: 'bash',
    })).toBe(-1)
  })

  it('refuses a pending approval with no readable tool name', () => {
    const records = [record('s1', 'bash')]
    expect(matchApprovalDismissRecord(records, {
      kind: 'approval', sessionId: 's1', toolName: 7,
    })).toBe(-1)
  })

  it('finds a match past the first record', () => {
    const records = [record('s1', 'bash'), record('s2', 'write'), record('s2', 'bash')]
    expect(matchApprovalDismissRecord(records, {
      kind: 'approval', sessionId: 's2', toolName: 'bash',
    })).toBe(2)
  })
})
