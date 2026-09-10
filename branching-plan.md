# Branching plan — fork a turn into a new conversation

Implementation plan for **PLAN.md candidate 2** ("Branch a turn into a new
conversation"). Investigation only: no source has been changed. This document
is the spec the change will be built against.

Target harness: DSH `0.1.5-alpha.2` (the peer floor in
`dsh-plugin/package.json` still reads `^0.1.5-alpha.1`, which admits it; the
integration suite passes against alpha.2 — see the seam notes below).

## Goal

From a DSH-View buffer, branch the **shown turn** into a new session: fork the
source session's completed-turn prefix, then open the child's conversation and
its prompt. Include the host route and `/turns` support the command needs, plus
the test and documentation work.

### Non-goals

- No transcript buffer (candidate 3). The command lives in DSH-View only.
- No ratings (candidate 4). The `/turns` record gains only `endSeq`, **not**
  the closing `messageId`.
- No branch from the sessions list or a dispatcher verb in this phase. The
  dispatcher is session-scoped and has no shown turn; a session-scoped "fork
  last completed turn" is a possible follow-up, deliberately deferred.
- No model carry-over and no auto-title (decisions below).

## Decisions (user-confirmed)

| # | Decision | Choice |
|---|---|---|
| 1 | Fork seam | `ctx.get('sessionController').fork(...)` — the native Cordis service, not `rpcCall` |
| 2 | Child model | Web parity: the child starts on the host **default** model; no `/model` re-selection |
| 3 | Child title | Leave untitled (the harness does not title a fork; the web UI titles client-side and we will not replicate it) |
| 4 | After fork | Open the child's DSH-View in following state **and** its DSH-Prompt below |
| 5 | Open shown turn | Refuse always; a turn with no `endSeq` cannot be a fork anchor (no `C-u` escape) |

## Harness facts (verified in `../deepseek-harness/`)

Verified against the reference checkout at `dsh-v0.1.5-rc.1-7-g2377c272a8` —
**newer than the alpha.2 target**, not the tag itself. The seam and its
semantics predate rc.1, but re-check the fork implementation at the
`dsh-v0.1.5-alpha.2` tag before building (see Confirm at implementation
time).

- **Service.** `@deepseek-ai/dsh-api-session-controller` registers the Cordis
  service `sessionController` (`super(ctx, 'sessionController', { namespace:
  'session' })`) and is mounted by the `web` profile
  (`packages/bundle/web-app/cordis.patch.yml`, row `session-controller`). Its
  `fork(request)` delegates to `commands.fork`.
- **Request/response.** `SessionForkRequest = { sessionId: SessionId; atSeq?:
  number }`; `SessionForkValue = { sessionId: SessionId }`
  (`packages/api/session-controller/src/types.ts`).
- **Semantics** (`packages/api/session-controller/src/commands.ts` `fork`):
  - Observes the source with `ctx.sessionQuery.observeSession` — **cold-safe,
    never resumes the source**.
  - Boundary = the first `turn/end` with `seq >= atSeq`; if none and (`atSeq`
    omitted or `atSeq > lastSeq`), the **last** `turn/end`; otherwise
    `session/fork-unavailable`.
  - With `atSeq` omitted a fork succeeds even mid-turn, cutting at the last
    completed turn (this is the behavior we will *not* expose: decision 5).
  - Seed = events up to `turn/end.seq + 1`, advanced to the next `turn/start`.
  - Child meta: `cwd`, `parentSession = source.id`, `isSeeded: true`, the
    source's **preset** (`composeAgent(presetForObservation(source))`).
  - Child agent options come from `agentDefaultModel.currentSelection()` —
    i.e. the **default model**, not the source's (decision 2 confirms parity).
  - No title service call (decision 3).
  - The child is attached to the source's workspace when one resolves; if that
    attach fails the error is `session/workspace-attach-failed` **after** the
    child was created (`details` carries `sessionId`/`workspaceId`).
  - Error codes: `gateway/bad-request`, `session/not-found`,
    `session/fork-unavailable`, `session/workspace-attach-failed`,
    `gateway/internal`.
- **Error shape.** `RemoteError` (`packages/typert/protocol/src/remote-error.ts`)
  is `{ isDSHRemoteError: true, code, message, details, name: 'RemoteError' }`.
  Duck-type on `isDSHRemoteError` + `code`, never `instanceof` (the harness's
  own cross-bundle rule).
- **Events.** `Session.snapshotEvents()` returns a dense
  `this.log.slice(...)` array; each `SessionEvent` carries `seq`. So
  `events[index].seq === index` for a session read from 0, and the
  `turn/end` event's `seq` is exactly the fork anchor to publish as `endSeq`.
- **Roster.** `agents.create` emits `session/created`, which the bridge's
  existing listener already turns into a `sessions-changed` SSE frame — the new
  route does **not** need its own broadcast.
- **Web UI precedent.** `packages/client/ui-chat/src/client/apply.ts`
  (`forkAt(seq)`) calls `ctx.sessions.fork({sessionId, atSeq, increaseTitle:
  true}).then(childId => ctx.sessions.open(childId))`. The client wrapper
  (`packages/api/session-controller/src/client/sessions/service.ts`) floors
  `atSeq` and does the `increaseTitle` rename client-side — both behaviors we
  are deliberately not replicating.

## Host plugin changes

### 1. `/turns` records gain `endSeq` (`dsh-plugin/src/logic.ts`)

This is the shared prerequisite PLAN.md names, restricted to fork targeting.

- Add `seq?: number` to `SessionEventLike`.
- Add `endSeq?: number` to `AssistantTurn`:
  ```ts
  /** `seq` of the turn's `turn/end` event: the fork anchor that cuts after
   * this turn. Absent while the turn is open. */
  endSeq?: number
  ```
- In `assistantTurns`, extend the `ends` fold to record the boundary seq.
  Iterate the boundary loop by index so a hole can supply the index as a
  fallback:
  ```ts
  const ends = new Map<number, { time: number; reason?: string; seq: number }>()
  for (let index = 0; index < log.events.length; index += 1) {
    const event = log.events[index]
    if (event === undefined) continue
    if (event.type === 'turn/start') { /* unchanged */ }
    else if (event.type === 'turn/end') {
      const data = event.data as { turn?: unknown; reason?: { kind?: unknown } } | undefined
      const turn = data?.turn
      if (typeof turn === 'number') {
        const kind = data?.reason?.kind
        ends.set(turn, {
          time: event.time,
          ...(typeof kind === 'string' ? { reason: kind } : {}),
          seq: typeof event.seq === 'number' ? event.seq : index,
        })
      }
    }
  }
  ```
  and set `record.endSeq = end.seq` alongside `endedAt`/`reason`.
- Update the `AssistantTurn` / `assistantTurns` doc comments and the `/turns`
  route comment in `index.ts` to mention `endSeq`.
- **Incremental merge is already safe**: `dsh-bridge--turns-cache-merge` drops
  cached turns `>= since` and prepends the full response records, so `endSeq`
  survives; no Emacs cache change is needed.

### 2. Optional `sessionController` service (`dsh-plugin/src/index.ts`)

- Add a minimal structural face beside the existing optional-service faces:
  ```ts
  /** Minimal face of the optional `sessionController` service (fork). */
  interface SessionControllerService {
    fork(request: { sessionId: SessionId; atSeq?: number }): Promise<{ sessionId: SessionId }>
  }
  ```
  Call it as a method (`sessionController.fork(...)`); do not destructure (the
  prototype method needs its receiver).
- Add a cross-bundle-safe error predicate and a status mapper next to
  `isSessionTitleInvalidError`:
  ```ts
  /** Whether an error is a Typert RemoteError carrying CODE. */
  function isRemoteErrorCode(error: unknown, code: string): boolean {
    return typeof error === 'object' && error !== null
      && (error as { isDSHRemoteError?: unknown }).isDSHRemoteError === true
      && (error as { code?: unknown }).code === code
  }
  ```
- Update AGENTS.md's optional-service list to include `sessionController`.

### 3. `POST /dsh-bridge/fork` route (`dsh-plugin/src/index.ts`)

Request body: `{ sessionId?: string; atSeq?: number }`.

- `sessionId` is optional and resolved **read-only** with the existing
  `resolveReadId` (never resumes; the same precedence `/session` uses).
- `atSeq`, when present and non-null, must be a non-negative safe integer,
  else `400`.
- Service absent → `501`.
- Apply the subagent fence before forking (the fork seam itself does not
  check origin): live source via `isSubagentChild(header.origin,
  ownedByLiveParent(session))`, cold source via
  `sessionPersistence.stat(id).header.origin` → `409`. This is deliberately
  the stricter **targeting-route** form, not a literal mirror of `/session`
  (which checks `header.origin` only): forking is a mutation, so a subagent
  child whose parent is merely cold must also be refused.
- Call `sessionController.fork({ sessionId: id, ...(atSeq === undefined ? {} :
  { atSeq }) })`.
- Success → `201`:
  ```json
  { "ok": true, "sessionId": "<child>", "parentSessionId": "<source>", "atSeq": 12 }
  ```
  (`atSeq` is `null` when omitted.) No extra `broadcastSessionsChanged`: the
  harness's `session/created` already emits one.
- Error mapping:

  | Harness error | HTTP | Notes |
  |---|---|---|
  | `BridgeError` from `resolveReadId` | its status | 404 unknown / 409 no session |
  | subagent source (pre-check) | 409 | targeting-route fence (stricter than `/session`) |
  | `gateway/bad-request` | 400 | bad `atSeq` (also guarded at the boundary) |
  | `session/not-found` | 404 | |
  | `session/fork-unavailable` | 409 | anchor pins an incomplete turn |
  | `session/workspace-attach-failed` | 502 | child exists; surface `details.sessionId` in the body |
  | other | 500 | `bridgeErrorStatus` |

  The "other" row is load-bearing: `presetForObservation` throws a **plain
  `Error`** when the `sessionProjections` service is unmounted, and
  `composeAgent` failures escape fork's try/catch — both arrive unwrapped
  (no `isDSHRemoteError` marker) and fall through to 500. A profile lacking
  `sessionProjections` therefore gets a 500 from `/fork` rather than a clean
  degradation; the bridge otherwise tolerates that service being absent, so
  note the asymmetry rather than pre-checking it.

- Add the route line to the `index.ts` header inventory:
  ```
  //   POST /dsh-bridge/fork { sessionId?, atSeq? } -> branch a completed-turn
  //        prefix into a new session (returns the child id; source may be cold,
  //        never resumed; 409 session/fork-unavailable / subagent-owned)
  ```

## Emacs changes (`emacs/dsh-bridge.el`)

### 4. Fork command

Split the pure-ish round trip from the interactive buffer work so ERT can test
both layers:

```elisp
(defun dsh-bridge--fork-turn (session-id at-seq)
  "Fork SESSION-ID at AT-SEQ (POST /fork); return the child id, or nil.
Echoes the host's error on failure."
  (message "dsh-bridge: branching…")
  (redisplay t)
  (let* ((result (dsh-bridge--request
                  "POST" "/fork"
                  (list (cons 'sessionId session-id) (cons 'atSeq at-seq))))
         (status (car result))
         (alist (cdr result)))
    (if (and (memq status '(200 201)) (alist-get 'sessionId alist))
        (alist-get 'sessionId alist)
      (message "dsh-bridge: %s"
               (or (dsh-bridge--error-message nil status alist)
                   "failed to branch the turn"))
      nil)))
```

```elisp
(defun dsh-bridge--shown-turn-record ()
  "The turn record the current DSH-View shows, or nil.
Force-refreshes the session's turn cache when the view is at rest so the
record's `endSeq' is current; then finds the record by turn number."
  (let* ((turns (dsh-bridge--view-turns-refresh
                 (null dsh-bridge--view-turn-index)))
         (turn dsh-bridge--view-turn))
    (and turn turns
         (seq-find (lambda (record)
                     (equal (alist-get 'turn record) turn))
                   turns))))

;;;###autoload
(defun dsh-bridge-fork-turn ()
  "Branch the shown turn into a new session, then open the child.
The child inherits the conversation through the shown turn and the agent
preset, but starts on the default model and is not auto-titled."
  (interactive)
  (unless (eq major-mode 'dsh-bridge-view-mode)
    (user-error "dsh-bridge: not a DSH-View buffer"))
  (let ((id dsh-bridge--view-content-session))
    (unless id (user-error "dsh-bridge: this view has no session"))
    (let* ((record (dsh-bridge--shown-turn-record))
           (end-seq (and record (alist-get 'endSeq record))))
      (unless end-seq
        (user-error "dsh-bridge: the shown turn is not completed; branch a completed turn"))
      (let ((child (dsh-bridge--fork-turn id end-seq)))
        (when child
          (dsh-bridge-fetch child t)
          (pop-to-buffer (dsh-bridge--prompt-buffer child)
                         dsh-bridge-prompt-display-action)
          (message "dsh-bridge: branched into %s (preset inherited; default model; untitled)"
                   (dsh-bridge--id-tail child)))))))
```

Notes:

- `dsh-bridge--request` (synchronous) matches the other mutating commands
  (`rename`/`archive`); fork is a local round-trip, and the "branching…" echo
  covers the compose/seed latency.
- `dsh-bridge-fetch child t` uses `url-retrieve-synchronously`, so its
  `pop-to-buffer` runs before the following `pop-to-buffer` of the prompt; the
  result is the view in the current window and the prompt below (the
  `dsh-bridge-reply` window shape). The child's newest inherited turn is
  complete, so the view fills with it rather than the waiting placeholder.
- Refusal cases: not a view buffer; no session in the view; no turn identity
  (a pushed message); the turn has no `endSeq` (still running) — decision 5.
- `dsh-bridge--prompt-buffer` asks (`y-or-n-p`) before erasing a modified
  draft when it reuses the shared prompt buffer (`dsh-bridge.el` — the
  rename/reply commands already live with this). The fork command can
  therefore prompt mid-flow; the ERT success case stubs
  `dsh-bridge--prompt-buffer`, so no test sees it.

### 5. Binding, menu, docs

- `(define-key dsh-bridge-view-mode-map (kbd "B") #'dsh-bridge-fork-turn)`.
  `B` is free under both parent branches: `special-mode-map` and
  `view-mode-map` leave it nil (verified in batch Emacs), and upstream
  `markdown-view-mode-map` — which `gfm-view-mode` reuses — binds only
  p/n/f/b/u, DEL, SPC, >, <, q, ?, so no `B` either. (Lowercase `b` was
  rejected: the earlier draft claimed `gfm-view-mode` has no keymap, which
  is wrong — it inherits markdown's outline map, where `b` is
  `markdown-outline-previous-same-level`. The shadow would have been
  harmless and consistent with the existing `q`/`M-p`/`M-n` overrides, but
  `B` avoids it outright.)
- Add `["Branch Turn" dsh-bridge-fork-turn ...]` to
  `easy-menu-define dsh-bridge-view-menu` (the view buffer's own menu).
- Extend the `dsh-bridge-view-mode` docstring key list with `B`.
- Extend the `dsh-bridge--turns-cache` docstring's record-key enumeration
  (`turn`, `startedAt`, `endedAt`, `reason`, `segments`) with `endSeq`.

## Contract reference

`GET /dsh-bridge/turns` turn record (additive change):

```json
{
  "turn": 3,
  "startedAt": 1757400000000,
  "endedAt": 1757400009000,
  "reason": "completed",
  "endSeq": 42,
  "segments": [{ "text": "…", "time": 1757400005000, "step": 1 }]
}
```

`endSeq` is absent (key omitted) while the turn is open — this is exactly what
makes decision 5 enforceable client-side.

## Testing

### Host unit (Vitest, `dsh-plugin/tests/logic.spec.ts`)

- Extend the `turnStart`/`turnEnd`/`turnLog` fixture builders to carry `seq`
  on the events. Today's fixtures have no `seq`, so without this every spec
  would exercise only the index-fallback branch — while production events
  always carry `seq`, i.e. the primary path would be untested.
- A completed turn folds `endSeq` equal to its `turn/end` event's `seq`.
- An open turn has no `endSeq` (key absent, not `undefined`-valued).
- A turn whose `turn/end` event lacks `seq` falls back to the array index.
- Existing `assistantTurns` expectations updated for the new field.

### Integration (`integration/tests/fork.spec.ts`, new)

Uses the shared fixture, `scriptMock`, `createSession`, `openSse`,
`waitFor('turn-complete')`, and the existing `/turns`, `/session`, `/sessions`
helpers:

1. **Happy path** — script one text turn; send; wait for `turn-complete`;
   `GET /turns` and take the last turn's `endSeq`; `POST /fork {sessionId,
   atSeq}` → `201`, `ok`, a `sessionId` distinct from the source.
2. **Lineage** — `GET /session?sessionId=<child>` → `parentSession == source`,
   `isSeeded == true`, child is live (`live: true`).
3. **Roster + inherited prefix** — `GET /sessions` contains the child as live;
   `GET /turns?sessionId=<child>` returns the inherited turn segment(s).
4. **Omitted `atSeq`** — forks the last completed turn (the harness fallback),
   distinct child id.
5. **Unavailable anchor** — script `{kind:'hang'}`, send, wait for the turn to
   start, then `POST /fork` with an `atSeq` inside the open turn (e.g. `1`) →
   `409` with `session/fork-unavailable` in the body.
6. **Unknown source** — `POST /fork {sessionId: 'session-does-not-exist'}` →
   `404`.
7. **Bad argument** — `atSeq: -1` or a string → `400`.

Optional (only if the fixture boots with the row disabled): a degraded fixture
with `disable: ['session-controller']` asserting `501` (the `launch` option
is `disable`, not `disabled` — `integration/host/launch.mjs`; the wrong key
would be silently ignored and boot a full profile). The `turns.spec.ts`
precedent shows that disabling a provider can strand its hard-injecting
consumers and fail the boot audit — for `session-controller` the hard
consumer is `ui-deliverables` in the web profile — so treat this as
best-effort rather than a required case; the `ctx.get(...) === undefined`
tolerance is already the established pattern.

### Elisp unit (ERT, `emacs/dsh-bridge-tests.el`)

Stub `dsh-bridge--request` (and `dsh-bridge-fetch` /
`dsh-bridge--prompt-buffer` where the buffer work is not the subject):

- Forks the shown completed turn: posts `sessionId` + the record's `endSeq`.
- Refuses when the shown turn has no `endSeq` (no request issued).
- Refuses a pushed message (no turn identity).
- Refuses outside a DSH-View buffer.
- Failure echo: a non-2xx body's `error` is surfaced and no child is opened.
- Success opens the child: `dsh-bridge-fetch` and `dsh-bridge--prompt-buffer`
  receive the child id.
- Extend `dsh-bridge-view-mode-basics` (which enumerates the view map's
  bindings) with a `B` assertion, and update its docstring's key list.

### Elisp live seat (ERT, `integration/dsh-bridge-it.el`)

A third test, `dsh-bridge-it-fork-turn`, mirroring the describe test's setup:
boot the fixture, script a text turn, create a session, send, wait for turns,
`dsh-bridge-fetch` the session, invoke `dsh-bridge-fork-turn`, then wait until
the child appears in `/sessions` with `parentSession`/`isSeeded` set. Asserts
the real route + service seam end to end from Emacs.

### Gate

`make build && make test` for the unit layer; `make integration-test` (with
`DSH_BRIDGE_DSH_COMMAND` / `DSH_BRIDGE_FIXTURE_CWD`) for the seam layer, per
AGENTS.md's rule that a host-plane change runs the integration gate.

## Documentation and housekeeping

- `dsh-plugin/src/index.ts` header route inventory: the `/fork` line above and
  the `/turns` record shape (`endSeq`).
- `README.md`: a "branch a turn" usage note under the DSH-View keys; the route
  in the route list. No change to "Permissions, authentication, and failure
  bounds": the route is bearer-authenticated like every other mutation and adds
  no new fence, no new file, and no new outbound contact.
- `AGENTS.md`: add `sessionController` to the optional-service list and note
  the fork seam's `{prepend}`-free, service-native nature in the host-plugin
  section.
- `PLAN.md`: flip candidate 2 to **Implemented** once landed, with the
  decision-2/3 caveats recorded.
- Version bump: `0.8.0` → `0.9.0` in all three copies (`emacs/dsh-bridge.el`
  `;; Version:` header and `dsh-bridge-version` defconst,
  `dsh-plugin/package.json` `version`), matching the per-feature minor bump
  precedent (candidate 1 took 0.7.0 → 0.8.0). `make package` enforces the
  agreement.

## Landing order

1. `logic.ts` `endSeq` + Vitest specs (host unit green).
2. `index.ts` service face + error predicate + `/fork` route + route-inventory
   comment.
3. `emacs/dsh-bridge.el` `dsh-bridge--shown-turn-record`,
   `dsh-bridge--fork-turn`, `dsh-bridge-fork-turn`, `B` binding, view menu,
   docstring.
4. ERT unit tests.
5. Integration spec + live-Emacs seat; run `make integration-test`.
6. Docs (README/AGENTS/PLAN) and the version bump.

Suggested commit split: (1) host route + `endSeq`; (2) Emacs command;
(3) integration coverage; (4) docs + version. `make test` after each;
`make integration-test` before commit 1's host-plane change as the
version-bump gate.

## Confirm at implementation time

- **Re-verify the fork seam at the target tag.** The Harness facts above were
  checked against a `0.1.5-rc.1`-era checkout, newer than the stated
  `0.1.5-alpha.2` target. Diff `packages/api/session-controller/` (and
  `RemoteError`'s marker) between `dsh-v0.1.5-alpha.2` and what was reviewed
  before building against either.
- **Live probe** of the service seam: assert `ctx.get('sessionController')` is
  defined in the `web` profile and that a bad `atSeq` throws a RemoteError with
  `isDSHRemoteError === true` and `code === 'gateway/bad-request'` (the plan's
  mapper depends on that marker, not on `instanceof`).
- **`endSeq` on a forked child's inherited turns**: confirm `/turns` folds the
  inherited prefix (expected, since `snapshotEvents()` spans the whole log) so
  the child's view opens with content.
- **`workspace-attach-failed` details**: confirm `details.sessionId` is the
  child id so the 502 body can carry it.
- Whether disabling `session-controller` lets a fixture boot (only affects the
  optional 501 integration case).

## Risks

- **Two observations' worth of latency** is not a concern here (the fork seam
  is local), but `resolveReadId` + the subagent pre-check + the service's own
  `observeSession` is three passes over the log for a cold source. Acceptable;
  noted for a future optimization if the route ever gets hot.
- **Silent divergence from the web UI** on model and title is a deliberate,
  documented choice; the fork message states both caveats so the user is not
  surprised when the branch continues on a different model.

## Addendum — implementation notes and deviations (2026-09-10)

Implemented on top of `c6e304e`. The adjacent harness checkout moved to
`0.1.5-rc.1` (`2377c272a8`) while this was being built; the integration fixture
ran against that, not the `0.1.5-alpha.2` tag.

### Confirm-at-implementation results

- **Tag re-verification.** `git diff dsh-v0.1.5-alpha.2..2377c272a8` over
  `packages/api/session-controller/` and `packages/typert/protocol/` touches
  only `package.json`/`README`; `@Remote('fork') fork(request)` and
  `RemoteError`'s `isDSHRemoteError`/`code` markers are unchanged. The seam is
  safe at either point.
- **Service probe.** The integration `fork.spec.ts` and the live-ERT seat
  prove `ctx.get('sessionController')` is present in the web profile and that
  `fork` works end to end.
- **Inherited prefix.** Confirmed: the child's `/turns` carries the source's
  completed-turn segments (`fork.spec.ts` asserts the text).
- **`workspace-attach-failed`.** The 502 path now surfaces `details.sessionId`
  in the body (per the plan). It has no test: no fixture mechanism forces a
  workspace attach to fail.
- **`disable: ['session-controller']` 501.** Not attempted; the plan marked it
  best-effort, and the `ctx.get(...) === undefined` → 501 path follows the
  established optional-service pattern.

### Deviations

1. **Integration case consolidation.** The plan's seven cases are four tests:
   the happy path also asserts lineage, roster, and the inherited prefix (one
   turn, four assertions); the bad-argument case adds a fractional `1.5`
   alongside `-1` and `'x'`; unknown-source shares that test. No coverage was
   dropped, only regrouping and a stronger argument matrix.
2. **Live-ERT child discovery.** Instead of a poll loop asserting the child row
   appears with `parentSession`/`isSeeded`, the seat diffs `/sessions` ids
   (new helper `dsh-bridge-it--session-ids`) to find the child, then reads
   `/session` for lineage. Fork is synchronous, so no wait is needed; the diff
   is what makes the child id addressable for the lineage read.
3. **Omitted the optional degraded-profile 501 integration test** (see above).
4. **README wording beyond the plan.** The plan said "no change to permissions
   bounds"; the fence is indeed unchanged, but the "cold reads never resume"
   sentence now names `POST /fork` alongside the session report, since
   AGENTS.md requires that section to track behavior.
5. **AGENTS.md** gained a dedicated host-plugin bullet (seam choice, read-only
   source resolution, `isDSHRemoteError` duck-typing, `endSeq`, and the
   plain-`Error` 500 asymmetry) rather than a passing mention.
6. **Test fixture helper.** ERT adds `dsh-bridge-test--fork-record` to build a
   completed record with `endSeq`; the plan did not name a helper.
7. **`logic.spec.ts` fixtures** stamp `seq` via `turnLog` (the plan's
   suggestion) and the `endSeq` expectations are pinned to the real indices;
   a dedicated fallback case builds an un-stamped log by hand.

