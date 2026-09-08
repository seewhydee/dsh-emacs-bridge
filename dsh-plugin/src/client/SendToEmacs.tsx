// dsh-emacs-bridge — "Send to Emacs" action for the assistant message actions
// row. The browser addresses the durable message by id; the host resolves its
// text from the session log and deposits it into the outbox for Emacs to pull
// (the chat node tree no longer rides the client session snapshot).
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

import { useCallback, useState } from 'react'
import { IconCheckOutline16, Tooltip } from '@deepseek-ai/dsh-client-ui-primitives'
import type { InjectFace, PropsLocale, PropsRuntime } from '@deepseek-ai/dsh-client-ui-slots'
// Type-only: pulls the ui-chat SlotMap merge (the assistant-actions entry).
import type {} from '@deepseek-ai/dsh-client-ui-chat/client'
// Type-only: pulls this package's LocaleNamespaceMap merge (the namespace seat).
import type {} from './locales.ts'
import { EmacsMiniIcon } from './EmacsMiniIcon.tsx'

/** Injected business face of one "Send to Emacs" entry: deposit the addressed message. */
export interface SendToEmacsInjected {
  /** Deposit one durable assistant message into the host outbox, by message id. */
  deposit: (messageId: string) => Promise<void>
}

/** Full props of one assistant-message "Send to Emacs" entry. */
export type SendToEmacsProps =
  PropsRuntime<'conversation.chat.assistant-actions'>
  & InjectFace<SendToEmacsInjected>
  & PropsLocale<'dsh-emacs-bridge'>

/**
 * The "Send to Emacs" action: deposit the assistant message into the bridge
 * outbox. A brief check swap confirms success; a failure surfaces a short
 * tooltip message and leaves the button usable.
 */
export function SendToEmacs({ messageId, deposit, t }: SendToEmacsProps) {
  const [sent, setSent] = useState(false)
  const [pending, setPending] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const onClick = useCallback(() => {
    if (pending) return
    setPending(true)
    setFailure(null)
    deposit(messageId)
      .then(() => {
        setPending(false)
        setSent(true)
        window.setTimeout(() => setSent(false), 1200)
      })
      .catch((error: unknown) => {
        setPending(false)
        setFailure(error instanceof Error ? error.message : String(error))
      })
  }, [pending, messageId, deposit])
  const label = failure ?? (sent ? t('sentToEmacs') : t('sendToEmacs'))
  return (
    <Tooltip label={label} side="bottom">
      <button
        type="button"
        aria-label={t('sendToEmacs')}
        disabled={pending}
        onClick={onClick}
        style={{
          display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
          width: 20, height: 20, border: 0, background: 'none', padding: 0,
          cursor: pending ? 'default' : 'pointer', color: 'inherit',
        }}
      >
        {sent ? <IconCheckOutline16 /> : <EmacsMiniIcon />}
      </button>
    </Tooltip>
  )
}
