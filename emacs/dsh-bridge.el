;;; dsh-bridge.el --- Emacs <-> DeepSeek Harness bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.	 If not, see <https://www.gnu.org/licenses/>.

;; Author: Chong Yidong <cyd@stupidchicken.com>
;; Version: 0.9.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience

;;; Commentary:

;; This package bridges Emacs and a running DeepSeek Harness (DSH)
;; session, moving text from Emacs to DSH and back over loopback HTTP.
;; This lets you compose prompts and read DSH's replies within Emacs.

;; It is bundled with a plugin for DSH, which should be installed with
;; \\`M-x dsh-bridge-install-plugin' before using the other commands.

;; During plugin installation, we must run the `dsh' executable;
;; customize `dsh-bridge-dsh-command' to specify how.  If this is nil
;; (the default), the package tries to autodetect, but that may not
;; work properly if `dsh' is installed in a non-standard location.

;; The interactive entry points are:
;;
;; `dsh-bridge'					  - transient dispatcher
;; `dsh-bridge-list-sessions'	  - browse DSH sessions
;; Consider giving one or both of these a global keybinding.
;;
;; \\`M-x dsh-bridge' opens a transient menu that prompts for the next
;; command, with the top line showing the session your next command
;; will act on.  From here, you can send the region/buffer to DSH as a
;; prompt or draft prompt, fetch output from the session, etc.
;;
;; \\`M-x dsh-bridge-list-sessions' opens a buffer with a tabulated
;; list of DSH sessions.  You can type \\`f' to fetch output, \\`r' to
;; compose a reply, etc.
;;
;; The DSH-View buffer shows assistant text fetched from DSH.
;; Typically, each DSH-View buffer contains one turn (i.e., all
;; replies from a prompt to an idle reply), with mid-turn segments
;; separated by dividers.  From here, type `r' to compose a reply for
;; the session, `M-p'/`M-n' to cycle through the turn history, etc.
;;
;; From the DSH-Prompt buffer, you can type out prompts for DSH and
;; send them with \\`C-c C-c', or send as draft with \\`C-c C-d'.
;; Type \\`C-c C-f' to open the corresponding DSH-View buffer,
;; \\`M-p'/\\`M-n' to cycle through the prompt history, etc.
;;
;; For other keybindings, refer to the menu bar or elisp docs.
;; Suggestions for user interface improvements are welcome.

;;; Code:

(require 'url)
(require 'url-util)
(require 'url-parse)
(require 'subr-x)
(require 'seq)
(require 'json)
(require 'transient)
(require 'cl-lib)
(require 'button)
(require 'help-mode)

(defconst dsh-bridge-version "0.9.0"
  "Version string for the DSH-Bridge package.
This should match the version reported by the running DSH plugin.")

;;; Customize options

(defgroup dsh-bridge nil
  "Connect Emacs to a DeepSeek Harness session."
  :group 'tools)

(defcustom dsh-bridge-dsh-command nil
  "How the DeepSeek Harness process (dsh) is invoked.
This variable is used only when installing or uninstalling the DSH
plugin.  Its value can be one of the following:

- nil (the default) does auto-detection.  The first available of these
  is used: \"dsh\" on PATH, the npm global bin directory, or
  \"npx --yes @deepseek-ai/dsh\".

- A single shell-style command, which is first processed with
  `split-string-and-unquote' (which handles quotes and backslashes, but
  does NOT expand ~).  Example: \"pnpm -C /path/to/deepseek-harness dsh\"

- A list of strings: a command, followed by arguments, all handled
  verbatim."
  :type '(choice (const :tag "Auto-detect" nil)
				 (string :tag "Command line (split shell-style)")
				 (repeat :tag "Argv list (verbatim)" string))
  :group 'dsh-bridge)

(defcustom dsh-bridge-url "http://127.0.0.1:3080/dsh-bridge"
  "Base URL for the `dsh-emacs-bridge' HTTP route."
  :type 'string
  :group 'dsh-bridge)

(defcustom dsh-bridge-profile "web"
  "DSH profile that `dsh-bridge-install-plugin' installs into."
  :type 'string
  :group 'dsh-bridge)

(defun dsh-bridge--dsh-home ()
  "Return the DeepSeek Harness (DSH) home directory.
This is the directory where DSH stores all user data, and is specified
by the environment variable $DSH_HOME, falling back on ~/.dsh.

Note: a relative $DSH_HOME resolves against the working directory of the
dsh process, not Emacs; callers should treat the result as best-effort
in that case."
  (let ((home (string-trim (or (getenv "DSH_HOME") ""))))
	(if (string-empty-p home) "~/.dsh" home)))

(defcustom dsh-bridge-token-file
  (expand-file-name "dsh-bridge-token" (dsh-bridge--dsh-home))
  "File holding the shared bearer token for the DSH bridge.
The token is generated by the DSH plugin, and is required for accessing
every \"/dsh-bridge\" route on the DSH loopback interface."
  :type 'file
  :group 'dsh-bridge)

(defcustom dsh-bridge-timeout 5
  "Timeout in seconds for synchronous bridge requests."
  :type 'number
  :group 'dsh-bridge)

(defcustom dsh-bridge-prompt-markdown t
  "Whether to try using `markdown-mode' in DSH-Prompt buffers.
If non-nil and `markdown-mode' is installed, `dsh-bridge-prompt-mode'
derives from `markdown-mode'.  Otherwise, it derives from `text-mode'.
Changing this option requires a reload to take effect."
  :type 'boolean
  :group 'dsh-bridge)

(defcustom dsh-bridge-view-gfm t
  "Whether DSH-View buffers are font-locked as GitHub-Flavored Markdown.
If non-nil and `markdown-mode' is installed at load time,
`dsh-bridge-view-mode' derives from `gfm-view-mode', so replies render
as GitHub-Flavored Markdown.  Otherwise, it derives from `special-mode'
with no GFM rendering.  Changing this option requires reloading the
package to take effect."
  :type 'boolean
  :group 'dsh-bridge)

(defcustom dsh-bridge-receive-pop t
  "If non-nil, \"Send to Emacs\" from DSH pops to the buffer.
When the user clicks the \"Send to Emacs\" button in DSH, the specified
assistant text is pushed to a DSH-View buffer.  If this option is
non-nil, run `pop-to-buffer' to select and display that buffer as well.
If nil, the buffer is filled but not selected."
  :type 'boolean
  :group 'dsh-bridge)

(defcustom dsh-bridge-show-session-ids nil
  "If non-nil, show raw session IDs in the DSH-Sessions buffer.
If nil (the default), session IDs are not shown, and sessions are only
identified by their title and workspace."
  :type 'boolean
  :group 'dsh-bridge)

(defcustom dsh-bridge-sessions-show-archived nil
  "Whether the DSH-Sessions buffer shows archived sessions by default.
The default is to hide them, similar to the DSH web interface.  The user
can also toggle visibility via `dsh-bridge-toggle-archived-sessions'."
  :type 'boolean
  :group 'dsh-bridge)

(defcustom dsh-bridge-status-indicator 'emoji
  "How the session status appears in header lines and the sessions list.
The value should be one of the following:

- `emoji': 🟢/🟡/⚪ for idle/running/unknown.  This is the default, but
  may not be supported on all terminals.
- `geometric': ●/■/? for idle/running/unknown, with the first two glyphs
  colored green/amber.
- `text': ✓/…/? for idle/running/unknown.
- `none': hide the indicator entirely."
  :type '(choice (const :tag "Emojis" emoji)
				 (const :tag "Geometric glyphs" geometric)
				 (const :tag "Text" text)
				 (const :tag "None" none))
  :set (lambda (sym val)
		 (set-default sym val)
		 ;; Re-render open bridge buffers so the new style takes effect
		 ;; immediately; guarded because this runs at load time, before the
		 ;; refresh helper below is defined.
		 (when (fboundp 'dsh-bridge--refresh-status-display)
		   (dsh-bridge--refresh-status-display)))
  :group 'dsh-bridge)

(defcustom dsh-bridge-turn-complete 'refetch
  "What to do when a session's turn completes on the host.
A value of `refetch' (the default) refills DSH-View buffers showing the
completing session with the completed turn and refreshes the `(k/n)'
turn-position count.  A value of nil means to do nothing other than
updating the status glyph."
  :type '(choice (const :tag "Refill the shown turn" refetch)
				 (const :tag "Status glyph only" nil))
  :group 'dsh-bridge)

(defcustom dsh-bridge-view-elapsed-ticker t
  "Whether the DSH-View header shows a live elapsed-time segment.
If non-nil, a running turn's elapsed time is shown in the DSH-View
header and refreshed by a short repeating timer."
  :type 'boolean
  :group 'dsh-bridge)

(defcustom dsh-bridge-view-follow-at-newest t
  "Whether reaching the newest turn in a DSH-View buffer resumes following.
If non-nil (the default), the DSH-View buffer automatically enters
turn-following state if it shows the session's latest turn.  If nil, you
must do an additional M-n (`dsh-bridge-prompt-next-history') from
turn (1/X) to enable turn-following state."
  :type 'boolean
  :group 'dsh-bridge)

(defcustom dsh-bridge-turn-boundary-echo t
  "Whether turn boundaries are announced in the echo area.
When non-nil, each \"turn-start\" and \"turn-complete\" event produces a
brief echo area message; see `dsh-bridge--view-displayed-p'."
  :type 'boolean
  :group 'dsh-bridge)

(defcustom dsh-bridge-prompt-resend-confirm t
  "Whether to guard against duplicate prompting in the DSH-Prompt buffer.
If non-nil, when `\\[dsh-bridge-send-and-exit]' is called with the
prompt text exactly matching the text last sent to the DSH session, ask
for confirmation first.

This option does not affect `\\[dsh-bridge-draft]'."
  :type 'boolean
  :group 'dsh-bridge)

(defcustom dsh-bridge-describe-timeout 15
  "Seconds to wait for the session report request.
The report reads a cold session's whole persisted log and folds its
projections, which can outlast the general `dsh-bridge-timeout'."
  :type 'number
  :group 'dsh-bridge)

(defcustom dsh-bridge-describe-auto-refresh t
  "Whether a visible session report refreshes when its turn completes.
The refresh re-fetches the report and preserves point; it is deferred so
the synchronous request never runs inside the SSE process filter."
  :type 'boolean
  :group 'dsh-bridge)

;;; Session tracking

(defvar dsh-bridge-default-session nil
  "The DSH bridge's default target session ID, if any.
This session is targeted by context-free DSH commands; if nil or
invalid, the commands try to target the last-active session instead.
Set with the command `\\[dsh-bridge-set-default-target].")

(defvar-local dsh-bridge--prompt-session nil
  "Session ID for the DSH-Prompt buffer, or nil (default target).")

(defvar dsh-bridge--last-resolved-active nil
  "Cons (ID . LABEL) of the last-active DSH session, or nil.
This is a cache for rendering last-active label and status indicators.

ID is the session id that the running DeepSeek Harness (DSH) process
resolved as last-active for a request without an explicit session.

LABEL is the session display label; see `dsh-bridge--session-label'.
Its value may be nil if the request is still incomplete.")

(defvar dsh-bridge--view-content-session) ; forward declaration

(defvar dsh-bridge--describe-session) ; forward declaration

(defconst dsh-bridge-describe-buffer-name "*dsh-bridge-describe*"
  "Buffer name of the read-only DSH session report.")

(defvar dsh-bridge--sessions-cache nil
  "Cache of DeepSeek Harness session data.
The value is a list where each item corresponds to one DSH session,
formatted as an alist with these keys:

- `id' (session id string)
- `title' (string or nil)
- `cwd' (string or nil)
- `live' (boolean: whether live agent exists)
- `running' (boolean: whether live agent is mid-turn)
- `lastActive' and `createdAt' (ms-epoch numbers)
- `workspace' and `workspaceId' (string or nil)
- `archived' (boolean)")

(defvar-local dsh-bridge--sessions-archived-p nil
  "Whether the DSH-Sessions buffer shows archived sessions.
This is initialized by the option `dsh-bridge-sessions-show-archived',
and toggled by `\\[dsh-bridge-toggle-archived-sessions]'.")

(defvar dsh-bridge--session-status nil
  "Alist of (SESSION-ID STATE . START-MS) live session status, or nil.
STATE is `running' or `idle'.  START-MS is the ms-epoch time of the
session's turn start; it is present only while STATE is `running' and a
start time was recorded.

This variable is seeded from the host's sessions list, and updated based
on turn-start/turn-complete frames in the notification stream.")

(defvar dsh-bridge--session-models nil
  "Alist of (SESSION-ID . MODEL-DATA) for the DSH model catalog.
This variable is set during `dsh-bridge-select-model', and used as a
display cache to show the active model in DSH-prompt buffers.")

(defvar dsh-bridge--pending-questions nil
  "Alist of \"ask-user\" questions pending in DSH sessions.
Each entry has the form (SESSION-ID . ((QUESTION-ID . QUESTIONS) ...)).")

(defvar dsh-bridge--session-context nil
  "Alist storing the token and context window usage in DSH sessions.
Each entry has the form (SESSION-ID . (USED-TOKENS . CONTEXT-WINDOW)).")

(defun dsh-bridge--status-set (session-id state &optional start-ms)
  "Record SESSION-ID's status as STATE (`running' or `idle').
START-MS, if non-nil, specifies the ms-epoch turn-start time kept for
the elapsed ticker; it is dropped when the session goes idle."
  (setq dsh-bridge--session-status
		(assoc-delete-all session-id dsh-bridge--session-status))
  (when (and session-id (memq state '(running idle)))
	(push (cons session-id
				(cons state (if (and (eq state 'running) (numberp start-ms))
								start-ms
							  nil)))
		  dsh-bridge--session-status)))

(defun dsh-bridge--status-turn-start (session-id)
  "Return the ms-epoch turn-start time for SESSION-ID, or nil.
The start time is set while the session's status is `running' and
cleared when it goes idle.  The value can also be nil if Emacs did not
see any \"turn-start\" frame for the session."
  (let ((entry (and session-id
					(assoc session-id dsh-bridge--session-status))))
	(cdr-safe (cdr-safe entry))))

(defun dsh-bridge--status-state (session-id)
  "Return SESSION-ID's display status: `running', `idle', or `unknown'.
Saved (cold) sessions are always `unknown'; for others, the result is
obtained by trying to look up the cached `dsh-bridge--session-status',
then the cached session data's `running' flag, and finally falling back
on `unknown'.  No active retrieval is done.  See
`dsh-bridge--session-status' for the tracker entry shape."
  (let ((row (and session-id (dsh-bridge--session-for-id session-id))))
	(or (and row (not (alist-get 'live row)) 'unknown)
		(and session-id
			 (let ((entry (cdr (assoc session-id dsh-bridge--session-status))))
			   (and (consp entry) (car entry))))
        (and row (if (alist-get 'running row) 'running 'idle))
        'unknown)))

(defun dsh-bridge--session-awaiting-p (session-id)
  "Whether SESSION-ID has a live ask-user question pending."
  (and session-id (assoc session-id dsh-bridge--pending-questions)))

(defun dsh-bridge--pending-question (session-id)
  "The (QUESTION-ID . QUESTIONS) entry for SESSION-ID's pending ask, or nil."
  (let ((entry (and session-id (assoc session-id dsh-bridge--pending-questions))))
	(and entry (car (cdr entry)))))

(defun dsh-bridge--status-glyph (session-id)
  "Return a status indicator for SESSION-ID as a propertized string.
The choice of string contents is based on `dsh-bridge--status-state', with a
pending ask-user question taking display precedence (awaiting > running > idle
> unknown)."
  (if (eq dsh-bridge-status-indicator 'none)
      ""
    (let* ((awaiting (dsh-bridge--session-awaiting-p session-id))
           (state (dsh-bridge--status-state session-id))
           (char
			(if awaiting
				(pcase dsh-bridge-status-indicator
                  ('geometric "◌") ('emoji "⏳") (_ "!"))
              (pcase dsh-bridge-status-indicator
                ('geometric (pcase state ('idle "●")  ('running "■")  (_ "?")))
                ('emoji (pcase state ('idle "🟢") ('running "🟡") (_ "⚪")))
                (_ (pcase state ('idle "✓")  ('running "…")  (_ "?"))))))
           (face
			(cond
			 (awaiting 'dsh-bridge-status-awaiting-face)
			 (state
			  (pcase state
                ('idle    'dsh-bridge-status-idle-face)
                ('running 'dsh-bridge-status-running-face)
                (_        'dsh-bridge-status-unknown-face))))))
      (propertize char 'face face))))

;;; DSH executable and plugin management

;; This library requires (i) a working DSH installation, and (ii) an
;; installed DSH plugin, which manages the loopback interface for the
;; data bridge between Emacs and DSH.

;; In accessing the DSH installation, we have a bit of code gnarliness
;; as we try to accommodate the several different ways `dsh' can be
;; invoked: (i) dsh directly installed on PATH, (ii) run via npm, and
;; (iii) run via pnpm (e.g. if running directly From a repo checkout).

;; When dsh-emacs-bridge is installed as an Emacs package, the user is
;; expected to run \\`M-x dsh-bridge-install-plugin' to install the
;; DSH plugin (Emacs packaging has no install/uninstall hooks, and we
;; opt not to abuse autoload magic).  This installs the plugin as a
;; *file copy*; \\`M-x dsh-bridge-uninstall-plugin' uninstalls it.
;; However, the DSH plugin cannot be hot-swapped; we rely on the
;; user's manual intervention to restart DSH for the plugin to load.

;; To help guide the user, `dsh-bridge--ensure-plugin' is called on
;; common entry-points, and auto-detects the DSH installation and/or
;; the DSH plugin.  If the plugin is missing, it offers to install it.

(defun dsh-bridge--detect-npm-launcher ()
  "Helper function to auto-detect an npm command to launch `dsh'."
  (let ((npm (executable-find "npm"))
		prefix)
	(and npm
		 (setq prefix (ignore-errors (car (process-lines npm "prefix" "-g"))))
		 (not (string-empty-p prefix))
		 (seq-some (lambda (f) (if (file-executable-p f) (list f)))
				   ;; Candidate executables in npm's prefix dir
				   (mapcar (lambda (file) (expand-file-name file prefix))
						   '("bin/dsh" "bin/dsh.cmd"
							 "Scripts/dsh" "Scripts/dsh.cmd"
							 "node_modules/.bin/dsh.cmd"))))))

(defun dsh-bridge--dsh-installed-p ()
  "Whether a `dsh' command is available without any download.
This is non-nil if `dsh-bridge-dsh-command' is set, or `dsh' is on PATH,
or an npm global install is found; nil if we will be using npx."
  (or dsh-bridge-dsh-command
	  (executable-find "dsh")
	  (dsh-bridge--detect-npm-launcher)))

(defun dsh-bridge--dsh-command ()
  "Return the installed DeepSeek Harness command, or nil if none.
If non-nil, the value is a list of strings, the first being the main
command and the rest consisting of program arguments.

The result is found by trying `dsh-bridge-dsh-command', then `dsh' on
PATH, then the npm global bin directory, then `npx --yes @deepseek-ai/dsh'."
  (cond (dsh-bridge-dsh-command
		 (if (stringp dsh-bridge-dsh-command)
			 (split-string-and-unquote dsh-bridge-dsh-command)
		   dsh-bridge-dsh-command))
		((executable-find "dsh") '("dsh"))
		((dsh-bridge--detect-npm-launcher))
		((executable-find "npx") '("npx" "--yes" "@deepseek-ai/dsh"))))

(defun dsh-bridge--plugin-install-state ()
  "Return the DSH bridge plugin's installation state.
One of `installed' (profile manifest lists the plugin), `not-installed'
(profile exists but plugin not in manifest), or `no-profile' (no profile
directory at all, possibly because DSH has never been run here).

This function works by reading the package.json manifest in DSH's
profile directory; the plugin counts as installed if it appears in
`dependencies' or in `dsh.profile.bundles'."
  (let* ((dir (expand-file-name (format "profiles/%s" dsh-bridge-profile)
								(dsh-bridge--dsh-home)))
		 manifest data)
	(cond
	 ((not (file-directory-p dir)) 'no-profile)
	 ((and (file-readable-p (setq manifest (expand-file-name "package.json" dir)))
		   (setq data (with-temp-buffer
						(insert-file-contents manifest)
						(ignore-errors
						  (json-parse-string (buffer-string)
											 :object-type 'alist
											 :array-type 'list))))
		   (or (assoc 'dsh-emacs-bridge (alist-get 'dependencies data))
			   (member "dsh-emacs-bridge"
					   (alist-get 'bundles
								  (alist-get 'profile
											 (alist-get 'dsh data))))))
	  'installed)
	 (t 'not-installed))))

(defun dsh-bridge--plugin-directory ()
  "Return the directory holding the bundled DSH plugin, or nil.
The directory must contain a manifest and built `lib/' artifacts.

Look in two locations: a `dsh-plugin' subdirectory next to this
file (installed Emacs package), or a `dsh-plugin' directory next to this
one (as in the source repository for the `dsh-emacs-bridge' project)."
  (let* ((lib-file (or (locate-library "dsh-bridge")
					   (symbol-file 'dsh-bridge--plugin-directory)))
		 (here (and lib-file (file-name-directory lib-file))))
	(when here
	  (seq-find (lambda (dir)
				  (and (file-directory-p dir)
					   (file-exists-p (expand-file-name "package.json" dir))
					   (file-exists-p (expand-file-name "lib/index.js" dir))
					   dir))
				(list (expand-file-name "dsh-plugin" here)
					  (expand-file-name "../dsh-plugin" here))))))

(defvar dsh-bridge--bridge-status-cache nil
  "Cached DSH bridge interface state, or nil if not yet probed.
Possible values are nil, `running', `not-running', `unreachable', and
`forbidden'.  The cache is set per-session, and reset if a real request
contradicts it or an install/uninstall runs.")

(defun dsh-bridge--bridge-status ()
  "Probe the status of the DSH bridge interface.
Possible values: `running', `not-running', `incompatible',
`unreachable', and `forbidden'.

This function works by requesting \"GET /dsh-bridge/status\" (which is
auth-free and loopback-fenced).  If the bridge is running, the plugin
version is checked against `dsh-bridge-version'; the return value is
`running' if the version matches, `incompatible' otherwise.  Any other
response means the route (and hence the plugin) is absent."
  (let* ((url-request-method "GET")
		 (url-request-data nil)
		 (url-request-extra-headers nil)
		 (buf (ignore-errors
				(url-retrieve-synchronously (concat dsh-bridge-url "/status")
											t nil dsh-bridge-timeout))))
	(if (null buf)
		'unreachable
	  (let* ((response (dsh-bridge--parse-response buf))
			 (status (car response))
			 (alist (ignore-errors
					  (json-parse-string (cdr response) :object-type 'alist))))
		(kill-buffer buf)
		(cond
		 ((eq status 403) 'forbidden)
		 ((and (eq status 200)
			   (equal (alist-get 'name alist) "dsh-emacs-bridge"))
		  (let ((version (alist-get 'version alist)))
			(if (and (stringp version)
					 (equal version dsh-bridge-version))
				'running
			  'incompatible)))
		 (t 'not-running))))))

(defun dsh-bridge--note-request-failure ()
  "Clear the DSH bridge status cache when a real request contradicts it.
Callers invoke this on a transport failure or a 401/404."
  (if (memq dsh-bridge--bridge-status-cache '(running unreachable))
	  (setq dsh-bridge--bridge-status-cache nil)))

(defvar dsh-bridge--plugin-diagnosed nil
  "Non-nil once the DSH plugin's problem has been diagnosed this session.")

(defun dsh-bridge--offer-plugin-install (diagnosis question)
  "Offer to install the bridge plugin.
DIAGNOSIS is a sentence stating what is wrong; QUESTION is the y-or-n
question to ask.  Fall back to a message if no DSH is available."
  (let ((cmd (dsh-bridge--dsh-command)))
	(if (and (y-or-n-p (concat diagnosis "\n" question))
			 ;; Extra confirmation if using npx
			 (or (not (equal (car cmd) "npx"))
				 (y-or-n-p "Running dsh via npx; this may download data.  Proceed?")))
		(let ((dir (dsh-bridge--plugin-directory)))
		  (cond
		   ((null dir)
			(error "dsh-bridge: no bundled plugin found"))
		   ((null cmd)
			(error "dsh-bridge: no DSH command found; set `dsh-bridge-dsh-command'."))
		   ((not (executable-find "pnpm"))
			(error "dsh-bridge: `pnpm' not found; try installing the plugin manually"))
		   (t
			(dsh-bridge--install-plugin-async dir))))
	  (message "dsh-bridge: plugin install aborted"))))

(defun dsh-bridge--ensure-plugin ()
  "Check for DSH bridge plugin availability, and maybe offer to install.
This function is called at the top of every bridge request.  The plugin
diagnosis runs only once per session; later commands proceed and surface
an ordinary request error if the bridge is unavailable or incompatible."
  (let ((state (or dsh-bridge--bridge-status-cache ; use cache or do a probe
				   (setq dsh-bridge--bridge-status-cache
						 (dsh-bridge--bridge-status)))))
	(cond
	 ((eq state 'running))
	 (dsh-bridge--plugin-diagnosed nil)
	 (t
	  (setq dsh-bridge--plugin-diagnosed t) ; bug user only once
	  (cond
	   ;; Version mismatch (maybe DSH wasn't restarted after upgrade).
	   ((eq state 'incompatible)
		(dsh-bridge--offer-plugin-install
		 "DSH plugin version mismatch."
		 "Reinstall plugin? (If already installed, restart `dsh web'.)"))
	   ((eq state 'forbidden)
		(display-warning :error
		  "dsh-bridge: connection route forbidden; check `dsh-bridge-url'"))
	   (t
		(let ((profile-state (dsh-bridge--plugin-install-state)))
		  (cond
		   ;; Plugin installed but DSH unavailable.
		   ((eq profile-state 'installed)
			(let ((msg (concat "dsh-bridge: plugin installed, but "
							   (if (eq state 'unreachable)
								   (format "no bridge is running at %s"
										   dsh-bridge-url)
								 "not loaded; restart \"dsh web\""))))
			  (display-warning :error msg)))
		   ;; No plugin in the profile.  Offer an install only if
		   ;; there is evidence that DSH exists; otherwise the npx
		   ;; fallback would download DSH, which is beyond our remit.
		   ((or (eq profile-state 'not-installed) (dsh-bridge--dsh-installed-p))
			(dsh-bridge--offer-plugin-install
			 (format "No DSH bridge plugin in profile \"%s\"." dsh-bridge-profile)
			 "Install it now?"))
		   (t
			(user-error "dsh bridge: no DSH installation found"))))))))))

;; Install or uninstall the DSH plugin

(defun dsh-bridge--install-plugin (dir)
  "Install the bundled plugin at DIR into `dsh-bridge-profile'.
This runs synchronously and returns non-nil on success.  It requires
`dsh' installed (see `dsh-bridge--dsh-command'), and `pnpm' on PATH."
  (let ((cmd (dsh-bridge--dsh-command)))
	(and cmd (executable-find "pnpm")
		 (let ((buffer (get-buffer-create "*dsh-bridge-install*")))
		   (zerop (apply #'call-process (car cmd) nil buffer nil
						 (append (cdr cmd)
								 (list "plugin" "--profile" dsh-bridge-profile
									   "add" (concat "file:" dir)))))))))

(defun dsh-bridge--validate-plugin-install ()
  "Whether the profile composes with the plugin installed.
Runs `dsh --profile PROFILE --dump-config', which composes the plugin tree
without booting `dsh web' — a broken bundle would otherwise fail the entire
boot.  Returns nil when no `dsh' CLI is available."
  (let ((cmd (dsh-bridge--dsh-command)))
	(and cmd
		 (let ((buffer (get-buffer-create " *dsh-bridge-dump-config*")))
		   (prog1 (zerop (apply #'call-process (car cmd) nil buffer nil
								(append (cdr cmd)
										(list "--profile" dsh-bridge-profile
											  "--dump-config"))))
			 (kill-buffer buffer))))))

(defun dsh-bridge--report-install-result (composed)
  "Report the outcome of a plugin install.
COMPOSED is whether the profile composition validated (`--dump-config')."
  (if composed
	  (message "DSH plugin installed to profile \"%s\"; please restart DSH"
			   dsh-bridge-profile)
	(display-warning :error "Error installing DSH plugin; \
run `M-x dsh-bridge-uninstall-plugin' and troubleshoot")))

(defun dsh-bridge--plugin-install-finished ()
  "Post-install handling for the synchronous path: re-arm, validate, report."
  (setq dsh-bridge--bridge-status-cache nil
		dsh-bridge--plugin-diagnosed nil)
  (dsh-bridge--report-install-result (dsh-bridge--validate-plugin-install)))

(defun dsh-bridge--validate-sentinel (process event)
  "Sentinel for the asynchronous post-install validation."
  (when (string-prefix-p "finished" event)
	(dsh-bridge--report-install-result (zerop (process-exit-status process)))))

(defun dsh-bridge--validate-plugin-install-async ()
  "Validate the composed profile asynchronously after an async install.
`--dump-config' pays node startup (seconds), so it runs as its own process
rather than blocking Emacs in the install sentinel."
  (let ((cmd (dsh-bridge--dsh-command)))
	(if (null cmd)
		(dsh-bridge--report-install-result nil)
	  (let ((process
			 (make-process
			  :name "dsh-bridge-validate"
			  :buffer (get-buffer-create " *dsh-bridge-dump-config*")
			  :command (append cmd
							   (list "--profile" dsh-bridge-profile
									 "--dump-config"))
			  :sentinel #'dsh-bridge--validate-sentinel)))
		(set-process-query-on-exit-flag process nil)))))

(defun dsh-bridge--install-sentinel (process event)
  "Sentinel for the asynchronous plugin install: chain into validation."
  (when (string-prefix-p "finished" event)
	(if (not (zerop (process-exit-status process)))
		(message "dsh-bridge: plugin install failed; see the *dsh-bridge-install* buffer")
	  (setq dsh-bridge--bridge-status-cache nil
			dsh-bridge--plugin-diagnosed nil)
	  (dsh-bridge--validate-plugin-install-async))))

(defun dsh-bridge--install-plugin-async (dir)
  "Install the bundled plugin at DIR asynchronously (for the install offer).
pnpm can take tens of seconds, which is fine for a deliberate `M-x' but rude
mid-keystroke when triggered by the fallback handler; the sentinel validates
the composed profile before suggesting a restart."
  (let ((cmd (dsh-bridge--dsh-command)))
	(when cmd
	  (let ((process
			 (make-process
			  :name "dsh-bridge-install"
			  :buffer (get-buffer-create "*dsh-bridge-install*")
			  :command (append cmd
							   (list "plugin" "--profile" dsh-bridge-profile
									 "add" (concat "file:" dir)))
			  :sentinel #'dsh-bridge--install-sentinel)))
		(set-process-query-on-exit-flag process nil)))))

;;;###autoload
(defun dsh-bridge-install-plugin ()
  "Install the bundled `dsh-emacs-bridge' plugin into the DSH profile.
Runs \"dsh plugin --profile PROFILE add file:DIR\", where PROFILE is
`dsh-bridge-profile' and DIR is the plugin directory bundled with this
package.  The `file:' spec makes pnpm copy the plugin into the profile,
so the installation survives upgrades of this Emacs package; re-run this
command after each upgrade to refresh the installed copy.

Restart \"dsh web\" afterwards for the plugin to load.

The installation requires a working `dsh' (see `dsh-bridge-dsh-command')
as well as `pnpm' on PATH."
  (interactive)
  (let ((dir (dsh-bridge--plugin-directory)))
	(unless dir
	  (user-error "No bundled dsh-emacs-bridge plugin found"))
	(unless (dsh-bridge--dsh-command)
	  (user-error "No `dsh' executable found; set `dsh-bridge-dsh-command'"))
	(unless (executable-find "pnpm")
	  (user-error "No `pnpm' executable found on PATH"))
	(if (dsh-bridge--install-plugin dir)
		(dsh-bridge--plugin-install-finished)
	  (display-buffer (get-buffer-create "*dsh-bridge-install*"))
	  (user-error "dsh plugin install failed"))))

;;;###autoload
(defun dsh-bridge-uninstall-plugin ()
  "Remove the bridge plugin from the DSH profile.
Calls \"dsh plugin --profile PROFILE remove dsh-emacs-bridge\", where
PROFILE is `dsh-bridge-profile'.  Running this is safe even if the
plugin is not installed.

Restart \"dsh web\" afterwards for the plugin to unload."
  (interactive)
  (if (not (eq (dsh-bridge--plugin-install-state) 'installed))
	  (message "dsh-bridge: no existing plugin installed")
	(unless (dsh-bridge--dsh-command)
	  (user-error "No `dsh' executable found; set `dsh-bridge-dsh-command'"))
	(unless (executable-find "pnpm")
	  (user-error "No `pnpm' executable found on PATH"))
	(let ((cmd (dsh-bridge--dsh-command))
		  (buffer (get-buffer-create "*dsh-bridge-install*")))
	  (if (zerop (apply #'call-process (car cmd) nil buffer nil
						(append (cdr cmd)
								(list "plugin" "--profile" dsh-bridge-profile
									  "remove" "dsh-emacs-bridge"))))
		  (progn
			(setq dsh-bridge--bridge-status-cache nil
				  dsh-bridge--plugin-diagnosed nil)
			(message "DSH plugin `dsh-emacs-bridge' removed; \
restart \"dsh %s\" to complete unload"
					 dsh-bridge-profile))
		(display-buffer buffer)
		(user-error "dsh plugin remove failed")))))

;;; Low-level HTTP plumbing

(defun dsh-bridge--parse-response (buffer)
  "Return (STATUS . BODY) for BUFFER.
STATUS is the HTTP response status code (`url-http-response-status', or nil
when the buffer carries none); BODY is the UTF-8 text after the response
headers (\"\" when no header terminator is present)."
  (with-current-buffer buffer
	(let ((status (bound-and-true-p url-http-response-status)))
	  (goto-char (point-min))
	  (cons status
			(if (re-search-forward "\r?\n\r?\n" nil t)
				(decode-coding-string
				 (buffer-substring-no-properties (point) (point-max)) 'utf-8)
			  "")))))

(defun dsh-bridge--token ()
  "Return the bridge bearer token as a unibyte string, or nil if none."
  (let ((token (and (file-readable-p dsh-bridge-token-file)
					(with-temp-buffer
					  (insert-file-contents dsh-bridge-token-file)
					  (string-trim (buffer-string))))))
	;; `insert-file-contents' yields a multibyte string, which is not
	;; accepted by `url-http'.  Multibyteness can even be induced by
	;; the authorization header, so watch out.
	(and token (string-to-unibyte token))))

;;; Push notifications

;; The DSH plugin implements a push channel, which updates Emacs on
;; happenings in the harness (turn lifecycle, per-session context
;; usage, session-inventory changes, the composer-draft push, and the
;; "Send to Emacs" outbox notice).

;; Emacs subscribes to this via a long-lived loopback connection to
;; `GET /dsh-bridge/events'.  As this is an in-principle infinite
;; stream, we operate it raw (with low-level code to handle HTTP/1.1,
;; chunking, etc.), rather than using `url-retrieve' or `url-http'
;; helpers.  Only the notification stream is handled like this; other
;; parts of the bridge use `url-http'.

(defvar dsh-bridge--notifications-enabled nil
  "Whether the DSH notification listener is currently enabled.")

(defvar dsh-bridge--notifications-paused nil
  "Whether the user has explicitly paused the DSH notification listener.
`dsh-bridge-notifications-stop' latches this so the listener stays off until
`dsh-bridge-notifications-start' is called again.")

(defvar dsh-bridge--notifications-process nil
  "The DSH bridge's live SSE notification process, or nil.")

(defvar dsh-bridge--notifications-timer nil
  "Reconnect timer for the DSH notification listener, or nil.")

(defvar dsh-bridge--notifications-raw ""
  "Raw bytes from the DSH bridge's notification process.
This variable is managed solely by `dsh-bridge--notifications-connect'
and `dsh-bridge--notification-filter'.")

(defvar dsh-bridge--notifications-headers-done nil
  "Non-nil once the HTTP response headers have been consumed.")

(defvar dsh-bridge--notifications-sse ""
  "Raw bytes from the DSH bridge's notification process.
The \"data:\" payloads are decoded to UTF-8 only at the point of
consumption, in `dsh-bridge--sse-parse'.  This variable is managed by
`dsh-bridge--notifications-connect' and `dsh-bridge--notification-filter'.")

(defvar dsh-bridge--notifications-receive-pending nil
  "Non-nil while a receive is scheduled for a push notification.")

(defun dsh-bridge--chunked-decode (text)
  "Decode HTTP/1.1 chunked-transfer-encoded TEXT (a unibyte string).
Return (DECODED . REST), where DECODED is the decoded body prefix, and
REST is the raw trailing text of an incomplete chunk."
  (let ((chunks nil)
		(rest text))
	(catch 'done
	  (while t
		(unless (string-match "\\`\\([0-9A-Fa-f]+\\)\r?\n" rest)
		  (throw 'done nil))
		(let* ((hex (match-string 1 rest))
			   (size (string-to-number hex 16))
			   (size-end (match-end 0)))
		  (if (= size 0)
			  (if (>= (length rest) (+ size-end 2))
				  (progn (setq rest (substring rest (+ size-end 2)))
						 (throw 'done nil))
				(throw 'done nil))
			(let ((data-end (+ size-end size)))
			  (if (>= (length rest) (+ data-end 2))
				  (progn (push (substring rest size-end data-end) chunks)
						 (setq rest (substring rest (+ data-end 2))))
				(throw 'done nil)))))))
	(cons (apply #'concat (nreverse chunks)) rest)))

(defun dsh-bridge--sse-parse (text)
  "Parse the accumulated bytes TEXT into (EVENTS . REST).
TEXT is a unibyte string containing the accumulated raw bytes from the
DSH bridge's notification process.

In the return value, EVENTS is a list of \"data:\" payloads (alists),
decoded from UTF-8, and REST stores the trailing bytes."
  (let ((events nil)
		(rest text))
	(while (string-match "\\(?:\r?\n\\)\\{2\\}" rest)
	  (let ((chunk (substring rest 0 (match-beginning 0))))
		(setq rest (substring rest (match-end 0)))
		(dolist (line (split-string chunk "\r?\n"))
		  (when (string-prefix-p "data:" line)
			;; Payload is decoded at the point of consumption, so a
			;; multibyte character split across chunk boundaries is
			;; never decoded prematurely.
			(let* ((payload (decode-coding-string
							 (string-trim (substring line 5)) 'utf-8))
				   (json (condition-case nil
						   (json-parse-string payload
											  :object-type 'alist
											  :array-type 'list)
						 (error nil))))
			  (when json (push json events)))))))
	(cons (nreverse events) rest)))

(defun dsh-bridge--describe-maybe-refresh (session-id)
  "Re-fetch the visible session report when it describes SESSION-ID.
Deferred: the report fetch is synchronous, so it must not run inside the
SSE process filter."
  (when (and dsh-bridge-describe-auto-refresh session-id)
	(let ((buffer (get-buffer dsh-bridge-describe-buffer-name)))
	  (when (and (buffer-live-p buffer)
				 (get-buffer-window buffer 'visible)
				 (with-current-buffer buffer
				   (equal dsh-bridge--describe-session session-id)))
		(run-at-time
		 0 nil
		 (lambda (buf)
		   (when (buffer-live-p buf)
			 (with-current-buffer buf
			   (when (equal dsh-bridge--describe-session session-id)
				 (revert-buffer)))))
		 buffer)))))

(defun dsh-bridge--notification-handle-events (events)
  "Dispatch decoded notification EVENTS received over the DSH bridge.
Currently supported events are:
- `turn-start': update status tracker, re-render, refresh DSH-View caches.
- `turn-complete': same as (i), and update session cache's `lastActive' slot.
- `replies-changed': refresh the turn cache (a text-bearing assistant message
  was committed mid-turn; the frame's `turn' names the turn that grew).
- `context': update `dsh-bridge--session-context' and re-render header
  lines reporting that data.
- `ask-user': record a pending ask-user question and surface it.
- `ask-user-resolved': retire a pending question (answered or cancelled).
- `sessions-changed': update existing DSH-Sessions buffers."
  (when (seq-some (lambda (e) (equal (alist-get 'kind e) "sessions-changed"))
				  events)
	(dsh-bridge--notification-sessions-changed))
  (dolist (event events)
	(let ((kind (alist-get 'kind event))
		  (id   (alist-get 'sessionId event)))
	  (cond
	   ((equal kind "turn-start")
		(when id
		  (dsh-bridge--status-set id 'running (alist-get 'time event))
		  (dsh-bridge--status-event-render id)
		  (dsh-bridge--models-event-refresh id)
		  (when dsh-bridge-turn-boundary-echo
			(message "dsh-bridge: session \"%s\" is running..."
					 (dsh-bridge--session-label id)))
		  ;; A turn boundary is also when the turn list grows: refresh it now
		  ;; so the View `(k/n)' counter tracks the live list during the turn,
		  ;; not only after it completes.  Deferred like the turn-complete
		  ;; refresh, to keep the SSE process filter non-blocking.
		  (run-at-time 0 nil #'dsh-bridge--view-turns-cache-refresh id)))
	   ((equal kind "turn-complete")
		(when id
		  (dsh-bridge--status-set id 'idle)
		  ;; Fold the turn's timestamp into the session cache.
		  (dsh-bridge--session-update-last-active id (alist-get 'time event))
		  ;; Defensive: a turn that ended without a resolved frame cannot still
		  ;; be waiting on the user.  Clear before rendering, or the status
		  ;; glyph would paint the just-stale `awaiting' state.
		  (dsh-bridge--ask-user-session-clear id)
		  (dsh-bridge--status-event-render id)
		  (dsh-bridge--models-event-refresh id)
		  (dsh-bridge--describe-maybe-refresh id)
		  (dsh-bridge--turn-complete-act id (alist-get 'reason event))))
	   ((equal kind "replies-changed")
		(when id
		  ;; One deferred job per frame (`dsh-bridge--turns-changed'): the
		  ;; turn-cache refresh and the following-view refill share it, so a
		  ;; frame costs one `/turns' round-trip however many views follow the
		  ;; session.
		  (run-at-time 0 nil #'dsh-bridge--turns-changed id)))
	   ((equal kind "context")
		(let ((used (alist-get 'usedTokens event))
			  (window (alist-get 'contextWindow event)))
		  (when (and id (numberp used) (numberp window))
			(setq dsh-bridge--session-context
				  (assoc-delete-all id dsh-bridge--session-context))
			(push (cons id (cons used window)) dsh-bridge--session-context)
			;; Redraw the prompt and view headers in the same tick.
			(dsh-bridge--refresh-view-headers)
			(force-mode-line-update t))))
	   ((equal kind "ask-user")
		(let ((question-id (alist-get 'questionId event))
			  (questions (alist-get 'questions event)))
		  (when (and id question-id questions)
			(dsh-bridge--ask-user-arrive id question-id questions))))
	   ((equal kind "ask-user-resolved")
		(when (and id (alist-get 'questionId event))
		  (dsh-bridge--ask-user-resolved id (alist-get 'questionId event)
										(alist-get 'outcome event))))))))

(defvar dsh-bridge--sessions-changed-timer nil
  "Timer for debounced sessions-list refetch after a `sessions-changed' frame.")

(defun dsh-bridge--notification-sessions-changed ()
  "Debounce a DSH-Sessions refetch after a sessions-changed frame.
Refetch if list is live, preserving point by session id.  Coalesce a
burst of frames (e.g., a rename) into one refresh."
  (when (timerp dsh-bridge--sessions-changed-timer)
	(cancel-timer dsh-bridge--sessions-changed-timer)
	(setq dsh-bridge--sessions-changed-timer nil))
  (when (and (buffer-live-p (get-buffer "*dsh-bridge-sessions*"))
			 (with-current-buffer "*dsh-bridge-sessions*"
			   (eq major-mode 'dsh-bridge-sessions-mode)))
	(setq dsh-bridge--sessions-changed-timer
		  (run-at-time 0.5 nil #'dsh-bridge--refresh-sessions-buffer))))

(defun dsh-bridge--notification-receive ()
  "Receive a pending DSH push notification."
  (setq dsh-bridge--notifications-receive-pending nil)
  (funcall 'dsh-bridge-receive)) ; defined below

(defun dsh-bridge--notification-filter (_proc string)
  "Process filter for the DSH push notification network connection."
  (setq dsh-bridge--notifications-raw
		(concat dsh-bridge--notifications-raw string))
  (unless dsh-bridge--notifications-headers-done
	(let ((pos (string-match "\r\n\r\n" dsh-bridge--notifications-raw)))
	  (when pos
		(setq dsh-bridge--notifications-raw
			  (substring dsh-bridge--notifications-raw (+ pos 4)))
		(setq dsh-bridge--notifications-headers-done t))))
  (when dsh-bridge--notifications-headers-done
	(let* ((decoded (dsh-bridge--chunked-decode dsh-bridge--notifications-raw))
		   (body (car decoded)))
	  (setq dsh-bridge--notifications-raw (cdr decoded))
	  (unless (string-empty-p body)
		(let* ((sse-str (concat dsh-bridge--notifications-sse body))
			   (parsed (dsh-bridge--sse-parse sse-str))
			   (events (car parsed)))
		  (setq dsh-bridge--notifications-sse (cdr parsed))
		  (when events
			;; Turn lifecycle: update the status tracker and re-render the
			;; matching buffers/list row.  Runs for any event batch, before the
			;; outbox handling below.
			(dsh-bridge--notification-handle-events events)
			(when (and (seq-some
						(lambda (e) (equal (alist-get 'kind e) "outbox"))
						events)
					   (not dsh-bridge--notifications-receive-pending))
			  (setq dsh-bridge--notifications-receive-pending t)
			  ;; Defer: `dsh-bridge-receive' does a synchronous pull that must
			  ;; not re-enter this filter via `accept-process-output'.
			  (run-at-time 0 nil #'dsh-bridge--notification-receive))))))))

(defun dsh-bridge--notifications-retry ()
  "Schedule a reconnect attempt for the notification listener."
  (when (and dsh-bridge--notifications-enabled
			 (not (timerp dsh-bridge--notifications-timer)))
	(setq dsh-bridge--notifications-timer
		  (run-at-time 5 nil #'dsh-bridge-notifications-start))))

(defun dsh-bridge--notification-sentinel (_proc event)
  "Sentinel for the SSE notification process: reconnect on close/error."
  (unless (string-prefix-p "open" event)
	(setq dsh-bridge--notifications-process nil)
	(when dsh-bridge--notifications-enabled
	  (dsh-bridge--notifications-retry))))

(defun dsh-bridge--notifications-connect (token)
  "Open the SSE connection and send the subscribe request."
  (let* ((parsed (url-generic-parse-url (concat dsh-bridge-url "/events")))
		 (host (url-host parsed))
		 (port (url-port parsed)))
	(setq dsh-bridge--notifications-raw "")
	(setq dsh-bridge--notifications-headers-done nil)
	(setq dsh-bridge--notifications-sse "")
	(setq dsh-bridge--notifications-process
		  (make-network-process
		   :name "dsh-bridge-notifications"
		   :host host
		   :service port
		   :family 'ipv4
		   :coding 'binary
		   :noquery t
		   :filter #'dsh-bridge--notification-filter
		   :sentinel #'dsh-bridge--notification-sentinel))
	(process-send-string
	 dsh-bridge--notifications-process
	 (format "GET %s?token=%s HTTP/1.1\r\nHost: %s:%d\r\nAccept: text/event-stream\r\n\r\n"
			 (url-filename parsed) (url-hexify-string token) host port))))

(defun dsh-bridge-notifications-start (&optional conditional)
  "Enable the DSH bridge notification listener (idempotent).
If called non-interactively with CONDITIONAL non-nil, do nothing if
`dsh-bridge--notifications-paused' or `dsh-bridge--notifications-enabled'
is non-nil."
  (interactive)
  (when (or (null conditional)
			(and (not dsh-bridge--notifications-paused)
				 (not dsh-bridge--notifications-enabled)))
	(setq dsh-bridge--notifications-paused nil)
	(setq dsh-bridge--notifications-enabled t)

	(when (timerp dsh-bridge--notifications-timer)
	  (cancel-timer dsh-bridge--notifications-timer)
	  (setq dsh-bridge--notifications-timer nil))
	(unless (and dsh-bridge--notifications-process
				 (process-live-p dsh-bridge--notifications-process))
	  (let ((token (dsh-bridge--token)))
		(if (null token)
			(dsh-bridge--notifications-retry)
		  (condition-case nil
			  (dsh-bridge--notifications-connect token)
			(error (dsh-bridge--notifications-retry))))))))

(defun dsh-bridge-notifications-stop ()
  "Pause the DSH bridge notification listener.
The listener stays off until `dsh-bridge-notifications-start' is called."
  (interactive)
  (setq dsh-bridge--notifications-paused t)
  (setq dsh-bridge--notifications-enabled nil)
  (when (timerp dsh-bridge--notifications-timer)
	(cancel-timer dsh-bridge--notifications-timer)
	(setq dsh-bridge--notifications-timer nil))
  (when (and dsh-bridge--notifications-process
			 (process-live-p dsh-bridge--notifications-process))
	(delete-process dsh-bridge--notifications-process))
  (setq dsh-bridge--notifications-process nil))

;;; Bridge requests

(defun dsh-bridge--extra-headers (payload)
  "Return HTTP header alist for request with PAYLOAD (nil for no body).
Include the Authorization header if a bearer token is known."
  (let ((token (dsh-bridge--token)))
	(append (and payload '(("Content-Type" . "application/json")))
			(and token `(("Authorization" . ,(concat "Bearer " token)))))))

(defun dsh-bridge--path (path session-id)
  "Return PATH with an optional ?sessionId= query parameter."
  (if session-id
	  (format "%s?sessionId=%s" path (url-hexify-string session-id))
	path))

(defun dsh-bridge--error-message (status http-status alist)
  "Return an error message for a failed request, or nil on success.
STATUS is the url-retrieve status plist, HTTP-STATUS is the HTTP status
code or nil, and ALIST is the decoded JSON body or nil."
  (let ((transport-error (plist-get status :error)))
	(cond
	 (transport-error (format "request failed: %s" transport-error))
	 ((and http-status (>= http-status 400))
	  (format "HTTP %s: %s" http-status
			  (or (alist-get 'error alist) "error")))
	 ((and alist (assoc 'error alist)) (alist-get 'error alist))
	 (t nil))))

(defun dsh-bridge--parse-json-body (body)
  "Decode JSON BODY as an alist, or nil when it is not a JSON object.
Arrays decode as lists (the async callback counterpart of `dsh-bridge--request',
whose JSON options this mirrors), and JSON null/false become nil."
  (condition-case nil
      (json-parse-string body
						 :object-type 'alist
						 :array-type 'list
						 :null-object nil
						 :false-object nil)
    (error nil)))

(defun dsh-bridge--call (method path payload callback)
  "Perform METHOD request to PATH on the DeepSeek Harness bridge.
PAYLOAD is an alist encoded as JSON (for POST) or nil (for GET).
CALLBACK is invoked with (status body-string HTTP-STATUS), where STATUS is nil
on a completed request (whatever the HTTP status) or an `:error' plist on a
transport failure/timeout.	Uses `url-retrieve-synchronously': a request here
is a short loopback round-trip, and the async `url-retrieve' path reports
process-sentinel failures (such as the bug#23750 \"Multibyte text in HTTP
request\" error) only via `message', which made them hard to diagnose."
  ;; Start the notification listener before the plugin check:
  ;; `dsh-bridge--ensure-plugin' can diagnose or error, and the status
  ;; tracker must hear `turn-start'/'turn-complete' regardless.
  (dsh-bridge-notifications-start t)
  (dsh-bridge--ensure-plugin)
  (let ((url-request-method method)
		(url-request-data
		 (and payload (encode-coding-string (json-encode payload) 'utf-8)))
		(url-request-extra-headers (dsh-bridge--extra-headers payload)))
	(let ((buf nil)
		  (err nil))
	  (condition-case e
		  (setq buf (url-retrieve-synchronously (concat dsh-bridge-url path)
												t nil dsh-bridge-timeout))
		(error (setq err e)))
	  (cond
	   (err (dsh-bridge--note-request-failure)
			(funcall callback (list :error (error-message-string err)) nil nil))
	   ((null buf) (dsh-bridge--note-request-failure)
		(funcall callback '(:error "request timed out") nil nil))
	   (t
		(let* ((response (dsh-bridge--parse-response buf))
			   (http-status (car response)))
		  (kill-buffer buf)
		  (when (memq http-status '(401 404))
			(dsh-bridge--note-request-failure))
		  (funcall callback nil (cdr response) http-status)))))))

(defun dsh-bridge--request (method path payload)
  "Perform METHOD request to PATH and return (STATUS . ALIST).
STATUS is the HTTP status code, or nil on transport failure.  ALIST is the
decoded JSON object (JSON null/false become nil, arrays become lists), or nil
when the body is not a JSON object."
  ;; Start the listener before the plugin check (see `dsh-bridge--call').
  (dsh-bridge-notifications-start t)
  (dsh-bridge--ensure-plugin)
  (let ((url-request-method method)
		(url-request-data
		 (and payload (encode-coding-string (json-encode payload) 'utf-8)))
		(url-request-extra-headers (dsh-bridge--extra-headers payload)))
	(let ((buf (url-retrieve-synchronously (concat dsh-bridge-url path)
										   t nil dsh-bridge-timeout)))
	  (if (null buf)
		  (progn (dsh-bridge--note-request-failure) (cons nil nil))
		(let* ((response (dsh-bridge--parse-response buf))
			   (status (car response))
			   (alist (ignore-errors
						(json-parse-string (cdr response)
										   :object-type 'alist
										   :array-type 'list
										   :null-object nil
										   :false-object nil))))
		  (kill-buffer buf)
		  (when (memq status '(401 404))
			(dsh-bridge--note-request-failure))
		  (cons status alist))))))

(defun dsh-bridge--fetch-sessions ()
  "Fetch the DSH session roster and return (STATUS . SESSIONS).
STATUS is the HTTP status, or nil on a transport failure.  SESSIONS is
the decoded session data, in the format of `dsh-bridge--sessions-cache'.
Also, update `dsh-bridge--sessions-cache' with the results.

SESSIONS may be nil if the roster is empty, or when the response has no
`sessions' key; callers can distinguish between the two cases by
checking STATUS for a failed request."
  (let* ((result (dsh-bridge--request "GET" "/sessions" nil))
		 (status (car result))
		 (sessions (and (eq status 200)
						(cdr (assoc 'sessions (cdr result))))))
	(when (eq status 200)
	  (setq dsh-bridge--sessions-cache sessions)
	  ;; Update session status trackers.  Each session's `running'
	  ;; flag becomes its live status; unlisted sessions are dropped."
	  (let ((seen '()) id)
		(dolist (session sessions)
		  (when (setq id (alist-get 'id session))
			(push id seen)
			(dsh-bridge--status-set id (if (alist-get 'running session)
										   'running
										 'idle))))
		(setq dsh-bridge--session-status
			  (seq-filter (lambda (entry) (member (car entry) seen))
						  dsh-bridge--session-status))))
	(cons status sessions)))

;;; Session labels

(defun dsh-bridge--session-title (session)
  "Return the title for SESSION, or nil if there is no title.
SESSION should be an alist; see `dsh-bridge--sessions-cache'."
  (let ((title (alist-get 'title session)))
	(and (stringp title) (not (string-empty-p title)) title)))

(defun dsh-bridge--session-for-id (id)
  "Return the session data for session id ID, or nil.
This is the `dsh-bridge--sessions-cache' entry with `id' matching ID.
See `dsh-bridge--sessions-cache' for the session data format."
  (seq-find (lambda (s) (equal (alist-get 'id s) id))
			dsh-bridge--sessions-cache))

(defun dsh-bridge--session-update-last-active (session-id time)
  "Update SESSION-ID's `lastActive' in the sessions cache to TIME (ms-epoch).
TIME is the turn frame's `time' field; nil leaves the value unchanged (an older
plugin omits it).  A no-op when the cache has no row for SESSION-ID.  Call
before re-rendering the sessions list so the Age cell and sort order go live."
  (when time
    (let ((session (dsh-bridge--session-for-id session-id)))
      (when session
        (setf (alist-get 'lastActive session) time)))))

(defun dsh-bridge--apply-session-directory (session-id cwd &optional buffer)
  "Set BUFFER's `default-directory' to SESSION-ID's workspace.
CWD, when non-nil, overrides the sessions-cache lookup for SESSION-ID.	Leaves
the directory alone when no cwd is known or BUFFER is not live.	 BUFFER is a
buffer name or buffer, defaulting to the current buffer."
  (let* ((buf (or buffer (current-buffer)))
		 (dir cwd))
	;; If CWD is not supplied, try filling it from session data.
	(and (null dir) session-id
		 (setq dir (alist-get 'cwd (dsh-bridge--session-for-id session-id))))
	(when (and dir (buffer-live-p (get-buffer buf)))
	  (with-current-buffer buf
		(setq default-directory (file-name-as-directory dir))))))

(defun dsh-bridge--session-label (session &optional no-default add-fallback-face)
  "Return the display label for SESSION.
SESSION should be a string (a session ID), or a session data alist in
the format described in `dsh-bridge--sessions-cache'.

If the session has no title, use the session ID as fallback.  As a final
fallback, use \"[Untitled Session]\" unless NO-DEFAULT is supplied, in
which case return nil.  If ADD-FALLBACK-FACE is non-nil, apply
`dsh-bridge-untitled-face' as a face property for any fallback string."
  (let ((alist (if (stringp session)
				   (dsh-bridge--session-for-id session)
				 session)))
	(or (and alist (dsh-bridge--session-title alist))
		(let ((fallback (or (if (stringp session)
								session
							  (alist-get 'id session))
							(unless no-default "[Untitled Session]"))))
		  (and add-fallback-face (stringp fallback)
			   (setq fallback
					 (propertize fallback 'face 'dsh-bridge-untitled-face)))
		  fallback))))

(defvar dsh-bridge--session-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] #'dsh-bridge-describe-session-at-mouse)
    map)
  "Local keymap for clickable session labels in header lines.")

(defun dsh-bridge--session-link (string session-id)
  "Return STRING propertized as a clickable describe link for SESSION-ID.
A nil or empty STRING, or a nil SESSION-ID, is returned unchanged, so a
header line without a bound session stays plain text."
  (if (or (null session-id) (not (stringp string)) (string-empty-p string))
	  string
	(propertize string
				'mouse-face 'highlight
				'help-echo "mouse-1: describe this session"
				'dsh-bridge-session-id session-id
				'keymap dsh-bridge--session-link-map)))

(defun dsh-bridge--relative-age (ts &optional now)
  "Return a compact relative age string for ms-epoch timestamp TS.
Matches DSH conventions (\"now\", \"5min\", \"3h\", \"2d\", \"4mo\", \"1y\").
NOW is the reference time in seconds (default: the current time)."
  (let* ((now (or now (float-time)))
		 (secs (max 0 (- now (/ ts 1000.0)))))
	(cond
	 ((< secs 60) "now")
	 ((< secs 3600) (format "%dmin" (floor (/ secs 60))))
	 ((< secs 86400) (format "%dh" (floor (/ secs 3600))))
	 ((< secs (* 30 86400)) (format "%dd" (floor (/ secs 86400))))
	 ((< secs (* 365 86400)) (format "%dmo" (floor (/ secs (* 30 86400)))))
	 (t (format "%dy" (floor (/ secs (* 365 86400))))))))

(defun dsh-bridge--workspace-label (session)
  "Return workspace label for SESSION.
SESSION should be an alist; see `dsh-bridge--sessions-cache'.
The workspace label is, in order of availability, the title, cwd
basename, raw cwd, or an empty string."
  (or (let ((ws (alist-get 'workspace session)))
		(and (stringp ws) (not (string-empty-p ws)) ws))
	  (let ((cwd (alist-get 'cwd session)))
		(and (stringp cwd) (not (string-empty-p cwd))
			 (let ((base (file-name-nondirectory (directory-file-name cwd))))
			   (and (not (string-empty-p base)) base))))
	  (or (alist-get 'cwd session) "")))

;;; Target helpers

(defun dsh-bridge--buffer-session (&optional buffer)
  "Buffer-local session affinity of BUFFER (default: the current buffer).
The prompt buffer's binding, else the output buffer's shown session, else
the session report's described session, else nil."
  (with-current-buffer (or buffer (current-buffer))
	(cond ((eq major-mode 'dsh-bridge-prompt-mode) dsh-bridge--prompt-session)
		  ((eq major-mode 'dsh-bridge-view-mode) dsh-bridge--view-content-session)
		  ((eq major-mode 'dsh-bridge-describe-mode) dsh-bridge--describe-session)
		  (t nil))))

(defun dsh-bridge--effective-session (&optional buffer)
  "The session id BUFFER acts on, or nil for last-active.
Buffer-local session, then the default target.	Every verb resolves its
target with this one helper, so the precedence cannot drift."
  (or (dsh-bridge--buffer-session buffer)
	  dsh-bridge-default-session))

(defun dsh-bridge--cache-last-active ()
  "Return the cached id of the most recently active live session, or nil.
Replicates the host's last-active algorithm (newest event time, falling back
to creation time, among live sessions).	 Display-only; never blocks."
  (let ((best nil) (best-time -1.0))
	(dolist (s dsh-bridge--sessions-cache best)
	  (when (alist-get 'live s)
		(let ((t0 (or (alist-get 'lastActive s) (alist-get 'createdAt s) 0)))
		  (when (> t0 best-time)
			(setq best-time t0)
			(setq best (alist-get 'id s))))))))

(defun dsh-bridge--prompt-status-session ()
  "The session id the prompt buffer's status and `✓ sent' marker read.
The buffer's binding, else the default target, else the resolved last-active
id (advisory — display only).  `dsh-bridge--effective-session' returns nil for
the last-active case, but a status/sent lookup needs a concrete id, so this
widens the rule."
  (or dsh-bridge--prompt-session
	  dsh-bridge-default-session
	  (car-safe dsh-bridge--last-resolved-active)
	  (dsh-bridge--cache-last-active)))

(defun dsh-bridge--dispatcher-header ()
  "Header string for the dispatcher: status plus the effective session.
This has the format \"<status> <label>[<qualifier>]\", where the
qualifier indicates if the DSH session is the user-specified default, or
the last-active session (as a fallback)."
  (let* ((buffer (or (bound-and-true-p transient--original-buffer)
					 (current-buffer)))
		 id label)
	(cond
	 ((setq id (dsh-bridge--effective-session buffer))
	  (setq label (dsh-bridge--session-label id))
	  ;; If targeting the default session, add a (default) qualifier.
	  (when (equal id dsh-bridge-default-session)
		(setq label (concat label " (default)"))))
	 ;; Try host-resolved last-active session.
	 ((setq id (car-safe dsh-bridge--last-resolved-active))
	  (setq label (concat (or (cdr dsh-bridge--last-resolved-active)
							  (dsh-bridge--session-label id))
						  " (last active)")))
	 ;; Otherwise, try the most recently active session.
	 ((setq id (dsh-bridge--cache-last-active))
	  (setq label (concat (dsh-bridge--session-label id) " (last active)"))))
	(unless label (setq label ""))
	(let ((status (and id (dsh-bridge--status-glyph id))))
	  (if (and status (not (string-empty-p status)))
		  ;; The transient menu leaves point at point-min; add a space
		  ;; to avoid overlapping the cursor with the status glyph.
		  (concat " " status " " label)
		label))))

(defun dsh-bridge--session-annotation (session)
  "One-line completion annotation for SESSION: workspace, running, age."
  (let ((ts (or (alist-get 'lastActive session)
				(alist-get 'createdAt session) 0)))
	(format "	 %s%s%s"
			(dsh-bridge--workspace-label session)
			(if (alist-get 'running session) " · running" "")
			(format " · %s" (dsh-bridge--relative-age ts)))))

(defun dsh-bridge--session-completion-table (choices)
  "Completion table over CHOICES, an alist of (STRING . SESSION).
Entries whose cdr is nil (e.g. a pseudo-entry) get no annotation."
  (let ((annots (mapcar (lambda (c)
						  (and (cdr c)
							   (cons (car c)
									 (dsh-bridge--session-annotation (cdr c)))))
						choices)))
	(lambda (string pred action)
	  (if (eq action 'metadata)
		  `(metadata (annotation-function .
					  ,(lambda (choice)
						 (let ((a (assoc choice annots)))
						   (and a (cdr a))))))
		(complete-with-action action choices string pred)))))

(defun dsh-bridge--id-tail (id)
  "A short stable suffix of session id ID, for display disambiguation.
DSH ids are `session-<uuid>', so the leading characters are identical; the
tail is the distinguishing part."
  (substring id (max 0 (- (length id) 6))))

(defun dsh-bridge--disambiguation-suffixes (sessions)
  "Distinct display suffixes for SESSIONS (which share a title).
Uses each session's workspace label when they are all distinct and non-empty;
otherwise falls back to a short id suffix, which is always distinct."
  (let ((labels (mapcar #'dsh-bridge--workspace-label sessions)))
	(if (and (= (length labels) (length (seq-uniq labels)))
			 (not (seq-some #'string-empty-p labels)))
		labels
	  (mapcar (lambda (s) (dsh-bridge--id-tail (alist-get 'id s)))
			  sessions))))

(defun dsh-bridge--read-ambiguous-session (title sessions)
  "Read one of SESSIONS (which share TITLE) via a second completing-read.
Each candidate appends a distinct suffix (workspace label, else id tail) and
is annotated with workspace, running state, and age.  Returns the chosen
session's id."
  (let* ((suffixes (dsh-bridge--disambiguation-suffixes sessions))
		 (choices (seq-mapn (lambda (s suffix)
							(cons (format "%s · %s" title suffix) s))
						  sessions suffixes))
		 (table (dsh-bridge--session-completion-table choices)))
	(alist-get 'id
			   (cdr (assoc (completing-read (format "Which %S? " title)
											table nil t)
						   choices)))))

(defun dsh-bridge--read-session-id (prompt &optional pseudo-entry)
  "Read a session id via completing-read, disambiguating duplicate titles.
Each candidate is annotated with its workspace, age, and running state.	 Both
live and saved (cold) sessions complete; the host resumes a saved id when the
request targets it.	 Untitled sessions complete as their raw id.  PSEUDO-ENTRY,
when non-nil, is an extra choice (e.g. \"(last-active)\" or \"(default)\") that
returns nil.  When several sessions share a title, a second completing-read
resolves the collision.	 With no sessions and no PSEUDO-ENTRY, signals an
error."
  (let* ((sessions (cdr (dsh-bridge--fetch-sessions)))
		 (choices (mapcar (lambda (s) ; return (LABEL . SESSION-DATA)
							(cons (dsh-bridge--session-label s t) s))
						  sessions))
		 (all (append choices
					  (and pseudo-entry (list (cons pseudo-entry nil)))))
		 (table (dsh-bridge--session-completion-table all)))
	(if (null all)
		(user-error "dsh-bridge: no sessions")
	  (let ((label (completing-read prompt table nil t)))
		(cond
		 ((equal label pseudo-entry) nil)
		 (t (let ((matches (seq-filter
							 (lambda (s)
							   (equal (dsh-bridge--session-label s t)
									  label))
							 sessions)))
			  (cond
			   ((null matches) nil)
			   ((null (cdr matches)) (alist-get 'id (car matches)))
			   (t (dsh-bridge--read-ambiguous-session label matches))))))))))

(defun dsh-bridge--read-session-override (prompt)
  "With a prefix argument, read a session for one-shot use.
Returns the chosen session id, or nil without a prefix argument (the caller
then uses the effective session)."
  (when current-prefix-arg
	(dsh-bridge--read-session-id prompt)))

(defun dsh-bridge--warn-if-unknown-session (id)
  "Check if session ID is unknown, and if so emit a warning."
  (unless (dsh-bridge--session-for-id id)
	(message "dsh-bridge: unknown session %s" id)))

(defun dsh-bridge--record-last-resolved (alist)
  "Record the session ALIST the host resolved for a nil-target request.
Advisory display cache only (see `dsh-bridge--last-resolved-active')."
  (let ((id (alist-get 'sessionId alist)))
	(when id
	  (setq dsh-bridge--last-resolved-active
			(cons id (or (alist-get 'title alist)
						 (dsh-bridge--session-label id)))))))

(defun dsh-bridge--region-or-buffer ()
  "Return the region text if the region is active, else the whole buffer."
  (if (use-region-p)
	  (buffer-substring-no-properties (region-beginning) (region-end))
	(buffer-substring-no-properties (point-min) (point-max))))

;;; Prompt history

;; The prompt history functionality is tied to DSH-Prompt buffers, for
;; which the buffer-local variable `dsh-bridge--prompt-session' tracks
;; the DSH session.  By default, there is one global DSH-Prompt buffer
;; (*dsh-bridge-prompt*), but we try to ensure things work even if the
;; user sets up multiple buffers (e.g., by renaming).

(defvar dsh-bridge--prompt-history nil
  "Alist of (SESSION-ID . PROMPTS) for DSH prompt history.
PROMPTS is a list of prompt strings, newest first.  This is a local
cache for the authoritative DSH-side history; each entry is updated when
`dsh-bridge--prompt-history-refresh' is called for that session.")

(defvar dsh-bridge--last-sent nil
  "Alist of (SESSION-ID . (TEXT . TS)) for the most recent prompt send.
TEXT is the sent prompt; TS is the float-time it was sent.  This
variable is updated by `dsh-bridge--prompt-history-record-send', and
used by the prompt header and the resend guard.  Drafts are not
recorded, so the guard never mistakes a draft push for a resend.")

;; Prompt history is tracked with two buffer-local variables.
;; Whenever `dsh-bridge--prompt-session' is reset, they must be reset.

(defvar-local dsh-bridge--prompt-history-index nil
  "Index into the current buffer's prompt list (newest first).
A nil value means the buffer holds a draft (i.e., not history).")

(defvar-local dsh-bridge--prompt-draft nil
  "Unsent buffer content saved when browsing prompt history, or nil.")

(defun dsh-bridge--buffer-prompt-history ()
  "Return the list of prompts for the current buffer's session, or nil."
  (and dsh-bridge--prompt-session
	   (cdr-safe (assoc dsh-bridge--prompt-session
						dsh-bridge--prompt-history))))

(defun dsh-bridge--prompt-history-position ()
  "Return the indicator string \" (k/n)\" for the prompt history.
Newest-first, 1-indexed (`(1/n)' is the newest).  This function uses the
buffer-local index and the cached list; no I/O."
  (let ((list (and dsh-bridge--prompt-history-index
				   (dsh-bridge--buffer-prompt-history))))
	(if list
		(format " (%d/%d)" (1+ dsh-bridge--prompt-history-index) (length list))
	  "")))

(defun dsh-bridge--prompt-history-refresh ()
  "Fetch the prompt history for this DSH-Prompt buffer.
Always fetches `GET /prompts' for the effective session; callers skip
the fetch while browsing, so \\`M-p' and \\`M-n' walk a stable list.  The
fetched list is cached in `dsh-bridge--prompt-history' under the session
id returned by the host."
  (let* ((path (dsh-bridge--path "/prompts" (dsh-bridge--effective-session)))
		 (result (dsh-bridge--request "GET" path nil))
		 (alist (cdr result))
		 (session-id (and alist (alist-get 'sessionId alist))))
	(unless session-id
	  (error "dsh-bridge: could not fetch prompt history"))
	;; Inject fetched history into `dsh-bridge--prompt-history'.
	(setq dsh-bridge--prompt-history
		  (cons (cons session-id (or (alist-get 'prompts alist) '()))
				(assoc-delete-all session-id dsh-bridge--prompt-history)))))

(defun dsh-bridge--prompt-show-history (&optional prompts)
  "Replace buffer contents from the prompt history.
If PROMPTS is supplied, use that as a list of prompts; otherwise use
the return value of `dsh-bridge--buffer-prompt-history'.

Use `dsh-bridge--prompt-history-index' to choose the element of PROMPTS
to insert; if this is nil, insert `dsh-bridge--prompt-draft' instead."
  (unless prompts
	(setq prompts (dsh-bridge--buffer-prompt-history)))
  (erase-buffer)
  (cond
   (dsh-bridge--prompt-history-index
	(let ((text (nth dsh-bridge--prompt-history-index prompts)))
	  (when text
		(insert text)
		(set-buffer-modified-p nil))))
   (dsh-bridge--prompt-draft
	(insert dsh-bridge--prompt-draft))) ; sets the modified flag
  (goto-char (point-max)))

(defun dsh-bridge-prompt-previous-history ()
  "Move backward through the DSH prompt history.
Replace the prompt in the current buffer with the previous prompt for
the current DSH session.  If the buffer has existing non-history
contents, stash it in `dsh-bridge--prompt-draft', so that a future
`dsh-bridge-prompt-next-history' can restore it."
  (interactive)
  (unless (eq major-mode 'dsh-bridge-prompt-mode)
	(user-error "Not in a DSH-Prompt buffer"))
  ;; Refetch prompt history if we were composing a draft (i.e., not
  ;; just walking history).
  (unless dsh-bridge--prompt-history-index
	(dsh-bridge--prompt-history-refresh))
  (let ((prompts (dsh-bridge--buffer-prompt-history)))
	(cond
	 ((null prompts)
	  (message "dsh-bridge: no earlier prompts in this session"))
	 ;; Stash the draft.
	 ((null dsh-bridge--prompt-history-index)
	  (setq-local dsh-bridge--prompt-draft (buffer-string))
	  (setq-local dsh-bridge--prompt-history-index 0)
	  (dsh-bridge--prompt-show-history prompts))
	 ;; If we edited a history prompt, disallow walking to avoid
	 ;; losing data.
	 ((buffer-modified-p)
	  (message
	   (substitute-command-keys
		"dsh-bridge: prompt history edited; \
send or `\\[revert-buffer]' first")))
	 ((>= dsh-bridge--prompt-history-index (1- (length prompts)))
	  (message "dsh-bridge: no earlier prompts in this session"))
	 (t
	  (setq-local dsh-bridge--prompt-history-index
				  (1+ dsh-bridge--prompt-history-index))
	  (dsh-bridge--prompt-show-history prompts)))))

(defun dsh-bridge-prompt-next-history ()
  "Move forward through the DSH prompt history.
After crossing the most recent historical prompt, restore the draft
stashed in `dsh-bridge-prompt-previous-history'."
  (interactive)
  (cond
   ((not (eq major-mode 'dsh-bridge-prompt-mode))
	(user-error "Not in a DSH-Prompt buffer"))
   ((null dsh-bridge--prompt-history-index)
	(message "dsh-bridge: no newer prompts"))
   ;; If we edited a history prompt, disallow walking.
   ((buffer-modified-p)
	(message
     (substitute-command-keys
	  "dsh-bridge: prompt history edited; send or `\\[revert-buffer]' first")))
   (t
	(setq-local dsh-bridge--prompt-history-index
				(unless (zerop dsh-bridge--prompt-history-index)
				  (1- dsh-bridge--prompt-history-index)))
	(dsh-bridge--prompt-show-history))))

(defun dsh-bridge--prompt-history-record-send (session-id text)
  "Update prompt history cache with TEXT for SESSION-ID.
Called from `dsh-bridge-send-text' after a prompt is successfully sent.
This may be called from any buffer (not only DSH-Prompt)."
  (when session-id
	;; Add to `dsh-bridge--prompt-history':
	(let ((entry (assoc session-id dsh-bridge--prompt-history)))
	  (if entry
		  (setcdr entry (cons text (cdr entry)))
		(push (cons session-id (list text)) dsh-bridge--prompt-history)))
	(setq dsh-bridge--last-sent
		  (cons `(,session-id . (,text . ,(float-time)))
				(assoc-delete-all session-id dsh-bridge--last-sent)))
	;; Invalidate history for any buffer tracking this session.
	(dolist (buf (buffer-list))
	  (with-current-buffer buf
		(when (equal session-id dsh-bridge--prompt-session)
		  (setq-local dsh-bridge--prompt-history-index nil)
		  (setq-local dsh-bridge--prompt-draft nil))))))

(defun dsh-bridge--revert-prompt-buffer (_ignore-auto _noconfirm)
  "Function to perform `revert-buffer' for DSH-Prompt buffers.
If walking through the prompt history, then:
- revert to the original form of the prompt if it has been edited;
- otherwise, return to the latest draft."
  (cond
   ((null dsh-bridge--prompt-history-index)
	(message "Nothing to revert."))
   ((buffer-modified-p)
	;; Restore the pristine version of this history entry.
	(dsh-bridge--prompt-show-history))
   (t
	;; Return to the draft.
	(setq-local dsh-bridge--prompt-history-index nil)
	(dsh-bridge--prompt-show-history))))

;;; Text senders (internal)

(defun dsh-bridge-send-text (text &optional session-id on-success)
  "Send TEXT to the DSH session as a prompt.
SESSION-ID overrides the effective session for this call only.
If ON-SUCCESS is a function, it is called with SENT-SESSION-ID in the
success branch of the send, after the history is recorded."
  (let* ((target (or session-id (dsh-bridge--effective-session)))
		 (payload (append (list (cons 'text text))
						  (and target (list (cons 'sessionId target))))))
	(dsh-bridge--call "POST" "/send" payload
	  (lambda (status body http-status)
		(let* ((alist (ignore-errors
						(json-parse-string body :object-type 'alist)))
			   (err (dsh-bridge--error-message status http-status alist)))
		  (cond
		   (err (message "dsh-bridge: %s" err))
		   ((null alist)
			(message "dsh-bridge: unreadable response: %s" body))
		   (t
			;; The session id in the response is authoritative,
			;; falling back to the requested target.  When neither
			;; names a session, the prompt is still reported as sent,
			;; but no session state is recorded or rendered.
			(let ((sent-id (or (alist-get 'sessionId alist) target)))
			  (if (null sent-id)
				  (message "dsh-bridge: prompt sent, but host reported no session")
				;; Optimistically mark the session as running so the
				;; header and sessions row flip immediately.  The SSE
				;; `turn-start' round-trip usually arrives shortly.  A
				;; turn that fails to start is corrected later.
				(dsh-bridge--status-set sent-id 'running)
				(dsh-bridge--status-event-render sent-id)
				(message "dsh-bridge: prompt sent")
				(when (null target)
				  ;; The host resolved last-active itself: record it.
				  (dsh-bridge--record-last-resolved alist))
				(dsh-bridge--prompt-history-record-send sent-id text))
			  (when (functionp on-success)
				(funcall on-success sent-id))))))))))

(defun dsh-bridge-send-draft (text &optional session-id)
  "Send TEXT to the DSH composer as a draft (not submitted).
SESSION-ID overrides the effective session for this call only."
  (let* ((target (or session-id (dsh-bridge--effective-session)))
		 (payload (append (list (cons 'text text))
						  (and target (list (cons 'sessionId target))))))
	(dsh-bridge--call "POST" "/draft" payload
	  (lambda (status body http-status)
		(let* ((alist (ignore-errors
						(json-parse-string body :object-type 'alist)))
			   (err (dsh-bridge--error-message status http-status alist)))
		  (cond
		   (err (message "dsh-bridge: %s" err))
		   ((null alist)
			(message "dsh-bridge: unreadable response: %s" body))
		   (t (message "dsh-bridge: draft pushed")
			  (unless target
				(dsh-bridge--record-last-resolved alist)))))))))

;;; Dispatcher layout

;; `eval-and-compile' because the transient macro expansion reads the
;; value at compile time.

(eval-and-compile
  (defconst dsh-bridge--verb-suffixes
	'(("s" dsh-bridge-send :description "send region/buffer (prompt)")
	  ("d" dsh-bridge-draft :description "send region/buffer (draft)")
	  ("f" dsh-bridge-fetch :description "fetch latest turn")
	  ("D" dsh-bridge-describe-session :description "describe session")
	  ("t" dsh-bridge-set-default-target :description "set default target")
	  ("u" dsh-bridge-clear-default-target :description "clear default target")
	  ("l" dsh-bridge-list-sessions :description "list sessions"))
	"Suffix specs for the `dsh-bridge' dispatcher.
Each spec is (KEY COMMAND DESCRIPTION).	 The view buffers no longer mirror
these letters; this table serves the dispatcher's layout alone.")

  (defun dsh-bridge--layout-verb (key)
	"Return the verb suffix spec with KEY from `dsh-bridge--verb-suffixes'."
	(assoc key dsh-bridge--verb-suffixes))

  (defconst dsh-bridge--dispatcher-layout
	(vconcat (list :description '(lambda () (dsh-bridge--dispatcher-header)))
			 (vconcat (list "Compose"
							'("r" dsh-bridge-prompt
							  :description "reply/open prompt buffer")
							(dsh-bridge--layout-verb "s")
							(dsh-bridge--layout-verb "d")))
			 (vconcat (list "Read"
							(dsh-bridge--layout-verb "f")
							(dsh-bridge--layout-verb "D")))
			 (vconcat (list "Sessions"
							(dsh-bridge--layout-verb "t")
							(dsh-bridge--layout-verb "u")
							(dsh-bridge--layout-verb "l")))
			 (vconcat (list '("q" transient-quit-one :description "quit"))))
	"Layout of the `dsh-bridge' dispatcher, grouped by purpose.
The verbs come from `dsh-bridge--verb-suffixes'; `r' (reply/open the prompt
buffer — the same key the buffers use) and `q' (quit) are dispatcher-only.
`t' set / `u' clear the default target; `S' is not a dispatcher key — in the
sessions list it keeps its tabulated-list sort meaning."))

;;; DSH-View buffer (*dsh-bridge-output*)

(defvar-local dsh-bridge--view-timestamp nil
  "Time the current DSH-View buffer was last refreshed, or nil.")

(defvar-local dsh-bridge--view-content-session nil
  "Session the DSH-View buffer's content came from, or nil.")

(defvar-local dsh-bridge--view-received-at nil
  "ms-epoch time the DSH-View buffer's contents were sent to Emacs.
This is set via a \"Send to Emacs\" push; if the contents were fetched
by an Emacs command, the value is nil.")

(defvar dsh-bridge--turns-cache nil
  "Alist of cached DSH-View turns, in the form (SESSION-ID EPOCH . TURNS).
For each turn, SESSION-ID is a session id string, EPOCH is its history
epoch, and TURNS is a list of turn records, newest first.  Each turn
record is an alist:

  (turn . NUMBER)
  (startedAt . MS-EPOCH)
  (endedAt . MS-EPOCH)		; absent while the turn is open
  (reason . KIND-STRING)	; absent while the turn is open
  (endSeq . SEQ)		; absent while the turn is open; the fork anchor
  (segments . ((text . STRING) (time . MS-EPOCH) (step . NUMBER)) ...)

An entry may have TURNS nil, which refers to a session folded to no
turns, e.g. after a compaction.")

(defvar-local dsh-bridge--view-turn nil
  "Turn number of the turn the DSH-View buffer shows, or nil.
A nil value corresponds to content with no turn identity, e.g., a
message pushed from DSH.")

(defvar-local dsh-bridge--view-turn-index nil
  "Index into the buffer's newest-first cached turn list, or nil.
A nil value means the view is \"at rest\", showing the content it was last
filled with (a fetch, a \"Send to Emacs\" push, or a follow refill).")

(defvar-local dsh-bridge--view-follow nil
  "Whether the DSH-View buffer is in turn-following state.
If non-nil, the buffer tracks the session's newest turn, auto-refilling
as its segments are committed (appending each new segment plus a
divider) and flipping to a newer turn when one appears.

This is set to nil by `\\[dsh-bridge-view-previous-reply]', which goes
to an older prompt.  The option `dsh-bridge-view-follow-at-newest'
controls whether to re-enter it automatically whenever the DSH-View
buffer is showing a session's latest turn.")

(defvar-local dsh-bridge--view-waiting nil
  "While non-nil, the DSH-View shows the running placeholder: the user has
just sent a prompt and the first reply of the new turn has not been committed
yet.  The value is the abandoned turn number whose content was showing before
the send (t when nothing was showing), so automatic refills only replace the
placeholder with a turn *newer* than the abandoned one — a textless new turn
must never resurrect the old content.  Set by `dsh-bridge--view-fill-waiting';
cleared when content arrives, on manual navigation/fetch, or when the sent
turn completes without text.")

(defvar dsh-bridge--view-ticker-timer nil
  "Repeating timer to repaint the DSH-View header, or nil.")

;;; Turn rendering and the position counter

;; The DSH-View shows one *turn*, consisting of text-bearing assistant
;; messages ("segments") separated by GFM horizontal-rule dividers.
;; For a still-running turn, the latest segment ends with a terminal
;; marker line "(continuing...)", or an "awaiting your response" note
;; if the agent is parked on an ask-user question.  Once the turn
;; completes, the final segment has no marker at the end.

(defvar dsh-bridge--view-segment-divider "\n\n---\n"
  "Text between two segments of the same turn in DSH-View buffers.
The default consists of (i) two newlines, (ii) a Markdown divider
\"---\", and (iii) one newline.  In `gfm-view-mode', (ii) is rendered as
a full-width line followed by a newline, so the divider appears as a
full-width line separated by single blank lines above and below.")

(defun dsh-bridge--view-turn-open-p (turn)
  "Whether TURN is still open (running): no end facts recorded yet.
A completed turn carries `endedAt' (and a `reason'), so an open turn is
recognized by their absence."
  (not (or (alist-get 'endedAt turn)
           (alist-get 'reason turn))))

(defun dsh-bridge--view-running-marker ()
  "The terminal marker line of a running turn, as a propertized string.
`(continuing...)' reads as \"this turn is not finished yet\".  The
`dsh-bridge-turn-marker' text property lets code (fill preservation, tests)
identify the marker regardless of model text that happens to read the same.

The face is given twice: as `face' (display when font-lock-mode is off, e.g.
the special-mode fallback or a user disabling font-lock) and as
`font-lock-face' (display when font-lock-mode is on).  Font lock manages only
the `face' property — its unfontify removes it and keywords write it — while
`font-lock-face' survives any font-lock pass, so the marker keeps its face no
matter when or how often the gfm-view-mode font-lock refontifies the buffer."
  (propertize "(continuing...)"
              'face 'dsh-bridge-view-marker-face
              'font-lock-face 'dsh-bridge-view-marker-face
              'dsh-bridge-turn-marker t))

(defun dsh-bridge--view-answer-key ()
  "The key sequence bound to `dsh-bridge-answer', as display text.
Searches the current buffer's local keymap (honoring a user rebinding), the
global map, and the DSH-View / DSH-Sessions maps, in that order; a command
bound nowhere reads as \"M-x dsh-bridge-answer\"."
  (let ((key nil)
        (maps (delq nil (list (and (current-local-map) (current-local-map))
                              (and (current-global-map) (current-global-map))
                              (and (boundp 'dsh-bridge-view-mode-map)
                                   dsh-bridge-view-mode-map)
                              (and (boundp 'dsh-bridge-sessions-mode-map)
                                   dsh-bridge-sessions-mode-map)))))
    (while (and (null key) maps)
      (setq key (where-is-internal 'dsh-bridge-answer (car maps) t)
            maps (cdr maps)))
    (if key (key-description key) "M-x dsh-bridge-answer")))

(defun dsh-bridge--view-await-question-text (text)
  "TEXT normalized for the awaiting note: one line, no double quotes,
truncated to about 72 columns with an ASCII ellipsis."
  (let* ((one-line (string-replace "\"" ""
				   (string-replace "\n" " " (or text ""))))
	 (one-line (replace-regexp-in-string "[ \t]+" " " one-line))
	 (one-line (string-trim one-line)))
    (if (> (length one-line) 72)
	(concat (substring one-line 0 69) "...")
      one-line)))

(defun dsh-bridge--view-awaiting-note (session-id)
  "The terminal note shown in place of `(continuing...)' while SESSION-ID is
parked on an ask-user question, as a propertized string.

The user has not seen the question yet, so the note leads with the pending
question's text (or its count) and says what to do next — the binding of
`dsh-bridge-answer', resolved live (`dsh-bridge--view-answer-key'), which
opens the question buffer.  Carries the same `dsh-bridge-turn-marker'
property as the running marker, so fill preservation and copy handling treat
the two interchangeably, plus `dsh-bridge-awaiting' to tell them apart.  The
face is carried both as `face' and `font-lock-face', for the same reason as
`dsh-bridge--view-running-marker': font-lock never removes the latter."
  (let* ((entry (dsh-bridge--pending-question session-id))
	 (questions (and entry (cdr entry)))
	 (count (length questions))
	 (first (car questions))
	 (raw (and (listp first) (alist-get 'question first)))
	 (text (dsh-bridge--view-await-question-text
		(and (stringp raw) (not (string-empty-p raw)) raw)))
	 (key (dsh-bridge--view-answer-key))
	 (body
	  (cond
	   ((and text (not (string-empty-p text)) (= count 1))
	    (format "Awaiting your response: “%s” — press %s to view and answer"
		    text key))
	   ((> count 1)
	    (format "Awaiting your response: %d questions — press %s to view and answer"
		    count key))
	   (t
	    (format "Awaiting your response — press %s to view the question" key)))))
    (propertize (concat "(" body ")")
		'face 'dsh-bridge-view-awaiting-face
		'font-lock-face 'dsh-bridge-view-awaiting-face
		'dsh-bridge-turn-marker t
		'dsh-bridge-awaiting t)))

(defun dsh-bridge--view-turn-tail (session-id)
  "The terminal marker of a running turn shown in SESSION-ID's view.
`(continuing...)' while the agent streams; the awaiting note
(`dsh-bridge--view-awaiting-note') while the session is parked on an
ask-user question, so the buffer itself says the user must act."
  (if (and session-id (dsh-bridge--session-awaiting-p session-id))
      (dsh-bridge--view-awaiting-note session-id)
    (dsh-bridge--view-running-marker)))

(defun dsh-bridge--view-running-placeholder ()
  "The placeholder line of a DSH-View waiting for a sent prompt's first reply.
`(running...)' reads as \"the agent is working, no reply committed yet\".  The
`dsh-bridge-turn-marker' text property is shared with the other furniture
lines, so fill preservation and copy handling treat them interchangeably.
The face is carried both as `face' and `font-lock-face', for the same reason
as `dsh-bridge--view-running-marker': font-lock never removes the latter."
  (propertize "(running...)"
              'face 'dsh-bridge-view-marker-face
              'font-lock-face 'dsh-bridge-view-marker-face
              'dsh-bridge-turn-marker t
              'dsh-bridge-running t))

(defun dsh-bridge--view-waiting-content (session-id)
  "The content line of a waiting DSH-View for SESSION-ID: the running
placeholder, or the awaiting note while a question is pending (a fresh turn
may ask before it commits any text)."
  (if (and session-id (dsh-bridge--session-awaiting-p session-id))
      (dsh-bridge--view-awaiting-note session-id)
    (dsh-bridge--view-running-placeholder)))

(defun dsh-bridge--view-waiting-accept-p (turn-number)
  "Whether content from TURN-NUMBER may replace the waiting placeholder.
A waiting view shows `(running...)' until a turn *newer* than the abandoned
one produces text; when nothing was abandoned (fresh session), any turn does."
  (and (numberp turn-number)
       (or (eq dsh-bridge--view-waiting t)
           (> turn-number dsh-bridge--view-waiting))))

(defun dsh-bridge--view-waiting-fill (session-id base &optional cwd)
  "Put the current DSH-View for SESSION-ID into the waiting state at BASE.
BASE is the abandoned turn number whose content was showing before the send
(nil for nothing).  The buffer shows the running placeholder (or the awaiting
note if a question is already pending) and turns on following; automatic
refills replace it only with a newer turn
(see `dsh-bridge--view-waiting-accept-p').  CWD, when non-nil, sets the
buffer's workspace directory."
  (dsh-bridge--view-fill session-id nil nil cwd t)
  (setq-local dsh-bridge--view-waiting (or base t))
  (setq-local dsh-bridge--view-follow t)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (dsh-bridge--view-waiting-content session-id))
    (goto-char (point-min)))
  (setq header-line-format (dsh-bridge--view-header-line))
  (dsh-bridge--view-ticker-ensure))

(defun dsh-bridge--view-turn-render (turn &optional session-id)
  "Buffer text for the whole TURN record, or \"\" for nil.
TURN's segments (oldest first) are joined by GFM horizontal-rule dividers; a
turn that is still running ends with the marker for SESSION-ID's view
(`dsh-bridge--view-turn-tail' — `(continuing...)' or the awaiting note), and
a completed turn ends cleanly after its last segment."
  (if (null turn)
      ""
    (let* ((texts (mapcar (lambda (seg) (or (alist-get 'text seg) ""))
                          (alist-get 'segments turn)))
           (body (mapconcat #'identity texts dsh-bridge--view-segment-divider)))
      (concat body
              (and (dsh-bridge--view-turn-open-p turn)
                   (if (string-empty-p body)
                       (dsh-bridge--view-turn-tail session-id)
                     (concat "\n\n" (dsh-bridge--view-turn-tail session-id))))))))

(defun dsh-bridge--view-turn-text (turn)
  "The raw Markdown of TURN's segments, blank-line separated (no dividers).
Used by `dsh-bridge-copy-reply' for a whole-turn copy."
  (mapconcat (lambda (seg) (or (alist-get 'text seg) ""))
			 (alist-get 'segments turn)
			 "\n\n"))

(defun dsh-bridge--view-turn-index-of (turns turn)
  "Index of TURN (a number) in TURNS (newest first), or nil when absent."
  (seq-position turns turn
				(lambda (record number)
				  (equal (alist-get 'turn record) number))))

(defun dsh-bridge--view-turn-position ()
  "Return the position segment for a DSH-View buffer.
This is a string of the form \"(k/n)\" (newest-first, 1-indexed), or the
empty string if there is no valid positioning.

If the DSH-View buffer is at rest, k is the position of the shown turn in the
session's cached turn list (a fetched turn is normally 1).  In turn-following
state, the segment reads `(latest/n)' instead.

This function uses the turns cache only, and does no synchronous I/O."
  (if dsh-bridge--view-waiting
      ;; Waiting for the first reply: the placeholder is not a turn, so no
      ;; position (the cache may still hold the abandoned turn).
      ""
    (let ((session dsh-bridge--view-content-session))
      (if (and session (dsh-bridge--turns-cache-turns session))
          (let* ((turns (dsh-bridge--turns-cache-turns session))
			   (n (length turns)))
			(cond
			 (dsh-bridge--view-follow (format " (latest/%d)" n))
			 (dsh-bridge--view-turn-index
			  (format " (%d/%d)" (1+ dsh-bridge--view-turn-index) n))
			 (dsh-bridge--view-turn
			  (let ((k (dsh-bridge--view-turn-index-of
						turns dsh-bridge--view-turn)))
				(if k (format " (%d/%d)" (1+ k) n) "")))
			 (t "")))
        ""))))

(defun dsh-bridge--view-elapsed-label (session-id)
  "The view header's elapsed-turn segment for SESSION-ID, or nil.
Returns \" ⏱ MM:SS\" while the session is running and a turn-start time is
known; nil when idle, unknown, or Emacs attached mid-turn (no t0).  Reads only
the status tracker — no I/O in a display path."
  (let ((start (and dsh-bridge-view-elapsed-ticker
					(eq (dsh-bridge--status-state session-id) 'running)
					(dsh-bridge--status-turn-start session-id))))
	(when (and start (numberp start))
	  (let ((secs (max 0 (floor (- (float-time) (/ start 1000.0))))))
		(format " ⏱ %02d:%02d" (floor (/ secs 60.0)) (% secs 60))))))

(defun dsh-bridge--view-buffers ()
  "Return all live buffers in `dsh-bridge-view-mode'."
  (seq-filter (lambda (buf)
				(with-current-buffer buf
				  (eq major-mode 'dsh-bridge-view-mode)))
			  (buffer-list)))

(defun dsh-bridge--session-views (session-id)
  "Return all live DSH-View buffers showing SESSION-ID.
A nil SESSION-ID matches view buffers not bound to a session."
  (seq-filter (lambda (buf)
				(with-current-buffer buf
				  (equal dsh-bridge--view-content-session session-id)))
			  (dsh-bridge--view-buffers)))

(defun dsh-bridge--session-view (session-id)
  "Return a DSH-View buffer showing SESSION-ID, or nil."
  (seq-find (lambda (buf)
			  (with-current-buffer buf
				(equal dsh-bridge--view-content-session session-id)))
			(dsh-bridge--view-buffers)))

(defun dsh-bridge--view-displayed-p (session-id)
  "Whether a DSH-View buffer is displaying SESSION-ID in a visible window.
A hidden view does not count as \"the user is looking\"."
  (seq-some (lambda (buf) (get-buffer-window buf 'visible))
	    (dsh-bridge--session-views session-id)))

(defun dsh-bridge--view-follow-enter ()
  "Put the current DSH-View buffer into turn-following state.
The buffer then tracks the session's newest turn, refilling as the turn's
segments are committed and flipping to a newer turn when one starts producing.
Also ensures the header's elapsed ticker runs if the session is live.
Announces the state change, since the only other feedback is the header's `⤓'
marker."
  (let ((turns (dsh-bridge--view-turns-refresh t)))
    ;; Explicitly entering follow shows whatever is newest; a leftover waiting
    ;; state must not gate it.
    (setq-local dsh-bridge--view-waiting nil)
    (setq-local dsh-bridge--view-follow t)
    (setq-local dsh-bridge--view-turn-index nil)
    (when turns
      (dsh-bridge--view-fill dsh-bridge--view-content-session (car turns) nil nil t))
    (setq header-line-format (dsh-bridge--view-header-line))
    (dsh-bridge--view-ticker-ensure)
    (message "dsh-bridge: following the newest turn")))

(defun dsh-bridge--view-open (session-alist &optional same-window)
  "Pop to a DSH-View buffer showing the session described by SESSION-ALIST.
SESSION-ALIST is the body of a successful \"GET /dsh-bridge/turns\"
response, and has a different format from the session alists stored in
`dsh-bridge--sessions-cache':

- `sessionId' (string, required): the session the response describes.
- `turns' (list, optional): the turn records, newest first, each having
  the form of an alist.
- `epoch' (number, optional): a ms timestamp.
- `running' (boolean, optional): whether the agent is mid-turn.  Its
  presence (not truthiness) seeds the status tracker.
- `title' (string, optional) and `cwd' (string, optional): display title
  and workspace directory (used for our display cache).

This function reuses a live DSH-View buffer already showing the session,
else a `*dsh-bridge-output*' buffer.  If SAME-WINDOW is non-nil, prefer
to pop to the buffer using the same window.  Return the buffer."
  (let ((id (alist-get 'sessionId session-alist)))
	(unless id
	  (error "dsh-bridge: /turns response has no sessionId"))
	(let* ((running-pair (assoc 'running session-alist))
		   (running (eq (cdr-safe running-pair) t))
		   (turns-pair (assoc 'turns session-alist))
		   (turns (cdr-safe turns-pair))
		   (follow (or (and turns
							(dsh-bridge--view-turn-open-p (car-safe turns)))
					   running))
		   (cwd (alist-get 'cwd session-alist))
		   (buffer (or (dsh-bridge--session-view id)
					   (get-buffer-create "*dsh-bridge-output*"))))
	  ;; Seed the status tracker when the field is present.
	  ;; JSON `false' decodes to nil, so compare value against t.
	  (when running-pair
		(dsh-bridge--status-set id (if running 'running 'idle)))
	  ;; Cache the whole turns array: an explicit empty list is a
	  ;; known-empty entry that replaces a stale one.
	  (when turns-pair
		(dsh-bridge--turns-cache-store id turns
									   (alist-get 'epoch session-alist)))
	  (with-current-buffer buffer
		(dsh-bridge--view-fill id (car-safe turns) nil cwd t)
		(when follow
		  (setq-local dsh-bridge--view-follow t))
		;; Re-set header after the follow flag so `⤓' marker is right.
		(setq header-line-format (dsh-bridge--view-header-line))
		(dsh-bridge--view-ticker-ensure)
		(setq-local dsh-bridge--view-waiting nil))
	  (funcall (if same-window
				   #'pop-to-buffer-same-window
				 #'pop-to-buffer)
			   buffer)
	  buffer)))

(defun dsh-bridge--view-follow-refill (session-id)
  "Refill every DSH-View buffer following SESSION-ID with its newest turn.
Called (deferred, right after `dsh-bridge--view-turns-cache-refresh') when a
`replies-changed' notification event arrives over the notification connection;
a no-op when no view showing SESSION-ID is turn-following.  Reads the caller's
single cache refresh — no further request — and refills each following view
from the newest cached turn record.  The fill is append-style (preserving
point when the shown turn merely grew a segment); when a newer turn has
started, the view flips to it.  A view in the waiting state (a prompt was
just sent, `dsh-bridge--view-waiting') accepts only content from a turn newer
than the abandoned one; anything else keeps the `(running...)' placeholder.
The refill passes no CWD, so `dsh-bridge--apply-session-directory' falls back
to the sessions cache (the old `/output'-based fill supplied the cwd from the
response)."
  (when (seq-find (lambda (buf)
                    (with-current-buffer buf
                      (bound-and-true-p dsh-bridge--view-follow)))
                  (dsh-bridge--session-views session-id))
    (let* ((turns (dsh-bridge--turns-cache-turns session-id))
           (newest (car-safe turns)))
      (when newest
        (dolist (buf (dsh-bridge--session-views session-id))
          (with-current-buffer buf
            (when (and dsh-bridge--view-follow
                       (not (and dsh-bridge--view-waiting
                                 (not (dsh-bridge--view-waiting-accept-p
                                       (alist-get 'turn newest))))))
              (dsh-bridge--view-fill session-id newest nil nil t t)
              (setq-local dsh-bridge--view-waiting nil))))))))

(defun dsh-bridge--turns-changed (session-id)
  "Handle one `replies-changed' frame for SESSION-ID, deferred.
Refresh the session's turn list once (keeping `(k/n)' counts and any
mid-browse index recomputations honest), then refill every turn-following
view from that cache — a frame costs one `/turns' round-trip regardless of
how many views follow the session (coarse-grained progress tracking,
not token streaming)."
  (dsh-bridge--view-turns-cache-refresh session-id)
  (dsh-bridge--view-follow-refill session-id))

(defun dsh-bridge--view-ticker-maybe-cancel ()
  "Cancel the view header elapsed ticker, if running."
  (when (timerp dsh-bridge--view-ticker-timer)
	(cancel-timer dsh-bridge--view-ticker-timer)
	(setq dsh-bridge--view-ticker-timer nil)))

(defun dsh-bridge--view-ticking-buffers ()
  "Live DSH-View buffers showing a running session in a visible window."
  (seq-filter (lambda (buf)
				(and (get-buffer-window buf 'visible)
					 (with-current-buffer buf
					   (and dsh-bridge--view-content-session
							(eq (dsh-bridge--status-state
								 dsh-bridge--view-content-session)
								'running)))))
			  (dsh-bridge--view-buffers)))

(defun dsh-bridge--view-ticker-ensure ()
  "Start (or retain) the DSH-View header elapsed ticker, as needed.
A single repeating timer shared by all DSH-View buffers; it runs only while
some view shows a running session in a visible window, and cancels itself
otherwise — so it provably never runs for a session no one is looking at."
  (if (or (not dsh-bridge-view-elapsed-ticker)
		  (null (dsh-bridge--view-ticking-buffers)))
	  (dsh-bridge--view-ticker-maybe-cancel)
	(unless dsh-bridge--view-ticker-timer
	  (setq dsh-bridge--view-ticker-timer
			(run-at-time 1 nil #'dsh-bridge--view-ticker-tick)))))

(defun dsh-bridge--view-ticker-tick ()
  "Ticker body: repaint each ticking view's header, or cancel the timer."
  (setq dsh-bridge--view-ticker-timer nil)
  (let ((bufs (and dsh-bridge-view-elapsed-ticker
                   (dsh-bridge--view-ticking-buffers))))
    (if (null bufs)
        (dsh-bridge--view-ticker-maybe-cancel)
      (dolist (buf bufs)
        (with-current-buffer buf
          (setq header-line-format (dsh-bridge--view-header-line))))
      (setq dsh-bridge--view-ticker-timer
            (run-at-time 1 nil #'dsh-bridge--view-ticker-tick)))))

(defun dsh-bridge--view-ticker-ensure-later ()
  "Re-evaluate the shared view ticker after the current buffer is killed.
Installed on each view buffer's local `kill-buffer-hook' by
`dsh-bridge--view-fill'.  The dying buffer is still live while the hook
runs, so an immediate `dsh-bridge--view-ticker-ensure' would keep (or
cancel) the timer on the dying buffer's account alone; deferring one
event-loop turn lets the scan see only the surviving views, so killing
one view never freezes another view's elapsed clock — and killing the
last ticking view still cancels the timer."
  (run-at-time 0 nil #'dsh-bridge--view-ticker-ensure))

(defun dsh-bridge--view-header-line ()
  "Return the header line for a DSH-View buffer.
Header line format:

 <status> <session-pos> <label> · HH:MM:SS[ · <ctx%>][ ⏱ MM:SS][ ⤓]

The session-pos segment is the position in the session's turn history (see
`dsh-bridge--view-turn-position'); the context % is the live context occupancy
(see `dsh-bridge--prompt-context-label'); the elapsed segment and the
turn-following marker appear while the shown session runs."
  (let* ((id dsh-bridge--view-content-session)
		 (status (dsh-bridge--status-glyph id))
		 (pos (dsh-bridge--view-turn-position))
		 (label (dsh-bridge--session-link (dsh-bridge--session-label id) id))
		 (context (and id (dsh-bridge--prompt-context-label id)))
		 (elapsed (and id (dsh-bridge--view-elapsed-label id)))
		 (await (and id (dsh-bridge--session-awaiting-p id) " · awaiting your answer"))
		 (time (if dsh-bridge--view-received-at
				   (format-time-string
					"%H:%M:%S" (/ dsh-bridge--view-received-at 1000))
				 (or dsh-bridge--view-timestamp "")))
		 (follow (if dsh-bridge--view-follow " ⤓" "")))
	(string-replace "%" "%%"
					(concat " " status " " pos " " label " · " time
							(and context (concat " · " context))
							await elapsed follow))))

(defmacro dsh-bridge--define-view-mode (parent)
  "Define `dsh-bridge-view-mode' as a variant of PARENT.
PARENT is `gfm-view-mode' (GFM rendering when markdown-mode is installed) or
`special-mode' (the fallback when it is absent).  A conditional expression
cannot go directly in the parent slot of `define-derived-mode' — the macro
quotes it into the mode metadata and the docstring generation calls
`symbol-name' on it — so the choice is resolved here, driven by
`dsh-bridge-view-gfm' and `(require \='markdown-mode nil t)'."
  `(define-derived-mode dsh-bridge-view-mode ,parent "DSH-View"
	 "Major mode for DSH-View buffers.
Read-only.  Keys: `g' refresh (re-fetch the shown session's newest turn),
`r' reply (bind the prompt buffer to the shown session, without changing the
default target), `w' copy, `B' branch the shown turn into a new session
(the child inherits the preset but starts on the default model), `i' receive
(pull the latest \"Send to Emacs\"
message), `l' list sessions, `q' dismiss.  `M-p'/`M-n' cycle the shown
session's agent turns (older / newer; a turn is the whole run from a prompt
to an idle reply, and the header shows the position `k/n' over the session's
turns).	 `g' is the view buffer's fetch: `f' elsewhere fetches the
session's latest turn into this buffer, so inside it the two coincide.

When markdown-mode is installed and `dsh-bridge-view-gfm' is non-nil, the mode
derives from `gfm-view-mode', so replies are font-locked as GitHub-Flavored
Markdown with native code-block highlighting and markdown's own navigation keys
are inherited.  Otherwise it derives from `special-mode' and no GFM font-locking
is applied."
	 (setq buffer-read-only t)))

;; The mode map is created by whichever branch of the `if' runs; declare it here
;; so the byte-compiler knows the `define-key' forms below are valid.
(defvar dsh-bridge-view-mode-map)

;; The mode and its `gfm-view-mode' parent are chosen at load time, so the
;; byte-compiler cannot see them through the conditional macro expansion;
;; declare them (mirroring the prompt mode) to keep the compile clean.
(declare-function dsh-bridge-view-mode "dsh-bridge")
(declare-function gfm-view-mode "markdown-mode")

(if (and dsh-bridge-view-gfm (require 'markdown-mode nil t))
	(dsh-bridge--define-view-mode gfm-view-mode)
  (dsh-bridge--define-view-mode special-mode))

(define-key dsh-bridge-view-mode-map (kbd "g") #'revert-buffer)
(define-key dsh-bridge-view-mode-map (kbd "q") #'quit-window)
(define-key dsh-bridge-view-mode-map (kbd "r") #'dsh-bridge-reply)
(define-key dsh-bridge-view-mode-map (kbd "w") #'dsh-bridge-copy-reply)
(define-key dsh-bridge-view-mode-map (kbd "i") #'dsh-bridge-receive)
(define-key dsh-bridge-view-mode-map (kbd "a") #'dsh-bridge-answer)
(define-key dsh-bridge-view-mode-map (kbd "B") #'dsh-bridge-fork-turn)
(define-key dsh-bridge-view-mode-map (kbd "D") #'dsh-bridge-describe-session)
(define-key dsh-bridge-view-mode-map (kbd "l") #'dsh-bridge-list-sessions)
(define-key dsh-bridge-view-mode-map (kbd "M-p")
			#'dsh-bridge-view-previous-reply)
(define-key dsh-bridge-view-mode-map (kbd "M-n")
			#'dsh-bridge-view-next-reply)

(easy-menu-define dsh-bridge-view-menu dsh-bridge-view-mode-map
  "Menu bar menu for DSH-View buffers."
  '("DSH Bridge"
	["Reply" dsh-bridge-reply
	 :help "Bind the prompt buffer to the shown session"]
	["Copy" dsh-bridge-copy-reply
	 :help "Copy the reply (region, else the whole shown turn)"]
	["Branch Turn" dsh-bridge-fork-turn
	 :help "Branch the shown turn into a new session"]
	["Receive Message…" dsh-bridge-receive
	 :help "Receive the latest message DSH sent to Emacs"]
	["Describe Session" dsh-bridge-describe-session
	 :help "Show the session's read-only report"]
	"---"
	["List Sessions" dsh-bridge-list-sessions
	 :help "Browse DSH sessions"]
	"---"
	["Refresh" revert-buffer
	 :help "Re-fetch the shown session's newest turn"]
	["Quit Window" quit-window
	 :help "Dismiss this buffer"]))

(defun dsh-bridge--revert-output (&rest _)
  "Re-fetch the newest turn into the current DSH-View buffer."
  (dsh-bridge-fetch))

;;; DSH-View history navigation (M-p/M-n)

;; M-p/M-n walk the session's *turns*: each turn is the whole run from a
;; prompt to an idle reply, rendered as one buffer with its segments separated
;; by divider lines.  A turn record carries a stable number, so navigation
;; never disambiguates by text equality (identical one-line segments used to
;; be ambiguous to the old reply-index lookup).

(defun dsh-bridge--turns-cache-entry (session-id)
  "The cached entry value for SESSION-ID — (EPOCH . TURNS) — or nil.
A nil return means the session has no entry (never fetched).  An entry whose
TURNS is nil is a *known-empty* snapshot (see `dsh-bridge--turns-cache')."
  (and session-id
       (cdr (assoc session-id dsh-bridge--turns-cache))))

(defun dsh-bridge--turns-cache-turns (session-id)
  "SESSION-ID's cached turn list (newest first), or nil.
A nil return covers both a session with no entry and a known-empty entry;
distinguish via `dsh-bridge--turns-cache-entry'."
  (let ((entry (dsh-bridge--turns-cache-entry session-id)))
    (and entry (cdr entry))))

(defun dsh-bridge--turns-cache-epoch (session-id)
  "SESSION-ID's cached history epoch, or nil when no entry exists."
  (car (dsh-bridge--turns-cache-entry session-id)))

(defun dsh-bridge--turns-cache-store (session-id turns epoch)
  "Replace SESSION-ID's cache entry with TURNS (newest first) at EPOCH.
The single writer for both halves of an entry — the turn list and the epoch
always travel together, so nothing can observe an epoch without its list (or
vice versa).  EPOCH may be nil for a response that carried no `epoch' field;
such an entry can never serve an incremental request (see
`dsh-bridge--turns-cache-fetch')."
  (when session-id
    (setq dsh-bridge--turns-cache
          (assoc-delete-all session-id dsh-bridge--turns-cache))
    (push (cons session-id (cons epoch turns)) dsh-bridge--turns-cache)))

(defun dsh-bridge--turns-query-path (session-id &optional since epoch)
  "The `/turns' request path for SESSION-ID, with optional SINCE/EPOCH params.
SINCE and EPOCH are numbers; absent ones are omitted."
  (concat (dsh-bridge--path "/turns" session-id)
          (and (numberp since) (format "&since=%d" since))
          (and (numberp epoch) (format "&epoch=%d" epoch))))

(defun dsh-bridge--turns-cache-merge (session-id cached since response epoch)
  "Merge an incremental `/turns' RESPONSE into SESSION-ID's CACHED list.
RESPONSE (newest first) holds every visible turn with `turn >= SINCE' —
inclusive, because the boundary turn is exactly the one that changes mid-turn
(segments append to it, a `turn/end' sets its end facts), so it is resent in
full.  Cached turns with `turn >= SINCE' (normally just the head, since SINCE
names the newest cached turn) are dropped, the response is prepended, and the
entry is stored at EPOCH.  Storing through `dsh-bridge--turns-cache-store'
keeps the merge and the epoch atomic."
  (dsh-bridge--turns-cache-store
   session-id
   (append response
           (seq-drop-while (lambda (record)
                             (>= (or (alist-get 'turn record) 0) since))
                           cached))
   epoch))

(defun dsh-bridge--turns-cache-fetch (session-id)
  "Fetch SESSION-ID's turn list into `dsh-bridge--turns-cache'.
Performs the `GET /dsh-bridge/turns' round-trip, requesting only the
incremental suffix (`since` = the newest cached turn number, plus the stored
`epoch`) when the session already has an entry with a numeric epoch and at
least one cached turn.  When
the response's `incremental' field is true the suffix is merged into the
cached list (`dsh-bridge--turns-cache-merge'); any other response replaces
the entry wholesale.  Field presence, not truthiness: an explicit empty
`turns' list means the session genuinely has no turns (e.g. after a full
compaction) and replaces the stale cache with a known-empty entry, while a
response without the field (an error or malformed body) leaves the cache
alone.  Returns a `(turns . FINAL-LIST)' cons — non-nil even when FINAL-LIST
is empty — of the list the cache holds after the fetch, or nil when
SESSION-ID is nil or the response has no `turns' field.  The cache is shared
by every DSH-View buffer, so one fetch serves them all — multi-view refills
call this once and skip the per-view refresh in `dsh-bridge--view-fill'."
  (when session-id
    (let* ((cached (dsh-bridge--turns-cache-entry session-id))
           (cached-turns (and cached (cdr cached)))
           (cached-epoch (and cached (car cached)))
           (newest (car-safe cached-turns))
           (since (and newest (alist-get 'turn newest)))
           (result (dsh-bridge--request
                    "GET"
                    (dsh-bridge--turns-query-path
                     session-id
                     ;; Incremental needs both params: `since' without a
                     ;; numeric `epoch' — or `epoch' without a `since' (a
                     ;; known-empty entry has no newest turn to anchor it) —
                     ;; could never be served incrementally, so send neither
                     ;; rather than imply it.
                     (and (numberp since) (numberp cached-epoch) since)
                     (and (numberp since) (numberp cached-epoch) cached-epoch))
                    nil))
           (alist (cdr result))
           (turns-pair (and alist (assoc 'turns alist))))
      (when turns-pair
        (let ((turns (cdr turns-pair))
              ;; An epoch-less response must not downgrade a numeric epoch.
              (epoch (or (alist-get 'epoch alist) cached-epoch)))
          (if (and (eq (alist-get 'incremental alist) t)
                   cached-turns
                   (numberp since)
                   ;; The incremental response must end at the `since' turn;
                   ;; anything else is a stale-since corner (an entry evicted
                   ;; and refilled by another path): replace fully instead.
                   (equal since (alist-get 'turn (car (last turns)))))
              (dsh-bridge--turns-cache-merge session-id cached-turns
                                             since turns epoch)
            (dsh-bridge--turns-cache-store session-id turns epoch))))
      ;; A pair of the list the cache now holds (post-merge or post-replace),
      ;; or nil when the response carried no `turns' field (cache untouched).
      (and turns-pair
           (cons 'turns (dsh-bridge--turns-cache-turns session-id))))))

(defun dsh-bridge--view-turns-refresh (&optional force)
  "Return the cached turn list (newest first) for the current view's session.
Fetches `GET /dsh-bridge/turns' (via `dsh-bridge--turns-cache-fetch') when
FORCE is non-nil or the session has no cache entry.  FORCE keeps the position
count current after a fill or a turn-complete refetch; a known-empty entry is
authoritative until such a forced refresh."
  (let ((session dsh-bridge--view-content-session))
    (when (and session
               (or force
                   (null (dsh-bridge--turns-cache-entry session))))
      (dsh-bridge--turns-cache-fetch session))
    (and session
         (dsh-bridge--turns-cache-turns session))))

(defun dsh-bridge--view-turns-cache-refresh (session-id)
  "Force-refresh the cached turn list for the DSH bridge's SESSION-ID.
This function fetches the turns for SESSION-ID (via
`dsh-bridge--turns-cache-fetch', which merges an incremental response into
the cached list or replaces the entry on a full one).

For any DSH-View buffer showing SESSION-ID, recompute a mid-browse
`dsh-bridge--view-turn-index' from the shown turn's number: the index
becomes the shown turn's position in the refreshed list, so the `(k/n)'
counter stays honest however the list changed (new turns at the head, or
a compaction that dropped turns mid-list).  When the shown turn vanished
from the list — replaced by a compaction, or the list came back empty —
the index is dropped: the view returns to \"at rest\", still showing its
content, and the next `M-p'/`M-n' re-enters navigation from the refreshed
list.  (Clamping the old index into the shorter list was rejected: it
would point at an unrelated turn.)  Then re-render the header.  No buffer
text is touched, so a mid-browse view is never clobbered.  Returns the
fresh list or nil; a session that is neither shown nor cached is left
alone."
  (when (or (dsh-bridge--session-view session-id)
            (assoc session-id dsh-bridge--turns-cache))
    (let ((pair (dsh-bridge--turns-cache-fetch session-id)))
      (when pair
        (let ((turns (cdr pair)))
          (dolist (buf (dsh-bridge--session-views session-id))
            (with-current-buffer buf
              (when dsh-bridge--view-turn-index
                (setq dsh-bridge--view-turn-index
                      (and dsh-bridge--view-turn
                           (dsh-bridge--view-turn-index-of
                            turns dsh-bridge--view-turn))))
              (setq header-line-format (dsh-bridge--view-header-line))))
          (dsh-bridge--view-ticker-ensure)
          turns)))))

(defun dsh-bridge--view-show-turn (index turns)
  "Display turn list INDEX (newest first) in the current DSH-View buffer.
Manual navigation always leaves turn-following state, and ends any waiting
state (`dsh-bridge--view-waiting')."
  (dsh-bridge--view-fill dsh-bridge--view-content-session (nth index turns)
						 nil nil t)
  (setq-local dsh-bridge--view-turn-index index)
  (setq-local dsh-bridge--view-follow nil)
  (setq-local dsh-bridge--view-waiting nil)
  (setq header-line-format (dsh-bridge--view-header-line))
  (dsh-bridge--view-ticker-ensure))

(defun dsh-bridge-view-previous-reply ()
  "Show the previous (older) turn of the shown session.
`M-p' walks the session's turns — each turn is the whole run from a prompt to
an idle reply, shown with every segment it committed.  Entering navigation
from rest force-refreshes the session's turn list, so the step and the
`(k/n)' count are current; subsequent steps reuse the cache.  Also leaves
turn-following state."
  (interactive)
  (setq-local dsh-bridge--view-follow nil)
  (let ((turns (dsh-bridge--view-turns-refresh
				(null dsh-bridge--view-turn-index))))
	(if (null turns)
		(message "dsh-bridge: no turns in this session")
	  (let* ((index (or dsh-bridge--view-turn-index
						(dsh-bridge--view-turn-index-of
						 turns dsh-bridge--view-turn)))
			 ;; Content with no turn identity (a pushed message) counts as the
			 ;; newest position: the first M-p steps one older.
			 (next (1+ (or index 0))))
		(if (>= next (length turns))
			(message "dsh-bridge: at the oldest turn")
		  (dsh-bridge--view-show-turn next turns))))))

(defun dsh-bridge-view-next-reply ()
  "In a DSH-View buffer, show the next (newer) turn of the current session."
  (interactive)
  (if dsh-bridge--view-follow
	  (message "dsh-bridge: already following the newest turn")
	(let* ((k dsh-bridge--view-turn-index)
		   (refetch-turn (and (null k) dsh-bridge--view-turn))
		   turns)
	  ;; If the view is at rest, try `dsh-bridge--view-turn' with a
	  ;; refreshed list.
	  (and refetch-turn
		   (setq turns (dsh-bridge--view-turns-refresh t))
		   (setq k (dsh-bridge--view-turn-index-of turns
												   dsh-bridge--view-turn)))
	  (cond
	   ((null k)
		(message "dsh-bridge: no newer turns"))
	   ((or (zerop k)
			(and (= k 1) dsh-bridge-view-follow-at-newest))
		(dsh-bridge--view-follow-enter))
	   (t
		(unless refetch-turn
		  (setq turns (dsh-bridge--view-turns-refresh)))
		(when turns
		  (dsh-bridge--view-show-turn (1- k) turns)))))))

;;; Verbs

;;;###autoload
(defun dsh-bridge-send (&optional session-id)
  "Send the region, or the whole buffer, to the DSH session as a prompt.
The session is the effective session of the current buffer; with a
prefix argument, choose a session for this call only."
  (interactive (list (dsh-bridge--read-session-override "Send to session: ")))
  (dsh-bridge-send-text (dsh-bridge--region-or-buffer) session-id))

;;;###autoload
(defun dsh-bridge-send-and-exit ()
  "Send a DSH-Prompt buffer as a prompt, then bury it and switch away.
This command must be called in a DSH-Prompt buffer.  Unlike
`dsh-bridge-send', it always sends the entire buffer contents.

If `dsh-bridge-prompt-resend-confirm' is non-nil and the text exactly
matches the session's last-sent text, confirm first.

After a successful send, pop to a DSH-View buffer following the session
and bury the buffer (see `dsh-bridge--prompt-exit')."
  (interactive)
  (unless (eq major-mode 'dsh-bridge-prompt-mode)
	(user-error "dsh-bridge: not a DSH-Prompt buffer"))
  (let ((text (substring-no-properties (buffer-string)))
		;; The buffer's binding, else the advisory id the send resolves to.
		(guard-session (dsh-bridge--prompt-status-session)))
	(if (string-empty-p text)
		(user-error "dsh-bridge: no text to send")
	  ;; Guard against an identical re-send to the session.
	  (when (and dsh-bridge-prompt-resend-confirm
				 (equal text (car-safe
							  (cdr-safe
							   (assoc guard-session dsh-bridge--last-sent))))
				 (not (y-or-n-p
					   (format "Resend same prompt to session \"%s\"? "
							   (dsh-bridge--session-label guard-session)))))
		(user-error "dsh-bridge: aborted"))
	  ;; Capture the invoking window for `dsh-bridge--prompt-exit'.
	  (let ((window (selected-window)))
		(dsh-bridge-send-text text
							  dsh-bridge--prompt-session
							  (lambda (sent-id)
								(dsh-bridge--prompt-exit sent-id window)))))))

(defun dsh-bridge--prompt-blank ()
  "Erase the DSH-prompt buffer and reset its navigation state.
Used to prepare the DSH-prompt buffer for a fresh prompt composition."
  (when (eq major-mode 'dsh-bridge-prompt-mode)
	(let ((inhibit-read-only t))
	  (erase-buffer))
	(setq-local dsh-bridge--prompt-history-index nil)
	(setq-local dsh-bridge--prompt-draft nil)
	(set-buffer-modified-p nil)))

(defun dsh-bridge--after-prompt-view (session-id)
  "Return a DSH-View buffer for SESSION-ID after a prompt.
This sets up a DSH-VIEW buffer for the session in following state,
initializing its header line and other necessary variables."
  ;; Fetch the session's turn list and record the epoch (for later
  ;; incremental fetches, and to know if a turn is already running).
  (let* ((path (dsh-bridge--path "/turns" session-id))
		 (result (dsh-bridge--request "GET" path nil))
		 (alist (cdr-safe result))
		 (turns-pair (assoc 'turns alist))
		 (turns (cdr-safe turns-pair)))
	(when turns-pair
	  (dsh-bridge--turns-cache-store session-id turns
									 (alist-get 'epoch alist)))
	(let* ((buf (or (dsh-bridge--session-view session-id)
					(get-buffer-create "*dsh-bridge-output*")))
		   (newest (car-safe turns)))
	  (with-current-buffer buf
		(if (and newest (dsh-bridge--view-turn-open-p newest))
			;; If a turn was already running, show it as usual.
			(progn
			  (dsh-bridge--view-fill session-id newest nil
									 (alist-get 'cwd alist) t)
			  (setq-local dsh-bridge--view-waiting nil))
		  ;; Otherwise, populate with a "running..." message.
		  (dsh-bridge--view-waiting-fill
		   session-id (and newest (alist-get 'turn newest))
		   (alist-get 'cwd alist)))
		(setq-local dsh-bridge--view-follow t)
		(setq header-line-format (dsh-bridge--view-header-line))
		(dsh-bridge--view-ticker-ensure))
	  buf)))

(defun dsh-bridge--prompt-exit (sent-session-id &optional window)
  "Clean up after a successful `dsh-bridge-send-and-exit'.
Called from `dsh-bridge-send-and-exit' after the prompt has been
successfully sent to the DSH bridge, with SENT-SESSION-ID as the
host-reported session id to which the prompt was delivered.

Bury the DSH-Prompt buffer, keeping its contents (the sent text also
stays in the prompt history; the next composition erases it, asking
first only if it was edited further).

If SENT-SESSION-ID is non-nil, pop to a DSH-View buffer showing that
session in turn-following state.  WINDOW, if non-nil, is the window the
send was invoked from; if still showing the prompt buffer, it is called
with `quit-window' to dismiss the prompt."
  (when (eq major-mode 'dsh-bridge-prompt-mode)
	(set-buffer-modified-p nil)
	(if (null sent-session-id)
		(bury-buffer)
	  (let ((buf (dsh-bridge--after-prompt-view sent-session-id))
			(prompt-window (or (and (window-live-p window)
									(eq (window-buffer window) (current-buffer))
									window)
							   (get-buffer-window (current-buffer)))))
		;; We want to dismiss the prompt buffer/window and show the
		;; view buffer, WITHOUT showing the view buffer in two
		;; separate windows or keeping the prompt buffer on-screen.
		(when prompt-window (quit-window nil prompt-window))
		(pop-to-buffer buf)))))

;;;###autoload
(defun dsh-bridge-draft (&optional session-id)
  "Send the region, or the whole buffer, to the DSH composer as a draft.
Like `dsh-bridge-send', but nothing is submitted; the text lands in the
composer for review.  With a prefix argument, choose a session for this call
only.  Whole-buffer drafts confirm exactly like whole-buffer sends."
  (interactive (list (dsh-bridge--read-session-override "Draft to session: ")))
  (let ((whole (not (use-region-p))))
	(when (and whole buffer-read-only)
	  (user-error "dsh-bridge: buffer is read-only and no region is active"))
	(when (and whole
			   (not (eq major-mode 'dsh-bridge-prompt-mode))
			   (not (y-or-n-p
					 (format "Send the whole %s buffer to DSH as a draft? "
							 (buffer-name)))))
	  (user-error "dsh-bridge: aborted"))
	(dsh-bridge-send-draft (dsh-bridge--region-or-buffer) session-id)))

;;;###autoload
(defun dsh-bridge-fetch (&optional session-id same-window)
  "Fetch the latest DSH turn and show it in a DSH-View buffer.
The session is the effective session of the current buffer; with a
prefix argument, fetch from a chosen session for this call only.
If SAME-WINDOW is non-nil, prefer to show the buffer in the same window."
  (interactive (list (dsh-bridge--read-session-override "Fetch from session: ")))
  (let ((target (or session-id (dsh-bridge--effective-session))))
	(dsh-bridge--call "GET" (dsh-bridge--path "/turns" target) nil
      (lambda (status body http-status)
		(let* ((alist (dsh-bridge--parse-json-body body))
			   (err (dsh-bridge--error-message status http-status alist)))
		  (cond
		   (err
			(message "dsh-bridge: %s" err))
		   ((null alist)
			(message "dsh-bridge: unreadable response: %s" body))
		   (t
			;; A nil target is resolved by the host: record it for display.
			(unless target
			  (dsh-bridge--record-last-resolved alist))
			(dsh-bridge--view-open alist same-window))))))))

;;;###autoload
(defun dsh-bridge-receive ()
  "Receive the latest \"Send to Emacs\" message into a DSH-View buffer.
Pulls the host's pending DSH→Emacs entries and displays the newest in a
DSH-View buffer, then acks every collected id.  Unless `dsh-bridge-receive-pop'
is nil, the buffer is selected (the push originates from the user clicking
the button in the DSH web UI, so the common flow is to want the message
visible on arrival).  When several messages were pending, only the latest is
shown and the message says so (the ack invariant weakens deliberately: the
alternative, a durable per-session store, is the deferred transcript buffer).
This is also the manual fallback if you want to fetch the pending message
yourself; the SSE listener calls it automatically unless
`dsh-bridge-notifications-stop' has been run."
  (interactive)
  (let* ((result (dsh-bridge--request "GET" "/outbox" nil))
		 (status (car result))
		 (alist (cdr result)))
	(cond
	 ((null status)
	  (message "dsh-bridge: request failed (is `dsh web' running?)"))
	 ((>= status 400)
	  (message "dsh-bridge: %s"
			   (or (alist-get 'error alist) (format "HTTP %s" status))))
	 (t
	  (let ((entries (alist-get 'entries alist)))
		(if (null entries)
			(message "dsh-bridge: nothing to receive")
		  (let ((buf (dsh-bridge--display-received entries)))
			;; Ack all collected ids, shown or not.
			(dsh-bridge--request "POST" "/outbox/ack"
								 `((ids . ,(mapcar (lambda (e) (alist-get 'id e))
												   entries))))
			(when dsh-bridge-receive-pop
			  (pop-to-buffer buf))
			(if (= (length entries) 1)
				(message "dsh-bridge: DSH sent a message to %s" (buffer-name buf))
			  (message "dsh-bridge: %d messages received from DSH"
					   (length entries))))))))))

(defun dsh-bridge--view-strip-running-marker (string)
  "STRING without a trailing running-turn marker, if one is present.
The marker is identified by its `dsh-bridge-turn-marker' text property, so
model text that happens to read \"(continuing...)\" is never stripped."
  (let ((start (text-property-any 0 (length string)
                                 'dsh-bridge-turn-marker t string)))
    (if start (substring string 0 start) string)))

(defun dsh-bridge--view-fill (session-id turn received-at &optional cwd no-turns-refresh preserve-point)
  "Fill the current buffer with TURN as the shown content of SESSION-ID.
The current buffer, which the caller is responsible for selecting and/or
creating, is put into `dsh-bridge-view-mode' if it is not already.  This
function does not perform any window-management.

TURN is either a turn record (see `dsh-bridge--turns-cache'), a raw text
string (a pushed message with no turn identity), or nil (empty content).

RECEIVED-AT is the ms-epoch send time for a pushed message, or nil.

CWD is the session's current working directory.

NO-TURNS-REFRESH, if non-nil, means not to refresh the session's turn
list (if omitted or default, a record fill refreshes this so the `(k/n)'
position count remains up-to-date).

If PRESERVE-POINT, point survives when the new content merely extends
the old.

The DSH-View buffer's turn-following state is preserved when refilling
the same session, and dropped when the shown session changes."
  (unless (eq major-mode 'dsh-bridge-view-mode)
    (dsh-bridge-view-mode))
  (add-hook 'kill-buffer-hook #'dsh-bridge--view-ticker-ensure-later nil t)
  (setq-local revert-buffer-function #'dsh-bridge--revert-output)
  (let ((old dsh-bridge--view-content-session))
    (setq-local dsh-bridge--view-content-session session-id)
    (unless (equal session-id old)
      (setq-local dsh-bridge--view-follow nil)))
  (setq-local dsh-bridge--view-received-at received-at)
  (setq-local dsh-bridge--view-turn-index nil)
  (setq-local dsh-bridge--view-turn
			(and (not (stringp turn)) (alist-get 'turn turn)))
  (setq-local dsh-bridge--view-timestamp (format-time-string "%H:%M:%S"))
  (dsh-bridge--apply-session-directory session-id cwd (current-buffer))
  (when (and session-id (not no-turns-refresh) (not (stringp turn)))
    (dsh-bridge--view-turns-refresh t))
  (let* ((old-text (buffer-string))
         (old-point (point))
         ;; The old buffer may end with a terminal furniture line (marker,
         ;; awaiting note, or running placeholder); when the new content turns
         ;; that boundary into the next segment's `---', the old line is
         ;; replaced mid-string, so compare against the old content without it.
         (old-core (and preserve-point
                        (dsh-bridge--view-strip-running-marker old-text)))
         (new-text (if (stringp turn) turn
                     (dsh-bridge--view-turn-render turn session-id))))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert new-text)
      (if (and preserve-point (string-prefix-p old-core new-text))
          (goto-char (min old-point (1+ (length old-core))))
        (goto-char (point-min)))))
  (setq header-line-format (dsh-bridge--view-header-line))
  (dsh-bridge--view-ticker-ensure))

(defun dsh-bridge--display-received (entries)
  "Display the newest entry of ENTRIES (an oldest-first list).
Reuses a DSH-View buffer (one already showing the entry's session, else
a buffer named `*dsh-bridge-output*'), fills it, and returns the buffer.

The content session is the entry's `sessionId', falling back to the
current buffer's session when the host omitted it.  When neither is
known, the default buffer is used."
  (let* ((entry (car (last entries)))
		 (entry-id (alist-get 'sessionId entry))
		 (session-id (or entry-id (dsh-bridge--buffer-session)))
		 (text (or (alist-get 'text entry) ""))
		 (buf (if session-id (dsh-bridge--session-view session-id))))
	(unless buf
	  (setq buf (get-buffer-create "*dsh-bridge-output*")))
	(unless entry-id
	  (message "dsh-bridge: message received without a session id"))
	(with-current-buffer buf
	  (dsh-bridge--view-fill session-id text (alist-get 'ts entry))
	  ;; A pushed message supersedes any waiting placeholder.
	  (setq-local dsh-bridge--view-waiting nil))
	buf))

(defun dsh-bridge--view-await-refresh (session-id)
  "Re-render the terminal furniture of every DSH-View buffer showing SESSION-ID.
Called when SESSION-ID's ask-user question arrives or is resolved: for a view
showing an open turn the terminal marker flips between `(continuing...)' and
the awaiting note (`dsh-bridge--view-awaiting-note'), so the refill reuses the
cached turn record and preserves point; a view in the waiting state (a fresh
turn may ask before committing any text) swaps its running placeholder for the
note instead.  A no-op for sessions no view shows in either state."
  (dolist (buf (dsh-bridge--session-views session-id))
    (with-current-buffer buf
      (cond
       (dsh-bridge--view-waiting
        ;; No content yet: refresh the placeholder/note line in place.
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (dsh-bridge--view-waiting-content session-id))
          (goto-char (point-min)))
        (setq header-line-format (dsh-bridge--view-header-line)))
       (t
        (let* ((turns (dsh-bridge--turns-cache-turns session-id))
               (record (and dsh-bridge--view-turn
                            (seq-find (lambda (r)
                                        (equal (alist-get 'turn r)
                                               dsh-bridge--view-turn))
                                      turns))))
          (when (and record (dsh-bridge--view-turn-open-p record))
            (dsh-bridge--view-fill session-id record nil nil t t))))))))

;;; Ask-user questions (the DSH `ask_user_question` tool)

;; The ask-user path registers an in-process answerer on the host's
;; `user-questions/request` waterfall (ahead of the browser forwarder).
;; While an Emacs SSE client is connected the bridge offers the question
;; to Emacs and, when the web UI is also open, still hands the request
;; to the browser forwarder so its own Q&A panel appears: the two
;; presentations race, and whichever answers first settles the request.
;; A browser-side rejection (no answerer, no loaded session, or the
;; panel closed) never ends the race, so Emacs decides in that case.
;; With no Emacs client connected the request delegates to the web UI
;; untouched.  The browser plugin's own draft-push SSE connection is
;; marked and never counts as Emacs — it exists whenever the web UI is
;; open and never answers questions (it does consume the resolved frame
;; so it can dismiss the web panel after an Emacs answer).  No loopback
;; wire and no third-party contact is involved, and the Emacs answer
;; arrives over the bearer-authed `POST /dsh-bridge/answer` route.  A
;; late or duplicate answer gets a 404 `not-pending` (benign);
;; cancelling from Emacs fails the asking tool call.

(defcustom dsh-bridge-question-auto-pop nil
  "Whether an arriving ask-user question pops to its question buffer.
When nil (the default), an ask is announced in the echo area and via the `⏳
awaiting' status glyph; the user answers it with `a' (in the DSH-View or
DSH-Sessions buffer) or by opening the question buffer directly.  Enable to
auto-pop the question buffer on arrival (most users find that intrusive)."
  :type 'boolean
  :group 'dsh-bridge)

;; Question buffer state and lookup -----------------------------------------
;; (Defined before the registry maintenance below, which banners live buffers
;; via `dsh-bridge--question-mark-resolved'.)

;; The derived mode is defined later in this section; declare it here so the
;; byte-compiler knows `dsh-bridge--question-buffer' calls a real function.
(declare-function dsh-bridge-question-mode "dsh-bridge")

(defvar-local dsh-bridge--question-id nil
  "The question id (bridge-minted) this question buffer answers.")
(defvar-local dsh-bridge--question-session nil
  "The session id this question buffer asks about.")
(defvar-local dsh-bridge--question-questions nil
  "The parsed question list this buffer renders.")
(defvar-local dsh-bridge--question-selection nil
  "Alist of (QUESTION-ID . (SELECTED-LABEL ...)) for marked options.")
(defvar-local dsh-bridge--question-custom nil
  "Alist of (QUESTION-ID . CUSTOM-TEXT) for typed custom answers.")
(defvar-local dsh-bridge--question-skipped nil
  "List of QUESTION-IDs the user chose to skip (answered with no selection).")
(defvar-local dsh-bridge--question-dead nil
  "Non-nil once the question this buffer asks is resolved (answered/cancelled).")
(defvar-local dsh-bridge--question-sent nil
  "What this buffer itself did, as a message, once it POSTs an answer or decline.
Set before the POST leaves.  The host broadcasts `ask-user-resolved' when the
waterfall settles, and that frame can reach us before the POST's own response
callback runs; `dsh-bridge--ask-user-resolved' then banners this buffer with
what it did rather than with \"answered elsewhere\".")
(defvar-local dsh-bridge--question-banner nil
  "The resolution banner rendered at the top of the buffer, or nil while the
question is open.  Set with `dsh-bridge--question-dead' by
`dsh-bridge--question-mark-resolved' and re-emitted by
`dsh-bridge--question-render', which also drops the now-false \"waiting for
your answer\" header.")

(defun dsh-bridge--question-find-buffer (question-id)
  "The live question buffer answering QUESTION-ID, or nil."
  (seq-find (lambda (buffer)
			  (with-current-buffer buffer
				(and (eq major-mode 'dsh-bridge-question-mode)
					 (equal dsh-bridge--question-id question-id))))
			(buffer-list)))

(defun dsh-bridge--question-mark-resolved (question-id message &optional bury)
  "Mark QUESTION-ID's live buffer resolved, banner it with MESSAGE, and bury it.
MESSAGE says what happened in the user's terms; BURY (the local-submit and
local-decline paths) also removes the buffer from every window, matching how
sending from DSH-Prompt exits.  A buffer already marked resolved is left alone,
so the local settlement and the later SSE `ask-user-resolved' frame do not
banner twice.  The buffer is re-rendered so the banner replaces the now-false
\"waiting for your answer\" header rather than sitting above it."
  (let ((buffer (dsh-bridge--question-find-buffer question-id)))
	(when (and buffer
			   (with-current-buffer buffer (not dsh-bridge--question-dead)))
	  (with-current-buffer buffer
		(setq-local dsh-bridge--question-dead t)
		(setq-local dsh-bridge--question-banner
				  (or dsh-bridge--question-sent message))
		(dsh-bridge--question-render))
	  (when bury
		(bury-buffer buffer)))))

;; Registry maintenance ----------------------------------------------------

(defun dsh-bridge--ask-user-session-clear (session-id)
  "Drop every pending ask for SESSION-ID, bannering any live question buffers.
Defensive cleanup on `turn-complete': a turn that ended without a resolved
frame cannot still be waiting on the user."
  (dolist (pending (cdr (assoc session-id dsh-bridge--pending-questions)))
	(dsh-bridge--question-mark-resolved
	 (car pending) "This question is no longer pending."))
  (setq dsh-bridge--pending-questions
		(assoc-delete-all session-id dsh-bridge--pending-questions)))

(defun dsh-bridge--ask-user-arrive (session-id question-id questions)
  "Record a newly arrived ask-user question, announce it, and render its buffer.
A question-id already in the registry is a replay — the plugin re-announces
pending asks to every reconnecting SSE client — so it just refreshes the
stored copy, silently, without re-messaging or touching the question buffer."
  (let* ((entry (assoc session-id dsh-bridge--pending-questions))
		 (slot (and entry (assoc question-id (cdr entry)))))
	(if slot
		(setcdr slot questions)
	  (if entry
		  (setcdr entry (cons (cons question-id questions) (cdr entry)))
		(push (cons session-id (list (cons question-id questions)))
			  dsh-bridge--pending-questions))
	  (let* ((first (car questions))
			 (q (and (listp first) (alist-get 'question first))))
		(message "dsh-bridge: session \"%s\" asks: %s (press %s to answer)"
				 (dsh-bridge--session-label session-id)
				 (or (and (stringp q) (substring q 0 (min 60 (length q)))) "")
				 (dsh-bridge--view-answer-key)))
	  (dsh-bridge--status-event-render session-id)
	  ;; The DSH-View body must say the session is parked, not "(continuing...)".
	  (dsh-bridge--view-await-refresh session-id)
	  (let ((buffer (dsh-bridge--question-buffer session-id question-id questions)))
		(when dsh-bridge-question-auto-pop
		  (pop-to-buffer buffer))))))

(defun dsh-bridge--ask-user-resolved (session-id question-id outcome)
  "Retire a pending ask for SESSION-ID when it was ANSWERED or CANCELLED.
The banner repeats what this buffer did when this Emacs was the one answering:
the host's resolved frame races the answer POST's response, so \"answered
elsewhere\" is only right when the buffer has no local submit on record."
  (let ((entry (assoc session-id dsh-bridge--pending-questions)))
	(when entry
	  (setcdr entry (cl-delete question-id (cdr entry) :key #'car :test #'equal))
	  (when (null (cdr entry))
		(setq dsh-bridge--pending-questions
			  (assoc-delete-all session-id dsh-bridge--pending-questions)))))
  (dsh-bridge--status-event-render session-id)
  (dsh-bridge--view-await-refresh session-id)
  (let ((buffer (dsh-bridge--question-find-buffer question-id)))
	(dsh-bridge--question-mark-resolved
	 question-id
	 (or (and buffer (buffer-local-value 'dsh-bridge--question-sent buffer))
		 (if (equal outcome "cancelled")
			 "This question was cancelled."
		   "This question was answered elsewhere (not in this buffer).")))))

;; The question buffer -------------------------------------------------------

(defun dsh-bridge--question-buffer (session-id question-id questions)
  "Find or create the question buffer for QUESTION-ID and return it.
A live buffer already answering QUESTION-ID is returned untouched, so burying
with `q' and returning with `a' keeps any in-progress marks.  A name collision
(two sessions sharing a label, each with a pending ask) gets a fresh name."
  (let ((existing (dsh-bridge--question-find-buffer question-id)))
	(if (and existing
			 (with-current-buffer existing (not dsh-bridge--question-dead)))
		existing
	  (let* ((base (format "*dsh-bridge-question: %s*"
						   (dsh-bridge--session-label session-id)))
			 (name (if (and (get-buffer base)
							(with-current-buffer (get-buffer base)
							  (and (eq major-mode 'dsh-bridge-question-mode)
								   (not dsh-bridge--question-dead))))
					   (generate-new-buffer-name base)
					 base))
			 (buffer (get-buffer-create name)))
		(with-current-buffer buffer
		  (unless (eq major-mode 'dsh-bridge-question-mode)
			(dsh-bridge-question-mode))
		  (setq-local dsh-bridge--question-id question-id)
		  (setq-local dsh-bridge--question-session session-id)
		  (setq-local dsh-bridge--question-questions questions)
		  (setq-local dsh-bridge--question-selection nil)
		  (setq-local dsh-bridge--question-custom nil)
		  (setq-local dsh-bridge--question-skipped nil)
		  (setq-local dsh-bridge--question-dead nil)
		  (setq-local dsh-bridge--question-sent nil)
		  (setq-local dsh-bridge--question-banner nil)
		  (dsh-bridge--question-render))
		buffer))))

(defun dsh-bridge--question-render ()
  "Populate the current question buffer from its state variables.
The whole buffer is re-rendered from `dsh-bridge--question-questions' plus the
selection/custom/skipped state on every change, so markers can never drift.
Every line of a question's block carries its question id as a text property,
so point anywhere in the block identifies the question.  A resolved buffer
renders its resolution banner in place of the \"waiting for your answer\"
header."
  (let ((inhibit-read-only t))
	(erase-buffer)
	(if dsh-bridge--question-dead
		;; The session is no longer waiting; the resolution banner, if any,
		;; takes the header's place.
		(when dsh-bridge--question-banner
		  (insert (propertize dsh-bridge--question-banner 'face 'error) "\n"))
	  (insert (propertize
			   (format "Session \"%s\" is waiting for your answer\n"
					   (dsh-bridge--session-label dsh-bridge--question-session))
			   'face 'bold)))
	;; The buffer itself must say how to work it: the mode docstring is not
	;; visible, and the keys (RET selects, C-c C-c submits) are not guessable.
	(insert (substitute-command-keys
			 (concat
			  "Mark an option with \\[dsh-bridge--question-toggle-at-point] "
			  "or its number key.  To answer with free text, press "
			  "\\[dsh-bridge--question-toggle-at-point] on the `c' row "
			  "(or `c' anywhere in the question): the answer is read in the "
			  "minibuffer, and an empty entry clears it.  On a single-choice "
			  "question a custom answer replaces any marked option; on a "
			  "multi-choice one it accompanies them.\n"
			  "\\[dsh-bridge--question-skip] skips the question at point, "
			  "\\[dsh-bridge--question-next] moves between questions.\n"
			  "\\[dsh-bridge--question-submit] submits your answers, "
			  "\\[dsh-bridge--question-decline] declines (cancels the tool call).\n\n")))
	(let ((n 0)
		  (total (length dsh-bridge--question-questions)))
	  (dolist (question dsh-bridge--question-questions)
		(let* ((qid (alist-get 'id question))
			   (qtext (alist-get 'question question))
			   (header (alist-get 'header question))
			   (detail (alist-get 'detail question))
			   (opts (alist-get 'options question))
			   (selected (cdr (assoc qid dsh-bridge--question-selection)))
			   (custom (cdr (assoc qid dsh-bridge--question-custom)))
			   (skipped (member qid dsh-bridge--question-skipped))
			   (block-start (point)))
		  (when (> n 0) (insert "\n"))
		  (cl-incf n)
		  (insert (format "Question %d of %d%s\n\n" n total
						  (if skipped " — skipped" "")))
		  (when (and (stringp header) (not (string-empty-p header)))
			(insert (propertize (concat header "\n") 'face 'bold)))
		  (insert (format "%s\n" (or qtext "")))
		  ;; The reviewed artifact (a plan-review's plan markdown) must be
		  ;; visible: deciding on it blind is worse than not surfacing it.
		  (when (and (stringp detail) (not (string-empty-p detail)))
			(insert "\n" detail "\n"))
		  (insert "\n")
		  (let ((i 0))
			(dolist (opt opts)
			  (cl-incf i)
			  (let* ((label (or (alist-get 'label opt) ""))
					 (desc (alist-get 'description opt))
					 (start (point)))
				(insert (format "  [%s] %d. %s%s\n"
								(if (member label selected) "x" " ")
								i label
								(if (and (stringp desc) (not (string-empty-p desc)))
									(concat " — " desc) "")))
				(put-text-property start (1- (point)) 'dsh-bridge-option label))))
		  ;; The custom-answer row is always present (the web UI offers one per
		  ;; question).  It is drawn as an action, not a checkbox: a `[ ]'
		  ;; bracket here would read as "mark this to enable typing" even
		  ;; though RET/`c' simply opens a minibuffer prompt.  The trailing
		  ;; hint says where the text goes and how to change or clear it.
		  (let* ((has-custom (and custom (not (string-empty-p custom))))
				 (start (point)))
			(insert (format "      c. %s %s\n"
							(if has-custom
								(concat "Custom answer: " custom)
							  "Type a custom answer...")
							(if has-custom
								"(RET to edit; empty clears)"
							  "(RET here or `c')")))
			(put-text-property start (1- (point)) 'dsh-bridge-option-custom t))
		  (put-text-property block-start (point) 'dsh-bridge-question-id qid))))
	(goto-char (point-min))))

(defun dsh-bridge--question-at-point ()
  "The question id of the block at point, or nil."
  (or (get-text-property (point) 'dsh-bridge-question-id)
	  (get-text-property (line-beginning-position) 'dsh-bridge-question-id)))

(defun dsh-bridge--question-multi-p (qid)
  "Whether question QID is a multi-select."
  (seq-some (lambda (q) (and (equal (alist-get 'id q) qid)
							 (eq (alist-get 'multiSelect q) t)))
			dsh-bridge--question-questions))

(defun dsh-bridge--question-set-selection (qid labels)
  "Set question QID's marked option labels to LABELS."
  (setq dsh-bridge--question-selection
		(assoc-delete-all qid dsh-bridge--question-selection))
  (push (cons qid labels) dsh-bridge--question-selection))

(defun dsh-bridge--question-rerender-at-point ()
  "Re-render after a state change, restoring point by line and column."
  (let ((line (line-number-at-pos))
		(col (current-column)))
	(dsh-bridge--question-render)
	(goto-char (point-min))
	(forward-line (1- line))
	(move-to-column col)))

(defun dsh-bridge--question-toggle-option (qid label)
  "Toggle LABEL for question QID (radio for single-select, checkbox for multi).
A single-select pick supersedes any typed custom answer, and any pick rescinds
a skip."
  (let* ((multi (dsh-bridge--question-multi-p qid))
		 (selected (cdr (assoc qid dsh-bridge--question-selection))))
	(if (member label selected)
		(setq selected (delete label selected))
	  (setq selected (if multi (append selected (list label)) (list label)))
	  (unless multi
		(setq dsh-bridge--question-custom
			  (assoc-delete-all qid dsh-bridge--question-custom))))
	(dsh-bridge--question-set-selection qid selected)
	(setq dsh-bridge--question-skipped (delete qid dsh-bridge--question-skipped))
	(dsh-bridge--question-rerender-at-point)))

(defun dsh-bridge--question-custom-answer (qid)
  "Prompt for a custom (free-text) answer to question QID.
An empty response clears the custom answer.  For a single-select question the
custom text supersedes any marked option; for a multi-select it accompanies
the marks (the harness's `matchesQuestions' wire rules)."
  (interactive (list (or (dsh-bridge--question-at-point)
						 (user-error "dsh-bridge: no question at point"))))
  (let* ((question (seq-find (lambda (q) (equal (alist-get 'id q) qid))
							 dsh-bridge--question-questions))
		 (current (cdr (assoc qid dsh-bridge--question-custom)))
		 (text (read-string (format "Custom answer for \"%s\" (empty clears): "
									(or (and question (alist-get 'question question)) ""))
							current)))
	(if (string-empty-p text)
		(setq dsh-bridge--question-custom
			  (assoc-delete-all qid dsh-bridge--question-custom))
	  (setq dsh-bridge--question-custom
			(assoc-delete-all qid dsh-bridge--question-custom))
	  (push (cons qid text) dsh-bridge--question-custom)
	  (unless (dsh-bridge--question-multi-p qid)
		(dsh-bridge--question-set-selection qid nil)))
	(setq dsh-bridge--question-skipped (delete qid dsh-bridge--question-skipped))
	(dsh-bridge--question-rerender-at-point)))

(defun dsh-bridge--question-toggle-at-point ()
  "Toggle the option at point; on the custom row, prompt for custom text."
  (interactive)
  (let ((qid (dsh-bridge--question-at-point)))
	(cond
	 ((null qid) (message "dsh-bridge: no question at point"))
	 ((get-text-property (line-beginning-position) 'dsh-bridge-option-custom)
	  (dsh-bridge--question-custom-answer qid))
	 ((get-text-property (line-beginning-position) 'dsh-bridge-option)
	  (dsh-bridge--question-toggle-option
	   qid (get-text-property (line-beginning-position) 'dsh-bridge-option)))
	 (t (message "dsh-bridge: no option at point")))))

(defun dsh-bridge--question-toggle-number ()
  "Toggle the Nth option of the question at point, N from the digit pressed."
  (interactive)
  (let* ((qid (dsh-bridge--question-at-point))
		 (n (string-to-number (this-command-keys)))
		 (question (and qid (seq-find (lambda (q) (equal (alist-get 'id q) qid))
									  dsh-bridge--question-questions)))
		 (opts (and question (alist-get 'options question)))
		 (opt (and (>= n 1) (<= n (length opts)) (nth (1- n) opts))))
	(if opt
		(dsh-bridge--question-toggle-option qid (or (alist-get 'label opt) ""))
	  (message "dsh-bridge: no option %d here" n))))

(defun dsh-bridge--question-next ()
  "Move point to the next question block, wrapping to the first."
  (interactive)
  (let ((here (dsh-bridge--question-at-point))
		(found nil))
	(save-excursion
	  (while (and (not found) (eq 0 (forward-line 1)))
		(let ((qid (dsh-bridge--question-at-point)))
		  (when (and qid (not (equal qid here)))
			(setq found (point))))))
	(goto-char (or found (point-min)))))

(defun dsh-bridge--question-skip ()
  "Toggle skipping the question at point.
A skipped question is answered with an empty selection — the web UI's skip
affordance, valid under the apiproxy's `matchesQuestions'.  Skipping clears
any marks and custom text for the question."
  (interactive)
  (let ((qid (dsh-bridge--question-at-point)))
	(if (null qid)
		(message "dsh-bridge: no question at point")
	  (if (member qid dsh-bridge--question-skipped)
		  (setq dsh-bridge--question-skipped
				(delete qid dsh-bridge--question-skipped))
		(push qid dsh-bridge--question-skipped)
		(dsh-bridge--question-set-selection qid nil)
		(setq dsh-bridge--question-custom
			  (assoc-delete-all qid dsh-bridge--question-custom)))
	  (dsh-bridge--question-rerender-at-point))))

(defun dsh-bridge--question-validate ()
  "Return the answers list for POSTing if every question is settled, else nil.
A question is settled when it is skipped, has a marked option, or has a typed
custom answer.  Wire shape per answer: { id, selected, custom? } where
`selected' holds option labels only — a skipped or custom-only answer sends an
empty array, and a single-select custom answer never travels with a selection
(the apiproxy's `matchesQuestions' rejects both violations)."
  (let (answers failed)
	(dolist (question dsh-bridge--question-questions)
	  (let* ((qid (alist-get 'id question))
			 (multi (eq (alist-get 'multiSelect question) t))
			 (skipped (member qid dsh-bridge--question-skipped))
			 (selected (cdr (assoc qid dsh-bridge--question-selection)))
			 (custom (cdr (assoc qid dsh-bridge--question-custom)))
			 (custom (and custom (not (string-empty-p custom)) custom)))
		(cond
		 (skipped
		  (push (list (cons 'id qid) (cons 'selected [])) answers))
		 ((or selected custom)
		  (push (append (list (cons 'id qid)
							  (cons 'selected
									(vconcat (if (or multi (null custom)) selected '()))))
						(and custom (list (cons 'custom custom))))
				answers))
		 (t (setq failed t)))))
	(and (not failed) (nreverse answers))))

(defun dsh-bridge--question-submit ()
  "Validate and POST the answers for this question buffer."
  (interactive)
  (if dsh-bridge--question-dead
	  (message "dsh-bridge: this question was already resolved")
	(let ((answers (dsh-bridge--question-validate)))
	  (when (null answers)
		(message "dsh-bridge: not all questions answered"))
	  (when answers
		;; Record what this buffer did before the request leaves: the
		;; resolved frame can outrun the POST's response (see the variable).
		(setq dsh-bridge--question-sent "Your answer was sent.")
		(dsh-bridge--call "POST" "/answer"
		  (append (list (cons 'questionId dsh-bridge--question-id)
						(cons 'sessionId dsh-bridge--question-session))
				  (list (cons 'answers answers)))
		  (lambda (status body http-status)
			(let* ((alist (condition-case nil
							(json-parse-string body :object-type 'alist)
						  (error nil)))
				   (reason (and alist (alist-get 'reason alist)))
				   (accepted (and alist (alist-get 'accepted alist))))
			  (cond
			   ((and status (null accepted))
				(message "dsh-bridge: %s" (dsh-bridge--error-message status http-status alist)))
			   ((and reason (equal reason "not-pending"))
				(message "dsh-bridge: already answered or cancelled")
				(dsh-bridge--question-mark-resolved
				 dsh-bridge--question-id
				 "This question was already answered or cancelled." t))
			   (accepted
				(message "dsh-bridge: answer sent to \"%s\""
						 (dsh-bridge--session-label dsh-bridge--question-session))
				(dsh-bridge--question-mark-resolved
				 dsh-bridge--question-id
				 "Your answer was sent." t))
			   (t (message "dsh-bridge: answer not accepted%s"
						   (if reason (concat ": " reason) "")))))))))))

(defun dsh-bridge--question-decline ()
  "Tell the model we will not answer (cancels the ask_user_question tool call)."
  (interactive)
  (if dsh-bridge--question-dead
	  (message "dsh-bridge: this question was already resolved")
	(setq dsh-bridge--question-sent
		  "You declined to answer; the question was cancelled.")
	(dsh-bridge--call "POST" "/answer"
	  (list (cons 'questionId dsh-bridge--question-id)
			(cons 'sessionId dsh-bridge--question-session)
			(cons 'cancelled t))
	  (lambda (_status body _http-status)
		(let* ((alist (condition-case nil
						(json-parse-string body :object-type 'alist)
					  (error nil)))
			   (reason (and alist (alist-get 'reason alist)))
			   (accepted (and alist (alist-get 'accepted alist))))
		  (cond
		   (accepted
			(message "dsh-bridge: question cancelled")
			(dsh-bridge--question-mark-resolved
			 dsh-bridge--question-id
			 "You declined to answer; the question was cancelled." t))
		   ((and reason (equal reason "not-pending"))
			(message "dsh-bridge: already answered or cancelled")
			(dsh-bridge--question-mark-resolved
			 dsh-bridge--question-id
			 "This question was already answered or cancelled." t))
		   (t (message "dsh-bridge: decline not accepted%s"
					   (if reason (concat ": " reason) "")))))))))

;; The `a' (answer) key and the question mode --------------------------------

(defun dsh-bridge-answer ()
  "Open the pending ask-user question buffer for the session at hand.
In a DSH-View / DSH-Prompt / DSH-Sessions buffer, answers the shown / point
session; otherwise reports that no question is pending."
  (interactive)
  (let* ((session (cond
				  ((and (eq major-mode 'dsh-bridge-view-mode)
						dsh-bridge--view-content-session)
				   dsh-bridge--view-content-session)
				  ((eq major-mode 'dsh-bridge-prompt-mode)
				   (dsh-bridge--prompt-status-session))
				  ((eq major-mode 'dsh-bridge-sessions-mode)
				   (tabulated-list-get-id))))
		 (entry (and session (dsh-bridge--pending-question session))))
	(cond
	 (entry
	  (pop-to-buffer (dsh-bridge--question-buffer session (car entry) (cdr entry))))
	 (session
	  (message "dsh-bridge: session \"%s\" has no pending question"
			   (dsh-bridge--session-label session)))
	 (t (message "dsh-bridge: no pending question")))))

(defun dsh-bridge--define-question-mode ()
  "Define `dsh-bridge-question-mode'."
  (define-derived-mode dsh-bridge-question-mode special-mode "DSH-Question"
	"Major mode for an ask-user question buffer.
Read-only; mark options with `RET' or an option's number key.  Free text is
entered in the minibuffer: press `RET' on the `c' row (or `c' anywhere in the
question) to type a custom answer, and an empty entry clears it.  Skip the
question at point with `C-c C-s'; move between questions with `TAB'.  `C-c C-c'
submits the answer, `C-c C-k' declines (cancels the tool call), and `q' buries
without answering (the question stays pending, and `a' reopens the buffer with
any marks intact)."))
(dsh-bridge--define-question-mode)

(defvar dsh-bridge-question-mode-map)
(define-key dsh-bridge-question-mode-map (kbd "RET") #'dsh-bridge--question-toggle-at-point)
(define-key dsh-bridge-question-mode-map (kbd "c") #'dsh-bridge--question-custom-answer)
(define-key dsh-bridge-question-mode-map (kbd "TAB") #'dsh-bridge--question-next)
(define-key dsh-bridge-question-mode-map (kbd "C-c C-s") #'dsh-bridge--question-skip)
(define-key dsh-bridge-question-mode-map (kbd "C-c C-c") #'dsh-bridge--question-submit)
(define-key dsh-bridge-question-mode-map (kbd "C-c C-k") #'dsh-bridge--question-decline)
(define-key dsh-bridge-question-mode-map (kbd "q") #'quit-window)
(define-key dsh-bridge-question-mode-map (kbd "n") #'forward-line)
(define-key dsh-bridge-question-mode-map (kbd "p") #'previous-line)
(dotimes (i 9)
  (define-key dsh-bridge-question-mode-map (kbd (number-to-string (1+ i)))
			  #'dsh-bridge--question-toggle-number))

;;; Prompt-buffer model selection and context occupancy

(defun dsh-bridge--fetch-models (session-id &optional force)
  "Fetch and cache the model catalog for SESSION-ID, returning its value.
When FORCE is nil and SESSION-ID has a cached entry, return it without a
request (the read-through display cache).  Return nil on failure."
  (when session-id
    (when (or force (null (assoc session-id dsh-bridge--session-models)))
      (let* ((result (dsh-bridge--request "GET" (dsh-bridge--path "/models" session-id) nil))
             (status (car result))
             (alist (cdr result)))
        (when (and (eq status 200) alist)
          (setq dsh-bridge--session-models
                (assoc-delete-all session-id dsh-bridge--session-models))
          (push (cons session-id alist) dsh-bridge--session-models))))
    (cdr (assoc session-id dsh-bridge--session-models))))

(defun dsh-bridge--models-event-refresh (session-id)
  "Force-refresh SESSION-ID's model cache after a turn SSE frame, when cached.
A web-UI model change takes effect at the session's next turn, so the turn
frames are the refresh trigger that keeps the header from going stale.
Sessions with no cache entry (nothing is displaying them) are left alone.
Deferred with `run-at-time' to keep the SSE process filter non-blocking."
  (when (assoc session-id dsh-bridge--session-models)
    (run-at-time 0 nil #'dsh-bridge--fetch-models session-id t)))

(defun dsh-bridge--fetch-context (session-id)
  "Seed the context cache for SESSION-ID from GET /context, when uncached.
Returns the (USED-TOKENS . CONTEXT-WINDOW) entry, or nil when unknown."
  (when (and session-id (null (assoc session-id dsh-bridge--session-context)))
    (let* ((result (dsh-bridge--request "GET" (dsh-bridge--path "/context" session-id) nil))
           (status (car result))
           (alist (cdr result)))
      (when (and (eq status 200) alist
                 (numberp (alist-get 'usedTokens alist))
                 (numberp (alist-get 'contextWindow alist)))
        (setq dsh-bridge--session-context
              (assoc-delete-all session-id dsh-bridge--session-context))
        (push (cons session-id (cons (alist-get 'usedTokens alist)
                                     (alist-get 'contextWindow alist)))
              dsh-bridge--session-context))))
  (cdr (assoc session-id dsh-bridge--session-context)))

(defun dsh-bridge--model-display-name (data provider model)
  "The catalog display name of PROVIDER/MODEL in DATA, or nil.
Searches the `groups' list for the provider, then its models for the id."
  (let ((group (seq-find (lambda (g) (equal (alist-get 'id g) provider))
                         (alist-get 'groups data))))
    (when group
      (let ((entry (seq-find (lambda (m) (equal (alist-get 'id m) model))
                             (alist-get 'models group))))
        (and entry (alist-get 'name entry))))))

(defun dsh-bridge--prompt-model-label (session-id)
  "The prompt header's model segment for SESSION-ID, or nil when unknown.
The catalog's display name, falling back to the raw model id; nil until the
first GET /models succeeds for the session."
  (let ((data (and session-id (cdr (assoc session-id dsh-bridge--session-models)))))
    (when data
      (let* ((current (alist-get 'current data))
             (provider (alist-get 'provider current))
             (model (alist-get 'model current)))
        (when model
          (or (dsh-bridge--model-display-name data provider model) model))))))

(defun dsh-bridge--prompt-context-label (session-id)
  "The prompt header's context-occupancy segment for SESSION-ID, or nil.
Renders the DSH formula `min(100, round(used/window*100))%'; nil until both
numbers are known."
  (let ((entry (and session-id (assoc session-id dsh-bridge--session-context))))
    (when entry
      (let ((used (cadr entry))
            (window (cddr entry)))
        (when (and (numberp used) (numberp window) (> window 0))
          (format "%d%%" (min 100 (round (* 100.0 (/ used (float window)))))))))))

(defun dsh-bridge--refresh-prompt-metadata ()
  "Fetch model/context metadata for the prompt buffer's effective session.
One request each, only when the session's entry is not already cached.  The
requests are synchronous loopback (like the other prompt-open requests); a
failure leaves the header segment empty until the next trigger."
  (let ((session (dsh-bridge--prompt-status-session)))
    (when session
      (dsh-bridge--fetch-models session)
      (dsh-bridge--fetch-context session))))

(defun dsh-bridge--model-catalog (data)
  "Flatten DATA's model groups into (PROVIDER/MODEL PROVIDER MODEL-ENTRY) triples.
MODEL-ENTRY is the catalog model alist (id, name, reasoning)."
  (let ((result '()))
    (dolist (group (alist-get 'groups data) (nreverse result))
      (let ((provider (alist-get 'id group)))
        (dolist (model (alist-get 'models group))
          (push (list (format "%s/%s" provider (alist-get 'id model))
                      provider model)
                result))))))

(defun dsh-bridge--select-model-apply (session-id provider model effort)
  "POST /model for SESSION-ID and refresh the model cache on success.
Returns non-nil on success; the header re-renders on the next redisplay."
  (let* ((payload (append (list (cons 'sessionId session-id)
                                (cons 'provider provider)
                                (cons 'model model))
                          (and effort (list (cons 'reasoningEffort effort)))))
         (result (dsh-bridge--request "POST" "/model" payload))
         (status (car result))
         (alist (cdr result)))
    (if (and (eq status 200) alist)
        (progn
          (setq dsh-bridge--session-models
                (assoc-delete-all session-id dsh-bridge--session-models))
          (dsh-bridge--fetch-models session-id t)
          (message "dsh-bridge: model %s/%s%s"
                   provider model (if effort (format " (%s)" effort) ""))
          t)
      (message "dsh-bridge: %s" (or (alist-get 'error alist) (format "HTTP %s" status)))
      nil)))

(defun dsh-bridge-select-model ()
  "Change the model (and reasoning effort) of the prompt buffer's session.
Picks from the host's live catalog via `completing-read' (`provider/model'
candidates annotated with the display name), then posts the selection through
the genuine `session.selectModel' handler — so the change applies to this
session and persists as the default, exactly as the web UI does."
  (interactive)
  (let* ((session-id (dsh-bridge--prompt-status-session))
         (data (dsh-bridge--fetch-models session-id t)))
    (if (null data)
        (message "dsh-bridge: model catalog unavailable")
      (let* ((catalog (dsh-bridge--model-catalog data))
             (current (alist-get 'current data))
             (current-key (and (alist-get 'provider current) (alist-get 'model current)
                               (format "%s/%s" (alist-get 'provider current)
                                       (alist-get 'model current))))
             (annotation (lambda (cand)
                           (let ((name (alist-get 'name (caddr (assoc cand catalog)))))
                             (and (stringp name) (not (string-empty-p name))
                                  (concat " " name))))))
        (if (null catalog)
            (message "dsh-bridge: no models available")
          (let ((chosen (completing-read
                         (format-prompt "Model" current-key)
                         (lambda (string pred action)
                           (if (eq action 'metadata)
                               `(metadata (annotation-function . ,annotation))
                             (complete-with-action action (mapcar #'car catalog) string pred)))
                         nil t nil nil current-key)))
            (when (and chosen (not (string-empty-p chosen)))
              (let* ((entry (assoc chosen catalog))
                     (provider (cadr entry))
                     (model-entry (caddr entry))
                     (reasoning (alist-get 'reasoning model-entry))
                     (efforts (and reasoning (alist-get 'efforts reasoning)))
                     (effort nil))
                (when efforts
                  (let* ((by-name (mapcar (lambda (e) (cons (alist-get 'name e) (alist-get 'id e)))
                                          efforts))
                         (current-effort (alist-get 'reasoningEffort current))
                         (default-name
                          (or (and current-effort (car (rassoc current-effort by-name)))
                              (let ((d (alist-get 'defaultEffort reasoning)))
                                (and d (car (rassoc d by-name)))))))
                    (setq effort
                          (cdr (assoc (completing-read (format-prompt "Reasoning effort" default-name)
                                                       (mapcar #'car by-name)
                                                       nil t nil nil default-name)
                                      by-name)))))
                (dsh-bridge--select-model-apply
                 session-id provider (alist-get 'id model-entry) effort)))))))))

;;;###autoload
(defun dsh-bridge--prompt-buffer (&optional session-id)
  "Prepare and return a DSH-Prompt buffer for a new composition.
If SESSION-ID is non-nil and a live buffer in `dsh-bridge-prompt-mode'
is bound to that session, reuse it.  Otherwise, use a buffer named
`*dsh-bridge-prompt*', creating it if necessary.  The chosen buffer is
bound to SESSION-ID; a nil SESSION-ID clears any existing binding, so
the buffer follows the default target (or last-active session).

If the buffer holds modified text (an unsent draft, or text edited
further after a send), ask for confirmation before erasing it; a
\"no\" answer keeps the text, which then targets SESSION-ID.
Unmodified text — kept from a previous send, or a pristine history
entry — is erased silently."
  (let ((oldbuf (when session-id
				  (seq-find (lambda (b)
							  (with-current-buffer b
								(and (eq major-mode 'dsh-bridge-prompt-mode)
									 (equal dsh-bridge--prompt-session
											session-id))))
							(buffer-list)))))
	(with-current-buffer (or oldbuf
							 (get-buffer-create "*dsh-bridge-prompt*"))
	  (unless (eq major-mode 'dsh-bridge-prompt-mode)
		(dsh-bridge-prompt-mode))
	  (when (or (string-blank-p (buffer-string))
				(not (buffer-modified-p))
				(y-or-n-p "Erase the existing prompt text? "))
		(dsh-bridge--prompt-blank))
	  (dsh-bridge-set-prompt-session session-id)
	  (current-buffer))))

;;;###autoload
(defun dsh-bridge-prompt ()
  "Pop to a DSH-Prompt buffer to compose a prompt.
The buffer is bound to the effective session of the current buffer (its
binding, else the default target, else last-active), so \\`r' from a
DSH-View or DSH-Sessions buffer continues that session's conversation.
The buffer starts as a fresh composition: text kept from a previous
send is erased silently, while an unsent or further-edited draft is
erased only after confirmation.  Earlier sent prompts stay in the
prompt history,
reachable with \\`M-p' / \\`M-n'.  \\<dsh-bridge-prompt-mode-map>\
\\[dsh-bridge-send-and-exit] sends and buries the buffer,
\\[dsh-bridge-fetch] fetches the session's latest turn, closing the
compose→read loop."
  (interactive)
  (pop-to-buffer (dsh-bridge--prompt-buffer (dsh-bridge--effective-session))))

(defconst dsh-bridge-prompt-display-action
  '(display-buffer-reuse-window display-buffer-below-selected)
  "`display-buffer' action for opening the prompt buffer to reply.
Reuse the prompt's window when already visible, else show it below the
selected window, so the output buffer stays visible (cf. `flymake',
`debug').")

(defun dsh-bridge-reply ()
  "Reply to the session whose reply is shown in the current DSH-View buffer.
The prompt buffer is bound to that session (no default-target change) and
shown in another window so the output stays visible."
  (interactive)
  (let ((id dsh-bridge--view-content-session))
	(cond
	 ((null id)
	  (user-error "dsh-bridge: no session to reply to"))
	 ((null (dsh-bridge--ensure-session-live id))
	  ;; A failed resume already echoed the host's error; only an id
	  ;; the cache does not know at all gets the not-known message.
	  (dsh-bridge--warn-if-unknown-session id))
	 (t
	  (pop-to-buffer (dsh-bridge--prompt-buffer id)
					 dsh-bridge-prompt-display-action)))))

(defun dsh-bridge--shown-turn-record ()
  "The turn record the current DSH-View buffer shows, or nil.
Force-refreshes the session's turn cache when the view is at rest, so the
record's `endSeq' is current, then finds the record by turn number."
  (let* ((turns (dsh-bridge--view-turns-refresh
                 (null dsh-bridge--view-turn-index)))
         (turn dsh-bridge--view-turn))
    (and turn turns
         (seq-find (lambda (record)
                     (equal (alist-get 'turn record) turn))
                   turns))))

(defun dsh-bridge--fork-turn (session-id at-seq)
  "Fork SESSION-ID at AT-SEQ via POST /fork; return the child id, or nil.
AT-SEQ is the shown turn's `endSeq', the fork anchor the host cuts after.
On failure the host's error is echoed and nil is returned."
  (message "dsh-bridge: branching…")
  (redisplay t)
  (let* ((result (dsh-bridge--request
                  "POST" "/fork"
                  (list (cons 'sessionId session-id) (cons 'atSeq at-seq))))
         (status (car result))
         (alist (cdr result)))
    (if (and (memq status '(200 201)) (alist-get 'sessionId alist))
        (alist-get 'sessionId alist)
      (message "dsh-bridge: %s"
               (or (dsh-bridge--error-message nil status alist)
                   "failed to branch the turn"))
      nil)))

;;;###autoload
(defun dsh-bridge-fork-turn ()
  "Branch the shown turn into a new session, then open the child.
The child inherits the conversation through the shown turn and the agent
preset, but starts on the default model and is not auto-titled.  A turn
that has not completed cannot be a fork anchor, so an open turn is
refused.  Only meaningful in a DSH-View buffer."
  (interactive)
  (unless (eq major-mode 'dsh-bridge-view-mode)
    (user-error "dsh-bridge: not a DSH-View buffer"))
  (let ((id dsh-bridge--view-content-session))
    (unless id
      (user-error "dsh-bridge: this view has no session"))
    (let* ((record (dsh-bridge--shown-turn-record))
           (end-seq (and record (alist-get 'endSeq record))))
      (unless end-seq
        (user-error "dsh-bridge: the shown turn is not completed; branch a completed turn"))
      (let ((child (dsh-bridge--fork-turn id end-seq)))
        (when child
          ;; Open the child's conversation: its view in this window, then its
          ;; prompt below (the `dsh-bridge-reply' window shape).  The child's
          ;; newest inherited turn is complete, so `dsh-bridge-fetch' fills the
          ;; view with it rather than the waiting placeholder.
          (dsh-bridge-fetch child t)
          (pop-to-buffer (dsh-bridge--prompt-buffer child)
                         dsh-bridge-prompt-display-action)
          (message "dsh-bridge: branched into %s (preset inherited; default model; untitled)"
                   (dsh-bridge--id-tail child)))))))

(defun dsh-bridge--view-shown-turn-markdown ()
  "The raw Markdown of the turn the DSH-View buffer shows, or nil.
Returns the shown turn's segments joined by blank lines (no divider lines)
when the buffer has a turn identity and that turn is still in the cached list;
nil for a pushed message with no turn identity, or when the turn is no longer
cached (e.g. after a compaction)."
  (let* ((session dsh-bridge--view-content-session)
		 (turn dsh-bridge--view-turn)
		 (turns (and session turn
					 (dsh-bridge--turns-cache-turns session)))
		 (record (and turns
					  (seq-find (lambda (r) (equal (alist-get 'turn r) turn))
								turns))))
	(and record (dsh-bridge--view-turn-text record))))

(defun dsh-bridge-copy-reply ()
  "Copy the reply in the current DSH-View buffer (region, else the whole turn).
With an active region, the raw text of the region is copied.  Otherwise the
whole shown turn's raw Markdown is copied — its segments joined by blank
lines, without the divider lines — or, for a pushed message that is not (yet)
a known turn, the whole buffer content.  The kill carries the original
Markdown source: under `gfm-view-mode', markup delimiters are hidden from
display and `filter-buffer-substring-function' would strip them from a copy,
so this copies the raw text instead."
  (interactive)
  (let* ((region-p (use-region-p))
		 (beg (and region-p (region-beginning)))
		 (end (and region-p (region-end)))
		 (str (if region-p
				  (buffer-substring beg end)
				(or (dsh-bridge--view-shown-turn-markdown)
					(buffer-string)))))
	(if (eq last-command 'kill-region)
		(kill-append str (and region-p (< end beg)))
	  (kill-new str)))
  (setq deactivate-mark t)
  (message "dsh-bridge: copied reply"))

;;; The prompt buffer

(defun dsh-bridge--prompt-sent-marker (session-id)
  "The \" ✓ sent HH:MM\" marker when the buffer text was just sent, else \"\".
The last-sent entry for SESSION-ID must equal the current buffer content; a
single edit makes them differ and the marker disappears (the `(:eval)' header
recomputes on the next redisplay)."
  (let ((entry (and session-id (assoc session-id dsh-bridge--last-sent))))
	(if (and entry (equal (car (cdr entry)) (buffer-string)))
		(format " ✓ sent %s" (format-time-string "%H:%M" (cdr (cdr entry))))
	  "")))

(defun dsh-bridge--prompt-header-line ()
  "Return the header line for the DSH-Prompt buffer.
Header line format:

 <status> <label>[ (k/n)][ · <model>][ · <ctx%>][ ✓ sent HH:MM]

The model and context segments stay empty until their first successful
fetch.  Editing the text clears the sent marker.  The `(k/n)' segment
appears when walking the prompt history."
  (let* ((session (dsh-bridge--prompt-status-session))
		 (status (dsh-bridge--status-glyph session))
		 (label (if session
					(dsh-bridge--session-link (dsh-bridge--session-label session) session)
				  ""))
		 (model (dsh-bridge--prompt-model-label session))
		 (context (dsh-bridge--prompt-context-label session))
		 (sent (dsh-bridge--prompt-sent-marker session))
		 (hist (dsh-bridge--prompt-history-position)))
	;; The returned string is %-escaped (see `header-line-format'), so
	;; turn any % (from context percentage or session title) into %%.
	(string-replace
	 "%" "%%"
	 (concat " " (if (string-empty-p status) label (concat status " " label))
			 hist (and model (concat " · " model))
			 (and context (concat " · " context)) sent))))

(defun dsh-bridge--prompt-mode-setup ()
  "Common setup for `dsh-bridge-prompt-mode'."
  (setq-local header-line-format '(:eval (dsh-bridge--prompt-header-line)))
  (setq-local revert-buffer-function #'dsh-bridge--revert-prompt-buffer))

(declare-function markdown-mode "markdown-mode")
(declare-function dsh-bridge-prompt-mode "dsh-bridge")

(defmacro dsh-bridge--define-prompt-mode (parent)
  "Define `dsh-bridge-prompt-mode' as a variant of PARENT.
PARENT is `markdown-mode' or `text-mode', chosen at load time: the mode is
defined once, with a literal symbol parent.	 A conditional expression cannot
go directly in the parent slot of `define-derived-mode' — the macro quotes it
into the mode metadata and the docstring generation calls `symbol-name' on it
— so the choice is resolved here, driven by `dsh-bridge-prompt-markdown' and
`(require \\='markdown-mode nil t)'."
  `(define-derived-mode dsh-bridge-prompt-mode ,parent "DSH-Prompt"
	 "Major mode for composing DSH prompts.
`C-c C-c' sends the whole buffer (as in Message mode, an active region
is ignored) and, on success, buries the buffer (text survives,
unmodified, for edit-and-resubmit; the window pops to a DSH-View buffer
following the sent session).  `C-c C-d' pushes it as a composer
draft, `C-c C-k' erases the buffer, `C-c C-f' fetches the effective
session's latest turn, `C-c C-s' rebinds this buffer's session, `C-c C-l'
lists sessions.  `M-p' and `M-n' walk the session's prompt history,
recalling earlier prompts (the current draft is restored by `M-n' at the
newest prompt); an edited history entry must be sent or reverted with
`revert-buffer' before walking on.  The header shows the session's
status glyph and a `✓ sent HH:MM' marker when the current text was just
sent.  When the mode derives from markdown-mode, several markdown keys
are shadowed by the bridge commands (C-c C-c, C-c C-d, C-c C-k, C-c C-s,
C-c C-f, C-c C-l); the markdown commands stay reachable via the menu."
	 (dsh-bridge--prompt-mode-setup)))

;; The map is created by whichever branch of the `if' runs; declare it here so
;; the byte-compiler knows the `define-key' forms below are valid.
(defvar dsh-bridge-prompt-mode-map)

(if (and dsh-bridge-prompt-markdown (require 'markdown-mode nil t))
	(dsh-bridge--define-prompt-mode markdown-mode)
  (dsh-bridge--define-prompt-mode text-mode))

(define-key dsh-bridge-prompt-mode-map (kbd "C-c C-c") #'dsh-bridge-send-and-exit)
(define-key dsh-bridge-prompt-mode-map (kbd "C-c C-d") #'dsh-bridge-draft)
(define-key dsh-bridge-prompt-mode-map (kbd "C-c C-k") #'dsh-bridge-erase-prompt)
(define-key dsh-bridge-prompt-mode-map (kbd "C-c C-f") #'dsh-bridge-fetch)
(define-key dsh-bridge-prompt-mode-map (kbd "C-c C-m") #'dsh-bridge-select-model)
(define-key dsh-bridge-prompt-mode-map (kbd "C-c C-s") #'dsh-bridge-set-prompt-session)
(define-key dsh-bridge-prompt-mode-map (kbd "C-c C-l") #'dsh-bridge-list-sessions)
(define-key dsh-bridge-prompt-mode-map (kbd "M-p")
			#'dsh-bridge-prompt-previous-history)
(define-key dsh-bridge-prompt-mode-map (kbd "M-n")
			#'dsh-bridge-prompt-next-history)

(defun dsh-bridge-erase-prompt ()
  "Erase the contents of the prompt buffer."
  (interactive)
  (erase-buffer))

(easy-menu-define dsh-bridge-prompt-menu dsh-bridge-prompt-mode-map
  "Menu bar menu for the DSH-Prompt buffer."
  '("DSH Bridge"
	["Send" dsh-bridge-send-and-exit
	 :help "Send the whole buffer to DSH and bury the prompt buffer"]
	["Send as Draft" dsh-bridge-draft
	 :help "Send the region (or whole buffer) to the DSH composer as a draft"]
	["Erase Prompt" dsh-bridge-erase-prompt
	 :help "Clear the prompt buffer"]
	"---"
	["Fetch Latest Turn" dsh-bridge-fetch
	 :help "Fetch the effective session's latest turn"]
	["Describe Session" dsh-bridge-describe-session
	 :help "Show the effective session's read-only report"]
	["Select Model…" dsh-bridge-select-model
	 :help "Change the session's model and reasoning effort"]
	["Set Prompt Session…" dsh-bridge-set-prompt-session
	 :help "Rebind this buffer's session (or follow the default target)"]
	["List Sessions" dsh-bridge-list-sessions
	 :help "Browse DSH sessions"]
	"---"
	["Previous Prompt" dsh-bridge-prompt-previous-history
	 :keys "M-p"
	 :help "Recall the previous prompt sent to this session"]
	["Next Prompt" dsh-bridge-prompt-next-history
	 :keys "M-n"
	 :help "Move forward through the prompt history"]
	"---"
	["Set Default Target…" dsh-bridge-set-default-target
	 :help "Set the bridge-wide default target (completing-read)"]))

;;; Session targeting

(defun dsh-bridge--refresh-view-headers ()
  "Refresh header lines of live bridge buffers after a retarget."
  (dolist (buf (dsh-bridge--view-buffers))
	(with-current-buffer buf
	  (setq header-line-format (dsh-bridge--view-header-line))))
  (dolist (buf (buffer-list))
	(with-current-buffer buf
	  (when (eq major-mode 'dsh-bridge-prompt-mode)
		(setq header-line-format
			  '(:eval (dsh-bridge--prompt-header-line)))))))

(defun dsh-bridge-set-prompt-session (session-id)
  "Bind the current buffer, which must be a DSH-Prompt buffer, to SESSION-ID.
If SESSION-ID is nil, the buffer instead follows the default target.
Updates the header and the session directory, and resets the
prompt-history walk when the binding changes."
  (interactive (list (dsh-bridge--read-session-id "Switch to Session: "
												  "(default)")))
  (unless (eq major-mode 'dsh-bridge-prompt-mode)
	(user-error "dsh-bridge: not a DSH-Prompt buffer"))
  (unless (equal session-id dsh-bridge--prompt-session)
	;; The history walk refers to the old session; reset it.
	(setq-local dsh-bridge--prompt-history-index nil)
	(setq-local dsh-bridge--prompt-draft nil))
  (setq-local dsh-bridge--prompt-session session-id)
  (setq header-line-format '(:eval (dsh-bridge--prompt-header-line)))
  (dsh-bridge--apply-session-directory session-id nil (current-buffer))
  (dsh-bridge--refresh-prompt-metadata)
  (when (called-interactively-p 'any)
	(message "dsh-bridge: prompt buffer %s"
			 (if (null session-id)
				 "follows the default target"
			   (format "bound to session \"%s\""
					   (dsh-bridge--session-label session-id))))))

;;;###autoload
(defun dsh-bridge-set-default-target (session-id)
  "Set the DSH bridge's default target session to SESSION-ID.
SESSION-ID is a session id string, or nil to clear the default target (fall
back to last-active).  A saved (cold) id binds directly; the host resumes it
when the next request targets it.  Emacs-local only: there is no host-side
pin to write, and clearing has no host round-trip."
  (interactive
   (list (dsh-bridge--read-session-id "Default target: " "(last-active)")))
  (setq dsh-bridge-default-session session-id)
  (dsh-bridge--refresh-view-headers)
  (dsh-bridge--refresh-sessions-buffer)
  ;; Re-point any DSH-Prompt buffer that follows the default target at its
  ;; effective session's workspace.
  (dolist (buf (buffer-list))
	(with-current-buffer buf
	  (when (and (eq major-mode 'dsh-bridge-prompt-mode)
				 (null dsh-bridge--prompt-session))
		(dsh-bridge--apply-session-directory
		 (dsh-bridge--effective-session buf) nil buf))))
  (message "dsh-bridge: default target %s"
		   (if session-id
			   (dsh-bridge--session-label session-id)
			 "last-active")))

(defun dsh-bridge-clear-default-target ()
  "Clear the default target; the bridge falls back to last-active."
  (interactive)
  (dsh-bridge-set-default-target nil))

;;; The sessions buffer

(defface dsh-bridge-default-target-face
  '((t :inherit font-lock-keyword-face))
  "Face for the default-target session in the DSH-Sessions buffer."
  :group 'dsh-bridge)

(defface dsh-bridge-untitled-face
  '((t :inherit font-lock-comment-face))
  "Face for \"[Untitled Session]\" in the DSH-Sessions buffer."
  :group 'dsh-bridge)

(defface dsh-bridge-status-running-face
  '((t :foreground "goldenrod3"))
  "Face for the running session status glyph (amber)."
  :group 'dsh-bridge)

(defface dsh-bridge-status-idle-face
  '((t :foreground "ForestGreen"))
  "Face for the idle session status glyph (green)."
  :group 'dsh-bridge)

(defface dsh-bridge-status-unknown-face
  '((t :inherit shadow))
  "Face for the unknown session status glyph (shadow)."
  :group 'dsh-bridge)

(defface dsh-bridge-status-awaiting-face
  '((t :inherit bold :foreground "orange"))
  "Face for a session whose turn is paused on an ask-user question."
  :group 'dsh-bridge)

(defface dsh-bridge-view-marker-face
  '((t :inherit shadow :italic t))
  "Face for the `(continuing...)' marker at the end of a running turn.
The marker is bridge furniture, not model text; this face keeps it visually
quiet so it never reads as part of the reply."
  :group 'dsh-bridge)

(defface dsh-bridge-view-awaiting-face
  '((t :inherit bold :foreground "orange"))
  "Face for the \"Awaiting your response…\" note at the end of a running turn.
Shown while the session is parked on an ask-user question, so the note stands
out from the quiet `(continuing...)' marker it replaces."
  :group 'dsh-bridge)

(defun dsh-bridge--default-target-marker (session)
  "Return the leftmost marker cell for SESSION: \"*\" when it is the default
target, else a space."
  (if (equal (alist-get 'id session) dsh-bridge-default-session)
	  (propertize "*" 'face 'dsh-bridge-default-target-face)
	" "))

(defun dsh-bridge--age-sorter (a b)
  "Sort predicate for the Age column: ascending by activity timestamp.
A and B are `tabulated-list' entries (ID COLS); the Age cell is a string
carrying the raw ms-epoch timestamp in its `dsh-bridge-age-ts' text property."
  (let* ((n (seq-position tabulated-list-format "Age"
						   (lambda (e elt) (equal (car e) elt))))
		 (ta (get-text-property 0 'dsh-bridge-age-ts (aref (cadr a) n)))
		 (tb (get-text-property 0 'dsh-bridge-age-ts (aref (cadr b) n))))
	(< ta tb)))

(defun dsh-bridge--session-visible-p (session)
  "Whether SESSION is shown in the current session list.
Archived sessions are hidden unless `dsh-bridge--sessions-archived-p' (or
`dsh-bridge-sessions-show-archived') is set, matching the web UI's default."
  (or dsh-bridge--sessions-archived-p
	  (not (alist-get 'archived session))))

(defun dsh-bridge--session-entry (session)
  "Return a `tabulated-list' entry (ID . COLS) for SESSION (a row alist)."
  (let* ((id (alist-get 'id session))
		 (activity (or (alist-get 'lastActive session)
					   (alist-get 'createdAt session) 0))
		 (age (propertize (dsh-bridge--relative-age activity)
						  'dsh-bridge-age-ts activity))
		 (workspace (dsh-bridge--workspace-label session))
		 (cwd (alist-get 'cwd session))
		 (workspace-cell (if (and (stringp cwd) (not (string-empty-p cwd)))
							 (propertize workspace 'help-echo cwd)
						   workspace))
		 (cols (vector (dsh-bridge--default-target-marker session)
					   (dsh-bridge--status-glyph (alist-get 'id session))
					   (dsh-bridge--session-label session nil t)
					   age
					   workspace-cell)))
	(when dsh-bridge-show-session-ids
	  (setq cols (vconcat cols (vector id))))
	(list id cols)))

(define-derived-mode dsh-bridge-sessions-mode tabulated-list-mode "DSH-Sessions"
  "Major mode for browsing DSH sessions.
`RET' or `r' opens the session under point (resuming a saved session on demand;
the default target is untouched), `t' sets the default target to the row's
session (also resuming saved sessions), `u' clears the default target, `f'
peeks the session's latest turn, `v' toggles archived-session visibility, `R'
renames the session, `d' archives it (one-way), `+' creates a session (possibly
in a new workspace), `W' renames the row's workspace, `w' copies the session id
under point, `D' describes the session, `g' re-fetches the list, `S' sorts by
column (inherited).	 `p' is previous-line (the tabulated-list convention; no
bridge command uses bare `p' — reply/open is `r' everywhere, `RET' here as
well).	Column legend: `*' = the default target session; the `S' (state) column
shows a session's live status, a filled circle that is green when idle and
amber when running (`?' when unknown; cold sessions are always unknown),
obeying `dsh-bridge-status-indicator' and updating live from the bridge's turn
notifications."
  (setq-local dsh-bridge--sessions-archived-p dsh-bridge-sessions-show-archived))

(define-key dsh-bridge-sessions-mode-map (kbd "RET")
			#'dsh-bridge-open-session)
(define-key dsh-bridge-sessions-mode-map (kbd "r")
			#'dsh-bridge-open-session)
(define-key dsh-bridge-sessions-mode-map (kbd "t")
			#'dsh-bridge-set-default-target-at-point)
(define-key dsh-bridge-sessions-mode-map (kbd "u")
			#'dsh-bridge-clear-default-target)
(define-key dsh-bridge-sessions-mode-map (kbd "f")
			#'dsh-bridge-peek-session)
(define-key dsh-bridge-sessions-mode-map (kbd "a")
			#'dsh-bridge-answer)
(define-key dsh-bridge-sessions-mode-map (kbd "v")
			#'dsh-bridge-toggle-archived-sessions)
(define-key dsh-bridge-sessions-mode-map (kbd "R")
			#'dsh-bridge-rename-session)
(define-key dsh-bridge-sessions-mode-map (kbd "d")
			#'dsh-bridge-archive-session)
(define-key dsh-bridge-sessions-mode-map (kbd "+")
			#'dsh-bridge-create-session)
(define-key dsh-bridge-sessions-mode-map (kbd "W")
			#'dsh-bridge-rename-workspace)
(define-key dsh-bridge-sessions-mode-map (kbd "w")
			#'dsh-bridge-copy-session-id)
(define-key dsh-bridge-sessions-mode-map (kbd "D")
			#'dsh-bridge-describe-session)

(easy-menu-define dsh-bridge-sessions-menu dsh-bridge-sessions-mode-map
  "Menu bar menu for the `*dsh-bridge-sessions*' buffer."
  '("DSH Bridge"
	["Open Session" dsh-bridge-open-session
	 :help "Bind the prompt buffer to the session under point and open it"]
	["Set Default Target" dsh-bridge-set-default-target-at-point
	 :help "Set the default target to the session under point"]
	["Clear Default Target" dsh-bridge-clear-default-target
	 :help "Clear the default target (use last-active)"]
	["View Latest Turn" dsh-bridge-peek-session
	 :help "Fetch the session's latest turn without changing anything"]
	["Show/Hide Archived" dsh-bridge-toggle-archived-sessions
	 :help "Toggle whether archived sessions are shown"]
	["Rename Session…" dsh-bridge-rename-session
	 :help "Rename the session under point"]
	["Archive Session" dsh-bridge-archive-session
	 :help "Archive the session under point (one-way: no unarchive)"]
	["Create Session…" dsh-bridge-create-session
	 :help "Create a new session, optionally in a new workspace"]
	["Rename Workspace…" dsh-bridge-rename-workspace
	 :help "Rename the workspace of the session under point"]
	["Copy Session Id" dsh-bridge-copy-session-id
	 :help "Copy the session id under point"]
	["Describe Session" dsh-bridge-describe-session
	 :help "Show the session's read-only report"]
	"---"
	["Refresh" revert-buffer
	 :help "Re-fetch the session list"]
	"---"
	["Set Default Target…" dsh-bridge-set-default-target
	 :help "Choose the default target (completing-read)"]
	["DSH Bridge Dispatcher…" dsh-bridge
	 :help "Open the dispatcher"]))

(defun dsh-bridge--resume-session (id)
  "Resume the cold session ID via POST /sessions/resume.
Echoes \"resuming…\" while the request is in flight, then refetches the session
list so the row flips to live.	Returns the refreshed row alist, or nil on
failure (the host reports 404 unknown / 409 subagent-owned / 500 composition)."
  (message "dsh-bridge: resuming session")
  (redisplay t)
  (let* ((result (dsh-bridge--request "POST" "/sessions/resume"
									  (list (cons 'sessionId id))))
		 (status (car result))
		 (alist (cdr result)))
	(if (and (eq status 200) alist)
		(progn
		  (dsh-bridge--fetch-sessions)
		  (dsh-bridge--refresh-sessions-buffer)
		  (dsh-bridge--session-for-id id))
	  (message "dsh-bridge: %s"
			   (or (dsh-bridge--error-message nil status alist)
				   (format "failed to resume session %s" id)))
	  nil)))

(defun dsh-bridge--ensure-session-live (id)
  "Return non-nil when SESSION ID is live, resuming a cold session on demand.
A saved (cold) session known to the session cache is resumed via
`dsh-bridge--resume-session' (echoing \"resuming…\", and the host's error on
failure); an id absent from the cache returns nil without a resume attempt,
leaving the not-known report to the caller."
  (let ((session (dsh-bridge--session-for-id id)))
	(cond
	 ((alist-get 'live session) t)
	 (session (and (dsh-bridge--resume-session id) t))
	 (t nil))))

(defun dsh-bridge-open-session ()
  "In a DSH-Sessions buffer, open a prompt for the session under point.
If the session is saved (cold), resume it first.  This command does not
change the default target session."
  (interactive)
  (let ((id (tabulated-list-get-id)))
	(cond
	 ((null id)
	  (message "dsh-bridge: no session under point"))
	 ((dsh-bridge--ensure-session-live id)
	  (pop-to-buffer-same-window (dsh-bridge--prompt-buffer id)
								 dsh-bridge-prompt-display-action))
	 (t
	  ;; A failed resume already echoed the host's error; only an id
	  ;; the cache does not know at all gets the not-known message.
	  (dsh-bridge--warn-if-unknown-session id)))))

(defun dsh-bridge-set-default-target-at-point ()
  "Set the default target to the session under point.
A saved (cold) session is resumed first, so the target is live once bound."
  (interactive)
  (let ((id (tabulated-list-get-id)))
	(if (null id)
		(message "dsh-bridge: no session under point")
	  (if (dsh-bridge--ensure-session-live id)
		  (dsh-bridge-set-default-target id)
		;; A failed resume already echoed the host's error; only an id the
		;; cache does not know at all gets the not-known message.
		(dsh-bridge--warn-if-unknown-session id)))))

(defun dsh-bridge-peek-session ()
  "In a DSH-Sesssions buffer, view the session under point in a DSH-View buffer."
  (interactive)
  (let ((id (tabulated-list-get-id)))
	(if id
		(dsh-bridge-fetch id t)
	  (message "dsh-bridge: no session under point"))))

(defun dsh-bridge-toggle-archived-sessions ()
  "Toggle whether archived sessions are shown in the session list.
Archived sessions are hidden by default (the web UI's behavior); this shows or
hides them for the current buffer only."
  (interactive)
  (setq dsh-bridge--sessions-archived-p (not dsh-bridge--sessions-archived-p))
  (dsh-bridge--list-sessions-in-buffer)
  (message "dsh-bridge: %s archived sessions"
		   (if dsh-bridge--sessions-archived-p "showing" "hiding")))

(defun dsh-bridge-rename-session ()
  "Rename the session under point.
Prompts for the new title (default: the current title) and calls
POST /sessions/rename.	A cold session is resumed first, since renaming it
makes it live (the web UI does the same)."
  (interactive)
  (let ((id (tabulated-list-get-id)))
	(if (null id)
		(message "dsh-bridge: no session under point")
	  (let* ((session (dsh-bridge--session-for-id id))
			 (current (or (alist-get 'title session) ""))
			 (title (read-string "Rename session to: " current)))
		(if (string-empty-p title)
			(message "dsh-bridge: empty title")
		  (let* ((result (dsh-bridge--request "POST" "/sessions/rename"
											  (list (cons 'sessionId id)
													(cons 'title title))))
				 (status (car result))
				 (alist (cdr result)))
			(if (eq status 200)
				(progn
				  (dsh-bridge--fetch-sessions)
				  (dsh-bridge--refresh-sessions-buffer)
				  (message "dsh-bridge: renamed session to %s" title))
			  (message "dsh-bridge: %s"
					   (dsh-bridge--error-message nil status alist)))))))))

(defun dsh-bridge-archive-session ()
  "Archive the session under point (one-way).
DSH has no unarchive at any layer, so this confirms first.	Works for live and
cold sessions alike."
  (interactive)
  (let ((id (tabulated-list-get-id)))
	(if (null id)
		(message "dsh-bridge: no session under point")
	  (let ((label (dsh-bridge--session-label id)))
		(if (not (y-or-n-p (format "Archive session %s?" label)))
			(message "dsh-bridge: aborted")
		  (let* ((result (dsh-bridge--request "POST" "/sessions/archive"
											  (list (cons 'sessionId id))))
				 (status (car result))
				 (alist (cdr result)))
			(if (eq status 200)
				(progn
				  (dsh-bridge--fetch-sessions)
				  (dsh-bridge--refresh-sessions-buffer)
				  (message "dsh-bridge: archived session %s" label))
			  (message "dsh-bridge: %s"
					   (dsh-bridge--error-message nil status alist)))))))))

(defun dsh-bridge-create-session ()
  "Create a new DSH session, optionally in a new workspace.
Completing-read over the host's workspaces plus a \"New workspace…\" entry; a
new workspace prompts for an existing directory (and an optional title).  The
prompted directory is expanded to a fully-qualified path before it is sent, so
a `~'-relative or relative answer is accepted.  The new session is bound as the
default target."
  (interactive)
  (let* ((wresult (dsh-bridge--request "GET" "/workspaces" nil))
		 (wstatus (car wresult))
		 (wlist (cdr wresult)))
	(if (not (eq wstatus 200))
		(message "dsh-bridge: %s"
				 (or (dsh-bridge--error-message nil wstatus wlist)
					 "failed to list workspaces"))
	  ;; An empty workspace list is a valid roster, not a failure: "New
	  ;; workspace…" is then the only choice.
	  (let* ((workspaces (cdr (assoc 'workspaces wlist)))
			 (labels (mapcar (lambda (w) (or (alist-get 'title w) (alist-get 'path w)))
							 workspaces))
			 (choice (completing-read "Create session in workspace: "
									  (append labels (list "New workspace…"))
									  nil t))
			 (is-new (equal choice "New workspace…"))
			 (workspaceId (and (not is-new)
							   (let ((match (seq-find (lambda (w)
														(equal (or (alist-get 'title w)
																   (alist-get 'path w))
																 choice))
													  workspaces)))
								 (and match (alist-get 'id match)))))
			 (new-path (and is-new (expand-file-name
									(read-directory-name "New workspace directory: ")))))
		(if (and is-new (not (file-directory-p new-path)))
			(user-error "dsh-bridge: %s is not an existing directory" new-path)
		  (let* ((workspaceTitle (and is-new
									  (let ((title (read-string "Workspace title (optional): ")))
										(and (not (string-empty-p title)) title))))
				 (payload (append (and workspaceId (list (cons 'workspaceId workspaceId)))
								  (and new-path (list (cons 'path new-path)))
								  (and workspaceTitle (list (cons 'workspaceTitle workspaceTitle)))))
				 (creates (dsh-bridge--request "POST" "/sessions/create" payload))
				 (cstatus (car creates))
				 (calist (cdr creates)))
			(if (eq cstatus 201)
				(let ((new-id (alist-get 'sessionId calist)))
				  (dsh-bridge--fetch-sessions)
				  (dsh-bridge--refresh-sessions-buffer)
				  (dsh-bridge-set-default-target new-id)
				  (message "dsh-bridge: created a new session"))
			  (message "dsh-bridge: %s"
					   (dsh-bridge--error-message nil cstatus calist)))))))))

(defun dsh-bridge-rename-workspace ()
  "Rename the workspace of the session under point.
The row's workspace id comes from the cached session; prompts for the new title
(default: the current workspace title)."
  (interactive)
  (let* ((id (tabulated-list-get-id))
		 (session (and id (dsh-bridge--session-for-id id)))
		 (workspaceId (and session (alist-get 'workspaceId session))))
	(if (null id)
		(message "dsh-bridge: no session under point")
	  (if (null workspaceId)
		  (message "dsh-bridge: session \"%s\" has no workspace to rename"
				   (dsh-bridge--session-label id))
		(let* ((current (or (alist-get 'workspace session) ""))
			   (title (read-string (format "Rename workspace %s to: " current) current)))
		  (if (string-empty-p title)
			  (message "dsh-bridge: empty title")
			(let* ((result (dsh-bridge--request "POST" "/workspaces/rename"
												(list (cons 'workspaceId workspaceId)
													  (cons 'title title))))
				   (status (car result))
				   (alist (cdr result)))
			  (if (eq status 200)
				  (progn
					(dsh-bridge--fetch-sessions)
					(dsh-bridge--refresh-sessions-buffer)
					(message "dsh-bridge: renamed workspace to %s" title))
				(message "dsh-bridge: %s"
						 (dsh-bridge--error-message nil status alist))))))))))

(defun dsh-bridge-copy-session-id ()
  "Copy the raw DSH session id under point to the kill ring."
  (interactive)
  (let ((id (tabulated-list-get-id)))
	(if id
		(progn
		  (kill-new id)
		  (message "dsh-bridge: copied session id %s" id))
	  (message "dsh-bridge: no session under point"))))

;;; Session report (DSH-Describe)

(defface dsh-bridge-describe-heading-face
  '((t :inherit bold))
  "Face for section headings in the DSH session report."
  :group 'dsh-bridge)

(defface dsh-bridge-describe-label-face
  '((t :inherit shadow))
  "Face for field labels in the DSH session report."
  :group 'dsh-bridge)

(defvar-local dsh-bridge--describe-session nil
  "The session id this DSH-Describe buffer reports, or nil.")

(define-derived-mode dsh-bridge-describe-mode help-mode "DSH-Describe"
  "Major mode for the read-only DSH session report.

The buffer is a `help-mode' buffer, so `q' quits, `g' re-fetches the
report, `l'/`r' walk the describe history (back/forward — Help mode's
keys, not the bridge's list-sessions/reply), `n'/`p' move between
sections, `TAB'/`S-TAB' move between buttons, and `RET'/`mouse-2'
follow the button at point.  Bridge commands: `w' copies the session
id, `f' opens the DSH-View for the session's latest turn, `o' opens the
DSH-Prompt buffer, `D' re-describes the session.")

(defvar dsh-bridge-describe-mode-map)
(define-key dsh-bridge-describe-mode-map (kbd "w") #'dsh-bridge--describe-copy-id)
(define-key dsh-bridge-describe-mode-map (kbd "f") #'dsh-bridge--describe-open-view)
(define-key dsh-bridge-describe-mode-map (kbd "o") #'dsh-bridge--describe-open-prompt)
(define-key dsh-bridge-describe-mode-map (kbd "D") #'revert-buffer)

(easy-menu-define dsh-bridge-describe-menu dsh-bridge-describe-mode-map
  "Menu bar menu for the `*dsh-bridge-describe*' buffer."
  '("DSH Bridge"
	["Copy Session Id" dsh-bridge--describe-copy-id
	 :help "Copy the described session's raw id"]
	["Open Prompt Buffer" dsh-bridge--describe-open-prompt
	 :help "Open a DSH-Prompt buffer for the described session"]
	["Latest Turn" dsh-bridge--describe-open-view
	 :help "Fetch the described session's latest turn into DSH-View"]
	"---"
	["Refresh Report" revert-buffer
	 :help "Re-fetch the session report"]
	["List Sessions" dsh-bridge-list-sessions
	 :help "Browse DSH sessions"]
	"---"
	["Quit Window" quit-window
	 :help "Dismiss this buffer"]))

(define-button-type 'dsh-bridge-describe-session-xref
  :supertype 'help-xref
  'help-function #'dsh-bridge-describe-session
  'help-echo "mouse-1/RET: describe this session")

(defun dsh-bridge--describe-string (value)
  "Return VALUE when it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun dsh-bridge--format-number (n)
  "Format number N with comma thousands separators; non-numbers -> \"—\"."
  (if (not (numberp n)) "—"
	(let* ((negative (< n 0))
		   (digits (number-to-string (abs (truncate n))))
		   (length (length digits))
		   (result ""))
	  (dotimes (index length)
		(setq result (concat (substring digits (- length index 1) (- length index))
							 (if (and (> index 0) (= 0 (% index 3))) "," "")
							 result)))
	  (concat (if negative "-" "") result))))

(defun dsh-bridge--format-duration (ms)
  "Format millisecond duration MS as \"450 ms\", \"12.3 s\", or \"2m 13.4s\"."
  (if (not (numberp ms)) "—"
	(let ((seconds (/ ms 1000.0)))
	  (cond
	   ((< ms 1000) (format "%.0f ms" ms))
	   ((< seconds 60) (format "%.1f s" seconds))
	   ((< seconds 3600)
		(format "%dm %04.1fs" (floor (/ seconds 60))
				(- seconds (* 60 (floor (/ seconds 60))))))
	   (t (format "%dh %dm" (floor (/ seconds 3600))
				  (floor (/ (% seconds 3600) 60))))))))

(defun dsh-bridge--format-percent (num den)
  "Format NUM/DEN as a percentage, or nil when DEN is not positive."
  (if (and (numberp num) (numberp den) (> den 0))
	  (format "%.1f%%" (* 100.0 (/ num (float den))))
	nil))

(defun dsh-bridge--format-time (ms)
  "Format ms-epoch MS as an absolute time plus its relative age; nil -> \"—\"."
  (if (numberp ms)
	  (concat (format-time-string "%Y-%m-%d %H:%M:%S" (/ ms 1000))
			  " (" (dsh-bridge--relative-age ms) ")")
	"—"))

(defun dsh-bridge--describe-section (title)
  "Insert a page separator and TITLE as a section heading.
The form feed makes `help-mode''s `n'/`p' walk the report's sections, and
its line is the single blank line between sections; the zero-width
`display' property keeps the `^L' glyph from showing."
  (unless (= (point) (point-min))
	(insert (propertize "\f" 'display "") "\n"))
  (insert (propertize title 'face 'dsh-bridge-describe-heading-face) "\n"))

(defun dsh-bridge--describe-row (label value &optional help)
  "Insert an aligned LABEL/VALUE row.
VALUE is a string or a function that inserts the value itself; HELP is
an optional `help-echo' string covering the value."
  (insert (propertize (format "  %-16s " label) 'face 'dsh-bridge-describe-label-face))
  (let ((beg (point)))
	(if (functionp value) (funcall value) (insert (format "%s" value)))
	(when help (put-text-property beg (point) 'help-echo help)))
  (insert "\n"))

(defun dsh-bridge--describe-button (label function &optional help)
  "Insert an action button LABEL that calls FUNCTION with no arguments."
  (insert-text-button label
					  'action (lambda (&rest _) (funcall function))
					  'follow-link t
					  'help-echo (or help (format "mouse-1/RET: %s" label))))

(defun dsh-bridge--describe-model-label (report)
  "The model display line for REPORT, or nil when no selection is known."
  (let* ((model (alist-get 'model report))
		 (name (dsh-bridge--describe-string (alist-get 'modelName report)))
		 (provider (dsh-bridge--describe-string (alist-get 'provider model)))
		 (id (dsh-bridge--describe-string (alist-get 'model model)))
		 (effort (dsh-bridge--describe-string (alist-get 'reasoningEffort model))))
	(when (or name provider id)
	  (concat (or name (if (and provider id) (format "%s/%s" provider id)
						 (or provider id)))
			  (and effort (format " (%s)" effort))))))

(defun dsh-bridge--describe-permission-label (report)
  "Return (NAME . DESCRIPTION) for REPORT's current permission, or nil."
  (let* ((permissions (alist-get 'permissions report))
		 (current (dsh-bridge--describe-string (alist-get 'currentValue permissions)))
		 (options (alist-get 'options permissions)))
	(when current
	  (let ((match (seq-find (lambda (option)
							   (equal (alist-get 'value option) current))
							 options)))
		(cons (or (dsh-bridge--describe-string (alist-get 'name match)) current)
			  (dsh-bridge--describe-string (alist-get 'description match)))))))

(defun dsh-bridge--describe-stats (report)
  "Insert the Stats section of REPORT."
  (dsh-bridge--describe-section "Stats")
  (let ((stats (alist-get 'stats report)))
	(if (not stats)
		(insert "  (unavailable)\n")
	  (let* ((ttft (alist-get 'ttftMs stats))
			 (ttft-steps (alist-get 'ttftSteps stats))
			 (decode-ms (alist-get 'decodeMs stats))
			 (decode-tokens (alist-get 'decodeTokens stats)))
		(dsh-bridge--describe-row
		 "Turns / steps"
		 (format "%s / %s" (dsh-bridge--format-number (alist-get 'turns stats))
				 (dsh-bridge--format-number (alist-get 'steps stats))))
		(dsh-bridge--describe-row "LLM time"
								  (dsh-bridge--format-duration (alist-get 'llmMs stats)))
		(dsh-bridge--describe-row "Tool time"
								  (dsh-bridge--format-duration (alist-get 'toolMs stats)))
		(dsh-bridge--describe-row
		 "First token"
		 (if (and (numberp ttft) (numberp ttft-steps) (> ttft-steps 0))
			 (format "%s avg over %s steps"
					 (dsh-bridge--format-duration (/ ttft (float ttft-steps)))
					 (dsh-bridge--format-number ttft-steps))
		   (dsh-bridge--format-duration ttft)))
		(dsh-bridge--describe-row
		 "Decode"
		 (concat (dsh-bridge--format-duration decode-ms)
				 (if (numberp decode-tokens)
					 (format " · %s tokens" (dsh-bridge--format-number decode-tokens))
				   "")
				 (if (and (numberp decode-tokens) (numberp decode-ms) (> decode-ms 0))
					 (format " · %.1f tok/s" (/ decode-tokens (/ decode-ms 1000.0)))
				   "")))))))

(defun dsh-bridge--describe-tokens (report)
  "Insert the Tokens section of REPORT."
  (dsh-bridge--describe-section "Tokens")
  (let ((tokens (alist-get 'tokens report)))
	(if (not tokens)
		(insert "  (unavailable)\n")
	  (let ((uncached (alist-get 'uncachedInputTokens tokens))
			(cache-read (alist-get 'cacheReadTokens tokens)))
		(dsh-bridge--describe-row "Input (uncached)" (dsh-bridge--format-number uncached))
		(dsh-bridge--describe-row "Output"
								  (dsh-bridge--format-number (alist-get 'outputTokens tokens)))
		(dsh-bridge--describe-row "Cache read" (dsh-bridge--format-number cache-read))
		(dsh-bridge--describe-row "Cache write"
								  (dsh-bridge--format-number (alist-get 'cacheWriteTokens tokens)))
		(dsh-bridge--describe-row
		 "Cache hit"
		 (or (dsh-bridge--format-percent
			  cache-read
			  (and (numberp uncached) (numberp cache-read) (+ uncached cache-read)))
			 "—"))))))

(defun dsh-bridge--describe-context (report)
  "Insert the Context section of REPORT."
  (dsh-bridge--describe-section "Context")
  (let ((context (alist-get 'context report)))
	(if (not context)
		(insert "  (unavailable)\n")
	  (let ((next (or (alist-get 'projectedTokens context)
					  (alist-get 'pressureTokens context)))
			(window (alist-get 'contextWindow context))
			(breakdown (alist-get 'breakdown report)))
		(dsh-bridge--describe-row
		 "Next request"
		 (if (numberp next)
			 (concat (dsh-bridge--format-number next)
					 (if (numberp window)
						 (format " / %s" (dsh-bridge--format-number window))
					   "")
					 (let ((percent (dsh-bridge--format-percent next window)))
					   (if percent (format " (%s)" percent) "")))
		   "—"))
		(dsh-bridge--describe-row "Last request"
								  (dsh-bridge--format-number (alist-get 'pressureTokens context)))
		(when breakdown
		  (dsh-bridge--describe-row
		   "Breakdown"
		   (format "system %s · tools %s · messages %s"
				   (dsh-bridge--format-number (alist-get 'systemTokens breakdown))
				   (dsh-bridge--format-number (alist-get 'toolsTokens breakdown))
				   (dsh-bridge--format-number (alist-get 'messageTokens breakdown)))))))))

(defun dsh-bridge--describe-actions (id)
  "Insert the Actions section for session ID."
  (dsh-bridge--describe-section "Actions")
  (insert "  ")
  (dsh-bridge--describe-button "[Open prompt]"
							   (lambda () (dsh-bridge--describe-open-prompt id)))
  (insert "  ")
  (dsh-bridge--describe-button "[Latest turn]"
							   (lambda () (dsh-bridge--describe-open-view id)))
  (insert "  ")
  (dsh-bridge--describe-button "[List sessions]" #'dsh-bridge-list-sessions)
  (insert "  ")
  (dsh-bridge--describe-button "[Copy id]"
							   (lambda () (dsh-bridge--describe-copy-id id)))
  (insert "\n"))

(defun dsh-bridge--describe-insert (id session status alist)
  "Insert the report body for session ID (nil when unknown).
SESSION is the cached session row or nil; STATUS and ALIST are the
`/session' response.  A non-200 STATUS renders the cached facts plus the
failure reason, never a fake zero."
  (let* ((report (and (eq status 200) (listp alist) alist))
		 (failure (unless report
					(or (dsh-bridge--error-message nil status alist)
						"request failed or timed out")))
		 (title (or (dsh-bridge--describe-string (alist-get 'title report))
					(dsh-bridge--session-title session)
					"[Untitled Session]"))
		 (live (if report (eq (alist-get 'live report) t)
				 (and session (alist-get 'live session))))
		 (running (and report (eq (alist-get 'running report) t)))
		 (cwd (or (dsh-bridge--describe-string (alist-get 'cwd report))
				  (dsh-bridge--describe-string (alist-get 'cwd session))))
		 (workspace (dsh-bridge--describe-string (alist-get 'workspace report)))
		 (created (or (alist-get 'createdAt report) (alist-get 'createdAt session)))
		 (last-active (or (alist-get 'lastActive report)
						  (alist-get 'lastActive session)))
		 (parent (dsh-bridge--describe-string (alist-get 'parentSession report)))
		 (preset (dsh-bridge--describe-string (alist-get 'agentPreset report)))
		 (model (dsh-bridge--describe-model-label report))
		 (permissions (dsh-bridge--describe-permission-label report)))
	(insert (propertize (format "DSH session %s" title)
						'face 'dsh-bridge-describe-heading-face)
			"\n\n")
	(when failure
	  (insert (propertize (format "  Report unavailable: %s\n" failure) 'face 'error)))
	(dsh-bridge--describe-row
	 "Id"
	 (lambda ()
	   (if id
		   (dsh-bridge--describe-button id (lambda () (dsh-bridge--describe-copy-id id))
										"mouse-1/RET: copy the session id")
		 (insert "(unknown)")))
	 "The raw DSH session id")
	(dsh-bridge--describe-row "State" (format "%s%s" (if live "live" "saved")
											  (if running " · running" "")))
	(dsh-bridge--describe-row "Created" (dsh-bridge--format-time created))
	(dsh-bridge--describe-row "Last prompt"
							  (dsh-bridge--format-time (alist-get 'lastPromptAt report)))
	(dsh-bridge--describe-row "Last active" (dsh-bridge--format-time last-active))
	(dsh-bridge--describe-row
	 "Directory"
	 (if cwd
		 (lambda ()
		   (dsh-bridge--describe-button cwd
										(lambda () (dsh-bridge--describe-open-directory cwd))))
	   "—")
	 cwd)
	(when workspace
	  (dsh-bridge--describe-row
	   "Workspace"
	   (lambda ()
		 (dsh-bridge--describe-button workspace
									  (lambda () (dsh-bridge--describe-open-directory cwd))))))
	(dsh-bridge--describe-row "Preset" (or preset "—"))
	(dsh-bridge--describe-row
	 "Model"
	 (if model
		 (lambda ()
		   (dsh-bridge--describe-button
			model (lambda () (dsh-bridge--describe-open-prompt id))
			"mouse-1/RET: open the prompt buffer (C-c C-m changes the model)"))
	   "default"))
	(dsh-bridge--describe-row "Permissions"
							  (if permissions (car permissions) "—")
							  (cdr permissions))
	(when parent
	  (dsh-bridge--describe-row
	   "Forked from"
	   (lambda ()
		 (help-insert-xref-button parent 'dsh-bridge-describe-session-xref parent))))
	(when (eq (alist-get 'isSeeded report) t)
	  (dsh-bridge--describe-row "Seeded" "yes"))
	(dsh-bridge--describe-stats report)
	(dsh-bridge--describe-tokens report)
	(dsh-bridge--describe-context report)
	(dsh-bridge--describe-actions id)))

(defun dsh-bridge--describe-copy-id (&optional id)
  "Copy the described session's raw id to the kill ring."
  (interactive)
  (let ((id (or id dsh-bridge--describe-session)))
	(if id
		(progn (kill-new id) (message "dsh-bridge: copied session id %s" id))
	  (message "dsh-bridge: no session"))))

(defun dsh-bridge--describe-open-directory (directory)
  "Open DIRECTORY in Dired, or as a file when it is not a directory."
  (interactive "DDirectory: ")
  (if (and (stringp directory) (not (string-empty-p directory)))
	  (if (file-directory-p directory) (dired directory) (find-file directory))
	(message "dsh-bridge: no directory recorded")))

(defun dsh-bridge--describe-open-prompt (&optional id)
  "Open the DSH-Prompt buffer for the described session."
  (interactive)
  (let ((id (or id dsh-bridge--describe-session)))
	(if id
		(pop-to-buffer (dsh-bridge--prompt-buffer id) dsh-bridge-prompt-display-action)
	  (message "dsh-bridge: no session"))))

(defun dsh-bridge--describe-open-view (&optional id)
  "Fetch the described session's latest turn into a DSH-View buffer."
  (interactive)
  (let ((id (or id dsh-bridge--describe-session)))
	(if id (dsh-bridge-fetch id) (message "dsh-bridge: no session"))))

;;;###autoload
(defun dsh-bridge-describe-session-at-mouse (event)
  "Describe the session named by the clicked header-line label in EVENT."
  (interactive "e")
  ;; A header-line click's position names no buffer point (`posn-point' is
  ;; nil there); the id travels on the clicked string.
  (let* ((position (event-start event))
	 (string-pos (and position (posn-string position)))
	 (id (and string-pos
		  (get-text-property (cdr string-pos)
					 'dsh-bridge-session-id
					 (car string-pos)))))
	(if id
		(dsh-bridge-describe-session id)
	  (message "dsh-bridge: no session under the mouse"))))

;;;###autoload
(defun dsh-bridge-describe-session (&optional session-id)
  "Show a read-only report for SESSION-ID.
Interactively, use the DSH-Sessions row at point, else the buffer's
effective session; with a prefix argument, prompt for any session id.
The report is a `help-mode' buffer: `g' re-fetches it, `l'/`r' walk the
describe history, and the session label in a DSH-View/DSH-Prompt header
line opens it with a mouse click.  A cold session is read from its
persisted log and is never resumed."
  (interactive
   (list (cond
		  ((and current-prefix-arg (eq major-mode 'dsh-bridge-sessions-mode))
		   (or (tabulated-list-get-id)
			   (dsh-bridge--read-session-id "Describe session: ")))
		  (current-prefix-arg
		   (dsh-bridge--read-session-id "Describe session: "))
		  ((eq major-mode 'dsh-bridge-sessions-mode)
		   (tabulated-list-get-id))
		  (t (dsh-bridge--effective-session)))))
  (let* ((result (let ((dsh-bridge-timeout dsh-bridge-describe-timeout))
				   (dsh-bridge--request "GET" (dsh-bridge--path "/session" session-id) nil)))
		 (status (car result))
		 (alist (cdr result))
		 (report (and (eq status 200) (listp alist) alist))
		 (id (or (and report (dsh-bridge--describe-string (alist-get 'sessionId report)))
				 session-id
				 (car-safe dsh-bridge--last-resolved-active)))
		 (session (and id (dsh-bridge--session-for-id id)))
		 (buffer (get-buffer-create dsh-bridge-describe-buffer-name))
		 (here (eq (current-buffer) buffer)))
	(with-current-buffer buffer
	  (unless (derived-mode-p 'help-mode)
		(dsh-bridge-describe-mode))
	  ;; `help-buffer' returns THIS buffer only when `help-xref-following'
	  ;; is non-nil AND the buffer is already help-mode-derived, and
	  ;; `help-setup-xref' must run before `erase-buffer' because it records
	  ;; point for the [back] button.
	  (let ((inhibit-read-only t)
			(help-xref-following t))
		(help-setup-xref (list #'dsh-bridge-describe-session id)
						 (called-interactively-p 'interactive))
		(erase-buffer)
		(setq-local dsh-bridge--describe-session id)
		(dsh-bridge--describe-insert id session status alist)
		(help-make-xrefs (current-buffer)))
	  (goto-char (point-min)))
	(unless here
	  (pop-to-buffer buffer))))


(defun dsh-bridge--list-sessions-in-buffer ()
  "Fill `*dsh-bridge-sessions*' with the current session roster.
Return non-nil if the roster was fetched.  If the fetch fails, leave the
DSH-Sessions buffer untouched and return nil."
  (let ((fetch (dsh-bridge--fetch-sessions)))
	(when (eq (car fetch) 200)
	  (let ((visible (seq-filter #'dsh-bridge--session-visible-p
								 (cdr fetch))))
		(with-current-buffer (get-buffer-create "*dsh-bridge-sessions*")
		  (unless (eq major-mode 'dsh-bridge-sessions-mode)
			(dsh-bridge-sessions-mode))
		  ;; Override tabulated-list's re-print-only revert: `g' must
		  ;; re-fetch the session list from the host.
		  (setq-local revert-buffer-function
					  (lambda (&rest _) (dsh-bridge--list-sessions-in-buffer)))
		  (setq tabulated-list-format (dsh-bridge--sessions-format))
		  (setq tabulated-list-sort-key '("Age" . t))
		  (setq tabulated-list-entries
				(mapcar #'dsh-bridge--session-entry visible))
		  (tabulated-list-init-header)
		  ;; REMEMBER-POS: entry ids are session ids, so an auto-refresh or
		  ;; post-mutation reprint keeps point on the same session's row.
		  (tabulated-list-print t))
		t))))

(defun dsh-bridge--refresh-sessions-buffer ()
  "Re-render `*dsh-bridge-sessions*' in place if it is live."
  (when (buffer-live-p (get-buffer "*dsh-bridge-sessions*"))
	(with-current-buffer "*dsh-bridge-sessions*"
	  (when (eq major-mode 'dsh-bridge-sessions-mode)
		(dsh-bridge--list-sessions-in-buffer)))))

(defun dsh-bridge--sessions-format ()
  "The `tabulated-list-format' for the sessions buffer.
The status column is two columns wide under the `emoji' indicator: emoji
glyphs are double-width, and in a one-column cell `tabulated-list-print-col'
would cover the glyph with an ellipsis `display' property."
  (let ((format (vector (list "*" 1 t)
						(list "?" (if (eq dsh-bridge-status-indicator 'emoji) 2 1) t)
						(list "Session" 40 t)
						(list "Age" 8 'dsh-bridge--age-sorter)
						(list "Workspace" 0 t))))
	(if dsh-bridge-show-session-ids
		(vconcat format [("Id" 40 t)])
	  format)))

(defun dsh-bridge--sessions-entries ()
  "`tabulated-list-entries' for the current sessions cache.
Reads `dsh-bridge--sessions-cache' only, without contacting the host, so it is
safe for a display refresh (e.g. after `dsh-bridge-status-indicator' changes)."
  (mapcar #'dsh-bridge--session-entry
		  (seq-filter #'dsh-bridge--session-visible-p dsh-bridge--sessions-cache)))

(defun dsh-bridge--refresh-status-display ()
  "Re-render status indicators in open bridge buffers.
The `:set' action of `dsh-bridge-status-indicator': changing the indicator
style updates an open DSH-Sessions list and the DSH-View header immediately
(the DSH-Prompt header is `(:eval ...)' and re-renders on redisplay).  Reads
the sessions cache only; never hits the host."
  (dsh-bridge--refresh-view-headers)
  (when (buffer-live-p (get-buffer "*dsh-bridge-sessions*"))
	(with-current-buffer "*dsh-bridge-sessions*"
	  (when (eq major-mode 'dsh-bridge-sessions-mode)
		;; The status column's width depends on the indicator style, so the
		;; format (and its rendered header) must be recomputed too.
		(setq tabulated-list-format (dsh-bridge--sessions-format))
		(tabulated-list-init-header)
		(setq tabulated-list-entries (dsh-bridge--sessions-entries))
		(tabulated-list-print t)))))

;;; Turn events and status re-rendering

(defun dsh-bridge--status-event-render (session-id)
  "Re-render surfaces showing SESSION-ID after a tracker change.
Each DSH-View buffer showing this session re-renders its header; the
sessions list re-prints only the affected row.  The prompt buffer's
`(:eval)' header repaints on the next redisplay; `force-mode-line-update'
ensures that paint lands in the same tick as the other surfaces."
  (dolist (buf (dsh-bridge--session-views session-id))
	(with-current-buffer buf
	  (setq header-line-format (dsh-bridge--view-header-line))))
  (dsh-bridge--view-ticker-ensure)
  (when (buffer-live-p (get-buffer "*dsh-bridge-sessions*"))
	(with-current-buffer "*dsh-bridge-sessions*"
	  (when (eq major-mode 'dsh-bridge-sessions-mode)
		(dsh-bridge--status-reprint-row session-id)))))
  ;; Redraw header/mode lines immediately so the prompt buffer's `(:eval)'
  ;; header picks the tracker change up in the same paint (not just on the next
  ;; unrelated redisplay).
  (force-mode-line-update t)

(defun dsh-bridge--status-reprint-row (session-id)
  "Re-print only the sessions-list row for SESSION-ID from the tracker.
Updates that row's entry in `tabulated-list-entries' and re-displays without
re-fetching (the sessions buffer would otherwise stay stale until `g').  The
print re-sorts by the active `Age' key (so a just-updated timestamp moves the
row) and passes REMEMBER-POS so point follows the session id when it does.
The full (non-UPDATE) print is deliberate: `tabulated-list-print''s UPDATE
path skips re-rendering a row whose id is already in place, so a changed
status/age cell on a row that does not move would otherwise never repaint."
  (let* ((session (dsh-bridge--session-for-id session-id))
		 (idx (seq-position tabulated-list-entries session-id
							(lambda (entry id) (equal (car entry) id)))))
	(when (and session idx)
	  (setf (nth idx tabulated-list-entries)
			(dsh-bridge--session-entry session))
	  (tabulated-list-print t))))

(defun dsh-bridge--view-cycling-p (&optional buffer)
  "Whether BUFFER (default: the current buffer) is a DSH-View mid M-p/M-n
turn cycling."
  (let ((buf (or buffer (current-buffer))))
	(and (buffer-live-p buf)
		 (with-current-buffer buf
		   (and (eq major-mode 'dsh-bridge-view-mode)
				dsh-bridge--view-turn-index)))))

(defun dsh-bridge--turn-reason-phrase (session-id reason)
  "A human phrase for SESSION-ID's completed turn given the REASON kind string."
  (let ((verb (pcase reason
				("completed" "finished")
				("aborted" "interrupted")
				("error" "failed")
				("max-tokens" "stopped at the token limit")
				("blocked" "blocked")
				(_ "ended"))))
	(format "session \"%s\" %s"
			(dsh-bridge--session-label session-id)
			verb)))

(defun dsh-bridge--turn-complete-act (session-id reason)
  "Update cache and inform the user after a turn ends.
SESSION-ID is the session id for the ended session, and REASON is a
string is a string describing how/why it ended.

This function runs the actions prescribed by `dsh-bridge-turn-complete',
then emits a message if `dsh-bridge-turn-boundary-echo' is non-nil."
  (if (and (eq dsh-bridge-turn-complete 'refetch)
		   (dsh-bridge--session-view session-id)
		   (not (seq-some #'dsh-bridge--view-cycling-p
						  (dsh-bridge--session-views session-id))))
	  (run-at-time 0 nil #'dsh-bridge--turn-complete-refetch session-id)
	(run-at-time 0 nil #'dsh-bridge--view-turns-cache-refresh session-id))
  (when dsh-bridge-turn-boundary-echo
	(message "dsh-bridge: %s"
			 (dsh-bridge--turn-reason-phrase session-id reason))))

(defun dsh-bridge--turn-complete-refetch (session-id)
  "Refill DSH-View buffers showing SESSION-ID's completed turn, without popping.
A non-popping fill (the user may be editing elsewhere); drops the session's
status entry on a 404 (the session died).  Fetches `GET /dsh-bridge/turns'
once, stores the fresh list, and re-renders each shown, non-cycling view from
its newest turn — the `(continuing...)' marker disappears now that `endedAt'
is known, so the completed turn ends cleanly (point is preserved when the
content merely changed in place)."
  (dsh-bridge--call "GET" (dsh-bridge--path "/turns" session-id) nil
	(lambda (status body http-status)
	  (let* ((alist (dsh-bridge--parse-json-body body))
			 (err (dsh-bridge--error-message status http-status alist)))
		(if err
			(when (eq http-status 404)
			  ;; Forget SESSION-ID's tracked status.
			  (setq dsh-bridge--session-status
					(assoc-delete-all session-id dsh-bridge--session-status)))
		  (let* ((shown-id (or (alist-get 'sessionId alist) session-id))
				 (turns-pair (assoc 'turns alist))
				 (turns (cdr turns-pair))
				 (views (dsh-bridge--session-views shown-id)))
			;; Field presence, not truthiness: an explicit empty `turns'
			;; list (no turns, e.g. after a full compaction) replaces the
			;; stale cache entry, and the response's `epoch' is recorded
			;; for later incremental fetches.
			(when turns-pair
			  (dsh-bridge--turns-cache-store shown-id turns
											 (alist-get 'epoch alist)))
			;; Only refill if a view still shows this session and the user
			;; has not started turn-cycling since the event (the cycling
			;; check at event time does not cover the timer delay).
			(when (and views
					   (not (seq-some #'dsh-bridge--view-cycling-p views)))
			  ;; Seed the tracker only when the response carries `running';
			  ;; JSON `false' decodes to nil, `true' to t (see
			  ;; `dsh-bridge--parse-json-body') — compare against t, never
			  ;; truthiness.
			  (let ((running-pair (assoc 'running alist)))
				(when running-pair
				  (dsh-bridge--status-set shown-id
										  (if (eq (cdr running-pair) t)
											  'running 'idle))))
			  ;; One `/turns' fetch serves every refilled view.
			  (let ((newest (car-safe turns)))
				(dolist (buf views)
				  (with-current-buffer buf
					(if dsh-bridge--view-waiting
						;; A sent turn just completed.  A newer turn's content
						;; would have refilled the view already via
						;; `replies-changed'; here, accept only genuinely
						;; newer content, else the turn was textless — clear
						;; to blank (idle) rather than resurrecting the
						;; abandoned turn.
						(if (dsh-bridge--view-waiting-accept-p
							 (and newest (alist-get 'turn newest)))
							(progn
							  (dsh-bridge--view-fill shown-id newest nil nil t t)
							  (setq-local dsh-bridge--view-waiting nil))
						  (dsh-bridge--view-fill shown-id nil nil nil t)
						  (setq-local dsh-bridge--view-waiting nil))
					  (when newest
						(dsh-bridge--view-fill shown-id newest nil nil t t)))))))))))))

;;;###autoload
(defun dsh-bridge-list-sessions ()
  "List DSH sessions in a tabulated buffer.
In the session list: `RET' opens the session under point (resuming a saved
session on demand; the default target is untouched), `t' sets the default
target, `u' clears it, `f' peeks the session's latest turn, `v' toggles
archived-session visibility, `R' renames the session, `d' archives it, `+'
creates a session, `W' renames the row's workspace, `w' copies the session id,
`D' shows session details, `g' re-fetches, `S' sorts by column.	 Legend: `*' =
default target, `…' = running."
  (interactive)
  (if (dsh-bridge--list-sessions-in-buffer)
	  (pop-to-buffer "*dsh-bridge-sessions*")
	(message "dsh-bridge: failed to fetch sessions")))

;;; The dispatcher

;;;###autoload
(transient-define-prefix dsh-bridge ()
  "Dispatch DSH bridge actions.
The header shows the effective session of the buffer the dispatcher was
invoked from; the verbs act on it.	`s' sends the region or buffer as a
prompt, `d' sends it as a draft, `r' opens the prompt buffer for the
effective session, `f' fetches the latest turn, `t' sets the default target,
`u' clears it, `l' lists sessions."
  dsh-bridge--dispatcher-layout)

;;; Menu bar (under Tools)

(defvar dsh-bridge-menu
  (easy-menu-create-menu
   "DSH Bridge"
   '(["DSH Bridge Dispatcher" dsh-bridge
	  :help "Open the DSH bridge dispatcher"]
	 ["List Sessions" dsh-bridge-list-sessions
	  :help "Browse DSH sessions in a tabulated list"]
	 "---"
	 ["Edit Prompt Buffer" dsh-bridge-prompt
	  :help "Pop to the DSH prompt buffer"]
	 ["Send Region or Buffer" dsh-bridge-send
	  :help "Send the region (or whole buffer) to DSH as a prompt"]
	 "---"
	 ["Fetch Latest Turn" dsh-bridge-fetch
	  :help "Fetch the latest assistant turn into a DSH-View buffer"]
	 ["Describe Session" dsh-bridge-describe-session
	  :help "Show a read-only report for a session"]
	 ["Receive Message…" dsh-bridge-receive
	  :help "Receive the latest message sent from DSH to Emacs"]
	 ["Set Default Target Session" dsh-bridge-set-default-target
	  :help "Set or clear the default DSH target session"]))
  "DSH Bridge menu, installed under Tools.")

(easy-menu-add-item nil '("Tools") dsh-bridge-menu)

(provide 'dsh-bridge)

;;; dsh-bridge.el ends here
