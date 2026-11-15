// dsh-emacs-bridge — Vitest specs for host-local attachment preparation.
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

import { mkdtempSync, mkdirSync, rmSync, truncateSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { prepareAttachments, type AttachmentStoreService } from '../src/attachments.ts'
import { MAX_ATTACHMENT_FILE_BYTES } from '../src/logic.ts'

const store = (maxImageBytes: number): AttachmentStoreService => ({
  imageLimits: {
    maxImageBytes,
    maxImagesPerMessage: 8,
    maxMessageImageBytes: maxImageBytes * 8,
    maxImagePixels: 1_000_000,
    maxImageDimension: 1_000,
  },
  saveImages: async () => [],
  saveFileStream: async () => ({ attachmentId: 'unused', name: 'unused', bytes: 0 }),
  isAttachmentError: () => false,
})

describe('prepareAttachments', () => {
  let root = ''

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'dsh-attachments-'))
  })

  afterEach(() => {
    rmSync(root, { recursive: true, force: true })
  })

  it('sniffs content rather than trusting file extensions and preserves request order', async () => {
    const image = { path: join(root, 'image.txt') }
    const file = { path: join(root, 'script.png'), name: 'script' }
    writeFileSync(image.path, new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
    writeFileSync(file.path, '#!/bin/sh\n')

    await expect(prepareAttachments([image, file], store(1024))).resolves.toEqual([
      { request: image, mediaType: 'image/png' },
      { request: file },
    ])
  })

  it('rejects an unreadable path as a caller error', async () => {
    const path = join(root, 'missing')
    await expect(prepareAttachments([{ path }], undefined)).rejects.toMatchObject({
      status: 400,
      message: `cannot read attachment: ${path}`,
    })
  })

  it('rejects a directory instead of passing it to the store', async () => {
    const path = join(root, 'directory')
    mkdirSync(path)
    await expect(prepareAttachments([{ path }], undefined)).rejects.toMatchObject({
      status: 400,
      message: `attachment is not a regular file: ${path}`,
    })
  })

  it('applies the store image byte limit after sniffing', async () => {
    const path = join(root, 'large.png')
    writeFileSync(path, new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
    await expect(prepareAttachments([{ path }], store(4))).rejects.toMatchObject({
      status: 413,
      message: `image exceeds the 4-byte limit: ${path}`,
    })
  })

  it('applies the bridge byte limit to verbatim files', async () => {
    const path = join(root, 'large.bin')
    writeFileSync(path, '')
    truncateSync(path, MAX_ATTACHMENT_FILE_BYTES + 1)
    await expect(prepareAttachments([{ path }], undefined)).rejects.toMatchObject({
      status: 413,
      message: `file exceeds the ${MAX_ATTACHMENT_FILE_BYTES}-byte limit: ${path}`,
    })
  })
})
