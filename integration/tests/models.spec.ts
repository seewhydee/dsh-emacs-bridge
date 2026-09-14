// dsh-emacs-bridge — integration spec: mock-LLM fidelity (model modalities,
// fragmented tool-call arguments, model errors).
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
//
// Pins the mock's advertised metadata against the bridge paths that read it:
//   - the image-support precheck: a session on the text-only mock model gets
//     400 MODEL_DOES_NOT_SUPPORT_IMAGES for an image-bearing /send, while the
//     default mock model stays image-capable;
//   - fragmented tool-call arguments: real providers split arguments across
//     tool-call-delta chunks, and the harness assembler must rebuild the same
//     JSON (proved by the ask surfacing with its question intact);
//   - {kind:'error'}: an adapter failure ends the turn with reason 'error'.

import { describe, it, expect, inject } from 'vitest'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { post, get, scriptMock, createSession, openSse } from './util.mjs'

/** A valid 1x1 PNG the attachment store's decoder accepts. */
const PNG_1X1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACXBIWXMAAAPoAAAD6AG1e1JrAAAADUlEQVQImWP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  'base64',
)

describe('the image-support precheck against advertised modalities', () => {
  it('rejects an image for a text-only model with 400 MODEL_DOES_NOT_SUPPORT_IMAGES', async () => {
    const fixture = inject('fixture')
    const scratch = mkdtempSync(join(tmpdir(), 'dsh-bridge-textonly-'))
    try {
      await post(fixture, '/mock-llm/reset', {})
      const sessionId = await createSession(fixture)

      // Select the explicitly text-only mock model for this session.
      const sel = await post(fixture, '/dsh-bridge/model', {
        sessionId, provider: 'mock', model: 'mock-model-text',
      })
      expect(sel.status, JSON.stringify(sel.body)).toBe(200)
      expect(sel.body.selected.model).toBe('mock-model-text')

      const png = join(scratch, 'shot.png')
      writeFileSync(png, PNG_1X1)
      const sent = await post(fixture, '/dsh-bridge/send', {
        text: 'Look at this.', sessionId, attachments: [{ path: png }],
      })
      expect(sent.status, JSON.stringify(sent.body)).toBe(400)
      expect(sent.body.reason).toBe('MODEL_DOES_NOT_SUPPORT_IMAGES')
    } finally {
      // session/selectModel persists the deployment default; restore the
      // image-capable default so later specs' sessions are unaffected.
      await post(fixture, '/dsh-bridge/model', { provider: 'mock', model: 'mock-model' })
      rmSync(scratch, { recursive: true, force: true })
    }
  }, 90000)

  it('still accepts an image on the default (image-capable) mock model', async () => {
    const fixture = inject('fixture')
    const scratch = mkdtempSync(join(tmpdir(), 'dsh-bridge-imageok-'))
    try {
      await post(fixture, '/mock-llm/reset', {})
      const sessionId = await createSession(fixture)
      const png = join(scratch, 'shot.png')
      writeFileSync(png, PNG_1X1)

      await scriptMock(fixture, [{ kind: 'text', text: 'I see it.' }])
      const sse = openSse(fixture, { timeoutMs: 10000 })
      try {
        const sent = await post(fixture, '/dsh-bridge/send', {
          text: 'Look at this.', sessionId, attachments: [{ path: png }],
        })
        expect(sent.status, JSON.stringify(sent.body)).toBe(200)
        await sse.waitFor('turn-complete')
      } finally {
        sse.close()
      }
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  }, 90000)
})

describe('fragmented tool-call arguments', () => {
  it('assembles an ask-user call whose arguments streamed across deltas', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    // fragmentArgs splits the arguments JSON across three tool-call-delta
    // chunks; the question only surfaces if the harness reassembles it.
    await scriptMock(fixture, [
      {
        kind: 'tool-call',
        name: 'ask_user_question',
        fragmentArgs: true,
        arguments: {
          questions: [{ id: 'q1', question: 'Fragmented or whole?', options: [{ label: 'Whole' }] }],
        },
      },
      { kind: 'text', text: 'Reassembled.' },
    ])

    const sse = openSse(fixture, { timeoutMs: 10000 })
    const sessionId = await createSession(fixture)
    try {
      const sent = await post(fixture, '/dsh-bridge/send', { text: 'Ask me.', sessionId })
      expect(sent.status).toBe(200)

      const askFrame = await sse.waitFor('ask-user')
      expect(askFrame.sessionId).toBe(sessionId)
      expect(askFrame.questions[0].id).toBe('q1')
      expect(askFrame.questions[0].question).toBe('Fragmented or whole?')

      const answer = await post(fixture, '/dsh-bridge/answer', {
        questionId: askFrame.questionId,
        sessionId,
        answers: [{ id: 'q1', selected: ['Whole'] }],
      })
      expect(answer.status).toBe(200)
      await sse.waitFor('turn-complete')

      const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      const texts = turns.body.turns.flatMap((t) => t.segments.map((s) => s.text))
      expect(texts).toContain('Reassembled.')
    } finally {
      sse.close()
    }
  }, 90000)
})

describe('a failing model call', () => {
  it('ends the turn with reason error', async () => {
    const fixture = inject('fixture')
    await post(fixture, '/mock-llm/reset', {})
    await scriptMock(fixture, [{ kind: 'error', message: 'mock provider exploded' }])
    const sessionId = await createSession(fixture)

    const sse = openSse(fixture, { timeoutMs: 10000 })
    try {
      const sent = await post(fixture, '/dsh-bridge/send', { text: 'boom', sessionId })
      expect(sent.status).toBe(200)
      const complete = await sse.waitFor('turn-complete')
      expect(complete.sessionId).toBe(sessionId)
      expect(complete.reason).toBe('error')

      const turns = await get(fixture, `/dsh-bridge/turns?sessionId=${sessionId}`)
      expect(turns.body.running).toBe(false)
    } finally {
      sse.close()
    }
  }, 90000)
})
