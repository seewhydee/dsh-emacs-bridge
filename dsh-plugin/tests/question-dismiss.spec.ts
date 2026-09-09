import { describe, expect, it } from 'vitest'
import {
  matchDismissRecord,
  questionIdsOf,
  sameQuestionIds,
} from '../src/client/question-dismiss.ts'

describe('question-panel dismissal matching', () => {
  it('questionIdsOf reads the string ids and skips malformed entries', () => {
    expect(questionIdsOf([{ id: 'q1' }, { id: 'q2' }])).toEqual(['q1', 'q2'])
    expect(questionIdsOf([{ id: 7 }, {}, { id: 'q3' }])).toEqual(['q3'])
    expect(questionIdsOf(undefined)).toEqual([])
  })

  it('sameQuestionIds compares sets, not order or duplicates', () => {
    expect(sameQuestionIds(['q1', 'q2'], ['q2', 'q1'])).toBe(true)
    expect(sameQuestionIds(['q1'], ['q1', 'q2'])).toBe(false)
    expect(sameQuestionIds(['q1', 'q1'], ['q1', 'q2'])).toBe(false)
    expect(sameQuestionIds([], [])).toBe(true)
  })

  it('matchDismissRecord matches the same session and question ids only', () => {
    const records = [{ sessionId: 's1', questionIds: ['q1'] }]
    expect(matchDismissRecord(records, {
      kind: 'question', sessionId: 's1', questions: [{ id: 'q1' }],
    })).toBe(0)
    // A different session or a different question set is not this resolution.
    expect(matchDismissRecord(records, {
      kind: 'question', sessionId: 's2', questions: [{ id: 'q1' }],
    })).toBe(-1)
    expect(matchDismissRecord(records, {
      kind: 'question', sessionId: 's1', questions: [{ id: 'q2' }],
    })).toBe(-1)
  })

  it('matchDismissRecord ignores non-question pending interactions', () => {
    const records = [{ sessionId: 's1', questionIds: ['q1'] }]
    // Approvals share the pending-interaction registry; cancelling one would
    // settle an unrelated wait.
    expect(matchDismissRecord(records, {
      kind: 'approval', sessionId: 's1', questions: [{ id: 'q1' }],
    })).toBe(-1)
  })

  it('matchDismissRecord finds a plan-review panel', () => {
    const records = [{ sessionId: 's1', questionIds: ['plan'] }]
    expect(matchDismissRecord(records, {
      kind: 'plan-review', sessionId: 's1', questions: [{ id: 'plan' }],
    })).toBe(0)
  })
})
