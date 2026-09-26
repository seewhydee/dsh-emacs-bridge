// dsh-emacs-bridge — integration-testing mock LLM: StreamChunk helpers.
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
// Plain data helpers that emit the harness's StreamChunk vocabulary (the shape
// is in-repo harness knowledge: packages/llm/llm/src/types.ts).  These are
// written against the contract, not copied, so the harness license is
// irrelevant — the emit shape is stable queue and the chunk fields are plain
// objects.  `CallId` is a runtime no-op branded string in the harness, so a
// plain string id is accepted by the assembler.

/**
 * Next mock call id. A block index alone cannot be the id: two queued script
 * entries place their call at the same block index, and the host pairs tool
 * results with calls by id, so a collision would mis-name the first result.
 * A module counter keeps every emitted call id distinct.
 */
let mockCallCounter = 0
function mockCallId() {
  mockCallCounter += 1
  return `mock-call-${mockCallCounter}`
}

/** Chunks that stream one plain text reply and finish with `stop`. */
export function textChunks(text) {
  const deltas = Array.from(text, (char) => ({ type: 'text-delta', index: 0, text: char }))
  return [
    { type: 'block-start', index: 0, blockType: 'text' },
    ...deltas,
    { type: 'block-end', index: 0, block: { type: 'text', text } },
    { type: 'usage', usage: { inputTokens: 10, outputTokens: text.length } },
    { type: 'finish', reason: { kind: 'stop' } },
  ]
}

/**
 * Chunks that emit one tool-call block and finish with `tool-calls`. An
 * optional lead-in text block is emitted first (mirrors the harness
 * `toolCallResponse` helper). `arguments` is the JSON string the tool receives.
 * With `fragmentArgs` the arguments stream across several `tool-call-delta`
 * chunks (the name rides the first one only), the way real providers fragment
 * arguments; the harness assembler must concatenate them back to the same JSON.
 */
export function toolCallChunks(name, argumentsJson, text, { fragmentArgs = false } = {}) {
  const chunks = []
  let index = 0
  if (text) {
    chunks.push(
      { type: 'block-start', index, blockType: 'text' },
      { type: 'text-delta', index, text },
      { type: 'block-end', index, block: { type: 'text', text } },
    )
    index += 1
  }
  chunks.push({ type: 'block-start', index, blockType: 'tool-call' })
  const callId = mockCallId()
  if (fragmentArgs && argumentsJson.length > 1) {
    // Three pieces: the middle boundary is deliberately off the half so a
    // boundary-aligned assembler bug cannot hide behind equal splits.
    const first = Math.max(1, Math.floor(argumentsJson.length / 3))
    const second = Math.max(first + 1, Math.floor(argumentsJson.length / 2))
    const pieces = [
      argumentsJson.slice(0, first),
      argumentsJson.slice(first, second),
      argumentsJson.slice(second),
    ].filter((piece) => piece.length > 0)
    pieces.forEach((piece, position) => {
      chunks.push({
        type: 'tool-call-delta',
        index,
        id: callId,
        ...(position === 0 ? { name } : {}),
        argumentsDelta: piece,
      })
    })
  } else {
    chunks.push(
      { type: 'tool-call-delta', index, id: callId, name, argumentsDelta: argumentsJson },
    )
  }
  chunks.push(
    {
      type: 'block-end',
      index,
      block: { type: 'tool-call', id: callId, name, arguments: argumentsJson },
    },
    { type: 'usage', usage: { inputTokens: 10, outputTokens: 5 } },
    { type: 'finish', reason: { kind: 'tool-calls' } },
  )
  return chunks
}

/**
 * Chunks that emit one reasoning block, optionally followed by one tool-call
 * block, and finish with `tool-calls` (or `stop` without a call).  The
 * reasoning text is what the bridge folds into a one-line thinking summary;
 * its full text must never reach Emacs.
 */
export function reasoningChunks(text, { toolCall } = {}) {
  const chunks = [
    { type: 'block-start', index: 0, blockType: 'reasoning' },
    ...Array.from(text, (char) => ({ type: 'reasoning-delta', index: 0, text: char })),
    { type: 'block-end', index: 0, block: { type: 'reasoning', text } },
  ]
  let outputTokens = text.length
  if (toolCall !== undefined) {
    const argumentsJson = JSON.stringify(toolCall.arguments ?? {})
    const callId = mockCallId()
    chunks.push(
      { type: 'block-start', index: 1, blockType: 'tool-call' },
      { type: 'tool-call-delta', index: 1, id: callId, name: toolCall.name, argumentsDelta: argumentsJson },
      {
        type: 'block-end',
        index: 1,
        block: { type: 'tool-call', id: callId, name: toolCall.name, arguments: argumentsJson },
      },
    )
    outputTokens += 5
  }
  chunks.push(
    { type: 'usage', usage: { inputTokens: 10, outputTokens } },
    { type: 'finish', reason: { kind: toolCall === undefined ? 'stop' : 'tool-calls' } },
  )
  return chunks
}

/**
 * A short, plausible canned reply for an auxiliary model call (a session title,
 * a compaction) that must never consume the script queue.
 */
export function auxChunks(purpose) {
  const text = purpose === 'session-title'
    ? 'Mock session title'
    : 'Mock auxiliary reply'
  return textChunks(text)
}
