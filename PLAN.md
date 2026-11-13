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

## Names

| Layer | Name |
|---|---|
| Repo / working tree | `dsh-emacs-bridge` |
| DSH plugin (npm package) | `dsh-emacs-bridge` (unscoped — `@deepseek-ai/` is reserved) |
| DSH plugin (Cordis id) | `dsh-bridge` |
| Emacs feature / file | `dsh-bridge.el` → feature `dsh-bridge`; prefix `dsh-bridge-` |

## Distribution

The DSH plugin ships through two channels from one build: the GitHub release
asset and the npm registry (`make publish` uploads the tarball `make release`
staged, so both hold the same bytes). The Emacs package is not published
separately — it rides inside the plugin tarball and is installed from the
Plugins-page card. MELPA/ELPA publication is a non-goal: their date-based
versions fight the exact-version lockstep the two halves verify. Release steps
live in AGENTS.md.

## Single-item detail inspector (implemented, optional)

The optional `dsh-bridge-extras` companion adds a separate read-only inspector
rather than expandable regions in DSH-View. The baseline's provenance/splice
contract is one reason: full reasoning, arguments, result bodies, and diff text
arrive at arbitrary sizes, so putting them in the view body would turn one splice
rule into a variable-shape body the view cannot prove. Just as importantly,
DSH-View already supplies the turn's bird's-eye view. RET on an activity line
therefore inspects only that reasoning block, logical tool invocation, or orphan
result; a second turn-wide roster would duplicate the view rather than complement
it. A tool invocation is one logical item, so its arguments, visible result, and
owned file changes belong together.

The host side keeps the same split. `/turns` stays summary-only (its newest-40
turn/newest-500 entry activity window is a view stream, not an archive).
`/details/item` takes an explicit session id, concrete shown turn, and item
selector: `seq + ord` for reasoning, or a validated per-turn `callId` for a tool
or orphan result. The response carries the item's complete reasoning,
arguments, result text, and each file diff. An item whose text exceeds
`DETAIL_FULL_LOAD_BYTES` withholds every text field on the first read and
reports `totalBytes` plus `deferred: true`; the inspector asks once and either
fetches the complete item with `full=1` or leaves it unloaded. Reads never call
`resolveTarget()`, so cold and archived sessions are not resumed.

Compaction makes turn-level visibility wrong: it can shadow one assistant
message while leaving another event in the same turn current. The fold therefore
classifies the selected reasoning block, result, and call against the current
surface seq set. Log-only tool calls have their own rule: a call is visible when
a current result settles it, or while it is unsettled in an open turn. Calls
whose only results were shadowed stay hidden rather than being resurrected from
the log.

An item response carries an observation identity: the numeric surface
`replaceGeneration` and terminal log cursor. Manual refresh deliberately
re-resolves the same item at a fresh observation and never substitutes a newest
turn or a different entry.

Per-call file changes are honest about provenance. `write` and `edit` results
carry durable `meta.diffs` fragments (and `write` a recorded `operation` and
canonical `path`); `str_replace_editor` has only a call-time presentation, so it
is `none`, not an inferred applied diff. The display diff module (`detail.ts`,
the only place that imports `diff`) renders bounded, fragment-relative text;
it never fabricates absolute hunk positions or final-newline markers, and the
inspector never offers patch application from it. The baseline changed-files
footer still just visits files: its `{path, op}` identity cannot distinguish two
calls that changed the same path, so per-call diffs are reached through their
owning tool item, whose `File:` lines are themselves file buttons. Whole-turn
workspace review (`workspaceChanges`) remains a
possible separate review UI because its recorders are live-only and cannot be
replayed cold; it is not part of the item inspector.

## New Feature Candidates

Ordered by recommended sequence, but out-of-sequence implementation is
acceptable based on user needs. Harness seams were last verified
against DSH 0.2.2-rc.1 plus post-release commits; the peer floor remains
`^0.2.0-rc.1`, while the dev dependencies are set to `^0.2.2-rc.1` and
the matching vendor set (cordis 4.1.0, schemastery 3.19.0). The two
ranges are deliberately not in lockstep — the peers are the
compatibility floor, the dev dependencies the verified build target.
The model-selection install seam spans two host generations: before
0.2.2-alpha.2 the bridge passes its selection ref, and from that release
the Agent owns the selection and ignores the extra argument. Subagent
targetability is classified only by the Session header's
`origin: 'subagent'`; the host no longer exposes runtime parent
ownership, and a historical fork's `parentSession` is not a subagent
relation.

Note: the in the versioning caret locks the minor, so `^0.2.0-rc.1` is
`>=0.2.0-rc.1 <0.3.0` and admits every 0.2 prerelease while refusing
the next minor line. The harness does not warn about a mismatch:
`evaluatePluginCompatibility` makes every `@deepseek-ai/dsh-*` peer a
hard `incompatible-version` refusal at install or enable, exemptible
only per exact version.

### 1. In-flight reasoning visibility

- **Problem** — DSH-View activity lines and the item inspector only see
  reasoning after the step's `assistant/message` commits. The web UI shows
  thinking text while it is still streaming, so a long reasoning block is
  invisible in Emacs until it finishes.
- **Why it is not a rendering tweak** — the activity fold walks committed
  session events and only recognizes `assistant/message`
  (`activityRelevantEvent`/`turnActivity`); `/details/item` selects reasoning
  blocks from committed events and their surface seqs. Live reasoning arrives
  as the host's process-local `agent/assistant-stream` frames; the bridge does
  not consume them, and the log-only `assistant/attempt` event is appended only
  at settlement, so neither path can serve a block in flight.
- **Shape** — host-side, listen to `agent/assistant-stream` per live agent and
  keep bounded per-session/per-step in-flight reasoning state (attempt id,
  revision, accumulated text, first-line summary; reset on replacement, drop on
  end/abort). Publish a summary-only SSE nudge so DSH-View can draw an in-flight
  thinking line; keep full text off SSE, as today. Expose the accumulated block
  through an explicit read-only, bearer-authenticated observation/route (extend
  `/details/item` with a live in-flight selector, or add a sibling route) with
  the same size-probe/full-load bounds. The inspector fetches it only
  when the user opens or refreshes that item.
- **Emacs** — stable identity for the in-flight block; incremental activity-line
  update; partial Markdown fontification; refresh until the committed block
  replaces it without duplication. Cold/archived sessions keep today's
  committed-only behavior.
- **Privacy and bounds** — in-flight reasoning is raw model output, so the read
  route must preserve the inspector's explicit-disclosure rules; update
  README's "Security Matters", the route inventory, and the `logic.ts` bounds.
  Cap accumulated bytes per attempt and live attempts per session, and drop state
  when the agent/turn ends.
- **Acceptance** — a mock-LLM scripted reasoning stream surfaces a thinking line
  in DSH-View before the step settles; the inspector can open that line and
  paginate its text; on completion the transient item hands off to the committed
  block with no duplicate line; stale/aborted attempts disappear.

### 2. Permission mode (display only, implemented)

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
