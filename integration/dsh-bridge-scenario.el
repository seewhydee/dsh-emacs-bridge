;;; dsh-bridge-scenario.el — interactive UX scenario runner for the fixture. -*- lexical-binding: t -*-
;;; Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
;;;
;;; This program is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see <https://www.gnu.org/licenses/>.
;;;
;;; The human layer for the integration framework: drives the SAME fixture the
;;; Vitest and ERT layers do, but from a live Emacs, so you can iterate on the
;;; DSH-View / prompt composer / sessions-list UX without a real model.  Not
;;; autoloaded, not packaged:
;;;
;;;   emacs -Q -l integration/dsh-bridge-scenario.el
;;;   M-x dsh-bridge-scenario-run
;;;
;;; The scenario buffer lists the review steps; `n' executes the current step's
;;; scripted action and advances, `p' goes back, `r' re-runs the action, `q'
;;; quits (offering to kill the fixture).

;;; Code:

(require 'json)
(require 'cl-lib)

;; This file's directory, captured AT LOAD TIME: `load-file-name' and
;; `buffer-file-name' are unreliable (or nil) when a command runs later, so
;; paths computed inside function bodies from those variables break.
(defconst dsh-bridge-scenario--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding this file (the repo's integration/ directory).")

;; The repo's Emacs package, so byte-compilation and a fresh `emacs` run know
;; the dsh-bridge symbols. This file lives in integration/, so emacs/ is one
;; directory up.
(add-to-list 'load-path (expand-file-name "../emacs" dsh-bridge-scenario--directory))
(require 'dsh-bridge)

(defgroup dsh-bridge-scenario nil
  "Interactive scenario runner for the dsh-emacs-bridge integration fixture."
  :group 'dsh-bridge)

(defconst dsh-bridge-scenario--step-keys
  '(("n" . "Next step") ("p" . "Previous step") ("r" . "Redo action")
    ("q" . "Quit (kill fixture)"))
  "Key -> description pairs shown in the scenario buffer.")

(defvar-local dsh-bridge-scenario--steps nil "The scenario's step vector.")
(defvar-local dsh-bridge-scenario--index 0 "Current step index.")
(defvar-local dsh-bridge-scenario--scenario nil "Current scenario data alist.")
(defvar dsh-bridge-scenario--fixture-proc nil "The fixture launcher process, or nil.")
(defvar dsh-bridge-scenario--fixture-output "" "Accumulated fixture launcher stdout.")
(defvar dsh-bridge-scenario--session-id nil
  "The fixture session this run drives, created at boot.")

(defun dsh-bridge-scenario--fixture-filter (_proc string)
  "Accumulate the fixture launcher's stdout STRING."
  (setq dsh-bridge-scenario--fixture-output
        (concat dsh-bridge-scenario--fixture-output string)))

(defun dsh-bridge-scenario--fixture-json ()
  "Parse the fixture marker line, or nil."
  (when (string-match "^FIXTURE_JSON \\(.+\\)$" dsh-bridge-scenario--fixture-output)
    (json-parse-string (match-string 1 dsh-bridge-scenario--fixture-output)
                       :object-type 'alist)))

(defun dsh-bridge-scenario--launch-path ()
  "Absolute path to the fixture launcher CLI."
  (expand-file-name "host/launch.mjs" dsh-bridge-scenario--directory))

(defun dsh-bridge-scenario--boot-fixture (&optional reset)
  "Boot (or, if RESET, reboot) the fixture and return its facts alist."
  (when (and reset dsh-bridge-scenario--fixture-proc
             (process-live-p dsh-bridge-scenario--fixture-proc))
    (signal-process (process-id dsh-bridge-scenario--fixture-proc) 'SIGTERM)
    (setq dsh-bridge-scenario--fixture-proc nil))
  (setq dsh-bridge-scenario--fixture-output "")
  (let ((proc (make-process
               :name "dsh-bridge-scenario-fixture"
               :command (list "node" (dsh-bridge-scenario--launch-path))
               :connection-type 'pipe
               :filter #'dsh-bridge-scenario--fixture-filter
               :noquery t
               :stderr (get-buffer-create "*dsh-bridge-scenario-stderr*"))))
    (setq dsh-bridge-scenario--fixture-proc proc)
    (let ((deadline (+ (float-time) 120)) facts)
      (while (and (null (setq facts (dsh-bridge-scenario--fixture-json)))
                  (< (float-time) deadline)
                  (process-live-p proc))
        (accept-process-output proc 0.5)
        (sleep-for 0.2))
      (unless facts (error "dsh-bridge-scenario: fixture did not report facts"))
      facts)))

(defun dsh-bridge-scenario--read-scenarios ()
  "Return the list of scenario files under integration/scenarios."
  (directory-files (expand-file-name "scenarios" dsh-bridge-scenario--directory)
                   t "\\.json\\'"))

(defun dsh-bridge-scenario--load-scenario (file)
  "Read the scenario FILE into an alist."
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-string (buffer-string) :object-type 'alist)))

(defun dsh-bridge-scenario--base-url ()
  "The fixture base URL (dsh-bridge-url minus the /dsh-bridge suffix)."
  (string-remove-suffix "/dsh-bridge" dsh-bridge-url))

(defun dsh-bridge-scenario--post (path body)
  "POST BODY (JSON-encodable) to PATH on the fixture; return the parsed alist.
The bearer token comes from `dsh-bridge-token-file', which
`dsh-bridge-scenario-run' points at the fixture's home."
  (require 'url)
  (let* ((url (concat (dsh-bridge-scenario--base-url) path))
         (url-request-method "POST")
         (url-request-extra-headers
          (list (cons "Content-Type" "application/json")
                (cons "Authorization"
                      (concat "Bearer "
                              (string-trim
                               (with-temp-buffer
                                 (insert-file-contents dsh-bridge-token-file)
                                 (buffer-string)))))))
         (url-request-data (json-encode body))
         (buffer (url-retrieve-synchronously url)))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          ;; url.el leaves CRLF header endings in the buffer (same reason
          ;; dsh-bridge.el matches "\r?\n\r?\n").
          (re-search-forward "\r?\n\r?\n")
          (json-parse-string (buffer-substring-no-properties (point) (point-max))
                             :object-type 'alist))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun dsh-bridge-scenario--script-mock (script)
  "Replace the mock LLM queue with SCRIPT (a vector of entry alists) via HTTP."
  (dsh-bridge-scenario--post "/mock-llm/script" (list :script script)))

(defun dsh-bridge-scenario--create-session ()
  "Create a fixture session in a workspace at the repo root; return its id."
  (let ((body (dsh-bridge-scenario--post
               "/dsh-bridge/sessions/create"
               (list :path (expand-file-name "../" dsh-bridge-scenario--directory)))))
    (or (alist-get 'sessionId body)
        (error "dsh-bridge-scenario: create-session failed: %s" body))))

(defun dsh-bridge-scenario--step-action (step)
  "Execute STEP's action (push the mock script / send the prompt)."
  (let ((kind (alist-get 'action step)))
    (pcase kind
      ("send"
       (dsh-bridge-scenario--script-mock
        (alist-get 'mockScript dsh-bridge-scenario--scenario))
       (dsh-bridge-send-text (alist-get 'text step)
                             dsh-bridge-scenario--session-id))
      ("push-script"
       (dsh-bridge-scenario--script-mock
        (alist-get 'mockScript dsh-bridge-scenario--scenario)))
      (_ (message "dsh-bridge-scenario: unknown action %S" kind)))))

(defun dsh-bridge-scenario--render ()
  "Render the scenario buffer from the current step index."
  (let ((buffer (get-buffer-create "*dsh-bridge-scenario*")))
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert (format "Scenario: %s\n%s\n\n"
                      (alist-get 'name dsh-bridge-scenario--scenario)
                      (alist-get 'description dsh-bridge-scenario--scenario)))
      (insert (format "Steps (step %d of %d)\n=========\n"
                      (1+ dsh-bridge-scenario--index)
                      (length dsh-bridge-scenario--steps)))
      (dotimes (i (length dsh-bridge-scenario--steps))
        (let* ((step (aref dsh-bridge-scenario--steps i))
               (marker (if (= i dsh-bridge-scenario--index) ">>" "  "))
               (observe (or (alist-get 'observe step) "")))
          (insert (format "%s %d. %s\n" marker (1+ i) observe))))
      (insert "\nKeys:\n")
      (dolist (k dsh-bridge-scenario--step-keys)
        (insert (format "  %s  %s\n" (car k) (cdr k))))
      (setq buffer-read-only t)
      (use-local-map (let ((map (make-sparse-keymap)))
                       (define-key map (kbd "n") #'dsh-bridge-scenario-next)
                       (define-key map (kbd "p") #'dsh-bridge-scenario-prev)
                       (define-key map (kbd "r") #'dsh-bridge-scenario-redo)
                       (define-key map (kbd "q") #'dsh-bridge-scenario-quit)
                       map)))
    (pop-to-buffer buffer)))

(defun dsh-bridge-scenario-next ()
  "Execute the current step's action and advance."
  (interactive)
  (when (< dsh-bridge-scenario--index (length dsh-bridge-scenario--steps))
    (dsh-bridge-scenario--step-action (aref dsh-bridge-scenario--steps dsh-bridge-scenario--index))
    (setq dsh-bridge-scenario--index (min (1+ dsh-bridge-scenario--index)
                                          (length dsh-bridge-scenario--steps)))
    (dsh-bridge-scenario--render)))

(defun dsh-bridge-scenario-prev ()
  "Move to the previous step without re-running its action."
  (interactive)
  (setq dsh-bridge-scenario--index (max 0 (1- dsh-bridge-scenario--index)))
  (dsh-bridge-scenario--render))

(defun dsh-bridge-scenario-redo ()
  "Re-run the current step's action."
  (interactive)
  (when (< dsh-bridge-scenario--index (length dsh-bridge-scenario--steps))
    (dsh-bridge-scenario--step-action (aref dsh-bridge-scenario--steps dsh-bridge-scenario--index))
    (dsh-bridge-scenario--render)))

(defun dsh-bridge-scenario-quit ()
  "Offer to kill the fixture and quit."
  (interactive)
  (when (and dsh-bridge-scenario--fixture-proc
             (process-live-p dsh-bridge-scenario--fixture-proc)
             (y-or-n-p "Kill the fixture? "))
    (signal-process (process-id dsh-bridge-scenario--fixture-proc) 'SIGTERM)
    (setq dsh-bridge-scenario--fixture-proc nil))
  (kill-buffer "*dsh-bridge-scenario*"))

;;;###autoload
(defun dsh-bridge-scenario-run (&optional scenario-file)
  "Run an interactive UX scenario from SCENARIO-FILE (or completing-read).
Boots the fixture, creates a session on it, points the repo's dsh-bridge
package at both, and pops the step-through scenario buffer."
  (interactive)
  (unless scenario-file
    (let ((choices (mapcar #'file-name-nondirectory (dsh-bridge-scenario--read-scenarios))))
      (setq scenario-file
            (completing-read "Scenario: " choices nil t))))
  (let ((file (or (seq-find (lambda (f)
                              (equal scenario-file (file-name-nondirectory f)))
                            (dsh-bridge-scenario--read-scenarios))
                  scenario-file)))
    (setq dsh-bridge-scenario--scenario (dsh-bridge-scenario--load-scenario file))
    (setq dsh-bridge-scenario--steps (alist-get 'steps dsh-bridge-scenario--scenario))
    (setq dsh-bridge-scenario--index 0)
    ;; Load the repo Emacs package and point it at the fixture.
    (add-to-list 'load-path (expand-file-name "../emacs" dsh-bridge-scenario--directory))
    (require 'dsh-bridge)
    (let ((facts (dsh-bridge-scenario--boot-fixture)))
      (setq dsh-bridge-url (concat (alist-get 'url facts) "/dsh-bridge"))
      (setq dsh-bridge-token-file
            (expand-file-name "dsh-bridge-token" (alist-get 'dshHome facts))))
    ;; The scenarios drive one session; create it now so `send' steps have a
    ;; target (a fresh fixture has none, and a bare send would 409).
    (setq dsh-bridge-scenario--session-id (dsh-bridge-scenario--create-session))
    (dsh-bridge-notifications-start)
    (dsh-bridge-scenario--render)))

;;;###autoload
(defun dsh-bridge-scenario-fresh-emacs ()
  "Launch a separate `emacs -Q' subprocess with the runner loaded, for clean runs."
  (interactive)
  (let ((script (expand-file-name "dsh-bridge-scenario.el"
                                  (file-name-directory (dsh-bridge-scenario--launch-path)))))
    (start-process "dsh-bridge-scenario-fresh" "*dsh-bridge-scenario-fresh*"
                   "emacs" "-Q" "-l" script)))

(provide 'dsh-bridge-scenario)
;;; dsh-bridge-scenario.el ends here
