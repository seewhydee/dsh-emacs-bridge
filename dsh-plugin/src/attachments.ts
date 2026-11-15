// dsh-emacs-bridge — host-local attachment preparation and staging.
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

import { createReadStream } from 'node:fs'
import { open, readFile, stat } from 'node:fs/promises'
import { basename } from 'node:path'
import {
  attachmentErrorHttpStatus,
  MAX_ATTACHMENT_FILE_BYTES,
  sniffImageMediaType,
  type AttachmentRequest,
  type BridgeImageMediaType,
} from './logic.ts'
import { BridgeError } from './errors.ts'

/**
 * Minimal face of the optional `attachments` service (`AttachmentStore`).
 * Read via `ctx.get`; a profile without it answers an attachment-bearing
 * `/send` with 501 while plain text sends are unaffected. The store is part
 * of the harness base bundle, so the `web` profile carries it.
 */
export interface AttachmentStoreService {
  /** Deployment-resolved image admission limits (source bytes and pixels). */
  readonly imageLimits: {
    maxImageBytes: number
    maxImagesPerMessage: number
    maxMessageImageBytes: number
    maxImagePixels: number
    maxImageDimension: number
  }
  /** Validate every member before committing any; reject with an AttachmentError. */
  saveImages(inputs: readonly {
    data: Uint8Array
    mediaType: BridgeImageMediaType
    name?: string
  }[]): Promise<readonly {
    attachmentId: string
    mediaType: BridgeImageMediaType
    bytes: number
    width: number
    height: number
    name?: string
  }[]>
  /** Streaming verbatim commit; `data` is consumed once, in bounded chunks. */
  saveFileStream(input: { data: AsyncIterable<Uint8Array>; signal?: AbortSignal; name?: string }): Promise<{
    attachmentId: string
    name: string
    bytes: number
  }>
  /** Stable-code membership test over the store's own failure taxonomy. */
  isAttachmentError(error: unknown): boolean
}

/**
 * The HTTP status and reason for an attachment-store failure. The store's
 * stable code decides (pure `attachmentErrorHttpStatus`: caller-correctable
 * limits 400/413, a file-incapable backend 501, storage faults 500); a value
 * the store does not recognize falls through to the caller's 500.
 */
export function attachmentFailure(
  error: unknown,
  store: AttachmentStoreService,
): { status: number; reason: string } | undefined {
  if (!store.isAttachmentError(error)) return undefined
  const code = (error as { code?: unknown }).code
  if (typeof code !== 'string') return undefined
  return { status: attachmentErrorHttpStatus(code), reason: code }
}

/** One attachment request after `stat` and content sniffing. */
export interface PreparedAttachment {
  request: AttachmentRequest
  /** Sniffed image type, or undefined for the verbatim file arm. */
  mediaType?: BridgeImageMediaType
}

/** One staged attachment, echoed back to the client. */
export interface StagedAttachment {
  name: string
  kind: 'image' | 'file'
  bytes: number
  mediaType?: BridgeImageMediaType
  attachmentId: string
}

/** The leading bytes read for content sniffing; any accepted signature fits. */
const SNIFF_BYTES = 32

/**
 * Sniff PATH's image type from its leading bytes. The caller has already
 * `stat`ed the path; a race that empties or removes it surfaces as a read or
 * store failure, never as a misdeclared image.
 */
async function sniffPathImageType(path: string, size: number): Promise<BridgeImageMediaType | undefined> {
  const handle = await open(path, 'r')
  try {
    const length = Math.min(size, SNIFF_BYTES)
    if (length === 0) return undefined
    const buffer = Buffer.alloc(length)
    const { bytesRead } = await handle.read(buffer, 0, length, 0)
    return sniffImageMediaType(buffer.subarray(0, bytesRead))
  } finally {
    await handle.close()
  }
}

/**
 * Stage every prepared attachment into the durable store and return the
 * ordered content blocks plus the client echo. Images are one `saveImages`
 * batch (all-or-nothing validation); files stream from disk one at a time.
 * Both arms keep the exact ref objects the store returned.
 */
export async function stageAttachments(
  store: AttachmentStoreService,
  prepared: readonly PreparedAttachment[],
): Promise<{ blocks: unknown[]; echo: StagedAttachment[] }> {
  const refByIndex = new Map<number, unknown>()
  const imageIndexes = prepared
    .map((item, index) => (item.mediaType === undefined ? -1 : index))
    .filter(index => index >= 0)
  if (imageIndexes.length > 0) {
    const inputs = await Promise.all(imageIndexes.map(async (index) => {
      const item = prepared[index] as PreparedAttachment
      return {
        data: await readFile(item.request.path),
        mediaType: item.mediaType as BridgeImageMediaType,
        name: item.request.name ?? basename(item.request.path),
      }
    }))
    const refs = await store.saveImages(inputs)
    imageIndexes.forEach((index, position) => { refByIndex.set(index, refs[position]) })
  }
  for (let index = 0; index < prepared.length; index += 1) {
    const item = prepared[index] as PreparedAttachment
    if (item.mediaType !== undefined) continue
    const stream = createReadStream(item.request.path)
    try {
      const ref = await store.saveFileStream({
        data: stream,
        name: item.request.name ?? basename(item.request.path),
      })
      refByIndex.set(index, ref)
    } finally {
      // A store that rejects before consuming the iterable never closes the
      // eagerly-opened fd; a consumed stream is already destroyed.
      stream.destroy()
    }
  }
  const blocks: unknown[] = []
  const echo: StagedAttachment[] = []
  for (let index = 0; index < prepared.length; index += 1) {
    const item = prepared[index] as PreparedAttachment
    const ref = refByIndex.get(index) as {
      attachmentId: string
      name?: string
      bytes: number
      mediaType?: BridgeImageMediaType
    }
    if (item.mediaType !== undefined) {
      blocks.push({ type: 'image', attachment: ref })
      echo.push({
        name: ref.name ?? basename(item.request.path),
        kind: 'image',
        bytes: ref.bytes,
        mediaType: ref.mediaType ?? item.mediaType,
        attachmentId: ref.attachmentId,
      })
    } else {
      blocks.push({ type: 'file', attachment: ref })
      echo.push({
        name: ref.name ?? basename(item.request.path),
        kind: 'file',
        bytes: ref.bytes,
        attachmentId: ref.attachmentId,
      })
    }
  }
  return { blocks, echo }
}

/** Validate and sniff every attachment before target resolution can resume a session. */
export async function prepareAttachments(
  requests: readonly AttachmentRequest[],
  store: AttachmentStoreService | undefined,
): Promise<PreparedAttachment[]> {
  const prepared: PreparedAttachment[] = []
  for (const request of requests) {
    let info
    try {
      info = await stat(request.path)
    } catch {
      throw new BridgeError(400, `cannot read attachment: ${request.path}`)
    }
    if (!info.isFile()) {
      throw new BridgeError(400, `attachment is not a regular file: ${request.path}`)
    }
    const mediaType = await sniffPathImageType(request.path, info.size)
    if (mediaType !== undefined && store !== undefined
      && info.size > store.imageLimits.maxImageBytes) {
      throw new BridgeError(413, `image exceeds the ${store.imageLimits.maxImageBytes}-byte limit: ${request.path}`)
    }
    if (mediaType === undefined && info.size > MAX_ATTACHMENT_FILE_BYTES) {
      throw new BridgeError(413, `file exceeds the ${MAX_ATTACHMENT_FILE_BYTES}-byte limit: ${request.path}`)
    }
    prepared.push({
      request,
      ...(mediaType === undefined ? {} : { mediaType }),
    })
  }
  return prepared
}
