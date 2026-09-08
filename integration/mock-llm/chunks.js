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
 */
export function toolCallChunks(name, argumentsJson, text) {
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
  chunks.push(
    { type: 'block-start', index, blockType: 'tool-call' },
    { type: 'tool-call-delta', index, id: `mock-call-${index}`, name, argumentsDelta: argumentsJson },
    {
      type: 'block-end',
      index,
      block: { type: 'tool-call', id: `mock-call-${index}`, name, arguments: argumentsJson },
    },
    { type: 'usage', usage: { inputTokens: 10, outputTokens: 5 } },
    { type: 'finish', reason: { kind: 'tool-calls' } },
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
