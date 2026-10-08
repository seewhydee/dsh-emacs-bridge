// dsh-emacs-bridge — the "Emacs install" card on this bundle's Plugins page
// (plugins.bundle.config). All state comes from the host routes
// GET /dsh-bridge/emacs (a batch status probe) and
// POST /dsh-bridge/emacs/install (a batch package-install-file run); the slot
// renders with no config form, so nothing here rides the settings pipeline.
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

import { useCallback, useEffect, useRef, useState } from 'react'
import { Button } from '@deepseek-ai/dsh-client-ui-primitives'
import type { PropsLocale, PropsRuntime } from '@deepseek-ai/dsh-client-ui-slots'
// Type-only: pulls the ui-plugin-manager SlotMap merge (the bundle.config seat).
import type {} from '@deepseek-ai/dsh-client-ui-plugin-manager/client'
// Type-only: pulls this package's LocaleNamespaceMap merge (the namespace seat).
import type {} from './locales.ts'
import { callBridge } from './bridge.ts'
import type { DshBridgeKey } from './locales.ts'

/** The failure tags GET /dsh-bridge/emacs can answer, all as 200s. */
type EmacsProblem = 'emacs-not-found' | 'emacs-version-unknown' | 'emacs-too-old' | 'probe-failed'

/** Body of GET /dsh-bridge/emacs (200): the status probe's report. */
interface EmacsStatusReport {
  bundledVersion: string | null
  /** The resolved configured Emacs command, as an argv array. */
  emacs: string[]
  emacsVersion?: string
  state?: 'installed' | 'outdated' | 'absent'
  packageUserDir?: string
  problem?: EmacsProblem
  output?: string
}

/** Body of POST /dsh-bridge/emacs/install (200): the batch run's outcome. */
interface EmacsInstallReport {
  ok?: boolean
  emacs?: string[]
  exitStatus?: number | null
  output?: string
  restartRequired?: boolean
  problem?: string
  /** The bundled elisp the run would install, for the manual fallback. */
  bundledPath?: string
}

/** Full props of the bundle-page Emacs install card. */
export type EmacsInstallProps =
  PropsRuntime<'plugins.bundle.config'>
  & PropsLocale<'dsh-emacs-bridge'>

type StatusState =
  | { readonly kind: 'loading' }
  | { readonly kind: 'error'; readonly message: string }
  | { readonly kind: 'ready'; readonly report: EmacsStatusReport }

type InstallPhase =
  | { readonly kind: 'idle' }
  | { readonly kind: 'confirm' }
  | { readonly kind: 'running' }
  | { readonly kind: 'done'; readonly report: EmacsInstallReport }

const sectionStyle = { display: 'flex', flexDirection: 'column', gap: 8, maxWidth: 560 } as const
const rowStyle = { display: 'flex', gap: 8, alignItems: 'baseline', fontSize: 13 } as const
const labelStyle = { flexShrink: 0, minWidth: 150, opacity: 0.65 } as const
const outputStyle = {
  margin: 0, padding: 8, fontSize: 12, whiteSpace: 'pre-wrap', wordBreak: 'break-all',
  maxHeight: 160, overflow: 'auto', borderRadius: 6, background: 'rgba(127, 127, 127, 0.12)',
} as const

/** The locale key wording one status-probe or install problem tag. */
function problemKey(problem: string): DshBridgeKey {
  switch (problem) {
    case 'emacs-not-found': return 'emacsProblemNotFound'
    case 'emacs-version-unknown': return 'emacsProblemVersionUnknown'
    case 'emacs-too-old': return 'emacsProblemTooOld'
    case 'spawn-failed': return 'emacsInstallProblemSpawnFailed'
    case 'timed-out': return 'emacsInstallProblemTimedOut'
    case 'nonzero-exit': return 'emacsInstallProblemNonzeroExit'
    default: return 'emacsProblemProbeFailed'
  }
}

/**
 * The Emacs install card: the bundled version, the configured Emacs command,
 * the probe-reported install state and target directory, and an explicit
 * two-step install button. The probe costs one `emacs --batch`, so it runs on
 * mount and after an install only — never on a poll.
 */
export function EmacsInstall({ view, t }: EmacsInstallProps) {
  const [status, setStatus] = useState<StatusState>({ kind: 'loading' })
  const [phase, setPhase] = useState<InstallPhase>({ kind: 'idle' })
  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
    }
  }, [])

  const refresh = useCallback(() => {
    setStatus({ kind: 'loading' })
    callBridge({ method: 'GET', path: '/dsh-bridge/emacs' })
      .then(({ ok, status: code, body }) => {
        if (!alive.current) return
        if (!ok) {
          const message = (body as { error?: unknown } | null)?.error
          setStatus({ kind: 'error', message: typeof message === 'string' ? message : `HTTP ${code}` })
          return
        }
        setStatus({ kind: 'ready', report: body as EmacsStatusReport })
      })
      .catch((error: unknown) => {
        if (alive.current) setStatus({ kind: 'error', message: error instanceof Error ? error.message : String(error) })
      })
  }, [])

  // Mount-only probe: the status is refreshed after an install via refresh(),
  // never polled.
  useEffect(() => {
    refresh()
  }, [refresh])

  const runInstall = useCallback(() => {
    setPhase({ kind: 'running' })
    callBridge({ method: 'POST', path: '/dsh-bridge/emacs/install', payload: {} })
      .then(({ ok, status: code, body }) => {
        if (!alive.current) return
        if (!ok) {
          const message = (body as { error?: unknown } | null)?.error
          setPhase({ kind: 'done', report: { ok: false, output: typeof message === 'string' ? message : `HTTP ${code}` } })
          return
        }
        const report = body as EmacsInstallReport
        setPhase({ kind: 'done', report })
        if (report.ok === true) refresh()
      })
      .catch((error: unknown) => {
        if (alive.current) {
          setPhase({ kind: 'done', report: { ok: false, output: error instanceof Error ? error.message : String(error) } })
        }
      })
  }, [refresh])

  if (view === 'summary') return t('emacsInstallSummary')

  const report = status.kind === 'ready' ? status.report : undefined
  const command = report?.emacs.join(' ')
  const installing = phase.kind === 'running'

  return (
    <section aria-label={t('emacsPackageTitle')} style={sectionStyle}>
      <h4 style={{ margin: 0 }}>{t('emacsPackageTitle')}</h4>
      <p style={{ margin: 0, fontSize: 13, opacity: 0.75 }}>{t('emacsInstallDescription')}</p>
      {status.kind === 'loading' ? (
        <p role="status" style={{ margin: 0, fontSize: 13 }}>{t('emacsStatusLoading')}</p>
      ) : status.kind === 'error' ? (
        <p role="alert" style={{ margin: 0, fontSize: 13 }}>{t('emacsStatusError', { message: status.message })}</p>
      ) : report === undefined ? null : (
        <>
          <div style={rowStyle}>
            <span style={labelStyle}>{t('emacsBundledVersionLabel')}</span>
            <code>{report.bundledVersion ?? '—'}</code>
          </div>
          {command === undefined ? null : (
            <div style={rowStyle}>
              <span style={labelStyle}>{t('emacsCommandLabel')}</span>
              <code>{command}</code>
            </div>
          )}
          {report.emacsVersion === undefined ? null : (
            <div style={rowStyle}>
              <span style={labelStyle}>{t('emacsVersionLabel')}</span>
              <span>{report.emacsVersion}</span>
            </div>
          )}
          {report.problem === undefined ? (
            <>
              <div style={rowStyle}>
                <span style={labelStyle}>{t('emacsStateLabel')}</span>
                <span>
                  {report.state === 'installed'
                    ? t('emacsStateInstalled')
                    : report.state === 'outdated'
                      ? t('emacsStateOutdated')
                      : t('emacsStateAbsent')}
                </span>
              </div>
              {report.packageUserDir === undefined ? null : (
                <div style={rowStyle}>
                  <span style={labelStyle}>{t('emacsTargetDirLabel')}</span>
                  <code>{report.packageUserDir}</code>
                </div>
              )}
            </>
          ) : (
            <p role="alert" style={{ margin: 0, fontSize: 13 }}>
              {t(problemKey(report.problem), { version: report.emacsVersion ?? '' })}
            </p>
          )}
          {report.output === undefined || report.output === '' ? null : (
            <pre style={outputStyle}>{report.output}</pre>
          )}
        </>
      )}
      {phase.kind === 'confirm' ? (
        <div role="alertdialog" aria-label={t('emacsInstallButton')} style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <p style={{ margin: 0, fontSize: 13 }}>
            {t('emacsInstallConfirm', {
              command: command ?? 'emacs',
              dir: report?.packageUserDir ?? '',
            })}
          </p>
          <div style={{ display: 'flex', gap: 8 }}>
            <Button variant="primary" size="sm" onClick={runInstall}>{t('emacsInstallConfirmButton')}</Button>
            <Button variant="ghost" size="sm" onClick={() => setPhase({ kind: 'idle' })}>{t('emacsInstallCancel')}</Button>
          </div>
        </div>
      ) : (
        <div>
          <Button
            variant="outline"
            size="sm"
            disabled={installing || status.kind === 'loading'}
            onClick={() => setPhase({ kind: 'confirm' })}
          >
            {installing ? t('emacsInstallRunning') : t('emacsInstallButton')}
          </Button>
        </div>
      )}
      {phase.kind !== 'done' ? null : phase.report.ok === true ? (
        <p role="status" style={{ margin: 0, fontSize: 13 }}>{t('emacsInstallSuccess')}</p>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <p role="alert" style={{ margin: 0, fontSize: 13 }}>
            {t('emacsInstallFailed')}
            {typeof phase.report.problem === 'string'
              ? ` ${t(problemKey(phase.report.problem), { status: phase.report.exitStatus ?? '' })}`
              : ''}
          </p>
          {phase.report.output === undefined || phase.report.output === '' ? null : (
            <pre style={outputStyle}>{phase.report.output}</pre>
          )}
          {typeof phase.report.bundledPath === 'string' && phase.report.bundledPath !== '' ? (
            <div style={rowStyle}>
              <span style={labelStyle}>{t('emacsInstallManualLabel')}</span>
              <code>{`(package-install-file "${phase.report.bundledPath}")`}</code>
            </div>
          ) : null}
        </div>
      )}
    </section>
  )
}
