# dsh-emacs — project plan

A two-way bridge between an Emacs session and a running DeepSeek Harness (`dsh
web`) session. The DSH text window is small and typing-poor; Emacs is a full
editor but lacks DSH's live agent. The bridge moves text in both directions
over loopback HTTP without window-switching and copy-paste.

Usage is documented in [README.md](README.md); the architecture rules and the
harness seams the plugin depends on are in [AGENTS.md](AGENTS.md). This file
is forward-looking: settled decisions, candidates, and non-goals. The harness
is pre-release with no compatibility promise; AGENTS.md owns the version-bump
re-verification checklist.

## Names (locked)

| Layer | Name |
|---|---|
| Repo / working tree | `dsh-emacs-bridge` |
| DSH plugin (npm package) | `dsh-emacs-bridge` (unscoped — `@deepseek-ai/` is reserved) |
| DSH plugin (Cordis id) | `dsh-bridge` |
| Emacs feature / file | `dsh-bridge.el` → feature `dsh-bridge`; optional companion `dsh-bridge-install.el` → feature `dsh-bridge-install`; prefix `dsh-bridge-` |

## Candidates

Ordered by recommended sequence, but out-of-sequence implementation is
acceptable based on user needs. Harness seams were verified against
DSH 0.1.7-rc.1; the peer floor in `dsh-plugin/package.json` is pinned
to match. rc.1 moved no host seam the bridge folds, but its faster
first-reply timing exposed two DSH-View races that the Emacs client now
closes: a `replies-changed` frame that arrives while the blocking send
is still on the wire — before the view and its turns-cache entry exist —
is replayed instead of dropped, and a slower `/turns` reply that lands
after a fresher one can no longer downgrade that turn's cached record.
The client bundle also names the size-neutral `IconCheckOutlineRegular`,
the rename that replaced the numeric icon export.

### 1. Plan and goal

In the web UI both are slash-command surface (`/plan`, `/goal`) over two
services — the slash handlers are thin text wrappers, so Emacs follows its
own conventions (no electric slash) and loses nothing: ordinary interactive
commands, dispatcher/menu/keymap entries, minibuffer reads. Plan-review
approval already works over the `user-questions/request` waterfall the
bridge already claims. Two stages: display first (`plan`/`goal` projections
folded into `SessionReport`, SSE push, header + `describe-session`
segments), then mutations (`planMode` toggle via
`agentPresets.serviceFor(agent, 'planMode')`; revision-CAS goal lifecycle
over `ctx.goals`).

### 2. Permission mode (display only)

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
risk acknowledgement. See [Deferred](#deferred).  Answering an on-demand
`approval/request` (a one-shot sandbox escalation or hook-gated tool ask) is
a separate, implemented feature.

### 3. Queue visibility and queued-item management

- **Problem** — a prompt sent from Emacs while a turn runs is queued
  host-side and invisible in Emacs; there is no way to retract, edit, or
  steer it.
- **Shapes** — two options, not mutually exclusive: (a) surface the host's
  `inbox` session projection (already wire-visible) as a queue list with
  per-item steer/remove plus a header count, mirroring the web UI's
  QueueDock; (b) a minimal retraction path — return the deposited message id
  from `/send` and expose a single "steer the last queued prompt" command via
  `sessionController.updateQueue`.  Option (a) is the real fix; (b) is a
  cheaper stepping stone.
- **Seed** — the read half already exists: `GET /dsh-bridge/sessions/queue`
  reports per-session queued/steering counts (added for the stop
  confirmation).
- **Interaction to settle** — after a stop, a previously queued prompt starts
  a new turn immediately (`cancel` uses `keepInbox: true`), which can make a
  stop look ineffective; the stop confirmation now warns when that is about
  to happen.

### 4. Compact

- To be scoped out: implement the functionality of the /compact
  command in the web interface.

### 5. Ratings/Feedback

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

### 6. `/emacs edit` flow

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

### 7. Cross-session search

- **Route** — `GET /dsh-bridge/search?q=`: full-text over live sessions plus
  cold logs read via `sessionPersistence.open(id, 'read')` (never resuming).
  Cold logs are read whole, so bound the cost: a `sessionId` scope parameter
  or a most-recent-N cap, with truncation reported.
- **UX** — an occur/grep-style results buffer; `RET` jumps to that session's
  transcript at the matching turn.

### 8. Transcript buffer

A continuous, read-only rendering of a whole session (`/prompts` + `/turns`
already carry the data), with turn separators and the existing follow/refresh
machinery. This is the natural home for the turn actions below; no new host
seam required.

## Deferred

- **Permission mutation from Emacs.** Changing a session's standing permission
  preset (or approval policy) from Emacs remains deferred: revisit only with an
  explicit risk design — a confirmation matching the web UI's acknowledgement,
  and a README "Permissions, authentication, and failure bounds" update.  This
  is deliberately distinct from *answering an on-demand `approval/request`*:
  an approval answer is a one-shot grant for the single operation it names 
  (`allowed-once`, `rejected`, or `cancelled`), never a policy change, and
  the harness still enforces a standing `approval: never` before any prompt,
  so Emacs grants nothing the web UI's own panel could not.
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
  `ui-goal/`, `ui-plan/`
- `packages/plan/plan-mode/src/index.ts` (`PlanModeController`, `/plan`,
  `plan/mode` event), `packages/goal/goal/src/` (`GoalService`, the `goal`
  projection fold, `GoalError` codes), `packages/goal/command-goal/src/`
  (`/goal` grammar), `ui-permission-presets/`
- `packages/llm/llm/src/types.ts` (user content blocks: text, image, file)
- `packages/client/tsdown.client.ts` + `packages/client/web/src/platform.ts`
  (client-bundle artifact contract)

Emacs (in `../emacs-30.2/`): `lib-src/emacsclient.c`, `lisp/server.el`,
`lisp/url/url.el`.
