# Plan and goal — design

Candidate 1 of [PLAN.md](PLAN.md). Harness seams were **read** from the
sibling source tree (`dsh-v0.1.5-rc.2-139`), but the resolved peer floor is
`^0.1.6-alpha.1` with installed dependencies at `0.1.6-alpha.2`; the tree
predates the floor, so Stage A begins by re-verifying every seam against the
resolved version (A0). Nothing below is authoritative until that check passes.

In the web UI both are slash-command surface (`/plan`, `/goal`) over two
services — the slash handlers are thin text wrappers, so Emacs follows its
own conventions and loses nothing: ordinary interactive commands, menu-bar
entries, minibuffer reads. Plan and goal are **orthogonal**: the harness has
no mutual exclusion (different services, projections, and lifecycles; both
may be active at once), so they get separate commands and separate header
cells, not a combined "mode". Plan-review approval already works:
`exit_plan_mode`'s question arrives over the `user-questions/request`
waterfall the bridge already claims, and its `plan-review` intent is
presentation-only (the DSH-Question buffer already fontifies the plan
detail). There is no permissions/approval interplay — plan mode is prompt
guidance only.

## Staging principle

Two stages, split so that **`make build && make test` is green at the end
of each** and Stage B starts from a clean, tested display layer. Stage A is
read-only (report sections, SSE push, Emacs headers/describe/caches) and adds
no routes, commands, menus, or keybindings. Stage B adds every mutation
surface (routes, commands, menus, dispatcher entries). Nothing in Stage A
references a Stage B symbol.

## Access

No new keybindings for now (will decide later). Stage A adds no commands.
Stage B adds autoloaded `M-x` commands and their entries in the mode menus
(view, prompt, sessions, describe) and in the `dsh-bridge` dispatcher.
Dispatcher entries do need dispatcher-local transient keys; those are not
mode keybindings, and the dispatcher docstring's key summary (and README's
dispatcher key list) is updated with them.

## Stage A — display (read-only; gate: `make build && make test`)

### A0 — re-verify the seams (do first)

Against the resolved (installed/pinned) harness version, confirm at minimum:

- `planMode.get(agent)` returns `{active, pending?}` and
  `planMode.set(agent, active)` returns
  `committed | queued | cancelled | noop`; the `plan` projection's wire view
  is `{active, pending}`; the projection key is process-global while the
  controller instance is entry-local.
- `goals.get(agent)` returns a `GoalView | undefined` whose `activation`
  (`'armed' | 'disarmed'`) is absent from the `goal` projection; the
  `GoalError` code set and the `goal/activation-changed` payload
  (`{sessionId, goal?: {id, revision, activation}}`).
- `agentPresets.serviceFor(agent, name)` resolves a preset-isolate service;
  the web overlay disables the host `plan-mode` row and the standard preset
  mounts it under `isolate: {planMode: true}`.
- Cold observations still fold the registered `plan`/`goal` projections
  through `sessionQuery.observeSession`.

Record the verified version in the code comments naming each seam.

### Reads

- **Report sections.** The `plan` projection (`{active, pending}`) and the
  `goal` projection (`{goal: {...}, roundsStarted, createdAt, updatedAt}`,
  null before first create / after clear) are wire-visible and fold for cold
  sessions, so extend `SessionReport` with `plan` and `goal` sections in
  `sessionReport`. No new route, no resume.
  - **`plan`** is `{active: boolean, pending?: boolean, queued?: boolean}`:
    - `active` — the logged plan state.
    - `pending` — the **wanted state** (direction) when a live read supplies
      one: `true` = a toggle-on is queued, `false` = a toggle-off is queued.
    - `queued` — `true` when a change is pending but the **direction is
      unknown**: the projection-only case (the projection's `pending` is
      `wanted ≠ active`).
    - The projection alone yields `{active, queued: pending}`; the live
      refinement (below) replaces that. A section with neither `pending` nor
      `queued` means "no pending change".
  - **`goal`** is the projection object plus an optional
    `activation: 'armed' | 'disarmed'` slot. **Use the harness's own string,
    not a boolean**: the two Emacs JSON decoders disagree
    (`dsh-bridge--parse-json-body` maps `false` to `nil`; the SSE decoder
    leaves it as `:false`), so a boolean cannot carry the "unknown vs
    disarmed" distinction this feature requires, while a string is
    unambiguous and absent stays nil.
  - *Shape rules.* `plan` is never legitimately null, so it simply joins the
    `strict` set. Only `goal` needs a special rule: a null `goal` is a
    legitimate state (no goal) — null is not `missing` — while a
    present-but-malformed value must become null **and** earn a `missing`
    entry. `reportPermissions` is not the template (its malformed case does
    not join `missing`); add an explicit malformed check for `goal`.
  - *Live refinement.* A pure `logic.ts` function,
    `refinePlanGoal(report, live)`, merges the wiring-read live facts into a
    copy of the durable report; the wiring does only the service reads and
    never builds report structure. `live` is
    `{plan?: PlanLiveRead | null, goalActivation?: 'armed' | 'disarmed'}`,
    with `PlanLiveRead = {active: boolean, pending?: boolean}`:
    - `plan` undefined → projection only (cold session, or no
      `agentPresets` service).
    - `plan` null → the live agent's preset mounts no `planMode`
      controller → set `plan = null` and name `plan` missing (dedup).
    - `plan` present → set `active`; when `pending` is defined, set
      `pending` and clear `queued`; otherwise retain the projection's
      `queued` (a logged-but-uncommitted `/plan` still reads as a
      direction-less queue while live).
    - `goalActivation` present → set `goal.activation`; absent → leave it
      absent.
    Keeping this pure is what lets Stage A's live-refinement tests run under
    Vitest without booting a host, and it honors `logic.ts`'s no-runtime
    rule.
  - *Wiring.* In `readSessionReport`, after the durable report is built,
    read the live facts **only when `report.live`**: `ctx.agents.get(id)`;
    `agentPresets.serviceFor(agent, 'planMode')` (absent service → leave
    `plan` undefined; controller absent → `plan: null`; else
    `controller.get(agent)`); `ctx.goals?.get(agent)?.activation`. Catch
    every read and degrade; neither may fail the report. The merge must run
    for both the `sessionQuery` and `fallbackSessionReport` paths, since
    both reach `readSessionReport`.
  - *Availability.* The plan projection key is **process-global**
    (`sessionProjections.register` keeps one registry and `snapshot`
    enumerates every registered wire key for every session), so while *any*
    mounted preset has plan mode, *every* session gets a `plan` key. Rules:
    - key absent → no plan-mode controller anywhere in the process → name
      `plan` in `missing`.
    - key present + live agent + controller absent → this session's preset
      mounts none → `plan: null`, `missing 'plan'`, definitively.
      (Registration is coupled to the controller's constructor, so there is
      no supported "key absent but service present" state; do not invent
      one.)
    - key present + cold → the bridge does not resume for display, so
      availability is unknowable: carry the projection value, do **not**
      name `missing`; the Stage B 501 is the backstop.
    - key present + live agent + controller present → live refinement, not
      missing.
  - Goal is host-plane and registered under `dsh web`; an absent goal
    service also removes the projection key, so `missing 'goal'` falls out
    of the same rule with no special casing.

### Push

- Extend the existing `sessionProjections.onChanged` feed (the
  `contextPressure` gate in `index.ts`) with `plan` and `goal` keys; new
  `planChangedMessage` / `goalChangedMessage` /
  `goalActivationChangedMessage` constructors in `logic.ts` with the
  payload documented on the constructor per policy:
  - **plan frame** — the full live-refined `{active, pending?, queued?}`.
    Skip a frame whose refined value is unchanged (the plan projection builds
    a fresh view object, so it otherwise fires on state the bridge does not
    surface); compare a serialized key, not object identity.
  - **goal frame** — the full live-refined goal object, including the
    `activation` slot when known (absent otherwise), or `null` to clear.
  - **activation frame** — from `goal/activation-changed`,
    `{sessionId, activation?, goalId?, revision?}`. When the event carries
    no `goal` (a clear with no current goal), emit **no** frame: the
    durable goal frame on the same commit clears the cache entry. When it
    does, include `goalId`/`revision` so the Emacs arm can reject a stale
    frame.
- The feed reads only the key it is emitting (`planMode.get` touches the
  `plan` projection, `goals.get` touches `goal`), so it is safe to call
  from `onChanged` without re-entering the registry for a sibling key. Do
  not read the sibling key there.
- Both feeds filter subagent children like the context arm. The activation
  event is either declared structurally or pulled in by a type-only
  devDependency, following the user-questions/approval pattern (never a
  runtime import).

### UX (Emacs) — display only

- *Caches and seeding* — two id-keyed global alists
  `dsh-bridge--session-plan` / `dsh-bridge--session-goal`, mirroring
  `dsh-bridge--session-context` (read-through display caches; advisory
  only, never mutation targets). A `dsh-bridge--fetch-plan-goal` helper
  GETs `/session` once per uncached session (the report now carries both
  sections) and seeds both in one request. **Bind `dsh-bridge-timeout` to
  `dsh-bridge-describe-timeout` for that request**: the target may be cold
  and `/session` folds its whole persisted log, which is exactly why
  `dsh-bridge-describe-timeout` exists. Wire it into the prompt-open
  metadata refresh (`dsh-bridge--refresh-prompt-metadata`) and the view-open
  path; the view-open seed is new work (today the only metadata seed is
  `dsh-bridge-set-prompt-session`). A failed seed caches nothing, so the
  next open retries, bounded by the describe timeout. Unknown state
  (`activation` absent, both pending bits absent) renders as nothing, never
  as "armed"/"not pending".
- *SSE arms* — `cond` arms in `dsh-bridge--notification-handle-events` for
  the new frame kinds (final kind strings live on the constructors in
  `logic.ts` per policy), mirroring the `context` arm: shape-check the
  payload, replace the session's cache entry wholesale, then
  `dsh-bridge--refresh-view-headers`, `force-mode-line-update`, and
  `dsh-bridge--describe-maybe-refresh`. A durable goal frame and an
  activation frame update different slots: an activation frame updates only
  the `activation` slot, and only when its `goalId`/`revision` match the
  cached entry; a durable goal frame never clears a known activation and
  vice versa; an activation frame with no `activation` is ignored.
- *Header cells* — appended to both header-line joins: view
  `… · <time>[ · plan][ · goal][ · await]`, prompt `… · <model>[ ·
  <ctx%>][ · plan][ · goal]` (ahead of the sent marker, which stays outside
  the join).
  - The plan cell is narrow: `plan` when active with no pending;
    `plan (queued on)` when `pending` is true; `plan (queued off)` when
    `pending` is false; `plan (change queued)` when only `queued` is
    set (direction unknown); else nothing. (The describe row names the
    current state explicitly as well: `on (queued off)`, `off (queued
    on)`, `<state> (change queued)`.)
  - The goal cell is flexible: `<phase>: <objective>` (e.g.
    `active: fix the flaky test`), the objective run through
    `dsh-bridge--header-text`, so width pressure truncates it with `…`
    rather than pushing workspace/model off the line. `(disarmed)` rides as
    the cell's untruncatable suffix **only for `phase = active` and
    `activation = disarmed`** (`active: fix the build (disarmed)`);
    `paused`/`blocked` already name their state. Nothing when the goal is
    absent or `complete` (GoalBar parity). Plain text, no new faces.
- *describe-session* — a `Plan mode` row in the identity block, next to
  `Permissions`, rendering `on` / `off` / `on (queued off)` /
  `off (queued on)` / `<state> (change queued)`, and `—` when the
  report names `plan` missing. This is the first consumer of the report's
  `missing` array (describe-session reads no such array today). A `Goal`
  section (own `dsh-bridge--describe-section`) after `Context`, shown
  whenever a goal exists — including `complete` (the report *is* the show;
  only the header hides complete): Objective (full, never truncated), Phase,
  Rounds `n/max`, Blocked only when `blockedReason` is set, Armed only
  when `activation` is present, and Created/Updated via
  `dsh-bridge--format-time`. **No action buttons in Stage A.**
- *Untouched* — DSH-Sessions gets no new columns. Stage A adds no menus,
  commands, keybindings, or tool-bar items; those are all mutations and land
  in Stage B.

### Tests (Stage A gate)

- Vitest: `session-report.spec.ts` section cases (present, absent →
  `missing`, malformed → null + `missing`, legitimate goal null → not
  `missing`) plus `refinePlanGoal` cases (`plan` undefined/null/read with
  and without `pending`, `goalActivation` present/absent, missing-array
  dedup); `logic.spec.ts` frame-constructor specs and the activation
  frame's identity/clear shape.
- ERT: header segments (plan / queued on / queued off / direction-less /
  hidden; goal phase + objective, `(disarmed)` only on an active disarmed
  goal, hidden when absent or `complete`, truncation under narrow widths);
  describe rows (missing-section, no-live-read, complete-goal,
  direction-less-queued, and the `missing`-consumer cases); seed-fetch
  wiring (read-through, view-open, describe-timeout binding); SSE dispatch
  arms (durable vs activation, stale id/revision ignored, no-activation
  ignored).
- `make build && make test` green before Stage B starts.

## Stage B — mutations (gate: `make build && make test`)

### Plan toggle

- `POST /dsh-bridge/plan-mode {active}` calling
  `ctx.agentPresets.serviceFor(agent, 'planMode')` (add `serviceFor` to the
  bridge's `AgentPresetsService` face). On `dsh web` the host `planMode`
  row is disabled and the controller lives in the preset's entry-local
  isolate realm, so `ctx.get('planMode')` is undefined and `serviceFor` is
  the only handle. Note that `serviceForAgent` is documented as *read*
  addressing for a caller that already holds the agent; using it for
  `.set()` is a deliberate internal-coupling decision, not a documented
  sanction. The command channel is not an alternative: it both turns plan on
  (optionally with a steer message) and off, and appends
  `command/run`/`command/done` lifecycle logging — exactly what we do
  **not** want (`commands.execute('/plan off')` stays rejected). If the
  harness grows a mutation seam, move to it.
- Tolerate `undefined` — a session whose preset mounts no controller answers
  a clear 501, never a fake success. `set` outcome passthrough:
  `committed` / `queued` / `cancelled` / `noop` (`set` between turns
  appends `plan/mode` now; mid-turn it queues and commits at the next
  accepted pre-step). Toggle off the **effective wanted state**
  (`pending ?? active`) so a second press cancels rather than re-queueing,
  and on `noop` distinguish "already there" from "an opposite change is
  pending", as the harness's own `/plan off` handler does.

### Goal lifecycle

- Routes `POST /dsh-bridge/goal/{set,pause,resume,clear}` over `ctx.goals`
  with revision CAS (`GoalRef` read from the live `get(agent)` view at
  request time — web parity: "the RPC's CAS is the guard"). Call the service
  host-side with the live agent (via `resolveTarget`) rather than the
  Remote, whose `resolveAgent` resumes implicitly.
- `set` is the merged create-or-edit and accepts
  `{objective, maxGoalRounds?}`: it reads the live view and calls `create`
  when there is no goal or the goal is `complete` (a racing create still
  surfaces `GOAL_ALREADY_EXISTS`), else `edit` with the current ref, which
  keeps phase and activation but may replace the objective and/or the round
  cap. The optional cap is what lets an exhausted goal be made resumable;
  the Emacs command exposes it behind a prefix argument.
- `pause` stops an active goal, `resume` accepts active-but-disarmed,
  paused, and blocked while rounds remain, and `clear` takes the current ref
  like the others and returns the tombstone (`goal/src/index.ts` builds it
  as `current.revision + 1` after the CAS check). `complete` and `block`
  stay model/host-owned (no slash verb, no web-UI verb; add only if demand
  appears).
- *Error mapping.* The service throws `HarnessError`/`GoalError` with a
  `.code`, not a Typert `RemoteError` (the bridge's `isRemoteErrorCode`
  marker will not match), so add a direct `.code` duck-type: stale revision
  (`GOAL_STALE_REVISION`) and invalid transition / already-exists
  (`GOAL_INVALID_TRANSITION`, `GOAL_ALREADY_EXISTS`) → 409; no current goal
  (`GOAL_NOT_FOUND`) → 404 — only pause/resume/clear can raise it, since
  `set` creates instead; invalid input (`GOAL_INVALID_OBJECTIVE`,
  `GOAL_INVALID_MAX_ROUNDS`, `GOAL_INVALID_BLOCK_REASON`, and
  `GOAL_INVALID_EDIT`) → 400; agent not live (`GOAL_AGENT_NOT_LIVE`) → 409;
  absent service → 501. The body carries the code so Emacs can word the
  revision-conflict hint.
- *Targets* follow the existing mutation semantics (`resolveTarget`, cold
  sessions resumed on demand, 404/409/413 preserved).
- *Disarmed note.* A freshly resumed session's active goal sits **disarmed**
  until `dsh-bridge-resume-goal` rearms it. Scope that note to the goal
  commands: `dsh-bridge--resume-session` / `dsh-bridge--ensure-session-live`
  are shared by open/reply/visit, so fetching the report and appending a note
  there would add a `/session` round-trip and a goal message to every
  resume. Have each goal command fetch the report after the POST and append
  the note when the result shows an active, disarmed goal.

### Emacs commands

- All `;;;###autoload`, `M-x`-callable, and in the Stage B menus; no
  mode-local keys. Names are verb-first (`dsh-bridge-toggle-plan-mode`,
  `dsh-bridge-set-goal`, `dsh-bridge-pause-goal`,
  `dsh-bridge-resume-goal`, `dsh-bridge-clear-goal`), matching both the
  usual Emacs convention and this file's existing commands. Targets via
  `dsh-bridge--interaction-session` (view: shown session; prompt: effective
  target; sessions list: row at point; describe: the shown session, via the
  arm added below), refusing with a `user-error` when nil ("no session at
  point; run from a DSH buffer or the session list") — never the
  display-only last-active fallbacks. This follows `dsh-bridge-stop-session`
  and `dsh-bridge-answer`; the `user-error` is a deliberate divergence from
  `dsh-bridge-stop-session`'s `message` on a nil target — a failed mutation
  is an error, not information. It does **not** copy
  `dsh-bridge-answer`'s single-pending-session fallback. AGENTS.md's
  "mutations resolve with `dsh-bridge--effective-session`" wording should
  be reconciled with that existing precedent in the same change.
  - `dsh-bridge-toggle-plan-mode` — as in the plan-toggle bullet above:
    direction from a fresh `/session` read at invocation (never the
    advisory cache), toggling `pending ?? active`; a numeric prefix
    argument sets explicitly (positive enables, otherwise disables). A
    missing section (preset without plan mode) is reported and nothing is
    sent; a queued outcome is reported as "applies from the next step".
  - `dsh-bridge-set-goal` — create or edit the goal: `read-string` with
    the current objective as the default when a goal exists. RET on the
    unchanged default skips the POST and reports "goal unchanged" (an
    `edit` would bump the revision for no-op). Empty input is rejected at
    the minibuffer read (re-prompt; `C-g` cancels). With a prefix argument,
    also read `maxGoalRounds` (default: the current cap, or the deployment
    default when creating). The host decides create vs edit from the live
    view, so a `complete` goal is replaced rather than edited; the success
    message names which happened.
  - `dsh-bridge-pause-goal` / `dsh-bridge-resume-goal` — immediate POST,
    no minibuffer. `dsh-bridge-resume-goal` doubles as the rearm command for
    a restored-disarmed goal, so it must stay discoverable next to wherever
    `(disarmed)` shows (header suffix, describe `Armed` row, menu).
  - `dsh-bridge-clear-goal` — `y-or-n-p` naming the objective.
  - *Wordings and errors* — set → "goal set: <objective>" when created and
    "goal updated: <objective>" when edited (the route reports the
    operation); pause → "goal paused"; resume → "goal resumed"; clear →
    "goal cleared". 409s show the `GoalError` text plus, for revision
    conflicts, a trailing hint to re-check with
    `dsh-bridge-describe-session`.
  - *Post-mutation refresh* — mirror `dsh-bridge--select-model-apply`: on
    200, force-refresh the plan/goal cache from `/session` rather than
    trusting SSE frame timing, so the header and the success message never
    disagree. For a queued plan toggle the `/session` fetch must reflect
    Stage A's live `pending`, not the projection alone.

### Menus, buttons, dispatcher

- For each mode's "DSH Bridge" top-level menu, Plan mode gets an entry with a
  toggle checkbox; Goal gets a submenu containing "Set Goal", "Clear Goal",
  and "Goal Active" with checkbox (toggling arms/pauses). Neither checkbox
  fabricates state: the plan entry is shaded when the report names `plan`
  missing or when no state is cached (the seed failed) and, for a cold
  session, is also shaded — no pending intent can exist off-process; "Goal
  Active" is shaded when no goal is defined, when `phase` is `complete`
  (`resume` rejects it), or when activation is unknown (always for a cold
  session). An unchecked box would otherwise assert "off"/"disarmed", which
  the unknown-state discipline forbids. Leave these out of the Tools→DSH
  Bridge global menu: they resolve via `dsh-bridge--interaction-session` and
  refuse with a `user-error` outside DSH buffers, so global-menu entries
  would mostly error (`dsh-bridge-stop-session` sits there only because it
  predates the `user-error` convention).
- describe-session gets `[edit objective] [pause|resume] [clear]` beside the
  objective via `dsh-bridge--describe-button` (the first invokes
  `dsh-bridge-set-goal`). Those buttons call their function with no
  arguments and `dsh-bridge--interaction-session` has no describe-mode arm
  today, so add one returning `dsh-bridge--describe-session` — the same arm
  `dsh-bridge--effective-session` already carries. Without it the buttons
  would `user-error` from the very buffer that presents them. (This also
  lets `dsh-bridge-answer` target the described session; that widening is
  intended.)
- Dispatcher: add the plan/goal verbs to
  `dsh-bridge--verb-suffixes`/`dsh-bridge--dispatcher-layout` with
  dispatcher-local keys; update the dispatcher docstring's key summary and
  README's dispatcher key list.
- No new mode-local keymaps or tool-bar items.

### Tests (Stage B gate)

- Vitest: route logic (which service call each outcome selects, the
  create-vs-edit and complete→replace branches in `/goal/set`, the optional
  `maxGoalRounds`, CAS-failure mapping, `GoalError.code` → status,
  degraded `serviceFor`).
- ERT: command marshaling (route paths and request payloads), the nil-target
  refusal, confirmation wording (`y-or-n-p` text, queued-outcome and
  disarmed notes), 409 message text with the revision-conflict hint, the
  created-vs-updated success wording, the unchanged-objective no-POST case,
  the toggle's fresh-read direction and prefix-argument behavior, the
  empty-objective re-prompt, the prefix `maxGoalRounds` read, the menu
  shading rules (missing plan section, unknown activation, complete goal),
  the describe buttons, and the menu/dispatcher wiring.
- `make build && make test` green.

### Repo hygiene

- Update the `/dsh-bridge/*` route inventory in the header of
  `dsh-plugin/src/index.ts` for the five new routes (Stage A already updates
  the `/session` response description and the new frame kinds). Update
  README's command/menu/dispatcher documentation. Run/update
  `make integration-test` (the new routes ride the `ctx.goals` and
  `agentPresets.serviceFor` seams). Bump the version in all three places per
  AGENTS.md if the feature warrants it.
