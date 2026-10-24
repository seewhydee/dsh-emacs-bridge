// dsh-emacs-bridge — bounded display diffing for committed per-call fragments.
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
// The durable `meta.diffs' fragments are the *applied* contextual hunks the
// producing tool recorded: oldText/newText only, with no original-file line
// positions and no final-newline marker.  This module turns them into bounded
// display text for the Emacs inspector.  It deliberately does not build an
// appliable patch: inventing absolute hunk positions would be a lie, and the
// inspector must never offer patch application or line navigation from these
// fragment-relative headers.
//
// `logic.ts` extracts the fragments (and stays dependency-free); this module
// carries the `diff' runtime dependency and the bounded `structuredPatch'
// call, the same approach the web UI's diff card uses.

import { structuredPatch } from 'diff'
import type { DetailFileChange, DetailDiffStatus } from './logic.ts'

/** Maximum UTF-8 bytes accepted from one side of a fragment before diffing. */
export const MAX_DIFF_INPUT_BYTES = 256 * 1024

/** Maximum lines accepted from one side of a fragment before diffing. */
export const MAX_DIFF_INPUT_LINES = 5000

/** Maximum UTF-8 bytes of rendered diff text for one detail response. */
export const MAX_DIFF_OUTPUT_BYTES = 128 * 1024

/** Maximum rendered lines for one detail response. */
export const MAX_DIFF_OUTPUT_LINES = 4000

/** Edit-search bound handed to `structuredPatch'; a miss degrades to `coarse'. */
export const MAX_DIFF_EDIT_LENGTH = 2000

/** How one fragment rendered. */
export type DiffRenderStatus = 'ok' | 'coarse' | 'too-large'

/** One file's rendered diff display. */
export interface RenderedFileChange {
  path: string
  absolute: string
  pathSource: 'recorded' | 'inferred'
  cwd?: string
  operation?: 'create' | 'update'
  /** The durable classification from the log. */
  status: DetailDiffStatus
  /** How the display was produced; `ok` is a bounded, exact line diff. */
  render: DiffRenderStatus
  added: number
  removed: number
  /** Total fragments in the durable record, including any not retained. */
  fragments: number
  retainedFragments: number
  droppedFragments: number
  /** Whether retention or the output bound dropped part of this file. */
  truncated: boolean
}

/** A rendered file-diff detail body. */
export interface RenderedFileChanges {
  text: string
  files: RenderedFileChange[]
  /** Whether the output bound dropped diff text. */
  truncated: boolean
}

/** Overridable bounds, for focused tests. */
export interface DiffRenderOptions {
  maxInputBytes?: number
  maxInputLines?: number
  maxOutputBytes?: number
  maxOutputLines?: number
  maxEditLength?: number
}

/** Count the lines in TEXT the way a text editor does. */
function lineCount(text: string): number {
  if (text === '') return 0
  let count = 1
  for (const ch of text) if (ch === '\n') count += 1
  return text.endsWith('\n') ? count - 1 : count
}

/** The lines of TEXT, without a trailing phantom line. */
function splitLines(text: string): string[] {
  return text === '' ? [] : text.replace(/\n$/, '').split('\n')
}

/** One appender that enforces the response's output byte/line bounds. */
class BoundedText {
  private parts: string[] = []
  private bytes = 0
  private lines = 0
  truncated = false

  constructor(private readonly maxBytes: number, private readonly maxLines: number) {}

  /** Append one line (the newline is added here). */
  line(text: string): boolean {
    if (this.truncated) return false
    const bytes = Buffer.byteLength(text, 'utf8') + 1
    if (this.lines + 1 > this.maxLines || this.bytes + bytes > this.maxBytes) {
      this.truncated = true
      return false
    }
    this.parts.push(text, '\n')
    this.bytes += bytes
    this.lines += 1
    return true
  }

  /** Append a final notice even after the bound tripped. */
  force(text: string): void {
    this.parts.push(text, '\n')
  }

  toString(): string {
    return this.parts.join('')
  }
}

/** Render one fragment's line diff, returning its display lines and counts. */
function renderFragment(
  fragment: { oldText: string | null; newText: string },
  options: Required<DiffRenderOptions>,
): { status: DiffRenderStatus; lines: string[]; added: number; removed: number } {
  const oldText = fragment.oldText ?? ''
  const newText = fragment.newText
  if (Buffer.byteLength(oldText, 'utf8') > options.maxInputBytes
    || Buffer.byteLength(newText, 'utf8') > options.maxInputBytes
    || lineCount(oldText) > options.maxInputLines
    || lineCount(newText) > options.maxInputLines) {
    return { status: 'too-large', lines: [], added: 0, removed: 0 }
  }
  const patch = structuredPatch('', '', oldText, newText, undefined, undefined, {
    context: 3,
    maxEditLength: options.maxEditLength,
  })
  let added = 0
  let removed = 0
  if (patch === undefined) {
    // The edit search hit its bound.  Degrade to a whole-fragment replacement
    // display rather than dropping the content or claiming an exact diff.
    const oldLines = splitLines(oldText)
    const newLines = splitLines(newText)
    const lines = [
      '  (edit search bound exceeded; showing whole fragments)',
      ...oldLines.map(line => `-${line}`),
      ...newLines.map(line => `+${line}`),
    ]
    return { status: 'coarse', lines, added: newLines.length, removed: oldLines.length }
  }
  const lines: string[] = []
  for (const hunk of patch.hunks) {
    for (const line of hunk.lines) {
      // The unified-diff no-newline marker annotates the patch, not content:
      // the durable fragment does not carry it, so it must not be fabricated.
      if (line.startsWith('\\')) continue
      if (line.startsWith('+')) added += 1
      else if (line.startsWith('-')) removed += 1
      lines.push(line)
    }
  }
  return { status: 'ok', lines, added, removed }
}

/** A compact human label for a durable status with no rendered fragments. */
function statusNote(status: DetailDiffStatus): string {
  switch (status) {
    case 'create': return '  (created; no recorded before-image)'
    case 'empty': return '  (no applied changes recorded)'
    case 'none': return '  (no durable applied diff available for this tool)'
    case 'unavailable': return '  (durable diff metadata is malformed or unreadable)'
    case 'applied': return ''
  }
}

/**
 * Render a result's complete file-change records into bounded, line-oriented
 * display text plus per-file metadata.  The text is a display artifact, never
 * an appliable patch.
 */
export function renderFileChanges(
  files: readonly DetailFileChange[],
  overrides: DiffRenderOptions = {},
): RenderedFileChanges {
  const options: Required<DiffRenderOptions> = {
    maxInputBytes: overrides.maxInputBytes ?? MAX_DIFF_INPUT_BYTES,
    maxInputLines: overrides.maxInputLines ?? MAX_DIFF_INPUT_LINES,
    maxOutputBytes: overrides.maxOutputBytes ?? MAX_DIFF_OUTPUT_BYTES,
    maxOutputLines: overrides.maxOutputLines ?? MAX_DIFF_OUTPUT_LINES,
    maxEditLength: overrides.maxEditLength ?? MAX_DIFF_EDIT_LENGTH,
  }
  const out = new BoundedText(options.maxOutputBytes, options.maxOutputLines)
  const rendered: RenderedFileChange[] = []
  for (const file of files) {
    let render: DiffRenderStatus = 'ok'
    let added = 0
    let removed = 0
    let truncated = file.droppedFragments > 0
    out.line(`File: ${file.path}`)
    out.line(`  status: ${file.status}${file.pathSource === 'inferred' ? ' (inferred path)' : ''}`)
    if (file.cwd !== undefined && file.cwd !== '') out.line(`  call directory: ${file.cwd}`)
    if (file.operation !== undefined) out.line(`  operation: ${file.operation}`)
    if (file.droppedFragments > 0) {
      out.line(`  (${file.droppedFragments} durable fragments omitted by the bridge)`)
    }
    if (file.status === 'applied') {
      out.line('  Applied per-call fragments (display only; not an appliable patch):')
      file.fragments.forEach((fragment, index) => {
        const result = renderFragment(fragment, options)
        if (result.status === 'too-large') {
          render = 'too-large'
          out.line(`  fragment ${index + 1}: too large to diff`)
          return
        }
        if (result.status === 'coarse' && render === 'ok') render = 'coarse'
        added += result.added
        removed += result.removed
        out.line(`  fragment ${index + 1}: +${result.added} -${result.removed}`)
        for (const line of result.lines) {
          if (!out.line(line)) {
            truncated = true
            break
          }
        }
      })
    } else {
      const note = statusNote(file.status)
      if (note !== '') out.line(note)
    }
    if (out.truncated) truncated = true
    rendered.push({
      path: file.path,
      absolute: file.absolute,
      pathSource: file.pathSource,
      ...file.cwd === undefined ? {} : { cwd: file.cwd },
      ...file.operation === undefined ? {} : { operation: file.operation },
      status: file.status,
      render,
      added,
      removed,
      fragments: file.totalFragments,
      retainedFragments: file.fragments.length,
      droppedFragments: file.droppedFragments,
      truncated,
    })
  }
  if (out.truncated) out.force('  (diff display truncated by the bridge)')
  return {
    text: out.toString(),
    files: rendered,
    truncated: out.truncated || rendered.some(file => file.droppedFragments > 0),
  }
}
