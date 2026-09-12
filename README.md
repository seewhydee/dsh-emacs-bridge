# dsh-emacs-bridge

This is a two-way bridge between [Emacs](https://www.gnu.org/software/emacs/)
and a [Deepseek Harness](https://github.com/deepseek-ai/deepseek-harness) 
session.  The bridge moves text from Emacs to DeepSeek Harness (DSH),
and vice versa, over loopback HTTP.  This lets you type in Emacs and
read DSH's replies without copy-pasting, while also avoiding streaming
voluminous LLM outputs through Emacs.

It consists of two components:

- `dsh-plugin/` — a DeepSeek Harness plugin (`dsh-emacs-bridge`).
- `emacs/dsh-bridge.el` — an Emacs package to interact with the harness.
- `emacs/dsh-bridge-install.el` — its optional companion library for
  installing and uninstalling the DSH plugin, loaded on demand.

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
2. (*optional*) If you run DSH from a source checkout, customize the
   variable `dsh-bridge-dsh-command` (e.g., `M-x customize-variable
   RET dsh-bridge-dsh-command RET`) with the DSH command (see below).
   Skip this if `dsh` is on the executable path or run via `npx`.
3. `M-x dsh-bridge-install-plugin` — install the bundled plugin into DSH.
4. Start or restart `dsh web`.

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

Optionally, you can also load `dsh-bridge-install.el`, which contains
the previously-mentioned `M-x dsh-bridge-install-plugin` command.  But
if you installed the DSH plugin directly by following the steps in the
preceding section, you probably won't need these.

## Usage

From Emacs, the main entry-points are these two commands:

- `M-x dsh-bridge` — open a transient menu for DSH commands.
- `M-x dsh-bridge-list-sessions` — show a list of DSH sessions.

Consider giving either of these a global keybinding, e.g.,

```elisp
(keymap-global-set "C-c d" #'dsh-bridge)
```

### Transient menu

The `M-x dsh-bridge` command opens a transient menu that prompts for
the next command.  The top line shows the session your next command
will act on.  The following commands are available from the transient
menu:

* `q` — exit the transient menu.
* `r` — open a buffer to type in a prompt.
* `s` — send the region or buffer as a prompt.
* `d` — send the region or buffer as a draft (can still edit in DSH's
        web interface before submitting).
* `f` — fetch and display the session's latest reply.
* `D` — describe the session.
* `t` — set the default target session.
* `u` — clear the default target session.
* `l` — open the DSH-Sessions buffer.

### DSH-Sessions buffer

The `M-x dsh-bridge-list-sessions` command opens a list of DSH
sessions.  The default target session (if any) is marked by a `*` in
the leftmost column, and the `S` (state) column shows each session's
live status.  The following commands are available from here:

* `q` — quit the window and bury the buffer.
* `RET` — do the next appropriate thing for the session at point.  If
          it is running, view the current replies, if waiting for a
          prompt, open a buffer to type a prompt, etc.
* `r` — open a buffer to type a prompt for the session at point.
* `f` — fetch and display the output from the session at point.
* `a` — answer a pending user query for the session at point.
* `t` — set the session at point as the default target.
* `u` — clear the default target.
* `v` — toggle whether archived sessions are shown (hidden by default).
* `R` — rename the session at point.
* `d` — archive the session at point.
* `+` — create a new session, optionally in a new workspace.
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
* `w` — copy the replies to the kill ring.
* `B` — branch the shown turn into a new session.
* `i` — receive the latest "Send to Emacs" message (see below).
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

#### Answering agent queries

If the model requests additional user input via the
`ask_user_question` tool, the query is surfaced in the DSH-View
buffer.  Type `a` here (or in the DSH-Sessions buffer with point on
the session) to open a buffer for handling the query.

In this buffer, mark the option(s) you choose with `RET`.  You can
also navigate to a question block and type your desired option's
number key, or type `c` and write a freeform answer via the
minibuffer.

To submit the answers, type `C-c C-c`.  Alternatively, type `C-c C-k`
to decline the query, canceling the tool call.

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
* `C-c C-k` — erase the buffer.
* `C-c C-f` — open the DSH-View buffer for this session.
* `C-c C-l` — open the DSH-Sessions buffer.
* `M-p`/`M-n` — walk the session's prompt history.

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

### Sending text from DSH to Emacs

The DSH plugin adds a "Send to Emacs" button that lets you push
specific assistant messages to Emacs.  This automatically pops to the
DSH-View buffer in Emacs.  You can use `i` in the DSH-View buffer (or
run `M-x dsh-bridge-receive`) to pull the last message pushed.

## Development testing

Running `make test` launches the standard unit test suite (Vitest for
plugin, ERT for elisp).  Running `make integration-test` performs a
suite of integration tests that boots the plugin against a live
DeepSeek Harness host with a mock LLM; see `integration/README.md`.
It is not part of `make test` (which stays fast); run it before
committing a host-plugin change and before a release.

## Permissions, authentication, and failure bounds

The DSH plugin registers its routes on the DSH web server's loopback
listener, and the browser plugin calls only same-origin
`/dsh-bridge/*` routes.  No third-party service is contacted.

Every `/dsh-bridge` route requires a shared bearer token stored at
`~/.dsh/dsh-bridge-token`, generated on first use in mode 0600.  Emacs
reads this file directly, while the browser plugin fetches it from the
loopback-only `GET /dsh-bridge/token` route (peer- and origin-fenced).

HTTP request bodies are capped at 1 MiB; larger bodies get a 413
error.  DSH-to-Emacs messages are held in a bounded outbox (100
unacknowledged entries); overflow evicts the oldest entries and is
reported to the collector.  Naming a cold (persisted-only) session
from Emacs resumes it on demand, matching the web UI; an id neither
live nor persisted is 404, a subagent-owned session is 409, and a
draft push fails with 409 when no browser client is subscribed.  The
read-only session report and the `POST /dsh-bridge/fork` source read are
the exceptions: each observes a cold session's persisted log without
resuming it.

`POST /dsh-bridge/send` also accepts an `attachments` list of absolute
host-local paths and reads those files itself, so attachment bytes never
travel through the 1 MiB JSON body.  This is within the same
bearer-token trust boundary as every other route (a token holder can
already mutate sessions and, through the model's tools, read files), but
it is a route-level file read, so it is stated here.  The bridge and the
DSH host must share a filesystem; a path the host cannot read is a 400.
Attachment bytes are copied into the content-addressed store under
`$DSH_HOME/attachments/v1` (images as normalized images, other files
verbatim), and one prompt may carry at most 20 attachments and 200 MiB
per file; the image store applies its own limits (20 MiB per image, 20
images, 200 MiB of images) and reports violations as 413 or 400.

## License

This software is released under the terms of the GNU General Public
License version 3, or later.  See [COPYING](COPYING).
