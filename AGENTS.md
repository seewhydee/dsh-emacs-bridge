# AGENTS.md

`dsh-emacs-bridge` is a two-way bridge between [Emacs](https://www.gnu.org/software/emacs/) and a running DeepSeek Harness (DSH) session, over loopback HTTP + SSE. Emacs is a companion to a live session, not a replacement client. A design principle: let DSH shoulder onerous model-wrangling (e.g. streaming chain-of-thought).

## Repository layout

- `dsh-plugin/` — the DSH plugin (npm package `dsh-emacs-bridge`, Cordis id `dsh-bridge`).
  - `src/index.ts` — host plugin: thin route wiring only.
  - `src/logic.ts`, `src/outbox.ts` — pure, dependency-free logic (no Cordis/dsh runtime imports).
  - `src/client/` — browser client half ("Send to Emacs" action, draft push, SSE-driven panel dismissal).
  - `tests/` — Vitest specs for the pure modules.
  - `tsdown.config.ts` / `tsdown.client.config.ts` — host build → ESM `lib/index.js`; browser build → CJS `lib/client.js`.
- `emacs/`
  - `dsh-bridge.el` — the Emacs package (feature `dsh-bridge`, prefix `dsh-bridge-`, internal `dsh-bridge--`), self-contained over the loopback interface.
  - `dsh-bridge-install.el` — optional companion: every definition that runs the `dsh` CLI or reads the DSH profile.
  - `dsh-bridge-tests.el` — ERT tests.
- `integration/` — seam harness: boots the real plugin against a live DSH host with a mock LLM.
- `Makefile`, `README.md` (user-facing install/usage/permissions), `PLAN.md` (design notes), `COPYING` (GPL-3.0).

Documentation pointers, kept current by policy:

- The `/dsh-bridge/*` route inventory lives in the header comment of `dsh-plugin/src/index.ts` — update it when routes change.
- SSE frame payloads are documented in doc comments on their constructors in `dsh-plugin/src/logic.ts` — update them when a frame shape changes.

## Maintaining this file

Update AGENTS.md sparingly. A new entry must pass one of these tests:

- It is a **policy or invariant** a code reader cannot discover from the code (locked names, the version-bump rule, fence/auth policy, testing gates, licensing).
- It is a **cross-cutting constraint** that binds changes beyond the one at hand ("no route binds beyond loopback", "`logic.ts` imports no runtime", "every contribution is an effect").
- It is a **pointer** to where a contract is authoritatively documented (the route inventory in `index.ts`, the SSE frames in `logic.ts`).

Do not add an entry merely to document some feature or fix you just implemented. Behavior descriptions and implementation details belong in the code and its comments, in README.md (high-profile user-facing behavior), or in PLAN.md (design rationale) — not here. A useful gut check: would an agent working on an *unrelated* part of the project go wrong without knowing this? If not, leave it out.

## Names (locked)

| Layer | Name |
|---|---|
| npm package | `dsh-emacs-bridge` (unscoped) |
| Cordis id (plugin row / HMR target) | `dsh-bridge` |
| Emacs feature / file | `dsh-bridge` / `dsh-bridge.el`, plus optional `dsh-bridge-install` / `dsh-bridge-install.el`; prefix `dsh-bridge-` |

These names appear across README, Makefile, `package.json`, `cordis.patch.yml`, both source trees, and the `/status` identity route. Renaming one means updating every reference together.

## Commands

```sh
make build     # build the plugin → dsh-plugin/lib/index.js + lib/client.js
make package   # build, then stage dsh-bridge-<version>.tar (Emacs package bundling the built plugin)
make test      # pnpm test in dsh-plugin/ + ERT via emacs --batch
make integration-test   # seam harness in integration/
make clean     # remove .package/ and dsh-bridge-*.tar
```

Inside `dsh-plugin/`: `pnpm install`, `pnpm build`, `pnpm test`. `make build` falls back to invoking `tsdown` directly when `pnpm build` refuses a symlinked `node_modules`; preserve that fallback.

## Version single source of truth

The `;; Version:` header of `emacs/dsh-bridge.el` is the source of truth. Two copies must agree with it (`make package` refuses to build on drift): the `dsh-bridge-version` defconst in the same file, and the `version` field of `dsh-plugin/package.json`. Bump all three at once.

## Architecture policy

### README.md

The README.md serves as a short introduction and quickstart; it is not an exhaustive user manual, and it is NOT a place to document minor tweaks. Keep the contents factually correct; if you make an important user-facing change, consider documenting it here, but note that the bar for inclusion is high. If in doubt, suggest the `README.md` change to the user as an optional follow-up.

### Host plugin (`dsh-plugin/src/`)

- `index.ts` is thin wiring. Keep every decision that can be pure in `logic.ts` / `outbox.ts`; those modules must never import the Cordis/dsh runtime, so Vitest can exercise them without booting a host.
- Required services are in the `inject` list; optional services are read with `ctx.get(...)` and must tolerate `undefined` — a profile lacking one must still boot a degraded-but-working bridge. Follow the existing pattern (minimal structural interface, cast, documented fallback). Keep the lists in sync with `src/index.ts`.
- All routes live under `/dsh-bridge`, registered once inside `ctx.effect(...)`; every contribution is an effect (`ctx.effect` / `ctx.on` / `ctx.inject`), never a bare registration.
- Bearer auth is required on every route except `/token` and `/status` (loopback peer + origin fences) and `/events` (EventSource token query parameter). Never add or loosen a fence without updating README.md's "Permissions, authentication, and failure bounds".
- Workspace display titles are unique for this bridge: both title writers (`/workspaces/rename`, `POST /sessions/create`) reject collisions with 409 and run inside `KeyedSerial.runExclusive('workspace-titles', ...)`. Do not add a workspace-title writer outside that section.
- Target resolution is host-side, last-active-by-default, with on-demand resume of cold sessions. Preserve the failure semantics: 404 unknown id, 409 subagent-owned / no-active-session / archived (an archived session is readable through the read-only routes but is never a run target until `POST /sessions/unarchive` restores it), 413 oversize body.
- Cold session reads use the `sessionPersistence` snapshot/handle API; cold presets and titles are folded in-repo in `logic.ts` (a cached null title is not authoritative — fall through to the log fold).
- Model catalog/selection are proxied through the host's own Typert Remote endpoints so parity with the web UI is exact.
- Fork goes through the optional `sessionController` service, deliberately not the `session/fork` Remote; `RemoteError` is duck-typed via its `isDSHRemoteError` marker, never `instanceof` (bundle boundaries).
- The changed-files fold walks the **raw log**, not the session surface (`tool/call` is log-only). `/turns` carries only `{path, op}`. Bounds live in `logic.ts` (`MAX_CHANGED_*`) and are user-visible in README.
- Ask-user and approval are answered through the `user-questions/request` / `approval/request` scoped waterfalls, registered with `{ prepend: true }`; their type packages are **type-only imports, never runtime dependencies**. Emacs races the web UI and stays the deciding answerer (browser-side rejections are swallowed into a never-settling branch). SSE clients are split by identity: the browser draft-push stream (`?purpose=draft`) never counts as Emacs; `?answer=0` is a notify-only Emacs that cannot settle approvals. Cancelling semantics differ per waterfall (ask-user cancel rejects the wait; approval cancel settles `'cancelled'`) — do not change either without a deliberate UX decision.
- Attachments in `POST /send` are path-based (absolute host-local paths; no bytes cross the body cap) and content-sniffed (signature, never extension). The seam is the attachments store, not the browser `fileUploads` receipt flow. Caps live in `logic.ts` (`MAX_ATTACHMENTS`, `MAX_ATTACHMENT_FILE_BYTES`) and are user-visible in README.
- Client-side (Emacs), attachments are in-buffer `<#attachment …>` tags, recognized textually and font-locked — never via text properties.

### Client plugin (`dsh-plugin/src/client/`)

- The locale namespace is `dsh-emacs-bridge`; `zh` is the key-set source of truth and `en` must remain a complete mirror.
- The browser plugin dismisses its own ask/approval panels on the host's `*-resolved` SSE frames (pure matchers in `question-dismiss.ts` / `approval-dismiss.ts`); `uiSession` is an optional collaborator.
- `tsdown.client.config.ts` replicates the harness's client-artifact contract (which is repo-locked and cannot run out-of-tree). Keep it in sync with the harness preset on any DSH version bump.

### Build and restart discipline

- `cordis.patch.yml` edits and client-bundle changes hot-reload; host plugin code and `package.json` changes require a `dsh web` restart.
- The harness is pre-release with no compatibility promise (pinned range in `dsh-plugin/package.json` `peerDependencies`). On any version bump, re-verify the seams listed in the integration harness (`make integration-test` is the gate).

### Emacs package (`emacs/`)

- Two libraries, `lexical-binding: t`. `dsh-bridge.el` is self-contained and must never `require` the companion at load time; the sole seam is `dsh-bridge--ensure-plugin`. Both files ship in the package tar.
- Docstrings state the function's intention, document its arguments and return value, and flag gotchas — nothing more. The code, not the docstring, is the contract: never use the docstring to narrate the implementation step by step. Tricky implementation details (why a splice is sound, why a race is safe) belong in code comments next to the code they describe.
- A command that mutates a session resolves its target with `dsh-bridge--interaction-session` (view: shown session; prompt: effective target; sessions list: row at point; describe: shown session) and refuses with a `user-error` when nil; the advisory last-active caches are display-only, never a mutation target.
- DSH-View bodies are filled incrementally by `dsh-bridge--view-fill` under a recorded provenance; any mismatch falls back to a full re-render. Do not add a splice path that cannot prove those checks, and keep terminal furniture (answer/approval notes, changed-files footer) out of the body.
- DSH-Question buffer edits go through `dsh-bridge--question-edit` (read-only, undo suppressed, modified flag cleared). A state change patches the affected region, found by text property, instead of re-rendering: a question's `detail`, and any markers or overlays inside it, must survive, so `dsh-bridge--question-render` stays the initial paint and the fallback only. A patch must re-apply the buffer's own question-id string, never the caller's — `next-single-property-change` compares with `eq`, so an equal-but-distinct string splits a block in two.
- Requires Emacs 29.1+. Paths given to `dsh-bridge-dsh-command` are not tilde-expanded; document full paths.

## Testing

- Pure plugin logic: Vitest (`dsh-plugin/tests/*.spec.ts`); spec `logic.ts` / `outbox.ts` behavior, not `index.ts` wiring.
- Elisp: ERT (`emacs/dsh-bridge-tests.el`), run headless via `make test`.
- The unit tests describe behavior: when you alter observable behavior, update its test in the same change.
- A change is complete when `make build && make test` passes

There is also an integration test suite, deliberately not part of `make test`. Integration tests target harness seams; run them (and possibly update the test suite) alongside any host-plane change or version-bump.  Read `integration/README.md` for information on how to run these tests, including what to do if `dsh` is not on PATH.

## Security and failure bounds

- Loopback only: no route may bind beyond loopback, and no third-party service is contacted. Keep the peer-address + origin fences on `/token` and `/status`.
- Shared bearer token at `$DSH_HOME/dsh-bridge-token` (default `~/.dsh/dsh-bridge-token`), generated on first use with mode 0600, compared constant-time.
- HTTP request bodies are capped (currently 1 MiB, 413 on oversize).
- The DSH→Emacs outbox is bounded (`OUTBOX_DEFAULT_CAP` in `outbox.ts`), evicts the oldest, and reports overflow.

These are user-visible invariants; any change must update README.md's "Permissions, authentication, and failure bounds" section alongside the code.

## Licensing and hygiene

- Every source file carries the GPL-3.0-or-later header (see `COPYING`); add it to new files.
- Build outputs and dependencies are gitignored (`node_modules`, `lib/`, `.package/`, `dsh-bridge-*.tar`, elisp artifacts, `pnpm-lock.yaml`). Keep source committed and artifacts ignored.

## Adjacent reference trees (not assumed)

The DeepSeek Harness sources may be present in a sibling directory (`../deepseek-harness/`) and Emacs sources in `../emacs-*/`; treat them as reference-only. The project must build and test standalone; anything this repo relies on knowing about the harness's contracts must be captured in-repo (e.g. `tsdown.client.config.ts` inlines the client-artifact contract instead of importing the harness preset).
