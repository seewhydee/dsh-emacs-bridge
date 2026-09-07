# dsh-emacs — project plan

A two-way bridge between an Emacs session and a running DeepSeek Harness (`dsh
web`) session. The DSH text window is small and typing-poor; Emacs is a full
editor but lacks DSH's live agent. The bridge moves text in both directions
over loopback HTTP without window-switching and copy-paste. Emacs is a
*companion* to a live DSH session (the web UI stays the primary interface),
not a replacement client — see [Deferred](#deferred) for why we are not
pursuing the Emacs-as-primary-client (ACP-style) model.

## Names (locked)

| Layer | Name |
|---|---|
| Repo / working tree | `dsh-emacs` |
| DSH plugin (npm package) | `dsh-emacs-bridge` (unscoped — `@deepseek-ai/` is reserved) |
| DSH plugin (Cordis id) | `dsh-bridge` |
| Emacs feature / file | `dsh-bridge.el` → feature `dsh-bridge`, prefix `dsh-bridge-` |

## What's implemented

**Host plugin** (`dsh-plugin/src/index.ts`, thin wiring over pure logic in
`src/logic.ts`; outbox in `src/outbox.ts`):

- Loopback HTTP routes under `/dsh-bridge/` on the harness's `webServer`:
  - `POST /send { text, sessionId? }` → `Agent.followup()` (submit).
  - `POST /draft { text, sessionId? }` → push to the DSH composer via SSE
    (409 when no browser client is subscribed).
  - `GET /output?sessionId=` → latest assistant text.  Kept deliberately as
    a single-shot "latest text" probe; the Emacs package no longer calls it.
  - `GET /prompts?sessionId=` → user prompts, newest first.
  - `GET /turns?sessionId=` → turn-aggregated assistant replies, newest
    first.  Each turn record is `{ turn, startedAt, endedAt?, reason?,
    segments: [{ text, time, step }] }` (segments oldest first), plus
    `running` and an `epoch` (the session surface's `replaceGeneration`,
    for cheap compaction detection).  The fold walks the session's own
    surface (`Session.surface.nodes` + `events[seq]`), so compaction
    shadowing behaves exactly as the reply list it replaced (see
    `turn-aggregation-plan.md`).
  - `GET /sessions` → merged live + persisted sessions, with titles (via the
    optional `sessionProjectionCache`, falling back to folding `session/title`
    events from `inspect()`), workspace titles, and archived flags (via the
    optional `workspaceRegistry`).
  - `GET /outbox`, `POST /outbox`, `POST /outbox/ack` → bounded, acked
    DSH→Emacs inbox; every entry is session-scoped; deposits fan an SSE
    notice out to all subscribers.
  - `GET /token` → vends the shared token (fenced to loopback peer + origin).
  - `GET /status` → `{ name, version }` (loopback-fenced), the probe/identity
    route: Emacs distinguishes "not running" / "not loaded" / "stale" and can
    compare the running version against the bundled one after an upgrade.
  - `GET /events?token=` → SSE stream (composer-draft push + outbox notices).
  - `GET /models?sessionId=` / `POST /model { sessionId, provider, model,
    reasoningEffort? }` → thin REST↔RPC adapters that self-call the host's own
    `session.models` / `session.selectModel` over loopback HTTP (the genuine
    handlers own the private per-session selection ref, so parity with the web
    UI is exact by construction).
  - `GET /context?sessionId=` → the latest `{ usedTokens, contextWindow }`
    from the token-meter `contextPressure` projection (204 when unknown), and
    a `{ kind:"context", sessionId, usedTokens, contextWindow }` SSE frame
    rebroadcast from `ctx.sessionProjections.onChanged`.
- Auth: shared bearer token at `$DSH_HOME/dsh-bridge-token` (generated on
  first use, mode 0600), required on every route except the two above.
- Targeting: no host-side pin. A request without `sessionId` resolves to the
  last-active live session, falling back to resuming the most recent cold
  session; explicit ids may name live or saved sessions — a saved id resumes
  on demand (404 unknown, 409 subagent-owned).

**Client plugin** (`dsh-plugin/src/client/`, `dsh.client` browser bundle):

- "Send to Emacs" button in the `conversation.chat.assistant-actions` slot
  (GNU Emacs icon, `zh`/`en` locales) → deposits the message into the outbox.
- Token auto-vend from `/dsh-bridge/token` (cached in memory + localStorage,
  one re-vend retry on 401).
- SSE subscription that applies incoming drafts via `SessionInput.setDraft`
  for the target session scope.

**Emacs package** (`emacs/dsh-bridge.el`):

- `M-x dsh-bridge` transient dispatcher; `dsh-bridge-list-sessions` tabulated
  session list (live + saved rows, archived-visibility toggle, default-target
  marker, open/set-target with on-demand resume, rename/archive/create/
  workspace-rename, peek/describe/copy-id).
- `dsh-bridge-view-mode`: read-only turn buffer with GFM font-lock (when
  markdown-mode is installed).  A buffer shows one agent turn — its committed
  segments separated by `(continuing…)` divider rules, closed by an
  elapsed/reason divider when the turn ends — and `M-p`/`M-n` walk the
  session's turns.  Copy, refetch, and follow mode (the follow refills
  append each new segment as `replies-changed` frames arrive).
- `dsh-bridge-prompt-mode`: markdown-derived composition buffer with prompt
  history (`M-p`/`M-n`), `C-c C-c` send / `C-c C-d` draft, and `C-c C-m`
  model selection (`completing-read` over the host catalog, with a second
  reasoning-effort prompt when the model advertises efforts).  The prompt
  header line shows `<glyph> <label> · <model> · <ctx%> [ ✓ sent HH:MM]`,
  fed by the `dsh-bridge--session-models` / `dsh-bridge--session-context`
  read-through caches (model refresh on open/rebind/turn frames/select;
  context via the `context` SSE frame plus a `GET /context` seed).
- Session selection is Emacs-side: a default target session plus per-buffer
  session bindings; commands fall back to last-active.
- SSE notification consumer (`make-network-process`, chunked decoding,
  reconnect with retry) that auto-receives outbox pushes into the view buffer
  and also feeds the live status tracker and sessions-list auto-refresh;
  `dsh-bridge-notifications-stop` (latched) to pause the stream,
  `dsh-bridge-receive` to pull manually.
- HTTP via `url-retrieve` + `json.el`, bearer token read from the token file.
- `dsh-bridge-install-plugin`: installs the bundled plugin build into a DSH
  profile (`dsh-bridge-profile`, default `web`) via `dsh plugin add file:...`.
- Plugin probing and management: every request probes `/dsh-bridge/token`
  first (per-session cache, dropped on contradicting evidence), and
  `dsh-bridge--ensure-plugin` diagnoses precisely — "dsh web not running" vs
  "installed but not loaded" vs "not installed" — offering a latched,
  asynchronous install on first failure (`dsh-bridge-install-plugin-offer`,
  default `ask`) and a one-time first-load pointer when the manifest lacks
  the plugin.  A running plugin's version is compared once per session
  against the bundled payload via `GET /dsh-bridge/status`, with a
  reinstall-and-restart pointer on mismatch.  `dsh-bridge-uninstall-plugin`
  pre-checks the profile manifest (pnpm's `remove` of an absent package
  exits 1) and both install paths validate the composed tree with
  `dsh --profile <profile> --dump-config` (asynchronously, on the offer path)
  before suggesting a restart.  The `dsh` CLI itself is resolved via
  `dsh-bridge-dsh-command` (auto-detect, memoized per session: PATH → npm
  global bin → `npx --yes @deepseek-ai/dsh`), since the standard installs
  (`npx @deepseek-ai/dsh web`, `pnpm dsh web`) do not put `dsh` on PATH.

**Tests:** Vitest for the plugin's pure logic (`pnpm test` in `dsh-plugin/`);
ERT for the Elisp helpers (`emacs --batch`).

**Session handling (resume, rename, archive, create; fork excluded) — see
`session-handling-plan.md`:**

- Saved (cold, persisted-only) sessions are first-class. Targeting or
  selecting one resumes it via `ctx.agents.resume()` (shared `composeBridgeAgent`
  selection-install-then-preset-mount helper, with an in-flight dedupe map
  mirroring the gateway's `agentFor`); regained/built agents are not
  plugin-tracked, so a config hot-reload does not kill them. Resume is
  implicit: an explicit cold id resumes on demand, and an untargeted request
  falls back to the most recent cold session when nothing is live. Subagent
  ownership is re-checked at the header boundary (409).
- New routes: `POST /sessions/resume`, `POST /sessions/rename`
  (`ctx.sessionTitle.rename`), `POST /sessions/archive`
  (`ctx.workspaceRegistry.archiveSession` — one-way), `POST /sessions/create`
  (optionally in a new workspace, `ctx.agents.create` +
  `workspace.attachSession`), `GET /workspaces`, and `POST /workspaces/rename`
  (uniqueness check via a pure `workspaceTitleConflict` helper).
- SSE `sessions-changed` frame on session/workspace inventory changes;
  `SessionRow` gains `workspaceId`. The "saved" label is retired from the Emacs
  UI (internal-only): the display cycle collapses to an archived-visibility
  toggle, and saved sessions are targetable. New session-list keys: `R` rename,
  `d` archive, `+` create, `W` rename-workspace; the list auto-refreshes on
  `sessions-changed`.

## Build & mount

- Plugin build: `make build` (installs deps if needed; falls back to direct
  tsdown when pnpm refuses a symlinked `node_modules`) → ESM `lib/index.js`
  (host) + CJS `lib/client.js` (browser, hand-rolled `tsdown.client.config.ts`
  emitting the factory-form bundle per the harness's client-artifact contract).
- Install (dev): `dsh plugin --profile web add link:<abs path to dsh-plugin>`,
  restart `dsh web` (see README for the source-checkout variant).
- Install (packaged): `make package` → `dsh-bridge-<version>.tar` (Emacs
  package bundling the built plugin); `M-x package-install-file`, then
  `M-x dsh-bridge-install-plugin`, then restart `dsh web`.
- Mount shape: dual-face — `"dsh": { "bundle": { "patch": "./cordis.patch.yml" },
  "client": { "platform": "web" } }` plus `exports["./client"]`.
- Restart discipline: `cordis.patch.yml` edits and client-bundle changes
  hot-reload; host plugin code and manifest changes need a `dsh web` restart.
- The harness is pre-release (`^0.1.1-rc.2`) with no compatibility promise —
  re-verify the Cordis service seams and the client-bundle artifact contract
  (`packages/client/tsdown.client.ts`) on any dsh version bump.

## Next steps

In suggested order:

1. **Turn-completion notifications (implemented).** The host subscribes
   `ctx.on('session/event')` and emits `{ kind: "turn-start" | "turn-complete",
   sessionId, reason? }` frames on the SSE stream (non-subagent sessions
   only); `/output` and `/turns` report `running`. Emacs tracks
   the live status (`dsh-bridge--session-status`), re-renders the matching
   buffer header and the sessions-list row, and on turn-complete refetches
   the shown reply (non-popping) or echoes a reason-phrased line per
   `dsh-bridge-turn-complete`. See `dsh-turns-plan.md`.
2. **Session handling: resume, rename, archive, create (fork excluded) (implemented).**
   Broadened from "resume saved sessions". Make saved (cold, persisted-only)
   sessions first-class: targeting or selecting one resumes it via
   `ctx.agents.resume()` (pattern: `ensureSession` in
   `packages/host/apiproxy/src/api-proxy.ts`), after which fetch/prompt
   buffers work on it. Plus the web-UI session/workspace operations that have
   clean service seams: rename session (`ctx.sessionTitle.rename`), archive
   session (`ctx.workspaceRegistry.archiveSession` — one-way: no unarchive
   exists at any layer), create session (optionally in a new workspace), and
   rename workspace (`Workspace.setTitle`). Fork is excluded: the cold-source
   fork logic (turn-boundary cut, seed/meta assembly, preset re-composition,
   workspace inheritance) is inlined in the gateway's `session.fork` handler
   with no service seam to reuse. Resume is implicit, web-UI style: an
   explicit cold target resumes on demand, and an untargeted request falls
   back to the most recent cold session when nothing is live — so the
   "saved" label is retired from the Emacs UI (internal-only). See
   `session-handling-plan.md`.
3. **Turn-aggregated DSH-View buffers (implemented; phase 1 of
   `turn-aggregation-plan.md`).** DSH-View shows one agent *turn* per buffer:
   the session's committed assistant messages grouped by harness turn, their
   segments separated by `(continuing…)` divider rules and closed by an
   elapsed/reason divider, and `M-p`/`M-n` walk turns instead of replies.
   `/replies` became `GET /turns`, whose records carry
   `{ turn, startedAt, endedAt?, reason?, segments }` plus `running` and an
   `epoch`; the pure `assistantTurns` fold walks `Session.surface.nodes` +
   `events[seq]`, so compaction shadowing matches the old reply list. The
   SSE turn frames (`turn-start`/`turn-complete`/`replies-changed`) now carry
   the `turn` number. Follow mode appends each new segment in place
   (preserving point) instead of jumping to the newest one-liner. Phase 2
   (`?since=` incremental retrieval on the `epoch`) is deferred.
4. **`/emacs edit` flow.** Host: register `/emacs` via
   `ctx.commands.register()` plus `POST /dsh-bridge/open { path, line? }`,
   both shelling out to `emacsclient` (spawn template:
   `packages/host/apiproxy/src/native-path-opener.ts`), respecting
   `server-name`. Emacs: optionally `dsh-bridge-open-file` for the reverse
   direction.
5. **Ergonomics, as demand warrants:** a per-session transcript buffer
   (each DSH-View buffer shows one turn, so a continuous read of a whole
   session is not yet available; the `/prompts` + `/turns` material is
   already served, and the turn records carry the boundary metadata a
   transcript renderer needs); a `dsh-bridge-minor-mode` for sending
   from any buffer (the transient menu currently fills this role).

No additional DSH-interface (client plugin) features are planned for now —
candidates (full-transcript export, a user-message action, bridge-status
indicator) are parked pending a decision on what the web UI side should grow.

## Deferred

- **Headless / profile-agnostic mode.** The shipped `headless` profile is
  one-shot task mode (no listening port, exits after one task), so "headless
  support" would mean a long-lived custom profile (`dsh-base` + the bridge
  bundle, via the existing `dsh plugin --profile <name> add` mechanism — no
  harness changes). The known path: drop the `webServer` injection and open
  the plugin's own loopback HTTP listener in `index.ts` (the route/auth/Emacs
  stack is unchanged; `workspaceRegistry` and `sessionProjectionCache` are
  already optional `ctx.get` reads). Deferred because: live sessions are
  per-process, so it could not attach to web-UI sessions anyway (only
  persisted ones); process lifecycle becomes a user support burden; and the
  resulting Emacs ↔ agent prompt/response core overlaps with the ACP
  ecosystem — the harness ships an ACP bridge (`packages/acp/acp`, fresh
  sessions only, committed text only) and agent-shell/acp.el are mature MELPA
  packages. Our differentiator is the companion-to-a-live-session model
  (attach, session inventory, draft review, cross-surface push), not
  Emacs-as-primary-client.
- Bridge-owned sessions via `ctx.agents.create()` with their own model/preset.
- Full live tail of assistant text into Emacs (rejected — that is DSH's job;
  see the README). Turn-completion notices (now implemented) are the
  substitute.
- `emacsclient` push for text transfer (pull won; push may still be wanted for
  the edit flow's file-opens).
- Binding the route beyond loopback (would need real auth, TLS, origin checks).
- **Plugin-management non-goals.** Unattended auto-install (a broken bundle
  fails the entire `dsh web` boot, so installs stay user-confirmed and
  validated); unattended auto-start of `dsh web` (Emacs does not own the
  process; a user-confirmed background start is a possible later addition);
  offering to *restart* a running server (would kill in-flight agent
  sessions); tandem install/uninstall via package.el hooks (package.el
  deliberately has none); reverse bundling (the Emacs package inside the dsh
  plugin) — the plugin-as-payload direction stands.

## References

DSH (in `../deepseek-harness/`):

- `docs/architecture.md` — extension-point map.
- `docs/cookbook/extension-cookbook.md` — plugin patterns; the ACP bridge
  (`packages/acp/acp`) is the closest architectural sibling.
- `docs/subsystems/core.md` — `Agent` handle (`followup`/`steer`/`inject`).
- `docs/subsystems/commands.md` — slash-command registry (edit flow).
- `packages/host/webserver/README.md` — `ctx.webServer.register(route)`.
- `packages/client/ui-message-feedback/` — template client plugin.
- `packages/client/tsdown.client.ts` + `packages/client/web/src/platform.ts` —
  client-bundle artifact contract.
- `packages/host/apiproxy/src/native-path-opener.ts` — spawn template for
  `emacsclient`.
- `packages/host/apiproxy/src/api-proxy.ts` (`ensureSession`) — resume pattern.

Emacs (in `../emacs-30.2/`):

- `lib-src/emacsclient.c`, `lisp/server.el` — edit flow.
- `lisp/url/url.el`, `lisp/url/url-http.el` — HTTP client.
