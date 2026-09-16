# Approval refinement: DWIM `a` + dual-presentation approval race

Status: **implemented** — this document records the design and the decisions
taken (the DWIM command is `dsh-bridge-answer` itself; `A` and the separate
`dsh-bridge-approve` command were removed, with no compatibility shims). Claims
below were checked against the bridge sources at commit `7807626` (post-`4acda07`)
and the harness checkout at `/home/cyd/src/deepseek-harness` (`0.1.5-rc.2`,
`c291e79`). Function names are the authority; line numbers are a snapshot.

Audience: the maintainer and the agent implementing this.
Supersedes the relevant parts of `approval-handling-plan.md` (§4 D1 and §5.3 are
the decisions this change reverses).

## 1. The two asks

1. **DWIM `a`.** Today `a` is `dsh-bridge-answer` (ask-user) and `A` is
   `dsh-bridge-approve` (approval). Ask-user and approval are mutually
   exclusive per session — both are await-inside-an-open-turn waits, and a turn
   cannot be parked on two at once — so one key can dispatch to whichever wait
   the target session actually has.
2. **Stop the exclusive claim.** Today an answering Emacs SSE client makes the
   host bridge *claim* every `approval/request` and never call `next()`, so the
   web UI's approval panel never appears. If Emacs is buggy or wedged, the
   approval cannot be answered anywhere (the documented "claimed approval"
   lockout). Ask-user does not have this problem: it both answers in Emacs and
   lets the web panel open, and whichever answers first dismisses the other.
   Approvals should behave the same way.

`approval-handling-plan.md` §4 D1 chose exclusive claim precisely because the
web approval panel had no "resolved elsewhere" dismissal. **That premise is
wrong**: `PendingApproval.abort()` is a usable dismissal seam (Part B). The
lockout is removable with no harness change.

---

## Part A — DWIM `a`

### A.1 Current state

| Thing | Where |
|---|---|
| `a` → `dsh-bridge-answer` | `dsh-bridge-view-mode-map` (`emacs/dsh-bridge.el:2810`), `dsh-bridge-sessions-mode-map` (`:5200`) |
| `A` → `dsh-bridge-approve` | same two maps (`:2811`, `:5201`) |
| `RET` already dispatches question → approval | `dsh-bridge-visit-session` (`:5319-5324`) |
| View terminal suffix already prefers a question note over an approval note | `dsh-bridge--view-turn-suffix` (`:2369-2375`) |
| Duplicated target resolution | `dsh-bridge-answer` (`:4211-4218`) and `dsh-bridge-approve` (`:4587-4594`) |
| Key-producing hints | `--view-awaiting-note` `\[dsh-bridge-answer]` (`:2242`), `--view-approval-note` `\[dsh-bridge-approve]` (`:2263`), arrival messages (`:3600`, `:4361`), defcustom docstrings (`:321`, `:339`, `:362`) |

Both commands:
- resolve a session from the buffer (view content session / prompt effective
  session / sessions row id);
- with no resolved session, use the *only* session with a pending item of their
  kind, and `user-error` when several are pending;
- with a resolved session that has no pending item, message and do **not** widen
  to the unique-pending fallback.

### A.2 Is mutual exclusivity safe?

Yes for a single session. `ask_user_question` (and plan-review/`exit_plan_mode`)
and `approval/request` are each awaited inside an open turn; the turn's tool step
blocks on the wait, so one agent/session has at most one pending interaction at a
time. Plan-review is an ask-user intent (same registry), so it is covered by the
question arm.

Two different sessions can each hold a *different* kind of pending wait. The DWIM
must therefore keep the "don't guess among several sessions" rule, but over the
**union** of both kinds (currently each command checks only its own kind). This
is a deliberate behavior change to the no-target fallback, and the only real
design subtlety in Part A.

### A.3 Proposed design

- Add one command, working name **`dsh-bridge-respond`** (final name a decision —
  see A.5). It:
  1. resolves a target session exactly as the two commands do today (shared
     helper, e.g. `dsh-bridge--interaction-session`);
  2. target has a pending question → question buffer (`dsh-bridge-answer`'s
     existing body / `dsh-bridge--question-buffer`);
  3. else target has a pending approval → approval buffer;
  4. else if no target was resolved: take the union of sessions in
     `dsh-bridge--pending-questions` and `dsh-bridge--pending-approvals`;
     exactly one → use it; more than one → the existing
     `user-error`-style refusal; none → echo "no pending query or approval";
  5. else (explicit target, nothing pending) → echo that the session has no
     pending query or approval.
  Question before approval, matching `dsh-bridge--view-turn-suffix` and
  `dsh-bridge-visit-session`.
- Bind `a` to it in `dsh-bridge-view-mode-map` and `dsh-bridge-sessions-mode-map`
  in place of `dsh-bridge-answer`.
- **Keep `dsh-bridge-answer` and `dsh-bridge-approve` as commands.** They are the
  implementation entry points (RET, direct `M-x`, ERT) and their explicit
  single-kind semantics remain useful. Make them thin wrappers or keep their
  current bodies and have the DWIM call them after choosing a session — but if
  the DWIM calls them, it must set the buffer context, because they re-resolve
  the session themselves. Cleanest: extract the target resolution + buffer
  opening into helpers that both the explicit commands and the DWIM call.
- Update hints that name `A` for approvals (`--view-approval-note`, the
  `--approval-arrive` echo) to name the DWIM command, so the displayed key is
  `a` (`substitute-command-keys` resolves to whatever the DWIM is bound to). The
  question hints keep pointing at the ask-user command only if it stays bound;
  if `a` moves to the DWIM, the question arrival message would print
  `M-x dsh-bridge-answer` unless repointed to the DWIM. Repoint both to the DWIM.
- `dsh-bridge-visit-session` can keep its two explicit arms (no behavior change)
  or call the DWIM; keeping the explicit arms avoids re-resolving.

### A.4 Touch points

- `emacs/dsh-bridge.el`: new command + helper; two `defvar-keymap` edits
  (`:2810-2811`, `:5200-5201`); hint strings (`:2242`, `:2263`, `:3600`,
  `:4361`); docstrings (`:321`, `:339`, `:362`) and the View/Sessions mode
  docstrings; README/AGENTS wording.
- `emacs/dsh-bridge-tests.el`: update the literal
  `"Awaiting approval for bash: press A to review"` assertion (`:7331`) and the
  arrival-message binding assertion (`:5544`); add DWIM dispatch tests
  (question wins; approval-only; explicit-target-no-pending; ambiguous union
  refusal; unbound unique pending).

### A.5 Decision needed — what happens to `A`?

- **Recommended:** keep `A` bound to `dsh-bridge-approve` for now. It is free,
  breaks no muscle memory, and gives an explicit "approval only" path. Hints use
  `a`.
- Alternative: unbind `A` (reclaiming it), which then requires every
  approval hint to be repointed anyway. No functional gain.

---

## Part B — Dual-presentation approval race

### B.1 Why the exclusive claim exists, and why it can go

Exclusive claim was chosen because the browser approval panel is a composer
takeover with no cancel button and no "resolved elsewhere" event; the bridge's
client-side `matchDismissRecord` deliberately refuses `kind: 'approval'`
(`dsh-plugin/src/client/question-dismiss.ts:71`). Racing would leave a stale
panel after an Emacs answer.

But `PendingApproval` (harness
`packages/client/ui-approval/src/client/contract/slots.ts:69-160`) has a public
`abort(reason: unknown): void` in addition to `answer(...)`. Its documented use
is transport/scope teardown, but mechanically it is exactly a dismissal:

- `abort()` rejects `pending.result`;
- in `answerApproval` (`packages/client/ui-approval/src/client/index.ts:27-57`)
  a non-delegation rejection is rethrown and the `finally` calls `remove()`,
  which unregisters the pending interaction → the composer takeover unmounts;
- the rejection reaches the host as a `rejected` Remote-event result, which the
  gateway turns into `cancelRemoteEvent`
  (`packages/api/gateway/src/index.ts:536-540`, `:559-576`), rejecting the
  *browser forwarder's* `next()` promise.

That last rejection is precisely what the bridge already knows how to absorb:
ask-user does exactly this on a browser-side rejection
(`dsh-plugin/src/index.ts:805-815`). So `abort()` is a usable dismissal seam, and
no harness change is required.

Confirmed reachable from the bridge's browser half: the bridge client plugin
already reads the same `uiSession.pendingInteractions` snapshot
(`dsh-plugin/src/client/index.ts:130-173`) and duck-types the values, so it can
add `abort` without importing the harness class.

### B.2 Host-plane change — race instead of claim

Rewrite `onApprovalRequest` (`dsh-plugin/src/index.ts:858-917`) to mirror
`onUserQuestionsRequest` (`:772-827`), keeping the delegation arm intact:

1. `request.agent` undefined → `next()` (unchanged).
2. Compute `sessionId`, `approvalId`, `callId`, and `detail` exactly as today.
3. **Delegation arm** (`approvalAnswerers.size === 0`, unchanged): no Emacs →
   `next()` silently; a notify-only Emacs present → broadcast the `approval`
   frame, `await next()`, broadcast `approval-resolved` with the delegated
   outcome (or `unavailable` on throw).
4. **Race arm** (`approvalAnswerers.size > 0`):
   - register the `pendingApprovals` entry and broadcast the `approval` frame
     (the `/events` replay and `POST /approval` route are unchanged);
   - the abort path settles `'cancelled'`;
   - if `browserSseClients.size > 0`, also call `next()` and race it against the
     Emacs POST, swallowing a browser rejection into a never-settling branch
     (Emacs stays the decider);
   - resolve through **one first-call-wins gate** shared by the POST settle and
     the browser-answer branch. This matters: with two independent settling
     paths, a late Emacs POST could overwrite the outcome that the `finally`
     broadcasts after the browser already won. The ask-user listener gets this
     for free (the browser cancel arm funnels into `pendingQuestions.settle`);
     the approval version must funnel both arms into one `finish(outcome)`.
   - `finally` removes the entry and broadcasts `approval-resolved` with the
     winning outcome.
5. Update the `/events` client-identity comment and the route-inventory header
   (`:23-28`, `:1622-1632`) to describe racing, not exclusive claim.

No new route, no new frame kind: `approvalResolvedMessage` already carries
`toolName` and `callId` "for a browser-side dismissal" (`logic.ts:1042-1055`).

### B.3 Browser-plane change — dismiss the panel

- **Pure matcher.** Add an approval matcher beside the question one (new
  `dsh-plugin/src/client/approval-dismiss.ts`, or extend `question-dismiss.ts` —
  a sibling module keeps the existing "question matcher refuses approvals" test
  meaningful). Record shape:
  `{ sessionId, toolName, callId?, at }`. Match requires `pending.kind ===
  'approval'`, the same session, and the same `toolName`; when the record and
  the pending object both carry a `callId`, compare them (this disambiguates
  concurrent same-tool asks); otherwise session + toolName is the identity.
  There is no bridge-minted id shared with the browser: the forwarded request
  carries `{toolName, callId?, reason?}` only, and `PendingApproval.key` is
  client-local. At most one interaction is visible per session anyway
  (harness `ui-session/src/client/index.ts:366-386` picks one by precedence).
- **Client wiring** (`dsh-plugin/src/client/index.ts`):
  - handle `approval-resolved` in the draft-stream listener (currently only
    `ask-user-resolved` and `draft` are handled, `:206-226`), pushing an
    approval dismiss record with the same TTL/retry bookkeeping questions use;
  - on `pendingInteractions` changes, run the existing dismissal pass over
    approvals too: matching pending approvals get `abort(new Error('resolved in
    Emacs'))` (synchronous; no window management), then the record is dropped;
  - `PendingApprovalLike` minimal interface gets `toolName`, `callId`, and
    `abort(reason): void`.
- `matchDismissRecord` stays question-only; the existing spec asserting it
  refuses `kind: 'approval'` (`dsh-plugin/tests/question-dismiss.spec.ts:52-59`)
  stays valid.

### B.4 What this fixes and what it costs

- **Fixes the lockout.** With the web panel open, a wedged/dead Emacs no longer
  parks the turn: the panel is already there. The documented "claimed approval"
  recovery path disappears and the README reference to it
  (`README.md:212-219`, whose target section does not actually describe it) can
  be replaced with the uniform race description.
- **New minor bound.** `abort()`'s rejection is reported to the host as a
  cancellation; harmless because the outer waterfall already settled, and the
  bridge swallows the `next()` rejection. It also makes the gateway emit
  `cancel` frames to every browser tab delivering that event — which is
  desirable (all panels dismiss), not a bug.
- **Behavior change to state:** with any browser stream open, the panel now
  *always* opens alongside Emacs. There is no longer a "web panel suppressed"
  posture. `dsh-bridge-approval-answer = notify-only` still means "Emacs does not
  answer"; it no longer changes whether the browser panel appears (the browser
  panel is the answerer either way when a browser is open).

### B.5 Alternatives considered

- **Upstream `PendingApproval.cancel()`** in the harness: semantically cleaner
  than `abort()`, but a cross-repo dependency and version-bump churn for a method
  that does not change behavior. Worth a follow-up issue/PR; not a blocker.
- **Rely on the forwarded request's AbortSignal to auto-dismiss:** not
  available. The client-side signal is the *delivery* signal
  (`packages/api/gateway/src/client/remote-events.ts:155-158`, `:223-248`),
  aborted only by an explicit host `cancel` frame or stream end. Settling the
  outer waterfall does not cancel the forwarded pending event — that is exactly
  why ask-user needed the explicit `ask-user-resolved` dismissal.
- **Mirror the Emacs outcome back through `answer()` to dismiss:** sends a
  fabricated decision over the wire, has no `cancelled` form, and races the real
  settlement. Rejected.
- **Dismiss only when no browser is the winner / claim when no browser:** a
  different asymmetry that still leaves the "Emacs bug" hole in the
  Emacs+browser case. Rejected.

---

## C. Task breakdown (suggested order)

1. **Host race** (`dsh-plugin/src/index.ts`): rewrite `onApprovalRequest` with
   the shared first-call-wins gate; update comments/header inventory. No route or
   frame change.
2. **Client dismissal** (`dsh-plugin/src/client/`): approval matcher + spec;
   `approval-resolved` handling; `abort()` wiring.
3. **Emacs DWIM** (`emacs/dsh-bridge.el`): helper + `dsh-bridge-respond`; keymap
   edits; hint/docstring repointing.
4. **Tests**: Vitest matcher spec; integration `approval.spec.ts` race case
   modeled on `ask-user.spec.ts:91-131`; ERT DWIM tests + updated literals.
5. **Docs**: README (usage `a`, race description, drop the lockout reference),
   AGENTS.md (approval host bullet, client-plugin bullet, Emacs DWIM bullet),
   `logic.ts` `approvalResolvedMessage` comment, `PLAN.md` cross-reference.
6. `make build && make test`, then `make integration-test` (host-plane change),
   then the three-place version bump if releasing.

## D. Test plan

- **Vitest.** `approval-dismiss` matcher: match by session + toolName; callId
  precision when both present; refusal for non-approval kinds and other
  sessions/tools; the existing `question-dismiss` refusal test unchanged.
- **Integration** (`integration/tests/approval.spec.ts`). Add a case with both
  an unmarked Emacs SSE stream and a `purpose=draft` browser stream (mirroring
  `ask-user.spec.ts:91-131`): the approval frame reaches Emacs, the **browser
  stream also receives `approval-resolved`** with `toolName`/`callId` after an
  Emacs decision, and the turn completes. Keep the existing cases (only-browser
  stream does not claim; notify-only does not claim/receive a settleable id;
  replay). No real browser Remote-event client exists in the fixture, so the
  browser-backed branch parks rather than answers — the same limitation the
  ask-user spec has.
- **ERT.** DWIM: a question and an approval in different sessions refuses to
  guess; one pending of either kind opens the right buffer; an explicit view
  session with nothing pending reports and does not widen. Update the
  `press A to review` literal and the arrival-binding assertion.

## E. Open decisions for the maintainer

1. **DWIM command name** — `dsh-bridge-respond`? (`dsh-bridge-answer-or-approve`
   is explicit but verbose; reusing/renaming `dsh-bridge-answer` changes an
   established command's meaning.)
2. **Keep `A`?** Recommended yes (free, non-breaking); hints move to `a`.
3. **Dismissal seam** — accept `abort()` as-is, or first upstream a
   `PendingApproval.cancel()` to the harness and depend on the newer pin?
   Recommended: ship on `abort()`, file the upstream follow-up separately.
4. **Posture semantics** — confirm that the browser panel always opening while a
   browser is connected (and Emacs answering unless `notify-only`) is the desired
   end state; no extra "suppress the browser panel" defcustom is proposed.
