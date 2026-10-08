// dsh-emacs-bridge — the bridge row's own configuration (plugins.row.config):
// the Emacs command the install routes run, and the install timeout. Values
// bind to the host-owned ConfigPageForm the Plugins page hands the row's page;
// a staged edit writes only on save (one revision-fenced mutate).
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

import { useState } from 'react'
import { Button, Input } from '@deepseek-ai/dsh-client-ui-primitives'
import type { PropsLocale, PropsRuntime } from '@deepseek-ai/dsh-client-ui-slots'
// Type-only: pulls the ui-plugin-manager SlotMap merge (the row.config seat).
import type {} from '@deepseek-ai/dsh-client-ui-plugin-manager/client'
// Type-only: pulls this package's LocaleNamespaceMap merge (the namespace seat).
import type {} from './locales.ts'

/** Full props of the bridge row's configuration entry. */
export type EmacsCommandFieldProps =
  PropsRuntime<'plugins.row.config'>
  & PropsLocale<'dsh-emacs-bridge'>

/** The row's config section, as the schema resolves it. */
interface BridgeRowConfig {
  /** Shell-style string or verbatim argv; the field edits the string form. */
  emacsCommand?: string | string[]
  emacsInstallTimeoutMs?: number
}

/** One argv word as shell-style text the host's splitter reads back verbatim.
 *  Whitespace, quotes, and backslashes force double quotes, whose only
 *  escapes are `\\` and `\"` — so an argv value survives a round trip through
 *  this field instead of being re-split into the wrong words on save. */
function quoteCommandWord(word: string): string {
  if (word !== '' && !/[\s'"\\]/.test(word)) return word
  return `"${word.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

/** Render an emacsCommand value (string or argv list) as editable text. */
function commandText(value: string | string[] | undefined): string {
  if (typeof value === 'string') return value
  if (Array.isArray(value)) return value.map(quoteCommandWord).join(' ')
  return ''
}

const fieldStyle = { display: 'flex', flexDirection: 'column', gap: 4, maxWidth: 560 } as const
const labelStyle = { fontSize: 13, fontWeight: 500 } as const
const hintStyle = { margin: 0, fontSize: 12, opacity: 0.65 } as const

/**
 * The bridge row's configuration fields. Edits are staged locally and written
 * by one save (clearing the command field restores the schema default through
 * an unset op). Without a form prop — the summary view, or a page that did not
 * build one — the entry is a one-liner or nothing.
 */
export function EmacsCommandField({ view, form, t }: EmacsCommandFieldProps) {
  // null = no staged edit; the input then shows the form's accepted value.
  const [draftCommand, setDraftCommand] = useState<string | null>(null)
  const [draftTimeout, setDraftTimeout] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [failed, setFailed] = useState(false)
  const [seedRevision, setSeedRevision] = useState(form?.state.revision)

  if (view === 'summary') return t('configSummary')
  if (form === undefined) return null
  if (form.state.status === 'unavailable') {
    return <p role="status" style={hintStyle}>{t('configUnavailable')}</p>
  }
  if (form.state.status === 'loading') return null

  // A newly accepted section reseeds the drafts (render-time adjustment), so a
  // save's folded response — or a refusal's recovery read — replaces staged text.
  const revision = form.state.revision
  if (revision !== seedRevision) {
    setSeedRevision(revision)
    setDraftCommand(null)
    setDraftTimeout(null)
    setFailed(false)
  }

  const value = (form.state.value ?? {}) as BridgeRowConfig
  const command = draftCommand ?? commandText(value.emacsCommand)
  const timeout = draftTimeout ?? (typeof value.emacsInstallTimeoutMs === 'number' ? String(value.emacsInstallTimeoutMs) : '')
  const timeoutInvalid = draftTimeout !== null && draftTimeout.trim() !== ''
    && !/^[1-9]\d*$/.test(draftTimeout.trim())
  const dirty = draftCommand !== null || draftTimeout !== null
  const writable = form.state.writable

  const save = () => {
    if (!dirty || timeoutInvalid || saving) return
    const ops: ({ op: 'set'; path: string[]; value: unknown } | { op: 'unset'; path: string[] })[] = []
    if (draftCommand !== null) {
      ops.push(draftCommand.trim() === ''
        ? { op: 'unset', path: ['emacsCommand'] }
        : { op: 'set', path: ['emacsCommand'], value: draftCommand })
    }
    if (draftTimeout !== null) {
      ops.push(draftTimeout.trim() === ''
        ? { op: 'unset', path: ['emacsInstallTimeoutMs'] }
        : { op: 'set', path: ['emacsInstallTimeoutMs'], value: Number(draftTimeout.trim()) })
    }
    setSaving(true)
    setFailed(false)
    form.mutate(ops, revision)
      .then((accepted) => {
        setSaving(false)
        if (!accepted) setFailed(true)
      })
      .catch(() => {
        setSaving(false)
        setFailed(true)
      })
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      {writable ? null : <p role="status" style={hintStyle}>{t('configReadOnly')}</p>}
      <div style={fieldStyle}>
        <label htmlFor="dsh-bridge-emacs-command" style={labelStyle}>{t('emacsCommandLabel')}</label>
        <Input
          id="dsh-bridge-emacs-command"
          value={command}
          disabled={!writable}
          placeholder="emacs"
          onChange={(event) => setDraftCommand(event.target.value)}
        />
        <p style={hintStyle}>{t('emacsCommandHint')}</p>
      </div>
      <div style={fieldStyle}>
        <label htmlFor="dsh-bridge-emacs-install-timeout" style={labelStyle}>{t('emacsInstallTimeoutLabel')}</label>
        <Input
          id="dsh-bridge-emacs-install-timeout"
          value={timeout}
          disabled={!writable}
          inputMode="numeric"
          aria-invalid={timeoutInvalid}
          placeholder="120000"
          onChange={(event) => setDraftTimeout(event.target.value)}
        />
        {timeoutInvalid
          ? <p role="status" style={hintStyle}>{t('configInvalidTimeout')}</p>
          : <p style={hintStyle}>{t('emacsInstallTimeoutHint')}</p>}
      </div>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
        <Button variant="primary" size="sm" disabled={!writable || !dirty || timeoutInvalid || saving} onClick={save}>
          {saving ? t('configSaving') : t('configSave')}
        </Button>
        {failed ? <span role="status" style={hintStyle}>{t('configSaveFailed')}</span> : null}
      </div>
    </div>
  )
}
