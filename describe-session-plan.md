# Better session description — implementation plan

Status: **implemented** (v0.8.0); this document is retained as the design
record, with the "Please confirm" items in §10 resolved as recommended.
Reviewed against the bundled Emacs
30.2 sources: the `*Help*`-avoidance and `help-xref-following` mechanics in
§3.1/§6.2 are confirmed by the `octave-help-mode` precedent, and the §11 open
questions are adjudicated there (all §10 recommendations stand as written).
This document plans PLAN.md's
[Candidate 1](PLAN.md) ("Session stats in `describe-session`") together with the
opportunity the task opens up: rebuilding the session report as a real Emacs
`describe-*`-style buffer (Help mode, page-separated sections, hyperlinks,
back/forward navigation), and making it reachable from every surface instead of
only from the sessions list.

The repo's own rules in [AGENTS.md](AGENTS.md) are treated as binding:
`index.ts` stays thin wiring, every pure decision goes in `logic.ts` and gets a
Vitest spec, every elisp helper gets ERT coverage, user-tunable behavior is a
`defcustom`, and a change is complete only when `make build && make test`
passes (plus `make integration-test` for the new host seam).

---

## 1. Goal and scope

**Goal.** `D` (and its new siblings) opens a read-only session report that is a
first-class Emacs help buffer: one consistent buffer, `help-mode` navigation,
`[back]`/`[forward]` links, buttons for every useful action, and the session's
real numbers (turns, timings, tokens, context) for live **and** cold sessions
without resuming anything.

**In scope**

- PLAN.md candidate 1 in full: `sessionStats`, `tokenUsage`, `contextPressure`,
  `contextBreakdown`, `modelSelection`, `agentPreset`, `permissions`, `title`,
  `sessionListMetadata.lastPromptAt`, plus header identity/lineage facts.
- A new read-only host route that reads one session through
  `ctx.sessionQuery.observeSession(id, { projectionMode: 'all' })`, with the
  AGENTS.md degraded fallback when that optional service is absent.
- A new Emacs major mode derived from `help-mode`, a single reusable report
  buffer, hyperlinks/buttons, formatting helpers, and entry points from the
  sessions list, DSH-View, the transient, the menu bar, and the session label
  in the DSH-View/DSH-Prompt header lines.
- Docs (`README.md`, `AGENTS.md`, `PLAN.md`), version bump, tests.

**Out of scope (deliberately)**

- Goal/plan/todos/turn-outline display (PLAN.md candidates 5 and the deferred
  section). The mode is designed so those slot in as extra sections later.
- Any mutation from the report (model change, permission change, archive,
  fork). The report is read-only; existing verbs remain the way to mutate.
- `/turns` `messageId`/`endSeq` (candidate 2/4 prerequisites) — not needed here.
- Browser/client-plugin changes: the web UI already renders these figures.

---

## 2. Current state

`dsh-bridge-describe-session` (emacs/dsh-bridge.el:4240) is a five-line
`special-mode` dump built **only** from the Emacs-side sessions cache:
`Session id`, `Title`, `State`, `Directory`, `Last active`. It:

- is reachable only from `D` in the DSH-Sessions buffer;
- has no hyperlinks, no refresh, no navigation, no faces;
- shows no statistics at all (the host sends none);
- works for a cold session only insofar as the cache row happens to carry it.

The host has no route for one session; `/sessions` returns list rows
(`SessionRow` in logic.ts:326) with `id/title/cwd/live/running/lastActive/
createdAt/workspace/workspaceId/archived` and nothing statistical.

The data all exists host-side and is already wire-shaped:

| Unit | Home (harness) | Wire value used by the bridge |
|---|---|---|
| `sessionStats` | `packages/session/session-stats/src/types.ts` | `turns, steps, llmMs, toolMs, ttftMs, ttftSteps, decodeMs, decodeTokens` |
| `tokenUsage` | `packages/llm/token-meter/src/projection.ts` | `uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens` (the `{totals,last}` state is host-only and never appears in a snapshot) |
| `contextPressure` | same file | `{pressureTokens?, projectedTokens?, contextWindow?}` |
| `contextBreakdown` | same file | `{systemTokens, toolsTokens, messageTokens}` |
| `title` | `packages/session/session-title/src/types.ts` | `string \| null` |
| `agentPreset` | `packages/preset/agent-presets/src/types.ts` | `string \| null` |
| `modelSelection` | `packages/api/session-controller/src/types.ts` | `{lastUsed, next}` |
| `permissions` | `packages/interaction/permission-presets/src/types.ts` | `{options:[{value,name,description?}], currentValue}` |
| `sessionListMetadata` | `packages/api/session-controller/src/types.ts` | `{blank, lastPromptAt}` |

Profile availability was checked: the `web` profile is
`@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app`
(`packages/boot/app-boot/src/profile.ts:116`). `session-query-sqlite` (the
`sessionQuery` service), `session-title`, `token-meter`, and
`permission-presets` ride the base bundle; `session-stats`, `agent-presets`,
and the session controller ride web-app. So in the shipped `web` profile all of
the above are present — but per AGENTS.md the bridge must still tolerate each
being absent.

`observeSession` is the right seam: it is live-preferred and, for a cold
session, restores an **unpublished** Session (`sessions.prepare`, never
`resume`) and folds the registered projections over the log
(`packages/session-query/session-query/src/observation.ts`). It returns a
disposable lease whose `header`, `source` (`'live' | 'prepared'`), `events`,
`cursor`, and `projections.values` we can read; it throws
`SessionQueryError('SESSION_QUERY_SESSION_NOT_FOUND')` for an unknown id. It
never resumes or publishes.

---

## 3. Recommended design decisions

The decisions below are the plan's recommendation. The ones that change
user-visible behavior are collected again in §10 as explicit "please confirm"
items.

### 3.1 Buffer and major mode — `help-mode`, one reusable buffer

Define a thin major mode:

```elisp
(define-derived-mode dsh-bridge-describe-mode help-mode "DSH-Describe" ...)
```

and render into a **single reusable** buffer named
`*dsh-bridge-describe*` (replacing `*dsh-bridge-session-details*`, which is
referenced nowhere else).

Why `help-mode`:

- `help-setup-xref` + `help-xref-stack-item` give `[back]`/`[forward]`
  buttons and `l`/`r` history for free, and `help-mode-revert-buffer`
  re-invokes the stored item, so `g` re-fetches *and* preserves point with no
  code of ours.
- `help-make-xrefs` auto-links quoted symbols and file names (so a
  `dsh-bridge.el` reference in the buffer becomes a source link).
- `button-buffer-map` supplies `TAB`/`S-TAB` button motion, `RET`/`mouse-2`
  push buttons, `q` quits, `n`/`p` walk pages (`\f` sections), `?`/`h`
  describe the mode.

Why one buffer rather than one per session: `help-xref-stack` is buffer-local.
If session B is described from a link inside session A's report, a per-session
buffer B starts with an empty stack and `l` fails. A single buffer makes
`A → B → l` work exactly like `describe-function → describe-variable → l`.

Why not reuse the standard `*Help*`: describing a session should not clobber
the user's last `C-h` output, and the bridge already owns namespaced buffers.
This matches bundled Emacs practice: `*Help*` reuse is the `C-h` help-system
family's pattern (the two dozen files using `with-help-window` are
describe-*/apropos-documentation commands), while application-specific
doc/report browsers own their buffers — the near-exact precedent is
`octave-help-mode` (lisp/progmodes/octave.el:1678), which derives from
`help-mode` and renders into its own reusable `*Octave Help*` buffer (a
defcustom, octave.el:1654); `idlwave-help-mode`, shortdoc, finder, apropos,
and WoMan/Man/Info likewise do not clobber `*Help*`.

The cost is the `help-xref-following` gotcha (see §6.2): `help-buffer`
returns our buffer only when **both** `help-xref-following` is non-nil **and**
the current buffer is already derived from `help-mode` — both conditions must
hold when `help-setup-xref` runs, since it installs the xref state in
`(help-buffer)`. This is the documented bundled idiom, not a hack: octave.el
binds `help-xref-following` around `help-setup-xref` with the comment "Bound
to t so that `help-buffer' returns current buffer for `help-setup-xref'".

### 3.2 Read-only guarantee

The describe path must never resume, create, rename, or publish a session.
It therefore does **not** use `resolveTarget`/`ensureLive` (both resume cold
sessions). It resolves an id and calls `observeSession` only.

Consequences to preserve:

- Describing a cold session reads its persisted log (cost proportional to log
  length, bounded by the observation reader's per-revision cache) and reports
  `live: false`.
- The default (no `sessionId`) is last-active live, else most recent cold —
  the same selection order as `resolveTargetId` — but the selected id is
  observed, not resumed.
- Subagent-owned ids are 409, matching the rest of the bridge. (Describing a
  subagent read-only is defensible, but parity is the rule today; revisit
  only with a deliberate decision.)

### 3.3 Data-source ladder (degraded-but-working)

The host builds the report in this order, recording what it could not read in
a `missing` list:

1. `ctx.get('sessionQuery')` present → `observeSession(id, {projectionMode:
   'all'})`; `projections.values` supplies every unit above. Works live and
   cold. This is the normal path.
2. `sessionQuery` absent, session **live** → `ctx.get('sessionProjections')
   ?.snapshot(session).values` (live-only; the same optional service the
   `/context` route already reads) plus the header. Cold stats/usage are
   unavailable and named in `missing`.
3. `sessionQuery` absent, session **cold** → `sessionPersistence.stat(id)`
   header facts only; title/preset folded from a read handle only if we keep
   the existing fold (`sessionTitle` / `sessionPreset`). No statistics.
   `basis: 'header'`.

The report carries `basis: 'observation' | 'header'` and `missing: string[]`
so Emacs can say *why* a section is absent rather than showing a bare dash.

### 3.4 Host route

```
GET /dsh-bridge/session?sessionId=   -> 200 SessionReport
```

- Bearer-authenticated like every non-exempt route; no fence change. GET only,
  no body, so the 1 MiB cap and origin rules are untouched.
- `sessionId` optional (omitted → last-active live, else most recent cold).
  A non-string `sessionId` is 400.
- 404 unknown id (including a header with no `cwd`, mirroring the harness's
  `inspectApiSession` "not found" rule); 409 subagent-owned; 409
  `no active session` when nothing is live or persisted; 500 for an
  observation/persistence failure, with the message.
- Implementation shape: resolve the id (pure, §5.1), `await
  sessionQuery.observeSession(...)`, build the report with the pure
  `sessionReport`, enrich `modelName` from the `session/modelCatalog` Remote
  (the same `rpcCall` the `/models` route uses; failure just leaves it null),
  `observation[Symbol.dispose]()` in a `finally`, then `sendJson`.

`/session` (singular) is the recommended path: it mirrors `/context` and
`/models`, reads one resource, and is unambiguous against the plural list
route in the prefix dispatcher. (`/sessions/describe` is the fallback name if
review prefers grouping; the route inventory comment and README change either
way.)

### 3.5 Where the logic lives

- `logic.ts` gains the pure pieces (no Cordis/dsh imports):
  `resolveReadTargetId`, `sessionReport`, `catalogModelName`, and their types.
- `index.ts` gains only: the optional `SessionQueryService` structural face,
  the route handler, workspace/archived extras from `workspaceRegistry`, and
  the model-catalog enrichment RPC.
- Emacs-side formatting (durations, token grouping, percentages, tokens/sec,
  cache-hit %) stays in elisp: it is presentation, not a host decision.

### 3.6 Report content and hyperlinks

Sections, separated by `\n\n\f\n` so `n`/`p` page navigation works:

```
DSH session "Fix the parser bug" (live · idle)
  Id           9f3c… (button: copy; `w' also copies)
  State        live · idle            [or "saved (cold)", "running"]
  Created      2026-09-09 18:53:12 (2h)
  Last prompt  2026-09-09 19:04:03 (1h)          [sessionListMetadata]
  Directory    /home/cyd/src/foo     (button: dired)
  Workspace    foo                   (button: dired)
  Preset       default
  Model        Anthropic/Claude …    (button: open prompt buffer)
  Permissions  workspace-write       (help-echo: preset description)
  Forked from  4a2b…                 (xref: describe the parent)
  Seeded       yes

Stats
  Turns 12 · Steps 48
  LLM time       2m 13.4s
  Tool time      18.2s
  First token    812 ms avg over 44 steps
  Decode         1m 44.0s · 12,345 tokens · 118.7 tok/s

Tokens
  Input (uncached)  45,678
  Output            12,345
  Cache read        1,234,567
  Cache write       23,456
  Cache hit         96.4%

Context
  Next request   123,456 / 200,000 (61.7%)
  Last request   120,000
  Breakdown      system 3,000 · tools 12,000 · messages 108,000

[back] [forward]
```

Plus a final action line of plain buttons: `[Open prompt]` `[Latest turn]`
`[List sessions]` `[Copy id]` (non-navigating `insert-text-button`s with
`'action`, so they do not enter the help history).

Hyperlink inventory:

| Text | Kind | Behavior |
|---|---|---|
| session id | action | copy to kill ring (also `w`) |
| Directory / Workspace | action | `dired` (fall back to `find-file` for a non-directory) |
| Model | action | open DSH-Prompt bound to the session (`C-c C-m` changes it) |
| Parent session | help xref | `dsh-bridge-describe-session` on the parent → `l`/`r` history |
| `dsh-bridge.el` | help xref (auto) | source file, via `help-make-xrefs` |
| action line | action | open prompt / fetch latest turn / list sessions / copy id |

Not hyperlinked: the raw title (it can be arbitrary text; making it a link
risks `help-make-xrefs` surprises and there is no obvious target), the preset
(no mutation from here), the numbers (copying the buffer covers it).

### 3.7 Keybindings and entry points

The describe buffer inherits `help-mode` keys; the bridge's usual `l`/`r`
meanings intentionally do **not** apply here (they are help back/forward), and
the report says so in its mode docstring and the README:

- `q` quit, `g`/`revert-buffer` re-fetch, `l`/`r` back/forward, `C-c C-b`/
  `C-c C-f` back/forward, `n`/`p` next/previous section, `TAB`/`S-TAB` button
  motion, `RET`/`mouse-2` push button, `?`/`h` describe the mode.
- Added: `w` copy session id, `f` fetch the session's latest turn into
  DSH-View, `o` open the prompt buffer, `D` re-describe (revert).

Invocation:

- `dsh-bridge-describe-session (&optional session-id)` becomes
  `;;;###autoload`. Interactive resolution: sessions buffer → row id; prefix
  arg → `dsh-bridge--read-session-id` completion; otherwise
  `dsh-bridge--effective-session`, and when that is nil let the host pick
  last-active (the report echoes the resolved id).
- `D` in DSH-Sessions (existing) and DSH-View (new, read-only buffer so no
  self-insert conflict).
- **Not** bound in DSH-Prompt: `D` is a self-inserting character there. Add
  "Describe Session" to the prompt menu bar instead.
- New verb in the transient "Read" group and in the top-level
  `dsh-bridge-menu`.
- `dsh-bridge--buffer-session` learns the describe mode, so the transient
  invoked from a report acts on the described session.
- Session label in the DSH-View and DSH-Prompt header lines becomes
  `mouse-1`-clickable → describe that session. Implemented with a shared
  keymap text property (`[header-line mouse-1]` →
  `dsh-bridge-describe-session-at-mouse`, which reads the id from a
  `dsh-bridge-session-id` text property) plus `mouse-face`/`help-echo`;
  properties survive the existing `string-replace "%" "%%"` escaping
  (verified against the repo's Emacs).

### 3.8 Refresh

`g`/`revert-buffer` re-fetches. Additionally (new `defcustom
dsh-bridge-describe-auto-refresh`, default t): when the report buffer is
visible and describes a session whose `turn-complete` (and optionally
`turn-start`) notification arrives, call `revert-buffer` — point is preserved
by `help-mode-revert-buffer`. This keeps the report from going stale after a
turn, matching the live status surfaces elsewhere. It is a small addition to
`dsh-bridge--notification-handle-events`; if review prefers a snapshot-only
report, set the defcustom to nil. One implementation constraint: the fetch is
synchronous (`dsh-bridge--request` uses `url-retrieve-synchronously`), so the
auto-refresh must be deferred with `run-at-time 0`, mirroring
`dsh-bridge--turn-complete-act`'s refetch pattern — calling `revert-buffer`
directly in the notification handler could freeze Emacs for up to
`dsh-bridge-describe-timeout` inside the process filter.

### 3.9 Timeouts and errors

- New `defcustom dsh-bridge-describe-timeout` (default 15 s, vs the 5 s
  general timeout): a cold session's full-log read plus projection fold can
  outrun the default. The request binds it around the call.
- On any request failure the buffer still opens: cached session row (if any),
  a one-line reason (`HTTP 404: …`, `request timed out`, transport error), and
  no fake zeros. Missing sections read `unavailable` rather than `0`.

---

## 4. `SessionReport` wire shape

```ts
export interface SessionReport {
  sessionId: string
  live: boolean                 // observation source === 'live'
  running: boolean              // live agent status; false when cold
  basis: 'observation' | 'header'
  missing: string[]             // e.g. ['stats','tokens','context','permissions']
  title: string | null
  cwd: string | null
  workspace: string | null
  workspaceId: string | null
  archived: boolean
  createdAt: number             // ms epoch, header fact
  lastActive: number | null     // best-effort; null when cold/unknown
  lastPromptAt: number | null   // sessionListMetadata view
  parentSession: string | null
  isSeeded: boolean
  origin: string | null
  delegationDepth: number | null
  agentPreset: string | null
  model: { provider: string; model: string; reasoningEffort?: string } | null
  modelName: string | null      // resolved host-side from session/modelCatalog
  permissions: {
    currentValue: string
    options: { value: string; name: string; description?: string }[]
  } | null
  stats: {
    turns: number; steps: number
    llmMs: number; toolMs: number
    ttftMs: number; ttftSteps: number
    decodeMs: number; decodeTokens: number
  } | null
  tokens: {
    uncachedInputTokens: number; outputTokens: number
    cacheReadTokens: number; cacheWriteTokens: number
  } | null
  context: {
    pressureTokens?: number; projectedTokens?: number; contextWindow?: number
  } | null
  breakdown: {
    systemTokens: number; toolsTokens: number; messageTokens: number
  } | null
}
```

Notes:

- `model` is the raw `modelSelection` view (`next ?? lastUsed`); when both are
  null the host also consults the model catalog default? **No** — resolving the
  catalog default is the `/models` route's job and would force a second live
  RPC. Emacs already caches `/models`; for a live session the report's
  `modelName` is filled host-side from the catalog, and when `model` is null
  Emacs shows "default". This avoids calling `/models` from the report, which
  would resume a cold session.
- `permissions` is the wire select. The exact sandbox/approval knobs are
  host-only state, so the preset `name`/`description` is the display-ready
  equivalent (as PLAN.md candidate 6 already states).
- All numbers are raw; no formatting host-side.

---

## 5. Host changes

### 5.1 `dsh-plugin/src/logic.ts` (pure, + Vitest)

- `resolveReadTargetId(explicitId, live, persisted): { kind: 'target'; id:
  live: boolean } | { kind: 'error'; status: 404 | 409; message }`. Same
  precedence as `resolveTargetId` (explicit → last-active live → most recent
  cold, skipping subagent-origin colds) but **without** the `hasAgent`
  requirement: a live session with no attached agent is still describable.
- `sessionReport(observation, extras): SessionReport`, where `observation` is a
  structural `{ source; header; projections?: { values: Record<string,
  unknown> } }` and `extras` carries `running`, `workspace`, `workspaceId`,
  `archived`. Guards every projection key, fills `missing`, and never throws on
  an unexpected shape.
- `catalogModelName(catalog, provider, model): string | null` — flatten
  `groups[].models[]` and return the display name (the pure half of what
  `dsh-bridge--model-display-name` does in elisp).
- Extend `SessionHeaderLike` with optional `parentSession`, `isSeeded`,
  `delegationDepth` (optional, so existing callers are unaffected).
- Export `SessionReport`, `SessionStatsReport`, `TokenUsageReport`,
  `ContextPressureReport`, `ContextBreakdownReport`, `PermissionReport`,
  `ReadTargetResult`.

### 5.2 `dsh-plugin/src/index.ts` (wiring)

- Add `SessionQueryService` (minimal structural face: `observeSession(id,
  options?)` returning the observation shape, with `[Symbol.dispose]`), read
  with `ctx.get('sessionQuery')`; document the fallback.
- Add `readSessionReport(id | undefined): Promise<SessionReport>`:
  resolve → observe (or live-registry / persistence fallback) → `sessionReport`
  → enrich `modelName` via `rpcCall('session/modelCatalog',
  rpcArgsPayload({}))` when `model` is set (best-effort) → dispose lease.
- Register `GET /dsh-bridge/session` inside the existing single
  `webServer.register` handler, following the established `try/catch` +
  `bridgeErrorStatus` pattern. Map `SESSION_QUERY_SESSION_NOT_FOUND` and a
  missing `header.cwd` to 404, `header.origin === 'subagent'` to 409.
- Update the route-inventory header comment (AGENTS.md requires this).
- No changes to the outbox, SSE frames, ask-user waterfall, or the client half.

### 5.3 Tests (`dsh-plugin/tests/`)

New `session-report.spec.ts` (or extend `logic.spec.ts`):

- full observation → every field mapped verbatim; `missing` empty.
- absent projection keys → `null` + named in `missing`; `basis` preserved.
- `source: 'prepared'` → `live: false`, `running: false`.
- header-only report → `basis: 'header'`, all numeric sections null.
- `title` projection present-but-null vs key-absent (the former is "untitled",
  the latter falls back to the log fold / `missing`).
- `permissions` current `custom` with a derived option.
- `resolveReadTargetId`: explicit live (no agent) → target; explicit cold →
  target live:false; unknown → 404; empty inventory → 409; default skips
  subagent-origin colds; default prefers newest live by event time.
- `catalogModelName`: hit, miss, absent groups.

---

## 6. Emacs changes (`emacs/dsh-bridge.el`)

### 6.1 New mode and buffer

- `dsh-bridge-describe-mode`, parent `help-mode`, lighter `DSH-Describe`,
  keymap with `w`/`f`/`o`/`D` additions and an `easy-menu-define` menu
  (`dsh-bridge-describe-menu`) exposing the bridge actions (back/forward stay
  Help mode's own menu items).
- `defvar-local dsh-bridge--describe-session` (the described id, used by
  refresh, auto-refresh, and `dsh-bridge--buffer-session`).
- Buffer name `*dsh-bridge-describe*`; the old
  `*dsh-bridge-session-details*` name disappears (grep confirms it is
  referenced only at the current implementation site).
- `dsh-bridge--buffer-session` gains a `dsh-bridge-describe-mode` clause so
  the transient and the region/buffer senders act on the described session.

### 6.2 Rendering

- `dsh-bridge--describe-render (id)`: fetch the report, then render.
  Ordering matters and must be commented: get buffer → enter the derived mode
  if needed → `(let ((inhibit-read-only t) (help-xref-following t))
  (help-setup-xref (list #'dsh-bridge-describe-session id)
  (called-interactively-p 'interactive)) (erase-buffer) … (help-make-xrefs
  (current-buffer)))`. Two preconditions make `help-buffer` return our buffer
  instead of `*Help*` when `help-setup-xref` runs: `help-xref-following`
  bound non-nil **and** the buffer already in the `help-mode`-derived mode —
  the mode entry must happen first. And `help-setup-xref` must run **before**
  `erase-buffer`: its docstring requires this because it records the previous
  position of point for the back button. Both details mirror the bundled
  `octave-help` idiom (lisp/progmodes/octave.el:1696-1703).
- `dsh-bridge--describe-insert-header/-stats/-tokens/-context/-permissions`
  helpers, each inserting a section and a `\n\n\f\n` separator.
- `dsh-bridge--describe-row (label value &optional help)` for the aligned
  `label value` lines with `help-echo`.
- Buttons: `dsh-bridge--describe-xref` (help xref) and
  `dsh-bridge--describe-button` (plain action button); actions
  `dsh-bridge--describe-copy-id`, `-open-directory`, `-open-prompt`,
  `-open-view`.
- `dsh-bridge-describe-session-at-mouse` + `dsh-bridge--session-link` +
  `dsh-bridge--session-link-map` for the header-line label; wired into
  `dsh-bridge--view-header-line` and `dsh-bridge--prompt-header-line`.
- Faces: `dsh-bridge-describe-heading-face` (inherit `bold`) and
  `dsh-bridge-describe-label-face` (inherit `shadow`), in the `dsh-bridge`
  group.

### 6.3 Formatting helpers (unit-testable, no I/O)

- `dsh-bridge--format-duration (ms)` → `450 ms`, `12.3 s`, `2m 13.4s`.
- `dsh-bridge--format-number (n)` → grouped `1,234,567`.
- `dsh-bridge--format-percent (num den)` → `61.7%` (nil when den ≤ 0).
- `dsh-bridge--format-absolute-time (ms)` → `2026-09-09 18:53:12` plus the
  existing `dsh-bridge--relative-age` in parentheses.
- Tokens/sec = `decodeTokens / (decodeMs / 1000)`; cache-hit % =
  `cacheRead / (uncachedInput + cacheRead)`. Both nil-guarded.

### 6.4 Commands and entry points

- Rewrite `dsh-bridge-describe-session (&optional session-id)` per §3.7;
  `;;;###autoload`.
- `dsh-bridge--describe-default-session` / `dsh-bridge--describe-read-session`
  helpers for the interactive spec.
- `D` in `dsh-bridge-view-mode-map`; new transient verb; top-level menu item;
  prompt-mode menu item (no key).
- `defcustom dsh-bridge-describe-timeout` (15) and
  `dsh-bridge-describe-auto-refresh` (t).
- Auto-refresh hook in `dsh-bridge--notification-handle-events`, deferred via
  `run-at-time 0` (see §3.8 — the fetch is synchronous).

### 6.5 Tests (`emacs/dsh-bridge-tests.el`)

Mock `dsh-bridge--request` (the established `cl-letf` pattern) with canned
`/session` responses:

- render: buffer name, `(derived-mode-p 'help-mode)`, read-only, title,
  `Turns`, `Cache hit`, `tok/s`, section page separators (`\f` present), mode
  line lighter.
- buttons: `next-button`/`button-at` finds the id button; pressing it puts the
  id on the kill ring; the parent-session xref describes the parent and
  `help-go-back` returns to the child; action buttons do not push history.
- refresh: second call after changing the mock updates the text via `g`
  (`revert-buffer`) and preserves point; `help-xref-stack` survives.
- degradation: request failure (cons nil nil) still opens the buffer with the
  cached row plus a reason line and no zeros; missing projection sections read
  `unavailable`.
- entry points: sessions `D`, view `D`, transient verb present, top-level menu
  item present, prompt-mode menu item present, no `D` binding in
  prompt-mode-map.
- header links: the view/prompt header line's label carries `mouse-face`,
  `help-echo`, and a keymap binding `[header-line mouse-1]`.
- `dsh-bridge--buffer-session` returns the described id from a report buffer.
- formatting helpers: exact expected strings, including nil/zero/negative
  guards.
- keybinding regression: existing `dsh-bridge-sessions-mode` `D` test at
  dsh-bridge-tests.el:1348 still passes.

---

## 7. Integration seam (`integration/`)

The new route is the first consumer of `sessionQuery`, an optional service the
unit suite cannot reach, so add a Vitest spec (e.g. in `turns.spec.ts` or a new
`session.spec.ts`):

- create a session, send a mock turn, wait for `turn-complete`, then
  `GET /dsh-bridge/session?sessionId=` → 200; assert `sessionId`, `live: true`,
  `basis: 'observation'`, `stats.turns >= 1`, `title` (the mock's auto-title
  may land asynchronously — assert only what the mock deterministically
  produces, e.g. `stats.steps >= 1` and non-null `tokens`/`stats` objects).
- unknown id → 404; malformed `sessionId` (repeated query) → 400 if we choose
  to reject it.
- assert the route does not create/resume: an unknown id stays unknown
  (`/sessions` still lacks it) after the describe call.

Cold-read verification is the known gap: the fixture launcher always starts a
fresh `DSH_HOME`, so no persisted-only session exists without a host restart.
Either (a) note it as a manual check, or (b) extend the launcher to boot a
second host against the same `DSH_HOME` in a follow-up. Recommend (a) for this
task and record the gap in the integration README checklist.

Also add an elisp end-to-end ERT test in `integration/dsh-bridge-it.el` that
points `dsh-bridge-url` at the fixture, creates a session, calls
`dsh-bridge-describe-session`, and asserts the rendered buffer contains the
real turn count. This is the strongest proof that host and elisp agree on the
report shape — exactly the contract-pinning `integration/` exists for — so it
lands alongside the Vitest spec, not as a stretch goal. (That file is
currently single-purpose (ask-user); the value justifies the second
scenario.)

---

## 8. Docs and version

- `dsh-plugin/src/index.ts` header: add the `/session` route line.
- `README.md`:
  - transient list: new "describe the session" verb;
  - sessions list: document `D` (already exists but currently undocumented);
  - DSH-View: document `D` and the header-label click;
  - new short "Session details buffer" subsection: what it shows, the
    `help-mode` keys (`q`, `g`, `l`/`r`, `n`/`p`, `TAB`, `RET`, `?`) and the
    note that `l`/`r` are back/forward here, not list/reply. Also note the
    inherited wart that `help-mode` bookmark support hardcodes popping to
    `*Help*` (`help-bookmark-jump`), so bookmarks on the report buffer are
    unsupported;
  - failure-bounds paragraph: describing a cold session reads its persisted
    log **without** resuming it (the current sentence says naming a cold
    session resumes it — describe is the exception).
- `AGENTS.md`:
  - add `sessionQuery` to the optional-service list;
  - add DSH-Describe to the Emacs buffer-mode paragraph;
  - keep the route inventory pointer accurate (already covered by §5.2).
- `PLAN.md`: move candidate 1 into the Status list (with a one-line pointer to
  this document), leave a short note in "Shared prerequisites" that
  `sessionQuery` is now wired, and keep the remaining candidates' numbering
  intact (no renumbering churn).
- Version: bump the three locked copies together (`;; Version:` header,
  `dsh-bridge-version` defconst, `dsh-plugin/package.json`) to **0.8.0** —
  a new route plus a new user-visible command/mode. `make package` enforces
  agreement.

---

## 9. Landing order

Each step ends green (`make build && make test`; the integration step also
`make integration-test`).

1. **Pure logic + specs.** `resolveReadTargetId`, `sessionReport`,
   `catalogModelName`, type extensions, Vitest. No behavior change yet.
2. **Host route.** `SessionQueryService`, `readSessionReport`, the route, the
   route-inventory comment. Manual `curl` against a running `dsh web`; then the
   integration Vitest spec.
3. **Emacs skeleton.** Mode, buffer, fetch+render of identity/state fields
   only, entry points, `dsh-bridge--buffer-session` clause, ERT for
   mode/buffer/entry points. `D` now opens the new buffer with the same facts
   as before, in `help-mode`.
4. **Report sections + formatting helpers + buttons/xrefs**, ERT coverage.
   This is where the buffer becomes a real describe buffer.
5. **Header-line links** in DSH-View/DSH-Prompt, ERT.
6. **Refresh** (`g` via `help-mode-revert-buffer`, auto-refresh defcustom),
   ERT.
7. **Docs + version bump**, `make package`, full `make test` and
   `make integration-test`.

Suggested commit boundaries: 1; 2; 3; 4; 5+6; 7.

---

## 10. Please confirm

1. **Single reusable `*dsh-bridge-describe*` buffer** rather than the standard
   `*Help*` (recommended: does not clobber help; per-session buffers break
   `l`/`r` history). If you prefer `*Help*`, §3.1 collapses to a much smaller
   change and loses only the namespaced buffer.
2. **Help-mode keys win in the report**: `l`/`r` are back/forward, not
   list-sessions/reply, and there is no `D` binding in the editable
   DSH-Prompt buffer (menu only). Recommended for describe-* fidelity.
3. **Route name `GET /dsh-bridge/session`** (vs `/sessions/describe`).
4. **Auto-refresh on turn completion** (defcustom, default on) vs a pure
   snapshot.
5. **Subagent-owned ids 409** in the report, matching target resolution, vs
   allowing read-only describe.
6. **Version bump to 0.8.0** now, together with the feature.

## 11. Open questions / risks

- **Cold-read cost.** A very large cold log is read whole for projections; the
  observation reader caches by persistence revision, but the first describe can
  be slow. `dsh-bridge-describe-timeout` plus a clear timeout message is the
  mitigation; a future `sessionQuery` "light" projection mode would be better.
- **Mock usage coverage.** Not really a risk: the mock LLM is in-repo
  (`integration/mock-llm/`), so make it emit a deterministic `usage` block and
  assert non-zero `tokens` in the integration spec. This is a task, not an
  open question.
- **`help-make-xrefs` surprises.** It may auto-link quoted text in a session
  title. Mitigation: insert the title as plain text (no quotes) and keep
  auto-linking only for our deliberate `dsh-bridge.el` reference; if it proves
  noisy, the bundled escape hatch is `octave-help-mode`'s — set
  `help-xref-symbol-regexp` to `regexp-unmatchable` buffer-locally
  (lisp/progmodes/octave.el:1684) and skip `help-make-xrefs`, inserting any
  deliberate links as explicit buttons.
- **`help-xref-following` misuse.** Every render path must enter the derived
  mode and bind `help-xref-following` around `help-setup-xref` (both are
  preconditions of `help-buffer` returning our buffer — see §6.2). This is
  the most error-prone line in the elisp change; even bundled Emacs wrote
  itself a comment about it (octave.el:1701). An ERT test that renders from a
  non-help buffer and asserts `*Help*` was not touched guards the regression.
- **`permissions` knobs.** The wire view exposes the preset, not the raw
  sandbox/approval values; the report therefore shows the preset name and its
  description. If exact knob values are wanted, that is a separate host-only
  read (candidate 6's live-only `sandboxMode` note) and belongs in a follow-up.
