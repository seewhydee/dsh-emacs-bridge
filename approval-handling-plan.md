# Approval handling (`approval/request`): implementation plan

Status: **reviewed and amended** — claims verified against the harness checkout
(`0.1.5-rc.2`) and the bridge sources; the [§4](#4-decisions-to-pin) decisions
are pinned as recorded there.
Audience: the maintainer and any agent implementing this.
Basis: a survey of the harness at `../deepseek-harness/` (pin per
`dsh-plugin/package.json`), summarized in [§2](#2-what-the-harness-actually-does).

## 1. Problem

The bridge can answer exactly one of the two interactive host waterfalls:
`user-questions/request` (ask-user and `exit_plan_mode` review). The other,
`approval/request`, is invisible to Emacs. A session parked on an approval looks
hung in Emacs — no indicator, no way to resolve it without going back to the web
UI.

`danger-full-access` is not a separate feature; it is one producer of that
waterfall (a sandbox-escalation ask). Handling the seam fixes the reported case
and every sibling case at once.

## 2. What the harness actually does

### 2.1 The two interactive waterfalls

Only two host waterfalls put a human in the loop. Both are forwarded to the
browser by `packages/api/remotes/src/remote-events.ts` (`approval/request` line
18, `user-questions/request` line 35). The browser's own pending-interaction
registry has exactly three kinds — `'approval' | 'plan-review' | 'question'`
(`packages/client/ui-workspace/src/client/tree.ts:38`). Plan-review is a
question intent, so the bridge already covers two of the three; `approval` is
the gap.

### 2.2 The approval seam

- Declaration: `packages/interaction/user-approval/src/types.ts:76-90`.
- Service: `packages/interaction/user-approval/src/index.ts:208-227` — requires
  an open turn, appends `approval/asked`, awaits one outcome, appends
  `approval/decided`.
- Request: `{ agent, toolName, callId?, reason?, signal? }`.
- Outcome: `'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'` (only
  `allowed-once` grants).
- The browser panel offers exactly two buttons, `allowed-once` and `rejected`
  (`packages/client/ui-approval/src/client/ApprovalPanel.tsx`); it attaches the
  tool-call detail through `callId`.

Producers, in-tree:

| Producer | Trigger | Default web profile? |
|---|---|---|
| Sandbox escalation from `bash`, `pwsh`, `write`, `edit` | Model retries a denied call with `sandbox_permissions` + `justification` (hint at `packages/sandbox/sandbox/src/escalation.ts:84-86`, pairing validated at `:51-61`); targets `workspace-write` **or** `danger-full-access` (`WIDER_MODES`, `:28-31`). Reason: `escalate sandbox to <mode>: <justification>` (`:177`); subject `command` for shell, `operation` for fs (`:80,140`). | **Yes** (tools in the `standard` preset; escalation advertised whenever `fs-sandbox`/`bash-sandbox` is mounted). |
| Hook-gated tool approval | `tools/pre-execute` returns `{kind:'ask'}` (gate at `packages/core/tools/src/index.ts:1465-1471`) → `ToolRuntime.serviceAsk` (`:1679-1719`) → `approval.request` (`:1696-1702`); produced by `hooks-claude-code` `permissionDecision: "ask"` (`packages/hooks/hooks-claude-code/src/index.ts:237-241`). Any tool name. | No — only if `dsh-hooks-claude-code` is added. `hooks-codex` only blocks. |
| Arbitrary third-party plugin | Returns `ask` from `tools/pre-execute`, or calls `ctx.approval.request` directly. | Profile-dependent. |
| ACP deployments | `@deepseek-ai/dsh-acp` answers approvals from its ACP client (`packages/acp/acp/src/index.ts:155-172`). | Only under `--profile acp`. |

Bounds that matter:

- The `danger-full-access` **permission preset** sets `approval: never`
  (`packages/bundle/base/cordis.patch.yml:224-241`), and `never` is enforced
  before dispatch — no prompt, no gap. A `danger-full-access` *query* therefore
  only appears while the session sits in `read-only`/`workspace-write`.
- Child/subagent agents are forced to `approvalPolicy: 'never'`
  (`packages/subagent/subagent/src/child-agent.ts:245`).
- The escalation schema is only advertised under a confining backend.

### 2.3 Already covered: `user-questions/request`

Two producers, both handled: `ask_user_question`
(`packages/interaction/tool-ask-user/src/index.ts:81`) and `exit_plan_mode`
review (`packages/plan/plan-mode/src/index.ts:298-340`). The bridge's item shape
already carries `detail`/`options`/`multiSelect`/`intent`
(`dsh-plugin/src/logic.ts:840-853`) and Emacs renders the plan detail
(`emacs/dsh-bridge.el:327-330`, `:3579-3612`). No hidden gap here.

A subagent's `ask_user_question` is refused (`DELEGATED_CALLER`,
`packages/interaction/user-questions/src/index.ts:94-106`), so there is no
"child question goes unseen" hole either.

### 2.4 Related hangs outside the seam (out of scope; see §3)

- `cordis_inspect_query` against a client provider blocks the tool call until a
  browser page answers `cordis/inspect-query`
  (`packages/extensions/cordis-host-runner/src/inspect-registry.ts:156-199`).
  Only in the `cordis` agent preset; the page answers automatically.
- `cordis_run` on a browser-half package returns `awaiting-approval`
  immediately (`packages/extensions/tool-cordis/src/index.ts:245-306`) — the
  turn is not blocked, but the work stalls until a browser gesture.
- Terminal `stdin_read` waits on a program, not a person
  (`packages/terminal/tool-terminal/src/index.ts:199,223`).

### 2.5 Ruled out

External subagent providers deny/decline unattended dialogs
(`packages/subagent/subagent-claude-code/src/run.ts:330-360`); MCP declares no
elicitation capability (`packages/mcp/mcp-client/src/connection.ts:238-241`);
LSP answers server requests itself; credentials authorization is
caller-supplied and user-initiated; directory picker / model / permission
preset / plan toggle / goal / feedback are all client-initiated.

## 3. Goal and non-goals

**Goal.** While an Emacs SSE client is connected, an `approval/request` is
surfaced to Emacs (with enough context to decide), the Emacs side shows the
session as parked rather than running, and the user can answer it from Emacs
with the same outcomes the web panel offers.

**Non-goals (this change).**

- `cordis_inspect_query` / `cordis_run` stalls (§2.4).
- Changing the harness's approval semantics, adding new outcomes, or
  auto-approving anything.
- Switching the session's standing permission preset from Emacs (still deferred
  in `PLAN.md`; answering an on-demand one-shot escalation is a separate
  question — see D2).
- Browser-side presentation redesign.

## 4. Decisions to pin

**D1 — Presentation: exclusive claim vs dual-presentation race.**
Ask-user races Emacs against the web panel, and the bridge's
`ask-user-resolved` frame lets its browser plugin dismiss the web panel. The
approval panel has **no** "resolved elsewhere" event, and
`question-dismiss.ts` deliberately refuses to touch `kind: 'approval'`
(`dsh-plugin/src/client/question-dismiss.ts:59-71`), so a raced panel would
linger after Emacs answered.
- **Decision:** *exclusive claim* for v1 — while any Emacs SSE client is
  connected, the bridge claims the approval and never calls `next()`, so the web
  panel never opens; with no Emacs client it delegates exactly as today.
  Simple, no browser work, no stranded panel. Cost: a user watching the browser
  while Emacs is connected sees no panel.
- **Lockout bound (accepted, must be documented):** once claimed, an approval
  cannot be un-claimed — a waterfall veto is one-way. If the Emacs client dies
  without reconnecting, the web panel never opened and the turn stays parked;
  recovery is reconnecting Emacs (the `/events` replay re-delivers the pending
  approval) or cancelling the turn from the web UI. Ask-user lacks this hole
  because it still calls `next()` when a browser is open. "Emacs connected" is
  not "Emacs user present". Alternatives considered: claim only when no browser
  client is connected (the browser then wins ties — a different asymmetry), or
  fund dual-presentation dismissal now. v1 accepts the bound and documents it
  in README's failure bounds.
- Deferred alternative: dual-presentation plus a new browser dismissal keyed on
  session + `toolName` + `callId` (the pending approval object does expose these;
  `cancel()` exists). More parity, more moving parts.

**D2 — Security stance for answering approvals.**
Answering an escalation is effectively a one-shot `danger-full-access` grant
from Emacs, which touches the `PLAN.md` deferral "Permission mutation from
Emacs … no `danger-full-access`". The existing README trust argument (a token
holder can already mutate sessions and run tools) covers it, and the harness
enforces `approval: never` before dispatch, so Emacs cannot grant anything the
web UI could not.
- **Decision:** allow answering all approvals from Emacs (one-shot, matching
  the web panel), document the trust implication, and add a two-value defcustom
  (`dsh-bridge-approval-answer`: `all` / `notify-only`). A third `safe-only`
  tier was considered and dropped: the only in-tree signal distinguishing an
  escalation is the `escalate sandbox to …` reason string, and sniffing it is
  fragile. Revisit only if a structured kind field appears on the request.

**D3 — Answer vs notify-only.**
The complaint is "can only be resolved by going back to the web interface", so
answering is the point. The notify-only configuration stays reachable via D2's
defcustom, but the ship is answering.

**D4 — Tool-call detail.**
`reason` carries the asker's explanation but not, e.g., the command being
escalated. The web panel gets that from the streamed tool call via `callId`.
- **Decision:** include bounded tool-call detail in the approval frame, folded
  host-side from the live session's `tool/call` event
  (`{ turn, step, callId, name, arguments }`, `arguments` a JSON string).
  Truncate to a cap (8 KiB, `…[truncated]`) **on a safe boundary** — never
  split a JSON escape (`\uXXXX`, `\x`) — so a client re-parsing the prefix is
  not handed corrupt JSON; omit `detail` on lookup failure (hook-gated asks may
  carry no `callId`). Without this, approving a `danger-full-access` escalation
  is blind. Ordering note: `tool/call` precedes `approval/asked` in the log
  (the service appends `approval/asked` before awaiting, and `tool/call`
  requires an open step), but the integration test asserts `detail` is
  populated rather than assuming the ordering.

**D5 — Emacs UX.**
- **Decision:** a dedicated read-only `dsh-bridge-approval-mode` buffer
  (tool name, reason, detail), command `dsh-bridge-approve`, bindings
  `y`/`a` allow-once, `n`/`r` reject, `C-c C-k` cancel-the-ask, `q` quit; an
  `A` binding next to the existing `a` (`dsh-bridge-answer`) in the DSH-View
  and DSH-Sessions **mode keymaps** (`dsh-bridge-view-mode-map`,
  `dsh-bridge-sessions-mode-map` — these are `defvar-keymap` maps, not
  transient prefixes; the `dsh-bridge` dispatcher transient has no answer
  suffix today, and v1 adds none there); a defcustom
  `dsh-bridge-approval-auto-pop` mirroring `dsh-bridge-question-auto-pop`.

**D6 — Names.**
Accepted: SSE kinds `approval` / `approval-resolved`; route
`POST /dsh-bridge/approval`; Emacs registry `dsh-bridge--pending-approvals`;
logic helpers `approvalMessage`, `approvalResolvedMessage`,
`approvalDecisionValid`, `toolCallForId`.

## 5. Design

### 5.1 Host plugin (`dsh-plugin/src/`)

- Type-only import of the seam, mirroring the ask-user coupling
  (`index.ts:88-94` is the `dsh-user-questions` precedent):
  `import type {} from '@deepseek-ai/dsh-user-approval'`,
  `import type { ApprovalOutcome } from '@deepseek-ai/dsh-user-approval'`, and
  `import type { ApprovalRequestEvent } from '@deepseek-ai/dsh-user-approval/types'`
  (the package has a `./types` subpath export, like `dsh-user-questions`).
  Never a runtime dependency. No change to the plugin `inject` list — the
  listener consumes the *event*, not `ctx.approval`.
- Register as a sibling `ctx.effect` next to the ask-user one
  (`dsh-plugin/src/index.ts:1478-1482` — that listener is a plain
  `ctx.effect(() => ctx.on('user-questions/request', …, { prepend: true }))`,
  **not** an `ctx.inject` block), with the **same `prepend: true`** so the
  listener runs before the api-remotes browser forwarder:
  `ctx.on('approval/request', (request, next) => onApprovalRequest(request, next), { prepend: true })`.
  (Cordis runs prepended listeners first, and a listener that does not call
  `next()` vetoes the rest of the chain — `vendor/cordis/src/events.ts:228-243`.)
- `onApprovalRequest` mirrors `onUserQuestionsRequest`
  (`dsh-plugin/src/index.ts:724-779`, doc comment `:699-723`):
  1. Resolve `sessionId` from the agent (ask-user uses `String(request.agent.id)`;
     keep the same derivation so the two seams label sessions identically).
  2. If there is no session id, or `emacsSseClients.size === 0`, `return next()`
     (D1). Unlike ask-user there is no browser-race arm — exclusive claim means
     the web panel is never opened while Emacs is connected.
  3. Mint `approvalId = randomUUID()` (`node:crypto`, as at `index.ts:731`),
     register `{ sessionId, toolName, callId, reason, detail, settle }` in a
     `pendingApprovals` map (first-call-wins `settle`, exactly like
     `pendingQuestions`), and broadcast the `approval` frame.
  4. Race the Emacs wait against `request.signal` abort; abort settles
     `'cancelled'`.
  5. Return the settled `ApprovalOutcome` (`allowed-once` / `rejected` /
     `cancelled`). Unlike ask-user, cancellation is a legal outcome value, so
     return `'cancelled'` rather than throwing. (A throwing or rogue listener is
     normalized to `'unavailable'` by the service —
     `user-approval/src/index.ts:278-285` — so the bridge must return cleanly.)
  6. In `finally`: remove the entry, drop the abort listener, broadcast
     `approval-resolved`.
- Replay: extend the `/events` subscribe block (`dsh-plugin/src/index.ts:1540-1549`)
  to replay `pendingApprovals` to a reconnecting Emacs, like `pendingQuestions`
  (the replay is already inside the `!isBrowser` guard, so `?purpose=draft`
  clients get none).
- Detail fold: a pure `toolCallForId(events, callId)` in `logic.ts` returning
  `{ name, arguments }` (truncated per D4) from the session's
  `snapshotEvents()`. Reach the events via
  `request.agent.session.snapshotEvents()` through the typed
  `ApprovalRequestEvent` import — the harness `Agent` exposes
  `readonly session: Session`, and `index.ts` already reaches through
  `agent.session` elsewhere. Do **not** add a structural `LiveAgentLike` cast:
  the minimal-interface-plus-fallback pattern in AGENTS.md is for optional
  `ctx` services, not event payloads.

### 5.2 Wire contract

SSE frames (constructors in `logic.ts`, documented there per AGENTS.md):

```
{ kind: 'approval', approvalId, sessionId, toolName, callId?, reason?, detail? }
    detail?: { name: string, arguments: string }   // bounded, omitted on lookup failure

{ kind: 'approval-resolved', approvalId, sessionId, outcome,
  toolName, callId? }
    outcome: 'allowed-once' | 'rejected' | 'cancelled'
```

Route (header inventory in `dsh-plugin/src/index.ts` must be updated):

```
POST /dsh-bridge/approval  { approvalId, sessionId, decision }
    decision: 'allowed-once' | 'rejected' | 'cancelled'
 -> 200 { accepted: true }
 -> 400 { accepted: false, reason: 'bad-response' }
 -> 404 { accepted: false, reason: 'not-pending' }
```

Bearer auth required (it is a mutation), same as `/answer`. Validation is pure
(`approvalDecisionValid`), and the handler settles first-call-wins; late or
duplicate POSTs read `not-pending`. As with `/answer` (`index.ts:1604-1608`),
a known `approvalId` with a **mismatched** `sessionId` also reads 404
`not-pending` — the check guards against cross-session answer leakage, and the
contract above should be read with that arm included.

### 5.3 Browser client plugin

D1 (exclusive claim) requires **no** client-plugin change. Verify explicitly
that `question-dismiss.ts` still ignores approvals, and that the bridge's own
draft stream (`?purpose=draft`) never counts as an Emacs client — both already
true.

If D1 later flips to dual-presentation, add an approval matcher + dismissal to
the client plugin and a bridge-minted identity the browser can match.

### 5.4 Emacs package (`emacs/dsh-bridge.el`)

(Elisp line citations below are from the review pass; the file drifts — treat
function names as the authority.)

- Registry `dsh-bridge--pending-approvals` (session → list of
  `(approvalId . plist)`), maintained by new `dsh-bridge--approval-arrive` /
  `dsh-bridge--approval-resolved` helpers patterned on
  `dsh-bridge--ask-user-arrive` / `-resolved` (`emacs/dsh-bridge.el:3461-3510`;
  the question registry shape they mirror is documented at `:506-508`).
- Notification dispatch: two new `kind` cases in
  `dsh-bridge--notification-handle-events` (`:830-910`); update its docstring,
  which enumerates the supported kinds.
- Parked indicator: extend the DSH-View terminal marker selection
  (`dsh-bridge--view-awaiting-note`, `:2141-2161`, and
  `dsh-bridge--view-turn-suffix`, `:2235-2265`) so an approval renders
  `(Awaiting approval: press A to review)`. Keep it in the suffix, carrying
  `dsh-bridge-turn-marker`, so the `dsh-bridge--view-fill` provenance checks are
  untouched. Refresh via `dsh-bridge--view-await-refresh` (`:3335-3363`).
- DSH-Sessions: `dsh-bridge-visit-session` (`RET`, `:4820-4872`) prioritizes a
  pending question (`:4839`) before all other row states, and
  `dsh-bridge--status-glyph` (`:568-576`) has an `asking` state. Give pending
  approvals the parallel treatment in both, or a parked session still looks
  merely running in the list — the original complaint.
- Turn cleanup: on `turn-complete`, retire that session's pending approvals
  exactly as `dsh-bridge--ask-user-session-clear` (`:3451-3459`, called from
  `:876`) does for questions. `turn-start` needs no arm: a new turn cannot
  start while one is parked on an approval, and the signal-abort path
  (settling `'cancelled'`) already retires the entry — the turn-complete arm
  is defensive, same as ask-user.
- `dsh-bridge-approval-mode` buffer + keymap (§D5), rendering tool name, reason,
  and detail. `dsh-bridge-approve` resolves the target session like
  `dsh-bridge-answer` (`:4076-4105`), opening the buffer.
- `A` binding next to `a` in the DSH-View and DSH-Sessions **mode keymaps**
  (`dsh-bridge-view-mode-map` `:2691`, `dsh-bridge-sessions-mode-map` `:4723`) —
  see §D5.
- `dsh-bridge--exit-to-view` behavior: an explicit Emacs submit/decline may jump
  to the view (like question submit); a host-arrived `approval-resolved` must
  only banner in place (never move windows), matching the ask-user rule.
  The `--question-sent` "POST reply races the resolved frame" handling
  (`:3407-3412`, `:3443-3446`, `:3500-3510`) has an exact approval analogue —
  copy it.
- Defcustoms: `dsh-bridge-approval-auto-pop` (mirroring
  `dsh-bridge-question-auto-pop`, `:318-324`); plus D2's restriction knob
  (`dsh-bridge-approval-answer`, values `all` / `notify-only`).

## 6. Task breakdown (suggested order)

1. `logic.ts`: `ApprovalRequestLike`/`ApprovalDecision` types,
   `approvalMessage`, `approvalResolvedMessage`, `approvalDecisionValid`,
   `toolCallForId` (with truncation cap constant) + Vitest specs.
2. `index.ts`: `pendingApprovals` map, `onApprovalRequest`, the
   `approval/request` registration, `/events` replay, `POST /approval` route,
   route-inventory header, type-only imports.
3. Emacs: registry + notification cases + parked marker + DSH-Sessions
   dispatch/status-glyph + turn cleanup.
4. Emacs: approval buffer, `dsh-bridge-approve`, keymap, mode-keymap `A`
   bindings, defcustoms.
5. Tests: ERT for the new elisp; integration scenario/spec.
6. Docs: README bounds, AGENTS.md seam bullets + version-bump note, PLAN.md
   cross-reference, logic doc comments.
7. `make build && make test`, then `make integration-test` (host-plane change),
   then the version bump in the three single-source-of-truth places if releasing.

## 7. Tests

- **Vitest** (`dsh-plugin/tests/logic.spec.ts`): frame shapes; decision
  validation (accepts the three, rejects others/missing); `toolCallForId`
  (found / missing / truncated / malformed `arguments`), including a truncation
  case proving the cut never splits a JSON escape.
- **ERT** (`emacs/dsh-bridge-tests.el`): arrive → registry + view marker;
  resolved → banner; buffer rendering of reason/detail; submit/reject/cancel
  POST payloads; `turn-complete` cleanup; approve command's session targeting
  (single pending vs several); DSH-Sessions status glyph and `RET` dispatch
  prioritizing a pending approval.
- **Integration** (`integration/tests/approval.spec.ts` +
  `integration/scenarios/approval.json`, modeled on `ask-user.spec.ts`): script a
  `bash` call carrying `sandbox_permissions: "danger-full-access"` +
  `justification`; assert the `approval` frame arrives **with `detail`
  populated** (do not assume the `tool/call` ordering — assert it), that a
  `?purpose=draft`-only client does **not** claim it, that reconnect replays it,
  that `POST /dsh-bridge/approval {decision:'allowed-once'}` settles the turn
  and the command runs, and that `rejected` fails the tool call. Use a harmless
  command (`true`). Add a second case for the no-Emacs delegation path reaching
  the browser forwarder. Run against the current harness rc (see §9).

## 8. Documentation

- `README.md` "Permissions, authentication, and failure bounds": state that
  Emacs can answer approval requests, including one-shot sandbox escalations,
  under the same bearer-token boundary, what D2 restricts, and the D1
  exclusive-claim lockout bound (a dead Emacs client leaves a claimed approval
  parked until reconnect or a web-side turn cancel).
- `dsh-plugin/src/index.ts` header route inventory + the `/events` client-identity
  comment (approvals, like questions, are answered only by unmarked Emacs clients).
- `AGENTS.md`: a host-plugin bullet for the approval seam (races/delegation,
  exclusive claim, outcome mapping, D2 stance); an Emacs bullet for the approval
  buffer/registry; extend the version-bump checklist to re-verify the approval
  coupling alongside ask-user.
- `PLAN.md`: record the outcome; reconcile the "Permission mutation from Emacs"
  deferral with D2.
- `logic.ts` doc comments on the new frame constructors.

## 9. Risks and open questions

- **Peer-version drift.** `@deepseek-ai/dsh-user-approval` is a type-only seam;
  its `RequestEvent`/`ApprovalOutcome` shape and the `approval/request`
  registration order are pre-release and may move. The integration test is the
  version-bump gate (mirrors the ask-user coupling note in AGENTS.md). The
  current checkout is `0.1.5-rc.2` against the plugin's `^0.1.5-alpha.1` pin —
  satisfied, but the pin predates the rc, so run `make integration-test`
  against the rc before merging.
- **D1 coexistence and lockout.** Exclusive claim means the browser shows
  nothing while Emacs is connected, and a claimed approval cannot be
  un-claimed: a dead Emacs client leaves the turn parked until reconnect
  (replay) or a web-side turn cancel. Accepted as a documented failure bound
  (§4 D1); revisit if the dismissal work is funded.
- **D2 blast radius.** Answering `danger-full-access` from Emacs is a real
  privilege grant; the README wording and the restriction knob are the
  mitigations.
- **Frame size.** Tool arguments can be large (`write` content). The cap +
  truncation marker must be enforced host-side, not left to the client, and the
  cut must not split a JSON escape (§4 D4).
- **Two Emacs instances / multiple buffers.** Replay plus `approval-resolved`
  must banner the stale buffer; the ask-user "sent before POST" race handling
  (`dsh-bridge--question-sent`) has an exact analogue that must be copied.
- **Signal abort vs exclusive wait.** Ensure the abort path removes the pending
  entry and broadcasts `approval-resolved` so a cancelled turn doesn't leave a
  live Emacs buffer.
- **`cordis_inspect_query`** remains a separate preset-gated hang; decide
  later whether it wants a stall/timeout indicator.
