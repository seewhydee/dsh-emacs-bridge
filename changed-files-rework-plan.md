# Changed-files rework plan

Status: **implemented** (2026-09-21). Scope agreed before coding.
Repo is pre-alpha; no backward-compatibility shims are carried.

## Decisions

1. **Remove the VC-diff surface entirely.** Footer button, `V` binding, menu
   item, the `dsh-bridge-view-vc-diff` command, and its dedicated face all go.
2. **The footer becomes a plain inline file list.**
   - no `[ ]` delimiters — the `dsh-bridge-view-changed-face` fontification is
     the clickability cue;
   - no `(op)` tag;
   - no per-file `[diff]` button;
   - one clickable entry per file, and clicking it visits the file (the only
     remaining per-file action).
3. **Remove the recorded-hunk viewing feature entirely while it is
   reconsidered.** This is the Emacs `*dsh-bridge-changes*` buffer/mode *and*
   the host surface that existed only to feed it (`GET /changes`,
   `hunksForPath`, its caps and tests).
4. **No shims, no deprecation period.** Delete, don't gate.

## Resulting UX

Before (one line per changed turn):

```
Changed files: [emacs/dsh-bridge.el] (edit) [diff]  [VC diff]
Changed files: [foo] (edit) [diff]  [VC diff]  [bar] (edit) [diff]  [VC diff]  [baz] (edit) [diff]  [VC diff]
```

After:

```
Changed files: emacs/dsh-bridge.el
Changed files: foo bar baz
```

- `Changed files:` is the `dsh-bridge-view-changed-label-face` label.
- Each path is a text button in `dsh-bridge-view-changed-face` (inherits
  `link`), two spaces apart, with `follow-link t` and
  `help-echo "Visit <path>"`. `RET`/click visits it against the session cwd
  (the view's `default-directory` is already the session cwd).
- The list wraps; see "Judgment calls" for why the footer adds no cap of its
  own (the host fold already bounds it at `MAX_CHANGED_FILES_PER_TURN`).

## Scope

**In scope**

- Emacs: delete the hunk viewer and the VC-diff command/bindings; rewrite the
  footer.
- Host: delete the `/changes` route, `readChangesLog`, and the
  `hunksForPath` fold (types, caps, helpers) plus their tests.
- Docs: README, PLAN.md, AGENTS.md, the `index.ts` route inventory.

**Out of scope (recorded, not fixed)**

- The deferred "proper diff" viewer (see design note below).
- A turn whose only output is tool calls is still absent from `/turns`, so a
  purely file-changing turn still shows no footer. That is a turn-fold issue
  (`assistantTurns`), not a footer issue; README already documents it.
- Unused fold fields (`absolute`, `firstTurn`, `lastTurn`, `turns`,
  `delivered`). The attribution layer is deliberately left intact for the
  deferred review surface; `op` stays on the wire for the same reason even
  though the footer no longer renders it.

## Work breakdown

### 1. Emacs — delete the hunk viewer and VC diff (`emacs/dsh-bridge.el`)

Delete outright:

- `dsh-bridge-view-changed-diff-face` (:457-460) — used only by the removed
  `[diff]`/`[VC diff]` labels.
- `dsh-bridge-changes-buffer-name` (:2466), `dsh-bridge--changes-session`
  (:2469), `dsh-bridge--changes-path` (:2472), `dsh-bridge--changes-file`
  (:2475).
- `dsh-bridge--changes-insert-side` (:2482), `dsh-bridge--changes-render`
  (:2493), `dsh-bridge--view-changed-hunks` (:2543), `dsh-bridge--changes-hunks`
  (:2561), `dsh-bridge-changes-next-hunk` (:2572),
  `dsh-bridge-changes-previous-hunk` (:2581),
  `dsh-bridge-changes-visit-file` (:2590), `dsh-bridge-changes-refresh`
  (:2597), `dsh-bridge-changes-mode-map` (:2605),
  `dsh-bridge-changes-mode` (:2614). This also removes the last
  `(require 'diff-mode nil t)`.
- `dsh-bridge-view-vc-diff` (:2624-2633).
- `"V" #'dsh-bridge-view-vc-diff` from `dsh-bridge-view-mode-map` (:3331).
- The `["VC Diff" dsh-bridge-view-vc-diff …]` item from
  `dsh-bridge-view-menu` (:3354-3355).

Keep: `dsh-bridge--view-visit-changed` (:2478), `dsh-bridge-view-changed-face`,
`dsh-bridge-view-changed-label-face`.

### 2. Emacs — rewrite the footer

- **`dsh-bridge--view-changed-files` (:2635-2680).** New signature
  `(turn)` — `session-id` is no longer used; drop it. Guard
  `(and dsh-bridge-view-changed-files (consp turn))`. Note this is a
  deliberate semantic change, not just a dropped parameter: a nil
  `session-id` previously suppressed the footer, and now it does not.
  Harmless in practice (the visit action needs no session, and a view always
  has one) — do not "restore" the condition later. Emit
  `"Changed files: "` (label face), then for each `files` entry a text button
  whose text is the bare `path` (face/`font-lock-face`
  `dsh-bridge-view-changed-face`, `follow-link t`,
  `help-echo "Visit <path>"`, `action` calling
  `dsh-bridge--view-visit-changed`), separated by two spaces. Drop the `op`
  read entirely.
- **`dsh-bridge--view-turn-suffix` (:2697).** Update the call to pass only
  `turn`. The footer still sits in the suffix above the terminal furniture and
  the turn marker stays last (invariant: AGENTS.md "keep terminal furniture …
  out of the body").
- **`dsh-bridge-view-changed-files` defcustom (:276-284).** Reword: the footer
  is a plain list of the files a turn changed, each entry a button that visits
  it; drop all diff/VC wording.
- **Section comment (:2456-2464)** and **buffer commentary (:2224-2231).**
  Rewrite to describe the plain list and delete the `[diff]`/`[VC diff]`
  sentences.

### 3. Host — remove `/changes` and the hunk fold

`dsh-plugin/src/index.ts`:

- Delete the `GET /dsh-bridge/changes` handler (:2253-2290).
- Delete `readChangesLog` (:1671-1728) — its only caller is that handler.
  (`resolveReadId`, `sessionPersistence`, `SessionQueryService`,
  `isSessionQueryNotFound` are used by other routes and stay.)
- Remove the now-unused `hunksForPath` import (:149).
- Trim `resolve` from the `node:path` import (:109) — its only real use is
  `resolve(cwd, path)` inside the deleted handler (the other `resolve` hits
  are `Promise.resolve` and an interface property). Not build-breaking
  (no `noUnusedLocals`; tsdown does not typecheck), but don't leave it.
- Update the `/turns` route's inline comment (:2221-2223): it ends with
  "hunks are lazy on /changes", which survives neither the route nor the
  fold.
- Route inventory header: delete the `GET /dsh-bridge/changes` block (:55-59).

`dsh-plugin/src/logic.ts`:

- Delete `hunksForPath`, `ChangedHunk`, `ChangedHunksResult`, `HunkTexts`,
  `diffsFromMeta`, `argumentHunks`, `capHunkText`, `MAX_CHANGED_HUNKS`,
  `MAX_CHANGED_HUNK_CHARS`, `MAX_CHANGED_HUNK_TOTAL_CHARS` (:618-786 approx.).
- Keep `changedFiles`, `ChangedFile`, `ChangedFilesResult`,
  `MAX_CHANGED_FILES`, `MAX_CHANGED_FILES_PER_TURN`, and the mutation
  vocabulary (still used for path attribution). Keep `SessionEventLike.surfaceOp`
  (the result pairing reads it).
- `/turns` and its `files: [{path, op}]` payload are **unchanged**.

### 4. Tests

ERT (`emacs/dsh-bridge-tests.el`):

- Delete `dsh-bridge-view-changed-hunks-renders` (:8603),
  `dsh-bridge-view-changed-hunks-absent` (:8662),
  `dsh-bridge-view-vc-diff` (:8672).
- Rewrite `dsh-bridge-view-changed-files-footer` (:8442): expected string
  becomes `"Changed files: src/a.ts  src/b.ts"`; replace the "every `[` is a
  button" scan with an assertion that a button sits at each path's start; keep
  the no-changes and opt-out assertions.
- Update `…-open-turn-order` (:8482), `…-buttons` (:8517), `…-splice`
  (:8567): call the new one-arg signature; `…-buttons` now asserts only the
  visit action; `…-default-directory` (:8548) searches for `src/a.ts` without
  brackets.
- `dsh-bridge-tool-bar-other-modes-default` (:8766): drop
  `dsh-bridge-changes-mode` from the mode list (leaves
  `dsh-bridge-question-mode`); retitle.
- `dsh-bridge-turns-cache-files-field` (:8685): unchanged (the wire keeps
  `op`).
- `dsh-bridge-test--view-file` (:1684) and `…-turn-render` (:1723): unchanged.

Vitest (`dsh-plugin/tests/logic.spec.ts`):

- Delete `describe('hunksForPath')` (:1593 to its end) and any fixture used
  only by it. The `changedFiles` describe and its fixtures stay.

Integration (`integration/tests/changes.spec.ts`):

- Drop all `/changes` assertions and the whole 400/404 test; retitle the file/
  describe to the changed-files fold only. Keep the `/turns` attribution
  assertions (turn + incremental suffix), including the `op` field.
- The file header comment loses its `/changes` sentence.

### 5. Docs

- `README.md`: delete the `V` bullet (:180); rewrite "#### Changed files"
  (:195-220) to describe the plain, clickable list and note that the recorded
  diff / review view is removed pending redesign (no `[diff]`, DSH-Changes, or
  VC-diff text survives).
- `PLAN.md` §9 (:282-299): rewrite the UX bullet to the current reality and
  record the deferred proper-diff direction (see below).
- `AGENTS.md` (:78): drop the `GET /changes` sentence; the changed-files fold's
  raw-log/`{path, op}` `/turns` statement stays. Line 99's "keep terminal
  furniture … out of the body" stays true.
- `index.ts` route inventory: covered in item 3.

### 6. Verification

- `make build && make test` (host Vitest + headless ERT) — the completion gate.
- `make integration-test` (host-plane change; see `integration/README.md` if
  `dsh` is not on `PATH`).
- Manual smoke: run a session that writes/edits a couple of files and confirm
  the footer reads as one line of clickable paths, with no `[diff]`/`[VC diff]`
  and no `(op)`.

## Judgment calls recorded

- **No footer-level cap on the inline list.** The list is not actually
  unbounded: the host fold already caps per-turn attribution at
  `MAX_CHANGED_FILES_PER_TURN` (50). Eliding further in the footer would
  *hide* files with no alternative surface left (the review buffer is gone),
  which is a functional regression. `special-mode` does not set
  `truncate-lines`, so a long list wraps. Known pre-existing gap, not made
  worse here: the fold's `truncated` flag is not surfaced per-turn on
  `/turns`, so a turn changing more than 50 files silently shows 50. If the
  list proves noisy in practice, the deferred review buffer is the proper
  home for the full list, not footer truncation.
- **`op` stays on the wire.** The Emacs footer stops rendering it, but the
  `/turns` payload and the host fold are left intact: removing them is churn
  in the layer that is described as solid, and the deferred review surface will
  want the operation/turn attribution. Revisit when that surface lands.
- **Deleting the host `/changes` route** (rather than leaving it dormant) is
  the one deletion not strictly required by the Emacs UX change. Rationale:
  `hunksForPath` exists only to feed the removed viewer, and pre-alpha keeps no
  dead surface. A future proper diff will need offsets the current fold does
  not produce, so it would be reworked rather than reused as-is.

## Design note: the deferred proper diff

The recorded-hunk viewer was removed because it could not be an honest
`diff-mode`: the persisted `FileDiff` is `{path, oldText, newText}` (harness
`packages/core/tools/src/presentation.ts`), and `computeHunkDiffs`
(`packages/fs/tool-fs/src/diff.ts`) discards the `structuredPatch` line
offsets. No truthful `@@ -L,N +L,M @@` can be synthesised, so
`diff-goto-source`/`diff-apply-hunk` would lie, and the surrounding custom
`n`/`p`/`RET` bindings half-imitated a mode it was not.

When the review surface is revisited, the honest options are:

1. **Real `diff-mode` via upstream offsets.** Persist `oldStart`/`newStart`
   (and counts) in `FileDiff`, or expose the pre/post images through the
   `fs/observed` version store. Then the bridge can emit a genuine unified diff
   and delete the bespoke mode entirely. Requires a DSH-side change and the
   usual version-bump re-verification.
2. **An honest non-diff change view.** Keep a `special-mode` buffer but
   present per-change headings (no diff-syntax `---`/`@@` markers) and
   deliberately chosen keys, without implying `diff-mode` semantics.

Option 1 is preferred if the upstream change is acceptable; option 2 otherwise.
This is explicitly deferred, not silently dropped.
