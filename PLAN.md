# dsh-emacs — project plan

A two-way bridge between an Emacs session and a running DeepSeek Harness (`dsh
web`) session. The DSH text window is small and typing-poor; Emacs is a full
editor but lacks DSH's live agent. The bridge moves text in both directions
over loopback HTTP without window-switching and copy-paste. Emacs is a
*companion* to a live DSH session (the web UI stays the primary interface),
not a replacement client — see [Settled decisions](#settled-decisions) for why
we are not pursuing the Emacs-as-primary-client (ACP-style) model.

## Names (locked)

| Layer | Name |
|---|---|
| Repo / working tree | `dsh-emacs-bridge` |
| DSH plugin (npm package) | `dsh-emacs-bridge` (unscoped — `@deepseek-ai/` is reserved) |
| DSH plugin (Cordis id) | `dsh-bridge` |
| Emacs feature / file | `dsh-bridge.el` → feature `dsh-bridge`, prefix `dsh-bridge-` |

## Status

Implemented and gated by `make test` (Vitest for the plugin's pure logic, ERT
for the Elisp) plus the `integration/` seam harness.

- **Host plugin** (`dsh-plugin/src/index.ts`; pure decisions in `logic.ts`,
  outbox in `outbox.ts`): loopback `/dsh-bridge/*` routes (inventory in the
  `index.ts` header comment), shared bearer token, host-side target resolution
  with on-demand resume of cold sessions, SSE turn/status/context/
  sessions-changed frames, a bounded DSH→Emacs outbox, the model
  catalog/selection proxied through the host's own Remotes, and ask-user
  ownership via the `user-questions/request` waterfall.
- **Client plugin**: "Send to Emacs" assistant action, composer-draft push,
  token auto-vend.
- **Emacs package**: transient dispatcher; tabulated session list
  (open/resume, rename, archive, create, workspace rename, peek/describe);
  per-turn DSH-View with `M-p`/`M-n`, follow mode and GFM rendering; DSH-Prompt
  composer with prompt history and model selection; SSE consumer with
  reconnect; plugin install/diagnosis.
- **Session report** (candidate 1):
  `GET /dsh-bridge/session` reads one session through `ctx.sessionQuery`
  (live or cold, never resuming) and returns identity/lineage plus
  `sessionStats`/`tokenUsage`/`contextPressure`/`contextBreakdown`/
  `modelSelection`/`permissions`/`title`; DSH-Describe renders it as a
  `help-mode` buffer with hyperlinks and back/forward history.

Usage is documented in [README.md](README.md); the architecture rules and the
harness seams the plugin depends on are in [AGENTS.md](AGENTS.md). This file
is forward-looking: settled decisions, candidates, and non-goals. The harness
is pre-release with no compatibility promise; AGENTS.md owns the version-bump
re-verification checklist.

## Settled decisions

- **Companion, not a replacement client.** The differentiator is attaching to
  a *live* session (session inventory, draft review, cross-surface push), not
  an Emacs-driven agent loop. The ACP ecosystem (`agent-shell`/`acp.el`, the
  harness's own `packages/acp/acp`) already covers Emacs-as-primary-client.
- **No live tail of assistant text.** Streaming every token into Emacs is
  DSH's job; Emacs gets turn-completion notices and on-demand turn fetches.
- **Observation is read-only; mutation is an explicit command.** Reads go
  through projections (`ctx.sessionQuery.observeSession(id, {projectionMode:
  'all'})` or `ctx.sessionProjections.stateOf`) so they never resume a cold
  session as a side effect. Writes are user-initiated commands that report
  what changed.
- **Host-side targeting, Emacs-side selection.** The host resolves a missing
  `sessionId` to last-active (falling back to the most recent cold session);
  Emacs keeps a default target plus per-buffer bindings.
- **Cold sessions are first-class.** An explicit cold id resumes on demand;
  subagent-owned sessions are 409.
- **Ask-user coexists with the web UI while an Emacs SSE client is
  connected**: the bridge offers the question to Emacs and (when the web UI is
  open) also calls `next()` so the browser panel appears; whichever answers
  first wins and the resolved frame dismisses the other presentation. With no
  Emacs SSE client the bridge delegates to the browser (`next()`) untouched.
- **Plugin management stays user-confirmed.** Installs are validated with
  `dsh --profile <p> --dump-config`; the bridge never auto-restarts a server.
- **`/output` is kept but unused** — a single-shot "latest text" probe; Emacs
  reads `/turns`.

## Candidates

Ordered by recommended sequence. Harness seams were verified against DSH
0.1.5-alpha.1; the peer floor in `dsh-plugin/package.json` is pinned to match
(node-semver prerelease rules exclude `0.1.5-alpha.1` from the old
`^0.1.3-alpha.2` floor).

**Shared prerequisites.** Two small additions unlock several candidates:

- `/turns` turn records gain the closing assistant message's `messageId`
  (ratings) and the turn's end `seq` as `endSeq` (fork targeting).
- The plugin's optional-service list gains `sessionQuery` (stats — **wired**:
  candidate 1 landed it), `messageFeedback` (ratings), `goals` (goal
  mutations), `sessionController`
  (fork), `commands` (slash-command catalog, `/emacs`),
  `permissionPresets`/`sandboxPolicy`/`approval` (permission display — none
  of the three is a Typert Remote; the wire surface is the `permissions`
  projection), and `serviceFor` on the `AgentPresetsService` face (plan
  mode). All are read with `ctx.get` and must tolerate `undefined`.

### 1. Session stats in `describe-session` (read-only)

**Implemented**.

Turn the current `D`/sessions-list details buffer into a real session report,
and make it reachable without going through the sessions list.

- **Data** — one call, live *and* cold, no resume:
  `ctx.sessionQuery.observeSession(id, {projectionMode:'all'})` returns the
  header plus projections:
  - `sessionStats` — turns, steps, `llmMs`, `toolMs`, `ttftMs`/`ttftSteps`,
    `decodeMs`/`decodeTokens` (tokens/sec = `decodeTokens / (decodeMs/1000)`);
  - `tokenUsage` — `uncachedInputTokens`, `outputTokens`, `cacheReadTokens`,
    `cacheWriteTokens` (cache-hit % = `cacheRead / (uncachedInput +
    cacheRead)`; cache writes are not reads);
  - `contextPressure` / `contextBreakdown`; `modelSelection`; `agentPreset`;
    `permissions`; `title`; `sessionListMetadata.lastPromptAt`.
  - Start time is `header.createdAt`; lineage is `parentSession`/`isSeeded`.
  - Observation snapshots carry **wire-visible projections only**; host-only
    units (`sandboxMode`) are silently absent (see candidate 6).
  - The harness has **no cost/USD** metric; do not promise one.
- **Discoverability** — the command is currently reachable only from the
  sessions buffer (`D` and its menu-bar menu). Generalize
  `dsh-bridge-describe-session` to take an optional session id (default: the
  current buffer's effective session), add it to the top-level
  `dsh-bridge-menu` and the transient, and make the session label in the
  DSH-View/DSH-Prompt header line clickable (`mouse-1` → describe).
- Keep the projection fold in `logic.ts` dependency-free; fall back to the
  existing persistence fold when `sessionQuery` is absent.

### 2. Branch a turn into a new conversation

**Implemented.**

- **Seam** — `ctx.get('sessionController').fork(...)` (the native service; the
  `session/fork` Remote proxy through `rpcCall` was the rejected alternative).
  The boundary is the first `turn/end` at/after `atSeq`; omit `atSeq` for the
  last completed turn. A fork without `atSeq` succeeds even mid-turn (cutting
  at the last completed `turn/end`); `session/fork-unavailable` is thrown only
  when `atSeq` pins a turn that has not completed. The host route
  (`POST /dsh-bridge/fork`) is `logic.ts`-free wiring over the service, resolves
  its source read-only (never resuming a cold session), 409s a subagent source,
  and maps the seam's `RemoteError` codes by their `isDSHRemoteError` marker.
- **Target** — the *shown* turn: fork at its `endSeq`, added to the `/turns`
  record (the `turn/end` event's `seq`); an open turn has no `endSeq` and is
  refused.
- **UX** — `B` in DSH-View forks at the shown turn, then opens the child's view
  (following) and its prompt, and reports the new id tail. The fork message
  states that a fork **inherits the preset but not the model** (the child starts
  on the default model) and is not auto-titled host-side (the web UI titles it
  client-side).

### 3. Transcript buffer

A continuous, read-only rendering of a whole session (`/prompts` + `/turns`
already carry the data), with turn separators and the existing follow/refresh
machinery. This is the natural home for the turn actions below; no new host
seam required.

### 4. Ratings on the turn-closing message

- **Seam** — `ctx.messageFeedback` (`list`/`put`/`delete`; also the Remotes
  `messageFeedback/list|put|delete`). Log-only, cold-readable, optimistic
  concurrency via `ifVersion` (`null` = require-absent); the target must be a
  finalized assistant `messageId`. Ratings are `positive`/`negative` plus an
  optional note.
- **Target** — one rating per turn, addressed to the turn's closing
  assistant `messageId`; rendered in DSH-View and the transcript.
- **Web parity** — the web UI renders the action strip on *every* turn's
  closing message (always visible on the latest turn, hover-revealed
  otherwise); only *branch* is disabled for non-latest turns. Emacs has no
  hover, so rating the shown turn is the faithful equivalent; narrowing to the
  latest turn would make ratings unavailable while browsing.

### 5. Plan mode and goal (display first)

- **Plan mode** — read the `plan` projection (`{active, pending}`). There is
  no Remote, and the controller is mounted in an entry-local `isolate` realm,
  so `ctx.get('planMode')` is `undefined`; the sanctioned mutation seam is
  `ctx.agentPresets.serviceFor(agent,'planMode')` (add `serviceFor` to the
  bridge's `AgentPresetsService` face). Plan-review questions arrive over the
  existing `user-questions/request` waterfall, so approving a plan from Emacs
  already works; a toggle command (`set(agent, bool)`, reporting
  `committed`/`queued`/`cancelled`/`noop`) can follow.
- **Goal** — read the `goal` projection: `{goal: {id, revision, objective,
  phase, blockedReason?, maxGoalRounds}, roundsStarted, createdAt,
  updatedAt}` (the revision for CAS lives at `goal.revision`). Mutations go
  through `ctx.goals` (revision-CAS `create/edit/pause/resume/complete/
  clear`, plus a read-only `get` and host-only `disarm`); prefer projection
  reads, because `goals/*` resolves `agentId` through `resolveAgent` and can
  resume a cold session as a side effect. `activation` is process-local (a
  restored active goal reads disarmed until `resume`) and is deliberately
  absent from the projection.
- **UX** — show goal phase and plan state in the DSH-View/Prompt header and
  `describe-session`; add mutating commands only if demand appears.

### 6. Permission mode (display only)

Show the effective sandbox mode (`read-only` / `workspace-write` /
`danger-full-access`) and approval policy (`ask` / `never` — note `never`
auto-*rejects*; it is not auto-approve) in the header and `describe-session`.
Read the `permissions` projection, which is wire-visible and display-ready
(a select control, `{options, currentValue}`), so it works live *and* cold.
The `sandboxMode` projection is host-only: it never appears in observation
snapshots, and `sessionProjections.stateOf` needs a live Session — treat it
as a live-only refinement, not the primary source.

Mutation from Emacs is deferred: it is a privilege-escalation surface behind
the same local token file, and the web UI gates full access behind an explicit
risk acknowledgement. See [Deferred](#deferred).

### 7. `/emacs edit` flow

Open a file (and line) from DSH in Emacs. The harness `open-in-app` catalog
ships VS Code, Zed, Sublime, Xcode… but **no Emacs target**, and the flow is
plain HTTP routes (`GET /open-in-app/apps`, `POST /open-in-app/open {app,
path}`), so either add an Emacs entry there/upstream or implement the
bridge-side route (`POST /dsh-bridge/open`, spawning `emacsclient` with
`server-name` respected).

Registering `/emacs` itself goes through `ctx.get('commands')` (optional —
tolerate `undefined`): `register({name, description, input?, recordInput?,
handler})`, where `name` carries **no slash** and must match
`/^[a-z][a-z0-9_-]*$/`; the handler receives `{commandId, agent, rawInput,
attachments, signal}` and returns `{kind:'success', text?} |
{kind:'error', text}`. Convenience, not core; keep it parked behind the
candidates above.

### 8. Slash-command catalog and execution

- **Seam** — the `commands/list` and `commands/execute` Remotes, proxied
  through the existing `rpcCall` exactly like the model Remotes.
  `list(agent)` returns name-sorted `CommandDescriptor`s (`{name (no slash),
  description, input?: {hint, attachments?}}`); `execute(agent, line,
  submittedAttachments, signal)` runs a slash line without sending it to the
  model, returning `undefined` for unknown lines and a settled `{commandId,
  result: {kind:'success'|'error', text?}}` otherwise. Check how `signal`
  crosses the RPC wire at implementation time.
- **UX** — `/`-completion in the DSH-Prompt composer (annotations from
  `description`), routing a submitted slash line to `execute` instead of
  `/send`, with the result rendered in the view buffer; also expose the
  catalog in the transient. Parity-plus: Emacs completion beats the web
  command palette for keyboard users.

### 9. Changed-files review

- **Data** — a pure fold in `logic.ts` over the session log's file-touching
  tool calls (the same log the `/turns` fold already walks), producing
  per-turn and per-session lists of modified paths resolved against the
  session cwd. Pin down the exact tool-event vocabulary (which events carry
  paths) at implementation time.
- **UX** — a tabulated review buffer: `RET` opens the file, a prefix opens
  `vc-diff` (or magit) for it; reachable from DSH-View and the transcript.
  This is the "what did it just change" workflow the web UI cannot match.

### 10. Cross-session search

- **Route** — `GET /dsh-bridge/search?q=`: full-text over live sessions plus
  cold logs read via `sessionPersistence.open(id, 'read')` (never resuming).
  Cold logs are read whole, so bound the cost: a `sessionId` scope parameter
  or a most-recent-N cap, with truncation reported.
- **UX** — an occur/grep-style results buffer; `RET` jumps to that session's
  transcript at the matching turn.

### 11. Attachments in `/send`

- **Seam** — `UserMessage` content blocks include `image` and `file` blocks
  whose bytes are owned by the content-addressed `attachments` store (one
  more optional `ctx.get`); file blocks never reach the provider — request
  assembly projects them to handle text. The bridge stages bytes through the
  store and builds the multi-block message host-side. The web composer
  submits file attachments as staged receipts (`CommandSubmitAttachment`);
  mirror that flow rather than inventing a second one.
- **UX** — "attach this buffer's file", dired-marked files, or an image from
  the composer.

### Cut / not planned

- `dsh-bridge-minor-mode` — the transient plus region/buffer send covers it.
- Further client-plugin (browser) features — no current demand.

## Deferred

- **Permission mutation from Emacs.** Revisit only with an explicit risk
  design: a confirmation matching the web UI's acknowledgement, no
  `danger-full-access`, and a README "Permissions, authentication, and failure
  bounds" update.
- **`todos` and `turnOutline` projection display.** Both are wire-visible
  observation units: `todos` would give an org-mode-native view of the
  agent's task list (header segment or side buffer); `turnOutline` would
  power imenu in the transcript buffer. Display-only polish parked behind
  the transcript candidate.
- **Headless / profile-agnostic mode.** The shipped `headless` profile is
  one-shot task mode (no listening port), so this would mean a long-lived
  custom profile (`dsh-base` + the bridge bundle) with the plugin's own
  loopback listener. Deferred because live sessions are per-process (it could
  only attach to persisted ones), process lifecycle becomes a support burden,
  and the resulting core overlaps with the ACP ecosystem.
- **`emacsclient` push for text transfer.** Pull won; push may return for the
  edit flow's file-opens.
- **Binding the routes beyond loopback.** Would need real auth, TLS, and
  origin checks.
- **Plugin-management non-goals.** Unattended auto-install (a broken bundle
  fails the whole `dsh web` boot); unattended auto-start; offering to
  *restart* a running server (would kill in-flight sessions); package.el
  hooks; reverse bundling.
- **Ask-user cancel delegation.** Cancelling from Emacs currently fails the
  ask; delegating to the browser via `next()` is a deliberate UX decision not
  yet made.

## References

DSH (in `../deepseek-harness/`), per the version pinned in
`dsh-plugin/package.json`:

- `docs/architecture.md`, `docs/cookbook/extension-cookbook.md`
- `docs/subsystems/core.md` (`Agent`), `commands.md`, `session.md`,
  `session-query.md`, `session-projection.md`, `web-server.md`, `typert.md`
- `docs/subsystems/goal.md`, `plan.md`, `permission-presets.md`, `approval.md`,
  `sandbox.md`, `feedback.md`, `token-meter.md`
- `packages/api/session-controller/src/index.ts` (`session/fork`,
  `resumeObserved`), `packages/interaction/user-questions/`,
  `packages/interaction/commands/` (`CommandDefinition`/`CommandDescriptor`,
  the `commands/list`/`execute` Remotes)
- `packages/host/open-in-app/src/catalog.ts` (editor catalog) and
  `src/shared.ts` (route shapes), `packages/client/ui-message-feedback/`,
  `ui-goal/`, `ui-plan/`, `ui-permission-presets/`
- `packages/llm/llm/src/types.ts` (user content blocks: text, image, file)
- `packages/client/tsdown.client.ts` + `packages/client/web/src/platform.ts`
  (client-bundle artifact contract)

Emacs (in `../emacs-30.2/`): `lib-src/emacsclient.c`, `lisp/server.el`,
`lisp/url/url.el`.
