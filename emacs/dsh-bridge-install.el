;;; dsh-bridge-install.el --- DSH plugin install/uninstall for dsh-bridge  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Optional companion library to `dsh-bridge', implementing commands
;; to install, uninstall, and diagnose the `dsh-emacs-bridge' plugin.
;; The rest of the package talks to DSH over loopback and works
;; without this file; the function `dsh-bridge--ensure-plugin' loads
;; this library on demand when the bridge is not running, and
;; `dsh-bridge-install-plugin' / `dsh-bridge-uninstall-plugin' are
;; autoloaded from here.

;; During plugin installation, we must run the dsh executable.  By
;; default, we try to find it automatically; if this does not work
;; (usually because dsh is installed in a non-standard location),
;; customize `dsh-bridge-dsh-command'.

;;; Code:

(require 'dsh-bridge)

;;; Customize options

;;;###autoload
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

;;;###autoload
(defcustom dsh-bridge-profile "web"
  "DSH profile that `dsh-bridge-install-plugin' installs into."
  :type 'string
  :group 'dsh-bridge)

;;; DSH executable detection

(defun dsh-bridge--detect-npm-launcher ()
  "Helper function to auto-detect an npm command to launch `dsh'."
  (let ((npm (executable-find "npm"))
		prefix)
	(and npm
		 (setq prefix (ignore-errors
						(car (process-lines npm "prefix" "-g"))))
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

;;; Plugin install state

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
	 ((and (file-readable-p
			(setq manifest (expand-file-name "package.json" dir)))
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

;;; Plugin diagnosis

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

(defun dsh-bridge-install--diagnose (state)
  "Diagnose an absent or mismatched DSH bridge plugin, offering to install.
STATE is the value of `dsh-bridge--bridge-status' and is never `running'.
The caller `dsh-bridge--ensure-plugin' has already latched
`dsh-bridge--plugin-diagnosed'."
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
		(user-error "dsh bridge: no DSH installation found")))))))

;;; Install or uninstall the DSH plugin

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


(provide 'dsh-bridge-install)

;;; dsh-bridge-install.el ends here
