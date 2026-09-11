// dsh-emacs-bridge — integration spec: attachments in POST /dsh-bridge/send.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// Drives the path-based attachment seam against the shared live fixture and the
// real `ctx.attachments` store: an image is sniffed from its bytes and reaches
// the provider as an image block, a generic file becomes a read-only handle
// text, an attachment-only prompt is accepted, and the route's validation,
// count cap, and per-file byte cap fail with the documented statuses. Each test
// resets the mock and uses its own session so the shared fixture stays
// deterministic.

import { describe, it, expect, inject } from 'vitest'
import { mkdtempSync, rmSync, statSync, writeFileSync, openSync, ftruncateSync, closeSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { post, scriptMock, mockRequests, createSession, openSse } from './util.mjs'

/** A valid 1x1 PNG the attachment store's decoder accepts. */
const PNG_1X1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACXBIWXMAAAPoAAAD6AG1e1JrAAAADUlEQVQImWP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  'base64',
)

/** The bridge's per-file attachment cap, mirrored for the oversize test. */
const MAX_ATTACHMENT_FILE_BYTES = 200 * 1024 * 1024

/** Send a prompt and, on acceptance, wait for the scripted turn to complete. */
async function sendAndWait(fixture, body) {
  const sse = openSse(fixture, { timeoutMs: 10000 })
  try {
    const sent = await post(fixture, '/dsh-bridge/send', body)
    if (sent.status === 200) await sse.waitFor('turn-complete')
    return sent
  } finally {
    sse.close()
  }
}

/**
 * Every content block of the *prompt's own* user messages in the mock's main
 * requests. Filters on `source.kind === 'user'` so plugin-injected context
 * messages (also user role) are not mistaken for the prompt.
 */
function userBlocks(requests) {
  return requests
    .filter((request) => request.purpose === undefined)
    .flatMap((request) => (request.messages ?? [])
      .filter((message) => message.role === 'user' && message.source?.kind === 'user')
      .flatMap((message) => message.content ?? []))
}

describe('attachments in POST /dsh-bridge/send', () => {
  it('stages an image and reaches the provider as an image block', async () => {
    const fixture = inject('fixture')
    const scratch = mkdtempSync(join(tmpdir(), 'dsh-bridge-image-'))
    try {
      await post(fixture, '/mock-llm/reset', {})
      const sessionId = await createSession(fixture)
      const png = join(scratch, 'shot.png')
      writeFileSync(png, PNG_1X1)
      const size = statSync(png).size

      await scriptMock(fixture, [{ kind: 'text', text: 'I see it.' }])
      const sent = await sendAndWait(fixture, {
        text: 'Look at this.', sessionId, attachments: [{ path: png }],
      })
      expect(sent.status, JSON.stringify(sent.body)).toBe(200)
      expect(sent.body.attachments).toHaveLength(1)
      const echo = sent.body.attachments[0]
      expect(echo.kind).toBe('image')
      expect(echo.mediaType).toBe('image/png')
      expect(echo.name).toBe('shot.png')
      expect(echo.bytes).toBe(size)
      expect(typeof echo.attachmentId).toBe('string')

      const blocks = userBlocks(await mockRequests(fixture))
      // The user message carries the attachment first, text last.
      const image = blocks.find((block) => block.type === 'image')
      expect(image).toBeDefined()
      expect(image.attachment.mediaType).toBe('image/png')
      expect(image.attachment.attachmentId).toBe(echo.attachmentId)
      expect(blocks.at(-1).type).toBe('text')
      expect(blocks.at(-1).text).toBe('Look at this.')
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  }, 90000)

  it('stages a generic file as a read-only handle text', async () => {
    const fixture = inject('fixture')
    const scratch = mkdtempSync(join(tmpdir(), 'dsh-bridge-file-'))
    try {
      await post(fixture, '/mock-llm/reset', {})
      const sessionId = await createSession(fixture)
      const file = join(scratch, 'notes.txt')
      writeFileSync(file, 'file contents\n')
      const size = statSync(file).size

      await scriptMock(fixture, [{ kind: 'text', text: 'Got it.' }])
      const sent = await sendAndWait(fixture, {
        text: 'Read this.', sessionId, attachments: [{ path: file }],
      })
      expect(sent.status, JSON.stringify(sent.body)).toBe(200)
      expect(sent.body.attachments).toHaveLength(1)
      const echo = sent.body.attachments[0]
      expect(echo.kind).toBe('file')
      expect(echo.name).toBe('notes.txt')
      expect(echo.bytes).toBe(size)

      // Files never reach a provider natively: the block is projected to text
      // naming the file, its byte count, and the saved read-only copy.
      const blocks = userBlocks(await mockRequests(fixture))
      const handle = blocks.find((block) => block.type === 'text'
        && typeof block.text === 'string' && block.text.includes('notes.txt'))
      expect(handle).toBeDefined()
      expect(handle.text).toContain(`${size} bytes`)
      expect(handle.text).toContain('read-only copy saved at')
      expect(handle.text).toContain('notes.txt')
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  }, 90000)

  it('accepts an attachment-only prompt', async () => {
    const fixture = inject('fixture')
    const scratch = mkdtempSync(join(tmpdir(), 'dsh-bridge-only-'))
    try {
      await post(fixture, '/mock-llm/reset', {})
      const sessionId = await createSession(fixture)
      const png = join(scratch, 'only.png')
      writeFileSync(png, PNG_1X1)

      await scriptMock(fixture, [{ kind: 'text', text: 'Alright.' }])
      const sent = await sendAndWait(fixture, { sessionId, attachments: [{ path: png }] })
      expect(sent.status, JSON.stringify(sent.body)).toBe(200)
      const blocks = userBlocks(await mockRequests(fixture))
      expect(blocks.some((block) => block.type === 'image')).toBe(true)
      // No text block: the prompt carried only the attachment.
      expect(blocks.some((block) => block.type === 'text')).toBe(false)
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  }, 90000)

  it('rejects a missing, relative, or directory path (400)', async () => {
    const fixture = inject('fixture')
    const scratch = mkdtempSync(join(tmpdir(), 'dsh-bridge-bad-'))
    try {
      const sessionId = await createSession(fixture)
      const missing = await post(fixture, '/dsh-bridge/send', {
        text: 'x', sessionId, attachments: [{ path: join(scratch, 'nope.txt') }],
      })
      expect(missing.status).toBe(400)

      const relative = await post(fixture, '/dsh-bridge/send', {
        text: 'x', sessionId, attachments: [{ path: 'relative.txt' }],
      })
      expect(relative.status).toBe(400)

      const directory = await post(fixture, '/dsh-bridge/send', {
        text: 'x', sessionId, attachments: [{ path: scratch }],
      })
      expect(directory.status).toBe(400)
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  }, 30000)

  it('rejects a prompt with neither text nor attachments (400)', async () => {
    const fixture = inject('fixture')
    const sessionId = await createSession(fixture)
    const empty = await post(fixture, '/dsh-bridge/send', { sessionId, text: '   ' })
    expect(empty.status).toBe(400)
    const malformed = await post(fixture, '/dsh-bridge/send', {
      sessionId, text: 'x', attachments: 'not-an-array',
    })
    expect(malformed.status).toBe(400)
  }, 30000)

  it('enforces the attachment count and per-file byte caps (400 / 413)', async () => {
    const fixture = inject('fixture')
    const scratch = mkdtempSync(join(tmpdir(), 'dsh-bridge-cap-'))
    try {
      const sessionId = await createSession(fixture)
      const png = join(scratch, 'cap.png')
      writeFileSync(png, PNG_1X1)

      const many = await post(fixture, '/dsh-bridge/send', {
        text: 'x',
        sessionId,
        attachments: Array.from({ length: 21 }, () => ({ path: png })),
      })
      expect(many.status).toBe(400)

      // A sparse file just over the cap: the size gate rejects it without
      // reading it whole.
      const huge = join(scratch, 'huge.bin')
      const fd = openSync(huge, 'w')
      try {
        ftruncateSync(fd, MAX_ATTACHMENT_FILE_BYTES + 1)
      } finally {
        closeSync(fd)
      }
      const oversize = await post(fixture, '/dsh-bridge/send', {
        text: 'x', sessionId, attachments: [{ path: huge }],
      })
      expect(oversize.status).toBe(413)
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  }, 30000)
})
