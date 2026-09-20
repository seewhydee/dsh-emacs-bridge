# dsh-emacs-bridge integration testing

This folder contains the integration tests for the dsh-emacs-bridge
project.  These tests are developer-only, and do not get staged into
the Emacs package tarball.

The integration tests aim to provide broad coverage of user-visible
features, including session creation, workspace management, ask-user
interactions, file and image attachments, etc.  The intention is to
detect problems that cannot be easily caught by the unit test suite
(Vitest for DSH-side plugin logic, ERT for Elisp).

The integration test suite boots a live DSH `web` profile with a
freshly built bridge plugin (`make build`) and mock LLM, mounted by
absolute `--patch` path in a fresh temp `DSH_HOME` (no install).  Each
session is routed via `agent-default-model`, so no real LLM call
happens, and the plugin is driven over HTTP/SSE.

## Prerequisites

- A `dsh` on PATH *or* appropriately-set `DSH_BRIDGE_DSH_COMMAND` and
  `DSH_BRIDGE_FIXTURE_CWD` envvars.  For a development environment
  using deepseek-harness sources in another directory, the latter can
  be set like this:
  ```sh
  export DSH_BRIDGE_DSH_COMMAND='node --import /path/to/node_modules/tsx/dist/esm/index.mjs /path/to/apps/cli/src/bin.ts'
  export DSH_BRIDGE_FIXTURE_CWD=/path/to/deepseek-harness
  ```
  Note that the deepseek-harness must be already built.  The launcher
  runs `<dsh> --profile web --patch <overlay> --no-open`, so the harness
  must carry the web bundle set and the fixture never opens a browser.
- In the dsh-emacs-bridge sources, `make build` must have produced
  `dsh-plugin/lib/index.js` (the launcher mounts it by absolute path).
- Emacs 29.1+.

## Run

```sh
make integration-test   # build + vitest seam specs + batch ERT
```

Run a single suite with `node dsh-plugin/node_modules/vitest/vitest.mjs run --config integration/vitest.config.ts`.

Agents are instructed by AGENTS.md to run this automated integration
test suite before committing changes to the DSH plugin, and/or changes
warranting a version-bump.

An ordinary `make test` only runs the fast unit tests, omitting these
integration tests.

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
| `tests/turns.spec.ts` | turn fold into `/turns`, auxiliary title/compaction calls, model catalog + selection parity, outbox round trip, 404/413 (oversize body) bounds, degraded-profile boot |
| `tests/auth.spec.ts` | the fences: 401 missing/wrong bearer on representative routes, 401 wrong SSE query token, `/token` vend happy path, 403 hostile Origin on `/token` + `/status` |
| `tests/ask-user.spec.ts` | the ask-user waterfall end to end (SSE frame, `/answer` settlement, pending-question replay), cancel/late/malformed settlements, and the browser-draft stream never owning a question |
| `tests/approval.spec.ts` | the approval waterfall end to end: a scripted `danger-full-access` bash escalation surfaces an `approval` frame (with host-folded tool-call detail), replays on reconnect, and settles from `/approval` — `allowed-once` runs the command, `rejected`/`cancelled` do not; the exclusive claim (a `purpose=draft`-only stream never claims) and the `answer=0` notify-only posture (notified, but not settleable) |
| `tests/sessions.spec.ts` | create by `path` (new and already-known workspace), create by `workspaceId`, create-argument bounds, workspace rename/conflict/blank/unknown, session rename/archive/unknown |
| `tests/session.spec.ts` | the read-only session report over the `sessionQuery` seam: live stats/token usage/model selection, 404 unknown (never created or resumed), 400 repeated `sessionId`, default target |
| `tests/cold-sessions.spec.ts` | the persisted-only roster: a session from a previous boot (two hosts sharing one `dshHome`) is listed cold with its durable title and observed by the report's cold arm; the cold write paths: `/send` naming a cold id resumes it on demand and lands the prompt, `/sessions/resume` brings a cold id live |
| `tests/fork.spec.ts` | branching a completed-turn prefix through the `sessionController` seam: the `/turns` `endSeq` anchor, child lineage and inherited prefix, the omitted-`atSeq` fallback, and the failure taxonomy (unknown source, bad argument, open-turn anchor) |
| `tests/attachments.spec.ts` | the path-based attachment seam through the real `ctx.attachments` store: image sniffing reaching the provider as an image block, a generic file projected to handle text, an attachment-only prompt, and the validation/count/byte-cap statuses |
| `tests/routes.spec.ts` | the composer-draft push (frame to the `purpose=draft` stream, 409 with only an Emacs client), the outbox `messageId` deposit (host-side text resolution, 404 unknown), `/context` (204 before any sample, 200 after a turn, SSE `context` frame), and `/send` with no active session (409 on a dedicated fixture) |
| `tests/queue.spec.ts` | the `/send` `mode` field (400 for an unknown value, so a typo never degrades a steer into a queued send; `steer` accepted) and `GET /sessions/queue` counts off a live agent (a follow-up parked in `next-turn`, a steer in `next-step`), zeros for an unknown or absent id |
| `tests/models.spec.ts` | mock-LLM fidelity: advertised modalities behind the image-support precheck (text-only model → 400 `MODEL_DOES_NOT_SUPPORT_IMAGES`; the default stays image-capable), fragmented `tool-call-delta` argument assembly, and a model error ending the turn with reason `error` |
| `tests/turns-incremental.spec.ts` | the `/turns` epoch contract incremental DSH-View filling relies on: a running turn grows segment by segment under a stable epoch, the inclusive `since` fetch re-sends the boundary turn in full, and a stale epoch forces the full-list fallback |
| `dsh-bridge-it.el` | the live-Emacs seats of the ask-user path (submit and decline), `C-c C-a` attachment staging plus send-time tag stripping, DSH-Describe rendering live host statistics, turn branching, incremental DSH-View filling (in-place segment append with a surviving marker, first-reply tailing, and the newer-turn rebuild), stopping a hung turn through `/sessions/stop` (the turn closes `aborted` and a second stop is a no-op), SSE reconnect resilience across a same-port fixture restart, the DSH-Sessions list over live data, outbox receive + ack draining, and cold-session resume driven from Emacs |

`tests/cold-sessions.spec.ts` boots a second host against a persisted
`dshHome` (the launcher's `dshHome` option) to cover the cold roster; the
describe route's cold arm is exercised there too.

## Mock LLM

`integration/mock-llm/index.js` plugs a scripted adapter into `ctx.llm` for the
`mock` provider. It advertises `mock-model` / `mock-model-pro` (image-capable)
and `mock-model-text` (text-only) with real `inputModalities` metadata and a
128k context window, so the bridge's image-support precheck and the
context-occupancy projection have genuine values to read. It keeps a script
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
arguments, text?, fragmentArgs?}` (`fragmentArgs: true` splits the arguments
JSON across several `tool-call-delta` chunks, the way real providers fragment
them), `{kind:'hang'}`, `{kind:'error', message}` (the adapter throws; the
turn ends with reason `error`).

## Failure bounds

Loopback only; no third-party service. The mock's bearer-gated control routes
mean nothing else on loopback can rewrite the mock mid-test. The residual
exposure is any process that can read `$DSH_HOME/dsh-bridge-token` on the same
host — the same trust boundary the bridge itself documents. Temp `DSH_HOME`
directories go to the OS temp dir and are removed when the fixture exits —
but only when the launcher created them: a caller-supplied home (the launch
library's `dshHome` option, the cold-resume reuse case) belongs to the caller.

## Adding a scenario

Add a `scenarios/<name>.json` with `mockScript` (the model's reply queue) and
`steps` (the human flow). Only the interactive runner consumes these files:
it pushes `mockScript` to the mock and drives `steps`, recording annotations.
The automated vitest suites do not read `scenarios/`; they script the mock
inline over `POST /mock-llm/script`.
