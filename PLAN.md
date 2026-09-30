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
DSH 0.2.0-rc.2 (the candidate published as `next`). rc.2 moved nothing
the bridge folds: every package it compiles against changed only its
version field and internal pins, except `dsh-user-questions` and
`dsh-tool-ask-user`, which gained an *opt-in* timed ask — a foreground
wait that continues the turn with `{pending: true}` at its deadline,
plus a `userQuestions` projection and a `user-question-reply` message
source. The web bundle mounts `tool-ask-user` with no config, so `mode`
stays the `legacy` blocking tool the bridge answers; and the bridge
already settles its wait from the request signal, so even the timed path
releases the turn at the deadline. The peer floor stays `^0.2.0-rc.1`,
which rc.2 satisfies: an installed 0.15.1 loads on rc.2 with no
reinstall, and narrowing the floor to rc.2 would refuse a runtime the
identical code serves. The dev dependencies do move to `^0.2.0-rc.2`
(what the build compiles and type-checks against), so the two ranges are
deliberately not in lockstep — the peers are the compatibility floor,
the dev dependencies the verified build target.

The floor is a caret deliberately: on 0.x a caret locks the minor, so
`^0.2.0-rc.1` is `>=0.2.0-rc.1 <0.3.0` and admits every 0.2 prerelease
while refusing the next minor line. The harness does not warn about a
mismatch: `evaluatePluginCompatibility` makes every `@deepseek-ai/dsh-*`
peer a hard `incompatible-version` refusal at install or enable,
exemptible only per exact version. That refusal is the sole mechanical
signal that the host-side shapes the bridge folds — those the three
runtime imports reach and those it only types against — were re-checked,
so opening a new harness minor line owes a floor bump and an integration
run.

### 1. Permission mode (display only, implemented)

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

### 2. Queue visibility and queued-item management

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

### 3. Compact

- To be scoped out: implement the functionality of the /compact
  command in the web interface.

### 4. Ratings/Feedback

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

### 5. `/emacs edit` flow

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

### 6. Cross-session search

- **Route** — `GET /dsh-bridge/search?q=`: full-text over live sessions plus
  cold logs read via `sessionPersistence.open(id, 'read')` (never resuming).
  Cold logs are read whole, so bound the cost: a `sessionId` scope parameter
  or a most-recent-N cap, with truncation reported.
- **UX** — an occur/grep-style results buffer; `RET` jumps to that session's
  transcript at the matching turn.

### 7. Transcript buffer

A continuous, read-only rendering of a whole session (`/prompts` + `/turns`
already carry the data), with turn separators and the existing follow/refresh
machinery. This is the natural home for the turn actions below; no new host
seam required.

### 8. Deadline-aware ask-user questions

- **Seam** — 0.2.0-rc.2 lets `tool-ask-user` run in `mode: 'timed'`: the ask
  carries `wait: {callId, timed: true}`, the client's countdown decides the
  first settlement, and the deadline continues the turn with
  `{pending: true, callId}`. A late answer arrives as a steered
  `user-question-reply` message that closes the question and records its
  answers, and the `userQuestions` projection exposes the still-answerable
  (`open`) and settled calls to every client.
- **What works today** — the bridge's answerer settles from the request
  signal, so the turn is released on time, and the default profile never
  enters this path (`mode` defaults to `legacy`).
- **Gap to settle** — the bridge answers from its own pending entry and
  banners the question resolved on abort, so after a deadline it neither
  shows the remaining wait nor offers the still-`open` call that the
  projection now reports. Decide whether Emacs surfaces the countdown, or
  re-derives answerable questions from `userQuestions` so a late answer can
  still come from Emacs. Opt-in and rare, so lowest priority.

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
