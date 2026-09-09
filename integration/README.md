# dsh-emacs-bridge integration testing

Dev-only. This top-level folder is **never** staged into the Emacs package tar —
`make package` stages from an explicit file list, so `integration/` is excluded
by construction.

## What it is

A seam harness for the two seams none of the existing suites reach: Vitest
covers the pure plugin logic and ERT covers elisp given canned frames, but
nothing boots the **real plugin against a real host**. This framework does:

- boots a live DSH `web` profile with the freshly built bridge plugin
  (`make build`) and a mock LLM, mounted by absolute `--patch` path in a fresh
  temp `DSH_HOME` (no install);
- routes every session at the mock provider via `agent-default-model`, so no
  real LLM call happens;
- drives the plugin over real HTTP/SSE and asserts the frames and routes;
- covers the ask-user seam end-to-end (the model calls `ask_user_question`
  mid-turn; the bridge's `user-questions/request` waterfall answerer must
  surface an `ask-user` SSE frame and settle the turn from `/answer`);
- covers session creation and workspace management — create by path and by
  workspace id, resolve-on-repeat-path, workspace-rename bounds, session
  rename/archive — in `tests/sessions.spec.ts`.

The mock, the launcher, and the vitest suites are the automated layer; the
`.el` files are the batch ERT layer and the interactive UX runner.

`make integration-test` is the pre-commit gate for host-plane (`dsh-plugin/src`)
changes and the version-bump gate for the harness seams AGENTS.md lists. It is
deliberately **not** part of `make test`, which stays unit-only and fast.

## Prerequisites

- A functioning `dsh` on PATH, **or** set `DSH_BRIDGE_DSH_COMMAND` to the dsh
  command. For a harness-source checkout that is run with `tsx`, the command is
  cwd-sensitive, so also set `DSH_BRIDGE_FIXTURE_CWD` to the harness root:
  ```sh
  export DSH_BRIDGE_DSH_COMMAND='node --import /path/to/node_modules/tsx/dist/esm/index.mjs /path/to/apps/cli/src/bin.ts'
  export DSH_BRIDGE_FIXTURE_CWD=/path/to/deepseek-harness
  ```
  The launcher spawns `<dsh> --profile web --patch <overlay>` and the harness
  must carry the web bundle set (a checkout-only install does not).
- `make build` has produced `dsh-plugin/lib/index.js` (the launcher mounts it by
  absolute path).
- Emacs 29.1+ for the ERT layer.

## Run

```sh
make integration-test   # build + vitest seam specs + batch ERT
```

`make test` stays unit-only and fast. Run a single suite with
`node dsh-plugin/node_modules/vitest/vitest.mjs run --config integration/vitest.config.ts`.

## Layout

```
integration/
  Makefile (target lives in ../Makefile)
  package.json            type:module, vitest + typescript devDeps (self-contained)
  mock-llm/               plain-ESM mock adapter; no harness imports, so the dsh
                          Loader imports it directly (no node_modules of its own)
  host/launch.mjs         fixture launcher CLI + library
  host/overlay.template.yml
  scenarios/*.json        scenario data (mock script + human step script)
  tests/                  vitest specs (+ global-setup.mjs + util.mjs)
  dsh-bridge-it.el        batch ERT end-to-end layer
  dsh-bridge-scenario.el  interactive UX runner (emacs -Q -l ...)
```

## Coverage

| Spec | Covers |
|---|---|
| `tests/turns.spec.ts` | turn fold into `/turns`, auxiliary title/compaction calls, model catalog + selection parity, outbox round trip, 404/oversize bounds, degraded-profile boot |
| `tests/ask-user.spec.ts` | the ask-user waterfall end to end (SSE frame, `/answer` settlement, pending-question replay) and the browser-draft stream never owning a question |
| `tests/sessions.spec.ts` | create by `path` (new and already-known workspace), create by `workspaceId`, create-argument bounds, workspace rename/conflict/blank/unknown, session rename/archive/unknown |
| `dsh-bridge-it.el` | the live-Emacs seat of the ask-user path |

## Mock LLM

`integration/mock-llm/index.js` plugs a scripted adapter into `ctx.llm` for the
`mock` provider. It advertises `mock-model` / `mock-model-pro`, keeps a script
queue consumed one entry per **main-turn** call (a `GenerateOptions` with no
`purpose`), and answers auxiliary calls (`session-title`, `compaction`) with a
canned reply without touching the queue. Control routes on the same loopback
webserver are guarded by the **same bearer token** as the bridge routes (read
lazily per request from `$DSH_HOME/dsh-bridge-token`):

- `POST /mock-llm/script` — replace the queue (`{script: [...]}`).
- `POST /mock-llm/push` — append entries.
- `GET  /mock-llm/requests` — every `GenerateOptions` recorded (with `purpose`).
- `POST /mock-llm/reset` — clear queue + recording.

Entry kinds: `{kind:'text', text, delayMs?}`, `{kind:'tool-call', name,
arguments, text?}`, `{kind:'hang'}`, `{kind:'error', message}`.

## Failure bounds

Loopback only; no third-party service. The mock's bearer-gated control routes
mean nothing else on loopback can rewrite the mock mid-test. The residual
exposure is any process that can read `$DSH_HOME/dsh-bridge-token` on the same
host — the same trust boundary the bridge itself documents. Temp `DSH_HOME`
directories go to the OS temp dir and are removed when the fixture exits —
but only when the launcher created them: a caller-supplied home (the launch
library's `dshHome` option, the cold-resume reuse case) belongs to the caller.

## Adding a scenario

Add a `scenarios/<name>.json` with `mockScript` (consumed by the automated
tests) and `steps` (the human flow). The automated suites consume `mockScript`;
the interactive runner drives `steps` and records annotations.
