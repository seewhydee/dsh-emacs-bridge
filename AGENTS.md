# AGENTS.md

`dsh-emacs-bridge` is a two-way bridge between [Emacs](https://www.gnu.org/software/emacs/) and a running DeepSeek Harness (DSH) session. It moves text in both directions over loopback HTTP: Emacs is a companion to a live session, and you can compose prompts in Emacs and read DSH's replies there, but it is not a replacement client. One of the project's design principles is to let DSH shoulder onerous model-wrangling tasks, such as streaming voluminous chain-of-thought tokens.

## Components

- `dsh-plugin/` — the DSH plugin, an npm package named `dsh-emacs-bridge` (Cordis id `dsh-bridge`). A host half (loopback HTTP routes plus an SSE stream) and a browser client half (the "Send to Emacs" action and composer-draft push).
- `emacs/dsh-bridge.el` — the Emacs package, feature `dsh-bridge`, symbol prefix `dsh-bridge-` (internal helpers `dsh-bridge--`).

## Repository layout

```
dsh-plugin/
  src/index.ts            host plugin: thin route wiring over the pure logic below
  src/logic.ts            pure, dependency-free decision logic (no Cordis/dsh runtime imports)
  src/outbox.ts           pure bounded DSH→Emacs outbox
  src/client/             browser client plugin (SendToEmacs.tsx, EmacsMiniIcon.tsx, locales.ts, question-dismiss.ts, index.ts)
  tests/                  Vitest specs for the pure modules
  cordis.patch.yml        bundle patch that inserts the `dsh-bridge` row (id + name)
  package.json            version, `dsh.client` mount, peerDependencies
  tsdown.config.ts        host build → ESM lib/index.js
  tsdown.client.config.ts browser build → CJS lib/client.js (replicates the harness client-artifact contract)
  tsconfig.json / vitest.config.ts
emacs/
  dsh-bridge.el           the Emacs package (loopback interface; loads the companion on demand)
  dsh-bridge-install.el   optional companion library: DSH plugin install/uninstall/diagnosis
  dsh-bridge-tests.el     ERT tests
Makefile   build / package / test / clean
README.md  user-facing install, usage, permissions and failure bounds
PLAN.md    design notes, the locked names table, deferred decisions
COPYING    GPL-3.0
```

The `/dsh-bridge/*` route inventory is documented in the header comment of `dsh-plugin/src/index.ts` (keep it current when routes change); the SSE frame payloads are documented in the doc comments on their constructors in `dsh-plugin/src/logic.ts` (`turnStartMessage`, `turnCompleteMessage`, `contextMessage`, `sessionsChangedMessage`, etc.) — update those when a frame shape changes.

## Names (locked)

| Layer | Name |
|---|---|
| npm package | `dsh-emacs-bridge` (unscoped) |
| Cordis id (plugin row / HMR target) | `dsh-bridge` |
| Emacs feature / file | `dsh-bridge` / `dsh-bridge.el`, plus the optional `dsh-bridge-install` / `dsh-bridge-install.el`; prefix `dsh-bridge-` |

These names appear across README, Makefile, `package.json`, `cordis.patch.yml`, both source trees, and the `/status` identity route. Renaming one means updating every reference together.

## Commands

```sh
make build     # install deps if needed, build the plugin → dsh-plugin/lib/index.js + lib/client.js
make package   # build, then stage dsh-bridge-<version>.tar (Emacs package bundling the built plugin)
make test      # pnpm test in dsh-plugin/ + ERT via emacs --batch
make integration-test   # seam harness (integration/): boot a live DSH host with a mock LLM, run vitest + batch ERT
make clean     # remove .package/ and dsh-bridge-*.tar
```

Inside `dsh-plugin/`: `pnpm install`, `pnpm build` (`tsdown && tsdown --config tsdown.client.config.ts`), `pnpm test` (`vitest run`).

`make build` falls back to invoking `tsdown` directly when `pnpm build` refuses a symlinked `node_modules`; preserve that fallback.

Install: `M-x package-install-file` on the tar, then `M-x dsh-bridge-install-plugin` to install the bundled plugin into DSH.

## Version single source of truth

The `;; Version:` header of `emacs/dsh-bridge.el` is the single source of truth. Two copies must agree with it, and `make package` refuses to build when either drifts:

- the `dsh-bridge-version` defconst in `emacs/dsh-bridge.el` (runtime staleness comparison against `GET /dsh-bridge/status`);
- the `version` field of `dsh-plugin/package.json` (what a source-checkout install reports).

Bump all three at once.

## Architecture rules

### Host plugin (`dsh-plugin/src/`)

- `index.ts` is thin wiring. Keep every decision that can be pure in `logic.ts` (and the outbox in `outbox.ts`); those modules import no Cordis/dsh runtime so Vitest exercises them without booting a host. Do not move runtime imports into them.
- The plugin `inject` list is `['agents', 'webServer', 'sessions', 'sessionPersistence']`. Optional services — `sessionProjectionCache`, `sessionProjections`, `sessionQuery`, `workspaceRegistry`, `agentDefaultModel`, `agentPresets`, `sessionTitle`, `sessionController`, `connection`, `attachments`, `llm` — are read with `ctx.get(...)` and must tolerate `undefined`: a profile lacking one must still boot and serve a degraded-but-working bridge. Follow the existing pattern: a minimal structural interface, a cast, and a documented fallback. Both lists mirror `src/index.ts`; keep them in sync.
- All routes live under the `/dsh-bridge` prefix, registered once inside `ctx.effect(() => webServer.register({...}))`; `register()` returns a disposer so a config hot-reload re-applies cleanly. Every contribution is an effect — `ctx.effect()` / `ctx.on()` / `ctx.inject()`, never a bare registration.
- Bearer auth is required on every route except `/token` and `/status` (fenced to loopback peer + origin) and `/events` (EventSource cannot set headers, so the token is a query parameter). Do not add or loosen a route's fence without updating README.md's "Permissions, authentication, and failure bounds".
- Target resolution is host-side, last-active-by-default, with on-demand resume of cold (persisted-only) sessions. Preserve the failure semantics: 404 unknown id, 409 subagent-owned or no-active-session, 413 oversize body.
- Cold session reads go through the `sessionPersistence` snapshot/handle API: `list()` returns `{header, revision}` snapshots, `stat(id)` is the cheap header read, and `open(id, 'read')` (header + `read()` events, always `close()`) is the full-log read. A cold session's preset is folded in-repo by `sessionPreset` in `logic.ts` (header `agentPreset`, last `agent-preset/selected` event wins — the replica of the harness's `agentPreset` projection; the harness's standalone `resolveSessionPreset` helper was removed).
- The model catalog and model changes are proxied through the host's own Typert Remote endpoints `session/modelCatalog` / `session/selectModel` over loopback `/api` (slash-form endpoint names, `{args}` named-argument payloads — see `rpcArgsPayload`; the channel is browser-authenticated, so `rpcCall` mints the authority-bound cookie via the optional `connection` service's `authenticatedUrl`), so parity with the web UI is exact. The session's current selection is read from the `modelSelection` projection (`next ?? lastUsed ?? catalog.default`, mirroring the web model directory), not from a removed `session.models` RPC. A bridge-composed agent's selection ref (`bridgeSelectionRef`) reads the same projection state live, so a mid-session switch takes effect on its next step.
- Branching a completed-turn prefix (`POST /dsh-bridge/fork { sessionId?, atSeq? }`) goes through the optional `sessionController` service's `fork({sessionId, atSeq?})`, deliberately not the `session/fork` Remote: the source id is resolved read-only (never resumed — the fork seam observes it cold-safe), a subagent source is 409, and the seam's `RemoteError` taxonomy is duck-typed by its `isDSHRemoteError` marker (never `instanceof`) because a bundle boundary can separate the class. `/turns` turn records carry `endSeq` (the `turn/end` event's `seq`, folded in `logic.ts`) as the client-side fork anchor; an open turn has no `endSeq`, so it cannot be branched. A profile without `sessionProjections` makes `presetForObservation` throw a plain `Error` that escapes the seam unwrapped and surfaces as a 500 — an accepted asymmetry, not pre-checked.
- Ask-user is answered through the `user-questions/request` scoped waterfall (`@deepseek-ai/dsh-user-questions` types are a type-only import — never a runtime dependency; the request-event type lives in the `./types` subpath export). The bridge's listener is registered with `{ prepend: true }` so it runs outside the api-remotes browser forwarder. While an Emacs SSE client is connected the bridge registers a pending question for Emacs and, when the web UI is also open (`browserSseClients` non-empty), still calls `next()` so the browser forwarder presents its own panel: the two race, whichever answers first settles the request, and the `ask-user-resolved` frame (which carries the asker's question ids) is what lets the browser plugin dismiss the web panel after an Emacs answer. A browser-side rejection is swallowed into a never-settling branch, never ending the race — Emacs stays the deciding answerer — except the web UI's own cancel (`ASK_CANCELLED`), which settles the ask as cancelled rather than parking the turn on Emacs. Otherwise the listener delegates with `next()` and the browser flow is untouched. SSE clients are split by identity: the browser plugin's draft-push stream connects with `?purpose=draft` and never counts as Emacs (it exists whenever the web UI is open and never answers — counting it would strand questions), while unmarked connections are Emacs and alone are eligible to answer (and to receive the pending-question replay on connect). Cancelling from Emacs rejects the wait (the asking tool call fails); do not turn cancel into `next()` delegation without a deliberate UX decision.
- Attachments in `POST /dsh-bridge/send` are **path-based**: the body's optional `attachments: [{path, name?}]` names absolute host-local files and the host reads them, so no bytes cross the 1 MiB JSON body cap. The bridge and the DSH host must share a filesystem; a containerized host or port-forwarded remote Emacs is unsupported (and fails loudly: 400 on an unreadable path). Content signatures (PNG/JPEG/GIF/WebP) decide image vs file — never the extension — because the store rejects a declared type that disagrees with the bytes (`IMAGE_TYPE_MISMATCH`). Images commit through `ctx.attachments.saveImages` (one all-or-nothing batch), files stream through `saveFileStream`; the exact returned refs become `image`/`file` content blocks in a `createUserMessage` handed to `agent.followup`. Before a text-only model is asked to accept an image, the route pre-rejects with `MODEL_DOES_NOT_SUPPORT_IMAGES` (optional `ctx.get('llm')` + the live `modelSelection` projection; best-effort — an unresolvable route skips the check and lets the harness's own text-model image projection take over).
- The attachment seam is the store, **not** the browser `fileUploads` receipt flow: receipts exist to stop an untrusted wire caller citing bytes it did not upload, while the bridge is a trusted host plugin (the harness's own subagent prompt admits images directly through `ctx.get('attachments')`), and `attachment-local` is in the base bundle while `file-upload` is web-app only. Accepted parity deviations from `session/prompt`: no `requestId` dedupe, no per-agent image-admission serialization, no disposed-agent re-check, and route-mapped errors instead of `session/agent-busy`. `AttachmentError` codes route through the pure `attachmentErrorHttpStatus`: size-family codes 413, caller-correctable content/count codes 400, a file-incapable backend 501, storage faults and unknown codes 500 (a write failure is not the caller's fault). The `stat`→sniff→read sequence is deliberately unlocked; a file changed mid-flight surfaces as a store error, not corrupt data. Caps live in `logic.ts` (`MAX_ATTACHMENTS` 20, `MAX_ATTACHMENT_FILE_BYTES` 200 MiB) and are user-visible in README.
- Client-side, attachments are **in-buffer MML-like tags**, mirroring `message-mode`/`mml-attach-file`: `C-c C-a` (`dsh-bridge-attach-file`) inserts `<#attachment filename="…">` at point (Dired marks attach as a batch), `M-x dsh-bridge-attach-buffer-file` attaches the visited file, deleting a line detaches, and the header shows `📎N`. The tags are stripped and parsed at send (`dsh-bridge--parse-attachments` returns the clean text plus ordered `(:path :name)` plists); they never enter the sent text, the prompt history, a composer draft, or the kept text after a successful send. Message mode's type/description/disposition prompts have no analogue (DSH sniffs the image type and has no such fields). `dsh-bridge-send` (region/buffer send) also parses tags — only those inside the sent region — and leaves them in the source buffer, so a repeat region-send re-uploads the bytes; this extends the plan's original prompt-buffer-only scope (recorded in PLAN.md candidate 11).

### Client plugin (`dsh-plugin/src/client/`)

- The "Send to Emacs" action registers into the `conversation.chat.assistant-actions` slot. The locale namespace is `dsh-emacs-bridge`; `zh` is the key-set source of truth and `en` must remain a complete mirror (`satisfies Record<DshBridgeKey, string>`).
- The browser plugin also consumes the host's `ask-user-resolved` SSE frames and cancels the matching pending question in `uiSession.pendingInteractions` (matched by session + the asker's question ids via the pure `question-dismiss.ts`), so answering in Emacs closes the web UI's own panel. `uiSession` is an optional collaborator (`ctx.inject`): without it the panel is simply not dismissed.
- `tsdown.client.config.ts` replicates the harness's client-artifact contract (factory-form banner/footer/intro wrapper, module-table externals, bundle-purity gate, `define` substitutions) because the harness's shared preset is repo-locked and cannot run for an out-of-tree package. Keep it in sync with the harness preset on any DSH version bump.

### Build and restart discipline

- `cordis.patch.yml` edits and client-bundle changes hot-reload; host plugin code and `package.json` (manifest) changes require a `dsh web` restart.
- The harness is pre-release with no compatibility promise (see `peerDependencies` in `dsh-plugin/package.json` for the pinned range). On any version bump, re-verify the Cordis service seams, the client-bundle artifact contract, and the ask-user host coupling: the `user-questions/request` scoped waterfall (registration order decides which answerer sees a request — the bridge prepends) and the `AskUserQuestionAnswer` shape its listener returns.

### Emacs package (`emacs/dsh-bridge.el`)

- Two libraries, `lexical-binding: t`.  `dsh-bridge.el` (feature `dsh-bridge`) is self-contained and works entirely over the loopback interface; `dsh-bridge-install.el` (feature `dsh-bridge-install`) is the optional companion that holds every definition which runs the `dsh` CLI or reads the DSH profile.  All symbols use the `dsh-bridge-` prefix; internal helpers use `dsh-bridge--`.
- `dsh-bridge.el` must never `require` the companion at load time; it has to keep working when the companion file is absent.  The sole seam is `dsh-bridge--ensure-plugin`, which on a non-`running` status calls `(require 'dsh-bridge-install nil t)` and then `dsh-bridge-install--diagnose` when that entry point is fbound, falling back to `dsh-bridge--warn-plugin-unavailable` otherwise.  There is deliberately no sibling-path lookup: the companion must be on `load-path` (the package tar's autoloads put it there), and a source checkout should add `emacs/` to `load-path` or load both files.
- Both files ship in the package tar and `make package` lists both explicitly.  The companion's two `defcustom`s and its `dsh-bridge-install-plugin` / `dsh-bridge-uninstall-plugin` carry `;;;###autoload` cookies, so Customize can reach the options (`customize-option`, saved values) before the library loads.  Cookies alone do not put the options in `M-x customize-group dsh-bridge`, though; `dsh-bridge.el` also sets the group's `custom-loads` to `"dsh-bridge-install"` (via `put`, not `custom-add-load`, to avoid loading `cus-edit`), which is what makes browsing the group load the companion and list them.  Keep both halves if the options move again.
- User-tunable behavior is a `defcustom` in the `dsh-bridge` group; do not hardcode what should be configurable.
- Session targeting: a command that acts on a session (sends, model changes, answering a question) resolves its target with `dsh-bridge--effective-session` and refuses when that is nil — a nil target is legitimate ("host resolves last-active") for reads and sends, but guessing one for a mutation is not.  The display-only paths instead widen `--effective-session` with the advisory `--last-resolved-active` / `--cache-last-active` caches inline (the dispatcher header, the prompt header line and its metadata fetch, and the describe fallback); never use those caches to choose a target, and do not key the `send-and-exit` resend guard on them.  `--last-resolved-active` records the host's answer to a request with no explicit session (written by `--record-last-resolved`, cleared in `--notification-handle-events` when a `turn-start` frame names a different session); it is preferred over the computed `--cache-last-active` because only the host sees the cold-resume fallback and the live-agent gate.  When `dsh-bridge-answer` has no explicit target, it uses the only pending question if exactly one exists and otherwise refuses.
- HTTP uses `url-retrieve` + `json.el`; the bearer token is read from the token file. SSE notifications use `make-network-process` with chunked decoding and reconnect-with-retry; keep the latched start/stop (`dsh-bridge-notifications-start` / `dsh-bridge-notifications-stop`) semantics intact.
- Buffer modes derive from `gfm-view-mode` falling back to `special-mode` (DSH-View), `tabulated-list-mode` (DSH-Sessions), `markdown-mode` falling back to `text-mode` (DSH-Prompt), and `help-mode` (DSH-Describe, the read-only session report: one reusable buffer with `help-setup-xref`/`help-make-xrefs` navigation). The view/prompt fallbacks are chosen at load time via a conditional macro (`dsh-bridge--define-view-mode` / `dsh-bridge--define-prompt-mode`), driven by the `dsh-bridge-view-gfm` / `dsh-bridge-prompt-markdown` defcustoms. The dispatcher is a `transient-define-prefix`.
- Requires Emacs 29.1+. Paths given to `dsh-bridge-dsh-command` are not tilde-expanded; document full paths.
- DSH-View bodies are filled incrementally: `dsh-bridge--view-fill` records a buffer-local provenance (session, history epoch, turn, `(step . time)` segment keys, body/tail character lengths) and splices a grown turn's new segments in front of the recorded body end, leaving text already on screen (and point inside it) untouched. This is sound because of the plugin's `/turns` epoch contract (`turnsSince`: an equal `surface.replaceGeneration` means the turn list can only have grown by appending segments). Any mismatch — non-numeric epoch, changed turn, segment-key gap, buffer drift, or no provenance — falls back to a full re-render. Point at the recorded body end follows the new tail; point inside the body is never moved. Do not add a splice path that cannot prove those checks.
- ERT tests live in `emacs/dsh-bridge-tests.el` and run headless.

## Testing

- Pure plugin logic is covered by Vitest (`dsh-plugin/tests/*.spec.ts`). Add specs for `logic.ts` and `outbox.ts` behavior rather than `index.ts` wiring.
- Elisp helpers are covered by ERT, run in batch via `make test`.
- Tests describe behavior: when a change alters observable behavior, update its test in the same change.
- A change is complete when `make build && make test` passes.
- The seam harness in `integration/` (`make integration-test`) is the version-bump gate for the harness seams AGENTS.md lists ("re-verify the Cordis service seams, the client-bundle artifact contract, and the ask-user host coupling"). It boots the real plugin against a live host with a mock LLM. Run it before committing any host-plane (`dsh-plugin/src/`) change and before a release; it is deliberately not part of `make test`, which stays unit-only and fast.

## Security and failure bounds

- Loopback only: no route may bind beyond loopback, and no third-party service is contacted. Keep the peer-address + origin fences on `/token` and `/status`.
- Shared bearer token at `$DSH_HOME/dsh-bridge-token` (default `~/.dsh/dsh-bridge-token`), generated on first use with mode 0600, compared constant-time.
- HTTP request bodies are capped (currently 1 MiB, 413 on oversize).
- The DSH→Emacs outbox is bounded (currently 100 unacknowledged entries, `OUTBOX_DEFAULT_CAP` in `outbox.ts`), evicts the oldest, and reports overflow.

These are user-visible invariants; any change must update README.md's "Permissions, authentication, and failure bounds" section alongside the code.

## Licensing and hygiene

- Every source file carries the GPL-3.0-or-later header (see `COPYING`); add it to new files.
- Build outputs and dependencies are gitignored (`node_modules`, `lib/`, `.package/`, `dsh-bridge-*.tar`, elisp artifacts, `pnpm-lock.yaml`). Keep source committed and artifacts ignored.

## Adjacent reference trees (not assumed)

For background, the DeepSeek Harness sources may be present in a sibling directory (`../deepseek-harness/`) and the Emacs sources in `../emacs-*/`. The harness's own `AGENTS.md` and `docs/`, and the Emacs `lisp/`/`lib-src/` sources, are useful for verifying service seams and details. Do not assume these directories exist; if they do, they must be treated as reference-only and not part of this repository. The project must build and test standalone, and anything this repo relies on knowing about the harness's contracts must be captured in-repo. For instance, this is why `tsdown.client.config.ts` inlines the client-artifact contract instead of importing the harness's shared preset.
