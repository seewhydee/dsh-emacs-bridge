// dsh-emacs-bridge — Vitest specs for the pure session-report logic.
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
import {
  catalogModelName,
  resolveReadTargetId,
  sessionReport,
  type LiveSessionLike,
  type SessionHeaderLike,
  type SessionObservationLike,
} from '../src/logic.ts'

const liveSession = (
  id: string,
  createdAt: number,
  lastEventTime?: number,
): LiveSessionLike => ({
  id,
  header: { createdAt },
  events: lastEventTime === undefined ? [] : [{ time: lastEventTime }],
  running: false,
})

const header = (id: string, createdAt: number, extra: Partial<SessionHeaderLike> = {}): SessionHeaderLike => ({
  id,
  createdAt,
  ...extra,
})

describe('resolveReadTargetId', () => {
  it('resolves an explicit live id without requiring an agent', () => {
    expect(resolveReadTargetId('live-1', [liveSession('live-1', 10)], []))
      .toEqual({ kind: 'target', id: 'live-1', live: true })
  })

  it('resolves an explicit cold id as not live', () => {
    expect(resolveReadTargetId('cold-1', [], [header('cold-1', 10)]))
      .toEqual({ kind: 'target', id: 'cold-1', live: false })
  })

  it('404s an unknown explicit id', () => {
    const result = resolveReadTargetId('nope', [liveSession('live-1', 10)], [])
    expect(result).toEqual({ kind: 'error', status: 404, message: 'session nope is not live' })
  })

  it('defaults to the newest live session by last event time', () => {
    const live = [liveSession('old', 100, 200), liveSession('new', 100, 300)]
    expect(resolveReadTargetId(undefined, live, []))
      .toEqual({ kind: 'target', id: 'new', live: true })
  })

  it('falls back to the newest cold session, skipping subagent origin', () => {
    const persisted = [
      header('subagent', 999, { origin: 'subagent' }),
      header('cold-old', 100),
      header('cold-new', 200),
    ]
    expect(resolveReadTargetId(undefined, [], persisted))
      .toEqual({ kind: 'target', id: 'cold-new', live: false })
  })

  it('409s when neither live nor persisted sessions exist', () => {
    expect(resolveReadTargetId(undefined, [], []))
      .toEqual({ kind: 'error', status: 409, message: 'no active session' })
  })
})

describe('sessionReport', () => {
  const values = {
    title: 'Fix the parser',
    agentPreset: 'default',
    modelSelection: {
      lastUsed: { provider: 'p', model: 'old' },
      next: { provider: 'p', model: 'new', reasoningEffort: 'high' },
    },
    permissions: {
      currentValue: 'custom',
      options: [
        { value: 'custom', name: 'Custom' },
        { value: 'workspace-write', name: 'Workspace write', description: 'Can edit files.' },
        { value: 7, name: 'bogus' },
      ],
    },
    sessionStats: {
      turns: 12,
      steps: 48,
      llmMs: 1000,
      toolMs: 200,
      ttftMs: 300,
      ttftSteps: 3,
      decodeMs: 400,
      decodeTokens: 1000,
    },
    tokenUsage: {
      uncachedInputTokens: 10,
      outputTokens: 20,
      cacheReadTokens: 30,
      cacheWriteTokens: 40,
    },
    contextPressure: { pressureTokens: 100, projectedTokens: 120, contextWindow: 200 },
    contextBreakdown: { systemTokens: 1, toolsTokens: 2, messageTokens: 3 },
    sessionListMetadata: { blank: false, lastPromptAt: 1234 },
  }

  const full: SessionObservationLike = {
    source: 'live',
    header: {
      id: 's1',
      createdAt: 1000,
      cwd: '/w',
      parentSession: 'parent-1',
      isSeeded: true,
      delegationDepth: 2,
      agentPreset: 'default',
    },
    events: [{ time: 2000 }, { time: 3000 }],
    projections: { values },
  }

  it('maps a full observation verbatim', () => {
    const report = sessionReport(full, {
      running: true,
      workspace: 'ws',
      workspaceId: 'ws-1',
      archived: false,
    })
    expect(report).toEqual({
      sessionId: 's1',
      live: true,
      running: true,
      basis: 'observation',
      missing: [],
      title: 'Fix the parser',
      cwd: '/w',
      workspace: 'ws',
      workspaceId: 'ws-1',
      archived: false,
      createdAt: 1000,
      lastActive: 3000,
      lastPromptAt: 1234,
      parentSession: 'parent-1',
      isSeeded: true,
      origin: null,
      delegationDepth: 2,
      agentPreset: 'default',
      model: { provider: 'p', model: 'new', reasoningEffort: 'high' },
      modelName: null,
      permissions: {
        currentValue: 'custom',
        options: [
          { value: 'custom', name: 'Custom' },
          { value: 'workspace-write', name: 'Workspace write', description: 'Can edit files.' },
        ],
      },
      stats: values.sessionStats,
      tokens: values.tokenUsage,
      context: values.contextPressure,
      breakdown: values.contextBreakdown,
    })
  })

  it('names every absent projection in missing and nulls its section', () => {
    const report = sessionReport({
      source: 'live',
      header: { id: 's2', createdAt: 5 },
      projections: { values: { title: 'Only a title' } },
    })
    expect(report.basis).toBe('observation')
    expect(report.missing).toEqual([
      'preset', 'model', 'permissions', 'stats', 'tokens', 'context', 'breakdown', 'lastPromptAt',
    ])
    expect(report.title).toBe('Only a title')
    expect(report.agentPreset).toBeNull()
    expect(report.stats).toBeNull()
    expect(report.tokens).toBeNull()
    expect(report.context).toBeNull()
    expect(report.breakdown).toBeNull()
    expect(report.permissions).toBeNull()
    expect(report.model).toBeNull()
    expect(report.lastPromptAt).toBeNull()
  })

  it('treats a present-but-null title as untitled, not as missing', () => {
    const report = sessionReport({
      source: 'live',
      header: { id: 's3', createdAt: 5 },
      events: [{ time: 9, type: 'session/title', data: { title: 'from log' } }],
      projections: { values: { title: null } },
    })
    expect(report.title).toBeNull()
    expect(report.missing).not.toContain('title')
  })

  it('folds the title and preset from the log for a header-only report', () => {
    const report = sessionReport({
      source: 'prepared',
      header: { id: 's4', createdAt: 5, agentPreset: 'from-header' },
      events: [
        { time: 9, type: 'agent-preset/selected', data: { agentPreset: 'from-log' } },
        { time: 10, type: 'session/title', data: { title: 'log title' } },
      ],
    })
    expect(report.basis).toBe('header')
    expect(report.live).toBe(false)
    expect(report.title).toBe('log title')
    expect(report.agentPreset).toBe('from-log')
    expect(report.lastActive).toBe(10)
    expect(report.missing).toEqual([
      'title', 'preset', 'model', 'permissions', 'stats', 'tokens', 'context', 'breakdown', 'lastPromptAt',
    ])
  })

  it('prefers the pending model selection and ignores malformed options', () => {
    const report = sessionReport({
      source: 'live',
      header: { id: 's5', createdAt: 1 },
      projections: {
        values: {
          modelSelection: { lastUsed: { provider: 'p', model: 'used' }, next: null },
          permissions: { currentValue: 'x', options: [{ value: 'x' }] },
        },
      },
    })
    expect(report.model).toEqual({ provider: 'p', model: 'used' })
    expect(report.permissions).toEqual({ currentValue: 'x', options: [] })
  })

  it('returns null context when every pressure field is absent', () => {
    const report = sessionReport({
      source: 'live',
      header: { id: 's6', createdAt: 1 },
      projections: { values: { contextPressure: {} } },
    })
    expect(report.context).toBeNull()
  })
})

describe('catalogModelName', () => {
  const catalog = {
    groups: [
      { id: 'p', models: [{ id: 'm', name: 'Model M' }, { id: 'n' }] },
      { id: 'q', models: [{ id: 'm', name: 'Other M' }] },
    ],
  }

  it('resolves a display name by provider and model', () => {
    expect(catalogModelName(catalog, 'p', 'm')).toBe('Model M')
  })

  it('returns null for a model with no display name', () => {
    expect(catalogModelName(catalog, 'p', 'n')).toBeNull()
  })

  it('returns null for an unknown provider, model, or catalog shape', () => {
    expect(catalogModelName(catalog, 'z', 'm')).toBeNull()
    expect(catalogModelName(catalog, 'p', 'z')).toBeNull()
    expect(catalogModelName(undefined, 'p', 'm')).toBeNull()
    expect(catalogModelName({ groups: 'nope' }, 'p', 'm')).toBeNull()
  })
})
