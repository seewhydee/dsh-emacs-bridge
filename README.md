# dsh-emacs-bridge

This is a two-way bridge between
[GNU Emacs](https://www.gnu.org/software/emacs/) and the
[Deepseek Harness](https://github.com/deepseek-ai/deepseek-harness)
(DSH).  The bridge allows you to control DSH from entirely within
Emacs, including submitting prompts, reading replies, and controlling
sessions and their properties.  The Emacs-side user interface is
designed to closely follow existing Emacs conventions and standards.

The bridge consists of two components:

- `dsh-plugin/` — a DeepSeek Harness plugin (`dsh-emacs-bridge`).
- `emacs/dsh-bridge.el` — an Emacs package to interact with the
  harness.  A companion library, `dsh-bridge-install.el`, is loaded on
  demand and provides commands to install/uninstall the DSH plugin.

## Installation

### Requirements

- `dsh`, the DeepSeek Harness.
- Node.js and `pnpm` to build the plugin.
- Emacs 29 or later.
- (Recommended) The [`markdown-mode`](https://jblevins.org/projects/markdown-mode/) Emacs package.

### Emacs package

To build an Emacs package that also bundles the DSH plugin, run this
in the repository's root directory:

```sh
make package
```

Then, in Emacs:

1. `M-x package-install-file RET /path/to/dsh-bridge-<version>.tar RET`
2. (*optional*) If you run DSH from a source checkout, meaning that
   `dsh` is *not* on the executable path or run via `npx`, customize
   `dsh-bridge-dsh-command` (e.g., `M-x customize-variable RET
   dsh-bridge-dsh-command RET`) to specify how to run DSH (see below).
3. `M-x dsh-bridge-install-plugin`
4. Start or restart `dsh web`

To remove the plugin later, run `M-x dsh-bridge-uninstall-plugin`.

Here is an example of `dsh-bridge-dsh-command` for a source checkout:

```elisp
(setq dsh-bridge-dsh-command "pnpm -C /path/to/deepseek-harness dsh")
```

Note that `~` is not expanded, so specify the full path.  Don't add an
additional `web` argument to the end.

### Manual compilation and installation

Instead of an all-in-one Emacs package, you can build and install the
DSH plugin and Emacs library manually.

#### Build and install the DeepSeek Harness plugin

From this repository's root directory:

```sh
make build   # emits dsh-plugin/lib/index.js + lib/client.js
```

If you have `dsh` installed on the executable path, run the following
commands:

```sh
# global install, from this repo root:
dsh plugin --profile web add link:./dsh-plugin
dsh web
```

If you have a source checkout of DSH and run it as a pnpm script
(`pnpm dsh web`), run the following from the `deepseek-harness`
directory instead, replacing the `link:` path with the appropriate
path into this repo:

```sh
# source checkout, from deepseek-harness root:
pnpm dsh plugin --profile web add link:/absolute/path/to/dsh-emacs-bridge/dsh-plugin
pnpm dsh web
```

#### Install the Emacs library

Put this in your Emacs init file (`~/.emacs.d/init.el` or `~/.emacs`),
replacing the path with the actual path to `dsh-bridge.el`:

```elisp
(load "/path/to/dsh-emacs-bridge/emacs/dsh-bridge.el")
```

Optionally, you can also load `dsh-bridge-install.el`, which supplies
the `M-x dsh-bridge-install-plugin` command (see above).  But if you
installed the DSH plugin directly by following the steps in the
preceding section, you can skip this.

## Usage

From Emacs, the main entry-points are these two commands:

- `M-x dsh-bridge` — open a transient menu for DSH commands.
- `M-x dsh-bridge-list-sessions` — show a list of DSH sessions.

Consider giving either or both a global keybinding, e.g.,

```elisp
(keymap-global-set "C-c d" #'dsh-bridge)
```

### Transient menu

The `M-x dsh-bridge` command opens a transient menu that prompts for
the next command.  The top line shows the session being acted on
(chosen based on your recent activity); you can cycle through
available sessions with `M-p`/`M-n`.  The following commands are
available from this menu:

* `q` — exit the transient menu.
* `M-p`/`M-n` — cycle through other sessions, ordered by age.
* `r` — open a buffer to type in a prompt, bound to the focus.
* `s` — send region or buffer as a prompt (if session is busy, it is queued).
* `d` — send region or buffer as a draft (can edit in DSH before submitting).
* `f` — fetch and display the latest set of replies.
* `D` — describe the session.
* `t` — pin the current session as the target.
* `T` — prompt for a session by title, and pin it.
* `u` — unpin the currently pinned session.
* `k` — stop the running session.
* `l` — open the DSH-Sessions buffer.
* `+` — create a new session, prompting for its workspace and its title;
        the new session is pinned and becomes the focus.
* `p` — toggle plan mode for the focus session.
* `G` — set or edit the goal objective (with `C-u`, also the round cap).
* `A` — pause an armed goal, or resume and rearm a stopped one.
* `X` — clear the current goal.

### DSH-Sessions buffer

The `M-x dsh-bridge-list-sessions` command opens a list of DSH
sessions.  The pinned target session (if any) is marked by a `*` in
the leftmost column, and the `S` (state) column shows each session's
live status.  The following commands are available from here:

* `q` — quit the window and bury the buffer.
* `RET` — do the next appropriate thing for the session at point: if
          running, view current replies; if waiting for a prompt, open
          a prompt buffer; etc.
* `r` — open a buffer to type a prompt for the session at point.
* `f` — fetch and display the output from the session at point.
* `a` — answer a pending user query for the session at point.
* `k` — stop the session at point if it is running.
* `t` — pin the session at point as the target.  A cold session binds
        without being resumed; the host resumes it when a later request
        acts on it.
* `u` — unpin.
* `v` — toggle whether archived sessions are shown (hidden by default).
* `R` — rename the session at point.
* `d` — archive the session at point.
* `U` — unarchive the session at point.
* `+` — create a new session, in an existing or new workspace.
* `W` — rename the workspace of the session at point.
* `D` — describe the session at point.
* `g` — refresh the DSH-Sessions buffer.

For a full list, see the menu bar.  Other `tabulated-list-mode` keys
are also available.

### DSH-View buffer

This read-only buffer contains the model output for a DSH session.
Each buffer holds one agent turn (i.e., all replies from a user prompt
to an idle).  It is fetched by `f` from the transient menu or the
DSH-Sessions buffer, `C-c C-f` from the prompt buffer, or pushed from
the web UI's "Send to Emacs" button (see below).

The following commands are available in a DSH-View buffer:

* `g` — re-fetch the current session's newest turn.
* `r` — open a DSH-Prompt buffer for the current session.
* `B` — branch the shown turn into a new session.
* `k` — stop the shown session's running turn.
* `i` — receive the latest "Send to Emacs" message (see below).
* `v` — show or hide the turn's tool calls and thinking summaries.
* `D` — describe the current session.
* `M-p`/`M-n` — cycle the current session's turns (older / newer).
* `l` — open the DSH-Sessions buffer.
* `q` — quit the window and bury the buffer.

When created, a DSH-View buffer usually follows the latest turn, so
that the buffer is automatically updated as more replies arrive.
Walking back through older turns with `M-p` suspends following;
cycling back to the newest turn with `M-n` resumes it automatically.
To customize this behavior, change `dsh-bridge-view-follow-at-newest`.

If Markdown mode is installed, and `dsh-bridge-view-gfm` is non-nil,
the reply is font-locked as GitHub-Flavored Markdown (the dividers use
GFM horizontal-rule syntax, so they render cleanly).

#### Changed files

A turn whose tool calls successfully changed files ends with a
`Changed files:` footer, a plain list of one clickable entry per file.
Clicking a path (or typing `RET` with point on it) visits the file,
resolved against the session directory.  There is currently no
recorded diff or review view: the previous hunk viewer was removed
pending a redesign (see `PLAN.md`).

Customize `dsh-bridge-view-changed-files` to `nil` to omit the footer.
A turn that produced no assistant text but did run a tool is still
served, so a purely file-changing turn shows its footer (and no
reply); refresh (`g`) after a turn completes to pick up its files.

#### Turn activity

By default a DSH-View buffer shows only the assistant's replies.  Type
`v` (`dsh-bridge-view-toggle-activity`) to interleave the shown turn's
*activity*: one line per tool call, one line per tool result, and a
one-line summary of each reasoning (thinking) block.  The toggle is
buffer-local and starts from `dsh-bridge-view-activity` (default
`nil`); it is also in the buffer's menu.

The thinking lines are summaries that the host derives from the
model's reasoning blocks; the full chain of thought never reaches
Emacs.  Activity streams in live, mid-turn, so a turn whose opening
step is tool-only or reasoning-only shows its lines before it has any
reply text.  Long sessions keep activity only for recent turns; within
a turn the host keeps the newest entries, so a busy live turn keeps
streaming and its oldest lines slide out.

#### Agent queries and approval requests

If the model requests additional user input via the
`ask_user_question` tool, the query is surfaced in the DSH-View
buffer.  Type `a` here (or in the DSH-Sessions buffer with point on
the session) to open a buffer for handling the query.

In this buffer, mark the option(s) you choose with `RET`.  You can
also navigate to a question block and type your desired option's
number key, or type `c` and write a freeform answer via the
minibuffer.  To submit the answers, type `C-c C-c`.  Alternatively,
type `C-c C-k` to decline the query.

In addition, some agent tools ask for approval before acting; for
example, `danger-full-access` asks before sandbox escalation.  Such
requests are also surfaced in the DSH-View buffer.  Type `a` to see
the request details in a help window; then you can type `y` to accept
the request once, `n` to reject it, or `c` to cancel it.  Quitting
(`C-g`) leaves the approval pending; type `a` again to restart it.

If the web UI is open, the query or approval is shown there too;
whichever answers first (Emacs or web UI) settles the request and
dismisses the other presentation.  To change this (e.g., letting the
web UI handle all requests), customize `dsh-bridge-approval-answer`.

### DSH-Prompt buffer

This buffer is used to compose a prompt, or reply, for a DSH session.
It is opened by `r` from the transient menu, DSH-View buffer, or the
DSH-Sessions buffer.  You can also open it with `RET` from the
DSH-Sessions, if the session is waiting for a prompt.

The target session affected is determined by how the buffer was
invoked; for instance, `r` from a DSH-View buffer opens a prompt for
the same session.

The following commands are available from the DSH-Prompt buffer:

* `C-c C-c` — send the buffer as a prompt, and pop to the DSH-View
              buffer to watch the reply.
* `C-c C-d` — push the buffer to the DSH composer as a draft.
* `C-c C-a` — attach a file to the prompt (see below).
* `C-c C-m` — set the model and reasoning effort.
* `C-c C-s` — rebind the buffer to another session.
* `C-c C-k` — stop the session if it is running, or erase the prompt otherwise.
* `C-c C-f` — open the DSH-View buffer for this session.
* `C-c C-l` — open the DSH-Sessions buffer.
* `M-p`/`M-n` — walk the session's prompt history.

If `C-c C-c` is invoked while the session is running, it asks how to
send the prompt: queue to run after the current turn, steer the
running turn, or cancel.  Customize `dsh-bridge-send-while-running` to
change this behavior.  To unconditionally steer, type `C-u C-c C-c`.

While walking the prompt history with `M-p`/`M-n`, you may edit
earlier prompts.  This blocks further history navigation; to resume,
you must send the prompt first, or revert with `M-x revert-buffer`.

When Markdown mode is installed, this buffer derives from it, so most
markdown editing commands are also available.

#### Attachments

The `C-c C-a` command attaches a file to send along with the prompt.
Like the analogous Message mode command, this prompts for a file in
the minibuffer, and inserts a tag line into the prompt buffer:
```
<#attachment filename="/home/you/screenshot.png">
```
If you change your mind and no longer want to attach the file, just
delete the tag line before sending the prompt.

From elsewhere in Emacs, you can also run this command (`M-x
dsh-bridge-attach-file`) directly to open a DSH-Prompt buffer with the
specified attachment, or `M-x dsh-bridge-attach-buffer-file` to open a
prompt with the current buffer's file as the attachment.

### Plan mode and goals

Plan mode and the session goal are provided by the following commands:

* `M-x dsh-bridge-toggle-plan-mode` — toggle plan mode.  With a
  numeric prefix argument, enable it if positive, disable otherwise.
* `M-x dsh-bridge-set-goal` — set or edit the goal objective.
  With a prefix argument, also read the goal round cap.
* `M-x dsh-bridge-toggle-goal` — pause or resume goal.
* `M-x dsh-bridge-pause-goal` — pause an active goal.
* `M-x dsh-bridge-resume-goal` — resume a paused or blocked goal.
* `M-x dsh-bridge-clear-goal` — clear the current goal.

These commands are also available in the menu bar.

### Sending text from DSH to Emacs

The DSH plugin adds a "Send to Emacs" button that lets you push
specific assistant messages to Emacs.  This automatically pops to the
DSH-View buffer in Emacs.  You can use `i` in the DSH-View buffer (or
run `M-x dsh-bridge-receive`) to pull the last message pushed.

## Permissions, authentication, and failure bounds

The bridge listens on the DSH web server's loopback interface and
never contacts a third-party service.  Every route is gated by a
shared bearer token, generated on first use and stored with owner-only
permissions at `~/.dsh/dsh-bridge-token`.  Emacs reads that file
directly, and the browser plugin fetches it from a route fenced to
loopback peers and same-origin pages.  Request bodies are capped at 1
MiB, and messages waiting for Emacs sit in a bounded outbox that
evicts the oldest entries (with a warning).

Turn activity is bounded too: `/turns` carries at most 60 activity
entries per turn — the oldest slide out first, so a live turn's newest
activity is always sent — and activity for at most the newest 40 turns,
so the payload cannot grow without limit over a long session.
Reasoning crosses the wire only as a one-line summary; the full text
stays on the host.

Note that any third party with access to the token can do everything
this Emacs package can: send prompts, read session logs (including
persisted ones), answer the model's questions and approval requests,
interrupt running turns, name files for the host to attach, etc.
However, approvals submitted via this route grant no authority the web
UI could not grant.

## License

This software is released under the terms of the GNU General Public
License version 3, or later.  See [COPYING](COPYING).
