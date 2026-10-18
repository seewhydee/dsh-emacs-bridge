# AGENTS.md

`dsh-emacs-bridge` is a two-way bridge between GNU Emacs and a running DeepSeek Harness (DSH) session, over loopback HTTP + SSE. Key design principles: (i) let DSH shoulder onerous model-wrangling like streaming chain-of-thought; (ii) offer a DSH controller that fits Emacs UX conventions, not just remaking the DSH web interface inside Emacs.

## Repository layout

- `dsh-plugin/` — the DSH plugin (npm package `dsh-emacs-bridge`, Cordis id `dsh-bridge`).
  - `src/index.ts` — host plugin: thin route wiring only.
  - `src/logic.ts`, `src/outbox.ts` — pure, dependency-free logic (no Cordis/dsh runtime imports).
  - `src/client/` — browser client half ("Send to Emacs" action, draft push, SSE-driven panel dismissal, Plugins-page Emacs-install card).
  - `tests/` — Vitest specs for the pure modules.
  - `tsdown.config.ts` / `tsdown.client.config.ts` — host build → ESM `lib/index.js`; browser build → CJS `lib/client.js`.
- `emacs/`
  - `dsh-bridge.el` — the Emacs package (feature `dsh-bridge`, prefix `dsh-bridge-`, internal `dsh-bridge--`), self-contained over the loopback interface.
  - `dsh-bridge-tests.el` — ERT tests.
- `integration/` — seam harness: boots the real plugin against a live DSH host with a mock LLM.
- `Makefile`, `README.md` (user-facing install/usage/permissions), `PLAN.md` (design notes), `COPYING` (GPL-3.0).

Documentation pointers, kept current by policy:

- The `/dsh-bridge/*` route inventory lives in the header comment of `dsh-plugin/src/index.ts` — update it when routes change.
- SSE frame payloads are documented in doc comments on their constructors in `dsh-plugin/src/logic.ts` — update them when a frame shape changes.

## Maintaining this file

Update AGENTS.md sparingly. A new entry must pass one of these tests:

- It is a **policy or invariant** a code reader cannot easily discover (locked names, the version-bump rule, fence/auth policy, testing gates, licensing).
- It is a **cross-cutting constraint** that binds changes beyond the one at hand ("no route binds beyond loopback", "`logic.ts` imports no runtime", "every contribution is an effect").
- It is a **pointer** to where a contract is authoritatively documented (the route inventory in `index.ts`, the SSE frames in `logic.ts`).

Do not add an entry merely to document some change you just made. Behavior descriptions and implementation details belong in the code and its comments, in README.md (high-profile user-facing behavior), or in PLAN.md (design rationale), not here. A useful gut check: would an agent working on an *unrelated* part of the project go wrong without knowing this? If not, omit it.

## Names

| Layer | Name |
|---|---|
| npm package | `dsh-emacs-bridge` (unscoped) |
| Cordis id (plugin row / HMR target) | `dsh-bridge` |
| Emacs feature / file | `dsh-bridge` / `dsh-bridge.el`; prefix `dsh-bridge-` |

These names appear across README, Makefile, `package.json`, `cordis.patch.yml`, both source trees, and the `/status` identity route. Renaming one means updating every reference together.

The Cordis id is never an install name: every install surface (the CLI and the Plugins-page dialog) reads a bare token as an npm package name, and `dsh-bridge` on npm is an unrelated third-party plugin. `dsh-emacs-bridge` is the only bare-name install spec.

## Commands

```sh
make build     # build the plugin → dsh-plugin/lib/index.js + lib/client.js
make package   # stage dsh-bridge-<version>.tar (pure-elisp Emacs package; no Node toolchain needed)
make release   # build, then pack + stage both release artifacts in .release/ (publish per "Release procedure")
make publish   # upload the staged plugin tarball to npm (refuses unless HEAD is the release tag)
make test      # pnpm test in dsh-plugin/ + ERT via emacs --batch
make integration-test   # seam harness in integration/
make clean     # remove .package/, .release/, dsh-bridge-*.tar, and the packed .tgz
```

Inside `dsh-plugin/`: `pnpm install`, `pnpm build`, `pnpm test`. `make build` falls back to invoking `tsdown` directly when `pnpm build` refuses a symlinked `node_modules`; preserve that fallback.

Do not do `git commit` or `git push` unless the user explicitly instructs.  In the usual workflow, after a change is made, the user and/or other agents will review before a commit is made.

## Version single source of truth

The `;; Version:` header of `emacs/dsh-bridge.el` is the source of truth. The `dsh-bridge-version` defconst in the same file and the `version` field of `dsh-plugin/package.json` must agree with it, and both `make package` and the package's `prepack` hook (which runs on every `pnpm pack` / `pnpm publish` / `npm publish` of `dsh-plugin/`, including ones that never touch the Makefile) refuse on drift. Bump all three at once, in the post-release bump below — the only commit that edits the version.

The default branch carries the version of the **next** release, never the last one, so a published version appears in exactly one tree: the tagged commit's. A build from HEAD is a development build, not a release; never distribute or upload one.

A version is a plain `X.Y.Z` literal in all three places: `package.el` cannot parse a `-dev` suffix (`version-to-list` returns nil), and build-time generation would put stamping back into the shipped elisp. `README.md` names no version, so no release step edits it.

## Release procedure

Two artifacts are attached to a GitHub release — `dsh-emacs-bridge-<version>.tgz` (the plugin, via `pnpm pack`) and `dsh-bridge-<version>.tar` (the pure-elisp package) — and `make publish` uploads that same plugin tarball, byte for byte, to npm, so both channels hold one build. The plugin tarball also carries `emacs/dsh-bridge.el`, staged by the `prepack` hook at pack time, so the artifacts cannot drift within a release; because the halves verify each other by exact version, a release always ships both. `make release` is local-only — build, pack, and stage both under `.release/` — and safe to re-run. Publishing is a separate, deliberate step:

1. Gate on `make build && make test` green, plus `make integration-test` for host-plane changes. The version already in the tree is the version being released; do not edit it.
2. `make release`.
3. `git tag v<version>` at that commit; push branch and tag. The `v<version>` convention is user-visible contract: release asset URLs embed it.
4. Publish the plugin to npm with `make publish` (refuses unless HEAD is exactly `v<version>` and the tree is clean; uploads `.release/dsh-emacs-bridge-<version>.tgz` and prints its sha256; answer the 2FA prompt). The first publish of a new package additionally preflights `npm publish --dry-run .release/dsh-emacs-bridge-<version>.tgz` and checks the file listing. The package carries no `private: true` — the tag check replaces it, and adding that field makes every publish impossible.
5. Preflight `gh auth status`, then `gh release create v<version> .release/dsh-emacs-bridge-<version>.tgz .release/dsh-bridge-<version>.tar --title "v<version>"` — the same plugin tarball the registry now holds.
6. Acceptance walk: on a clean profile, follow README's Installation end-to-end on both channels (a first install hot-applies — no `dsh web` restart): `dsh plugin --profile web add dsh-emacs-bridge@<version>`, naming the exact version because pnpm ≥ 11 holds back releases younger than a day, and the tarball URL. Then the upgrade path (a later `dsh plugin add` replaces the installed plugin; restart `dsh web`) and the Plugins-page Emacs-package card.
7. Only once the release is published and the walk passes, bump the three version copies (above) to the next patch (e.g. `0.17.0` → `0.17.1`), commit, and push — bump last.

A release carrying a breaking install or protocol change renumbers to the next minor in one ordinary commit before step 1; the minor is reserved for that meaning, and a version skipped by such a renumber is never released. Additive changes take a patch.

Releases are linear and forward-only: a fix ships as the next version from the default branch, never as a re-cut of a published release and never from a release branch.

Published releases are immutable on both channels: never edit or re-upload assets on an existing release, never re-publish an npm version — downstream installs pin the URL or the registry integrity hash — and never treat `npm unpublish` as a fix, since it burns the version number and breaks anyone who already installed it. Fixes ship as a new patch version. `.release/` is staging, not an archive: every `make release` replaces it, so reproducing a published version means checking out its tag.

## Architecture policy

### README.md

README.md is a short introduction and quickstart, not an exhaustive user manual, and never a place to document minor tweaks. Keep it factually correct. If you make an important user-facing change, consider documenting it there, but the bar for inclusion is high; if in doubt, suggest the change to the user as an optional follow-up.

### Host plugin (`dsh-plugin/src/`)

- `index.ts` is thin wiring. Keep every decision that can be pure in `logic.ts` / `outbox.ts`; those modules must never import the Cordis/dsh runtime, so Vitest can exercise them without booting a host.
- Required services are in the `inject` list; optional services are read with `ctx.get(...)` and must tolerate `undefined` — a profile lacking one must still boot a degraded-but-working bridge. Follow the existing pattern (minimal structural interface, cast, documented fallback). Keep the lists in sync with `src/index.ts`.
- All routes live under `/dsh-bridge`, registered once inside `ctx.effect(...)`; every contribution is an effect (`ctx.effect` / `ctx.on` / `ctx.inject`), never a bare registration.
- Bearer auth is required on every route except `/token` and `/status` (loopback peer + origin fences) and `/events` (EventSource token query parameter). Never add or loosen a fence without updating README.md's "Permissions, authentication, and failure bounds".
- The plugin's `Config` fields (`emacsCommand`, `emacsInstallTimeoutMs`) must stay `.volatile()`: the settings forms projection carries only volatile Config fields (an ordinary field never reaches the Plugins-page configure page, so the row would silently lose its form), and volatile writes apply live with no `dsh web` restart.
- Workspace display titles are unique for this bridge: both title writers (`/workspaces/rename`, `POST /sessions/create`) reject collisions with 409 and run inside `KeyedSerial.runExclusive('workspace-titles', ...)`. Do not add a workspace-title writer outside that section.
- Target resolution is host-side, last-active-by-default, with on-demand resume of cold sessions. Preserve the failure semantics: 404 unknown id, 409 subagent-owned / no-active-session / archived (an archived session is readable through the read-only routes but is never a run target until `POST /sessions/unarchive` restores it), 413 oversize body.
- Cold session reads use the `sessionPersistence` snapshot/handle API; cold presets and titles are folded in-repo in `logic.ts` (a cached null title is not authoritative — fall through to the log fold).
- Model catalog/selection are proxied through the host's own Typert Remote endpoints so parity with the web UI is exact.
- Fork goes through the optional `sessionController` service, deliberately not the `session/fork` Remote; `RemoteError` is duck-typed via its `isDSHRemoteError` marker, never `instanceof` (bundle boundaries).
- The changed-files fold walks the **raw log**, not the session surface (`tool/call` is log-only). `/turns` carries only `{path, op}`. Bounds live in `logic.ts` (`MAX_CHANGED_*`) and are user-visible in README.
- A session's **effective working directory** is folded in-repo from the raw log (`working-directory/change`, else `header.cwd`) by `effectiveCwd` in `logic.ts`; the header keeps only the original project. Every route that reports a session directory (`/turns`, `/session`, `/sessions`, mutation responses) must serve it, and the changed-files fold resolves each call against the directory in effect at that call. A cold roster row carries only a header, so it still serves the original project.
- Turn activity (`/turns` `activity`) carries a one-line summary per reasoning block, never the full reasoning text: it is a cross-cutting privacy invariant, so no route may start serving raw reasoning without updating README.md's "Permissions, authentication, and failure bounds". Bounds live in `logic.ts` (`MAX_ACTIVITY_*`) and are user-visible in README.
- Ask-user and approval are answered through the `user-questions/request` / `approval/request` scoped waterfalls, registered with `{ prepend: true }`; their type packages are **type-only imports, never runtime dependencies**. Emacs races the web UI and stays the deciding answerer. SSE clients are split by identity: the browser draft-push stream (`?purpose=draft`) never counts as Emacs; `?answer=0` is a notify-only Emacs that cannot settle approvals. Cancelling semantics differ per waterfall (ask-user cancel rejects the wait; approval cancel settles `'cancelled'`) — do not change either without a deliberate UX decision.
- Attachments in `POST /send` are path-based (absolute host-local paths; no bytes cross the body cap) and content-sniffed (signature, never extension). The seam is the attachments store, not the browser `fileUploads` receipt flow. Caps live in `logic.ts` (`MAX_ATTACHMENTS`, `MAX_ATTACHMENT_FILE_BYTES`) and are user-visible in README.
- Client-side (Emacs), attachments are in-buffer `<#attachment …>` tags, recognized textually and font-locked — never via text properties.

### Client plugin (`dsh-plugin/src/client/`)

- The locale namespace is `dsh-emacs-bridge`; `zh` is the key-set source of truth and `en` must remain a complete mirror.
- The Plugins-page presence (the install card at `plugins.bundle.config` keyed `dsh-emacs-bridge`, the config field at `plugins.row.config` keyed `dsh-emacs-bridge#dsh-bridge`) calls the bearer routes through the shared token machinery in `bridge.ts`; `@deepseek-ai/dsh-client-ui-plugin-manager` is a **type-only import, never a runtime dependency**.
- The browser plugin dismisses its own ask/approval panels on the host's `*-resolved` SSE frames (pure matchers in `question-dismiss.ts` / `approval-dismiss.ts`); `uiSession` is an optional collaborator.
- `tsdown.client.config.ts` replicates the harness's client-artifact contract (which is repo-locked and cannot run out-of-tree). Keep it in sync with the harness preset on any DSH version bump.

### Build and restart discipline

- `cordis.patch.yml` edits and client-bundle changes hot-reload; host plugin code and `package.json` changes require a `dsh web` restart.
- The harness is pre-release with no compatibility promise (pinned range in `dsh-plugin/package.json` `peerDependencies`). On any version bump, re-verify the seams listed in the integration harness (`make integration-test` is the gate).

### Emacs package (`emacs/`)

- One library, `lexical-binding: t`, self-contained over the loopback interface: no Emacs code path runs the `dsh` CLI or downloads anything. Installing the plugin is DSH's job (`dsh plugin add`), never Emacs's; Emacs only diagnoses availability — `dsh-bridge--plugin-install-state` reads the profile manifest to split "installed but not loaded" from "not installed" — and warns under the `dsh-bridge` custom group. Conversely, installing the Emacs package is the plugin's job (the Plugins-page card runs the configured `emacsCommand` in batch), and no elisp ever drives an install.
- Docstrings state the function's intention, its arguments and return value, and notable gotchas — nothing more. The code, not the docstring, is the contract: never use the docstring to narrate the implementation step by step. Tricky implementation details (why a splice is sound, why a race is safe) belong in code comments next to the code they describe.
- A session command resolves its target through the menu focus first: whenever the `dsh-bridge` dispatcher is open, its recorded focus (`dsh-bridge--focus`) wins for the session verbs, whether they are invoked through the menu or directly. Reads consult it through `dsh-bridge--focus-session` (commands that also take an optional session id read their interactive choice through `dsh-bridge--session-for-command`, which adds the prefix-argument override); mutation verbs use `dsh-bridge--confirmed-session`, which refuses the `advisory` last-active guess and a menu that names no session, so the menu cannot mutate a session the user has not confirmed by cycling or pinning. With no menu open the focus is nil and both fall back on `dsh-bridge--effective-session`: the buffer's own binding, then the pinned target, refusing with a `user-error` when neither names one. A refusal that stops a command before it acts — including declining a confirmation — is a `user-error`; a host response or a no-op is reported with `message`. Never teach `dsh-bridge--effective-session` about the focus: helpers use it directly, and any caller that can run with a menu open passes an explicit session id. `dsh-bridge-answer` deliberately adds NODEFAULT: it acts only on the buffer's own binding and refuses from a buffer that names no session, so answering always carries the context of the session that asked and a sole pending session elsewhere is never an implicit target.
- DSH-View bodies are filled incrementally by `dsh-bridge--view-fill` under a recorded provenance; any mismatch falls back to a full re-render. Do not add a splice path that cannot prove those checks, and keep terminal furniture (answer/approval notes, changed-files footer) out of the body.
- DSH-Question buffer edits go through `dsh-bridge--question-edit` (read-only, undo suppressed, modified flag cleared). A state change patches the affected region, found by text property, instead of re-rendering, so a question's `detail` and any markers or overlays inside it survive; `dsh-bridge--question-render` stays the initial paint and the fallback only. A patch must re-apply the buffer's own question-id string, never the caller's — `next-single-property-change` compares with `eq`, so an equal-but-distinct string splits a block in two.
- Requires Emacs 29.1+.

## Testing

- Pure plugin logic: Vitest (`dsh-plugin/tests/*.spec.ts`); spec `logic.ts` / `outbox.ts` behavior, not `index.ts` wiring.
- Elisp: ERT (`emacs/dsh-bridge-tests.el`), run headless via `make test`.
- The unit tests describe behavior: when you alter observable behavior, update its test in the same change.
- A change is complete when `make build && make test` passes.

There is also an integration test suite, deliberately not part of `make test`. It targets harness seams: run it (and possibly update it) alongside any host-plane change or version bump. Read `integration/README.md` for how to run it, including what to do if `dsh` is not on PATH.

## Security and failure bounds

- Loopback only: no route may bind beyond loopback, and no third-party service is contacted. Keep the peer-address + origin fences on `/token` and `/status`.
- The host runs the configured `emacsCommand` once, in batch with fixed arguments, only on an explicit user action (`POST /dsh-bridge/emacs/install`); nothing from the request body reaches the command line, output capture is bounded, probe and install are serialized under one `KeyedSerial` key, and the only write outside `$DSH_HOME` is the user's Emacs package directory. Nothing else in the plugin may run Emacs.
- Shared bearer token at `$DSH_HOME/dsh-bridge-token` (default `~/.dsh/dsh-bridge-token`), generated on first use with mode 0600, compared constant-time.
- HTTP request bodies are capped (currently 1 MiB, 413 on oversize).
- The DSH→Emacs outbox is bounded (`OUTBOX_DEFAULT_CAP` in `outbox.ts`), evicts the oldest, and reports overflow.

These are user-visible invariants; any change must update README.md's "Permissions, authentication, and failure bounds" section alongside the code.

## Licensing and hygiene

- Every source file carries the GPL-3.0-or-later header (see `COPYING`); add it to new files. `dsh-plugin/package.json` declares the same SPDX identifier, and `dsh-plugin/LICENSE` is a copy of `COPYING` because npm packs a package-local license file but never the repository root's — keep the copy in step if the license text ever changes.
- Build outputs and dependencies are gitignored (`node_modules`, `lib/`, `.package/`, `.release/`, `dsh-bridge-*.tar`, `dsh-emacs-bridge-*.tgz`, elisp artifacts, `pnpm-lock.yaml`). Keep source committed and artifacts ignored.

## Adjacent reference trees (not assumed)

The DSH sources may be present in a sibling directory (`../deepseek-harness/`) and Emacs sources in `../emacs-*/`; treat them as reference-only. The project must build and test standalone.
