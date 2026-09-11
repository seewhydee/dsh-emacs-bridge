;;; dsh-bridge-it.el — batch Emacs end-to-end tests against a live fixture. -*- lexical-binding: t -*-
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
;;; The first asynchronous ERT layer in this repo.  The existing suite
;;; (emacs/dsh-bridge-tests.el) is purely synchronous; these tests boot the
;;; repo's REAL `dsh-bridge.el` against a live DSH host (the fixture launcher)
;;; and drive the async notification/SSE paths.  The flagship ask-user test:
;;; notifications start, send a prompt, wait for the pending-question registry
;;; to populate.  With the current plugin bug this never happens, so the test
;;; fails by assertion timeout — the intended RED per integration-testing-plan.md
;;; ("Landing order").  Growth (a fresh-view recovery test, a fixture-restart
;;; reconnect-resilience test) follows the plan's coverage checklist.
;;;
;;; Run via `make integration-test`: `emacs --batch -L emacs -L integration -l
;;; integration/dsh-bridge-it.el -f ert-run-tests-batch-and-exit`.  The fixture
;;; launcher needs `DSH_BRIDGE_DSH_COMMAND` and (for a checkout dsh)
;;; `DSH_BRIDGE_FIXTURE_CWD` set in the environment (inherited by emacs and by
;;; the make-process children).

;;; Code:

(require 'ert)
(require 'json)
(require 'cl-lib)

;; This file's directory, captured AT LOAD TIME: `load-file-name' and
;; `buffer-file-name' are both nil when a test function runs in batch Emacs,
;; so any path computed inside a function body from those variables fails.
(defconst dsh-bridge-it--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding this file (the repo's integration/ directory).")

;; The repo's real Emacs package: this file lives in integration/, so emacs/ is
;; one directory up. Requiring it here also makes byte-compilation know the
;; dsh-bridge symbols it drives.
(add-to-list 'load-path (expand-file-name "../emacs" dsh-bridge-it--directory))
(require 'dsh-bridge)

;; url.el's request-session vars are dynamically scoped; require url and declare
;; them special so `let' binds them dynamically (and byte-compile does not flag
;; them as unused lexical bindings).
(require 'url)
(defvar url-request-method nil)
(defvar url-request-extra-headers nil)
(defvar url-request-data nil)

(defvar dsh-bridge-it--fixture-proc nil
  "The running fixture launcher process, or nil.")
(defvar dsh-bridge-it--fixture-output ""
  "Accumulated stdout from the fixture launcher.")
(defvar dsh-bridge-it--fixture nil
  "The parsed fixture facts alist, or nil.")

(defun dsh-bridge-it--fixture-filter (_proc string)
  "Accumulate STRING from the fixture launcher into `dsh-bridge-it--fixture-output'."
  (setq dsh-bridge-it--fixture-output
        (concat dsh-bridge-it--fixture-output string)))

(defun dsh-bridge-it--fixture-json ()
  "Parse the `FIXTURE_JSON ...' marker line from the accumulated output, or nil."
  (when (string-match "^FIXTURE_JSON \\(.+\\)$" dsh-bridge-it--fixture-output)
    (json-parse-string (match-string 1 dsh-bridge-it--fixture-output)
                       :object-type 'alist)))

(defun dsh-bridge-it--boot-fixture ()
  "Boot one fixture via the launcher CLI; return its facts alist."
  (let* ((launch (expand-file-name "host/launch.mjs" dsh-bridge-it--directory))
         (proc (make-process
                :name "dsh-bridge-it-fixture"
                :command (list "node" launch)
                :connection-type 'pipe
                :filter #'dsh-bridge-it--fixture-filter
                :noquery t
                :stderr (get-buffer-create "*dsh-bridge-it-fixture-stderr*"))))
    (setq dsh-bridge-it--fixture-proc proc)
    (setq dsh-bridge-it--fixture-output "")
    (let ((deadline (+ (float-time) 120))
          facts)
      (while (and (null (setq facts (dsh-bridge-it--fixture-json)))
                  (< (float-time) deadline)
                  (process-live-p proc))
        (accept-process-output proc 0.5)
        (sleep-for 0.2))
      (unless facts
        (error "dsh-bridge-it: fixture did not report facts within 120s"))
      facts)))

(defun dsh-bridge-it--kill-fixture ()
  "Terminate the fixture launcher (and, via its SIGTERM handler, the dsh child)."
  (when (and dsh-bridge-it--fixture-proc
             (process-live-p dsh-bridge-it--fixture-proc))
    (signal-process (process-id dsh-bridge-it--fixture-proc) 'SIGTERM)
    (accept-process-output dsh-bridge-it--fixture-proc 1)))

(defun dsh-bridge-it--url ()
  "The fixture bridge URL (base, without the /dsh-bridge suffix)."
  (alist-get 'url dsh-bridge-it--fixture))

(defun dsh-bridge-it--token ()
  "The fixture bearer token."
  (alist-get 'token dsh-bridge-it--fixture))

(defun dsh-bridge-it--wait (predicate &optional timeout-ms)
  "Wait for PREDICATE to return non-nil, up to TIMEOUT-MS (default 30000)."
  (let ((deadline (+ (float-time) (/ (or timeout-ms 30000) 1000.0))))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (sleep-for 0.2)
      (redisplay t))
    (funcall predicate)))

(defun dsh-bridge-it--post (path body)
  "POST BODY (alist) to PATH on the fixture; return the parsed response alist."
  (require 'url)
  (let* ((url (concat (dsh-bridge-it--url) path))
         (url-request-method "POST")
         (url-request-extra-headers
          (list (cons "Content-Type" "application/json")
                (cons "Authorization" (concat "Bearer " (dsh-bridge-it--token)))))
         (url-request-data (json-encode body))
         (buffer (url-retrieve-synchronously url))
         (raw nil))
    (unwind-protect
        (progn
          (when (buffer-live-p buffer)
            (setq raw (with-current-buffer buffer
                        (goto-char (point-min))
                        ;; url.el leaves CRLF header endings in the buffer
                        ;; (same reason dsh-bridge.el matches "\r?\n\r?\n").
                        (re-search-forward "\r?\n\r?\n")
                        (buffer-substring-no-properties (point) (point-max)))))
          raw)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun dsh-bridge-it--parse-json (string)
  "Parse STRING as JSON into an alist."
  (json-parse-string string :object-type 'alist))

(defun dsh-bridge-it--script-mock (script)
  "Replace the mock LLM script queue with SCRIPT."
  (dsh-bridge-it--post "/mock-llm/script" (list (cons 'script script))))

(defun dsh-bridge-it--create-session (path)
  "Create a session in a workspace by PATH; return its session id."
  (let* ((body (dsh-bridge-it--parse-json
                (dsh-bridge-it--post "/dsh-bridge/sessions/create"
                                     (list (cons 'path path)))))
         (id (alist-get 'sessionId body)))
    (unless id (error "dsh-bridge-it: create-session failed: %s" body))
    id))

;; (The repo's Emacs package is loaded near the top, before the helpers.)

(defun dsh-bridge-it--wait-for-turns (session-id timeout-ms)
  "Wait until SESSION-ID has at least one folded turn, up to TIMEOUT-MS."
  (dsh-bridge-it--wait
   (lambda ()
     (let* ((result (dsh-bridge--request "GET" (dsh-bridge--path "/turns" session-id) nil))
            (turns (alist-get 'turns (cdr result))))
       (and (listp turns) turns)))
   timeout-ms))

(defun dsh-bridge-it--session-ids ()
  "The fixture roster's session ids (live and persisted)."
  (let* ((result (dsh-bridge--request "GET" "/sessions" nil))
         (rows (alist-get 'sessions (cdr result))))
    (mapcar (lambda (row) (alist-get 'id row)) rows)))

(ert-deftest dsh-bridge-it-describe-session ()
  "The real session report renders live host statistics in a help-mode buffer."
  (unwind-protect
      (let* ((facts (dsh-bridge-it--boot-fixture)))
        (setq dsh-bridge-it--fixture facts)
        (setq dsh-bridge-url (concat (dsh-bridge-it--url) "/dsh-bridge"))
        (setq dsh-bridge-token-file
              (expand-file-name "dsh-bridge-token" (alist-get 'dshHome facts)))
        (dsh-bridge-it--script-mock
         (vector (list :kind "text" :text "Report me.")))
        (let ((session-id (dsh-bridge-it--create-session
                           (expand-file-name "../" dsh-bridge-it--directory))))
          (dsh-bridge-send-text "Please report." session-id)
          (should (dsh-bridge-it--wait-for-turns session-id 30000))
          (dsh-bridge-describe-session session-id)
          (with-current-buffer dsh-bridge-describe-buffer-name
            (should (derived-mode-p 'help-mode))
            (let ((text (buffer-string)))
              (should (string-match-p "DSH session" text))
              ;; The real turn count, not just the label: exactly one turn
              ;; completed (steps are left loose — an async auto-title may
              ;; fold in extra ones).
              (should (string-match-p "Turns / steps\\s-+1 / " text))
              (should (string-match-p "Tokens" text))
              (should (string-match-p "Cache hit" text))))))
    (when (get-buffer dsh-bridge-describe-buffer-name)
      (kill-buffer dsh-bridge-describe-buffer-name))
    (dsh-bridge-it--kill-fixture)))

(ert-deftest dsh-bridge-it-fork-turn ()
  "The live-Emacs seat of branching: `B' forks the shown turn into a child.
Drives the real command against the live fixture: fetch a session with one
completed turn, fork from its view, and prove the new child carries the
source as `parentSession' with `isSeeded' set."
  (unwind-protect
      (let* ((facts (dsh-bridge-it--boot-fixture)))
        (setq dsh-bridge-it--fixture facts)
        (setq dsh-bridge-url (concat (dsh-bridge-it--url) "/dsh-bridge"))
        (setq dsh-bridge-token-file
              (expand-file-name "dsh-bridge-token" (alist-get 'dshHome facts)))
        (dsh-bridge-it--script-mock
         (vector (list :kind "text" :text "Branch this.")))
        (let* ((session-id (dsh-bridge-it--create-session
                            (expand-file-name "../" dsh-bridge-it--directory)))
               (before (dsh-bridge-it--session-ids)))
          (dsh-bridge-send-text "Please branch." session-id)
          (should (dsh-bridge-it--wait-for-turns session-id 30000))
          ;; Open the session's DSH-View, which selects the buffer, then branch
          ;; the shown (completed) turn; the command opens the child and its
          ;; prompt.
          (dsh-bridge-fetch session-id t)
          (dsh-bridge-fork-turn)
          (let* ((after (dsh-bridge-it--session-ids))
                 (child (seq-find (lambda (id) (not (member id before))) after)))
            (should child)
            (let* ((result (dsh-bridge--request
                            "GET" (dsh-bridge--path "/session" child) nil))
                   (report (cdr result)))
              (should (equal (alist-get 'parentSession report) session-id))
              (should (eq (alist-get 'isSeeded report) t))))))
    (when (get-buffer "*dsh-bridge-prompt*")
      (kill-buffer "*dsh-bridge-prompt*"))
    (dsh-bridge-it--kill-fixture)))

(ert-deftest dsh-bridge-it-ask-user ()  "Flagship: the live-Emacs seat of the ask-user path."
  (unwind-protect
      (let* ((facts (dsh-bridge-it--boot-fixture)))
        (setq dsh-bridge-it--fixture facts)
        (setq dsh-bridge-url (concat (dsh-bridge-it--url) "/dsh-bridge"))
        (setq dsh-bridge-token-file
              (expand-file-name "dsh-bridge-token" (alist-get 'dshHome facts)))
        ;; Script the mock: ask a question, then continue with text.
        (dsh-bridge-it--script-mock
         (vector
          (list :kind "tool-call" :name "ask_user_question"
                :arguments (list
                            :questions
                            (vector
                             (list :id "q1" :question "Pick a color"
                                   :options (vector (list :label "Red")
                                                     (list :label "Blue"))))))
          (list :kind "text" :text "Proceeding with your choice.")))
        (let ((session-id (dsh-bridge-it--create-session
                           (expand-file-name "../" dsh-bridge-it--directory))))
          (dsh-bridge-notifications-start)
          (dsh-bridge-send-text "Pick a color for me." session-id)
          ;; The ask surfaces via the waterfall answerer → SSE → Emacs.
          ;; With the current bug this never populates, so the wait fails and the
          ;; test reproduces the report.
          (should (dsh-bridge-it--wait
                   (lambda () (dsh-bridge--session-awaiting-p session-id))
                   15000))
          ;; The session is awaiting, not continuing.
          (should (dsh-bridge--session-awaiting-p session-id))))
    (dsh-bridge-it--kill-fixture)))

(defmacro dsh-bridge-it--with-fixture (&rest body)
  "Boot one fixture, bind the bridge globals, run BODY, then tear down.
BODY runs with `dsh-bridge-it--fixture' set and `dsh-bridge-url' /
`dsh-bridge-token-file' pointed at the fixture."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (let* ((facts (dsh-bridge-it--boot-fixture)))
         (setq dsh-bridge-it--fixture facts)
         (setq dsh-bridge-url (concat (dsh-bridge-it--url) "/dsh-bridge"))
         (setq dsh-bridge-token-file
               (expand-file-name "dsh-bridge-token" (alist-get 'dshHome facts)))
         ,@body)
     (when (get-buffer "*dsh-bridge-prompt*")
       (kill-buffer "*dsh-bridge-prompt*"))
     (dsh-bridge-it--kill-fixture)))

(defun dsh-bridge-it--get (path)
  "GET PATH on the fixture's base URL; return the parsed JSON alist, or nil."
  (require 'url)
  (let* ((url (concat (dsh-bridge-it--url) path))
         (url-request-method "GET")
         (url-request-extra-headers
          (list (cons "Authorization" (concat "Bearer " (dsh-bridge-it--token)))))
         (buffer (url-retrieve-synchronously url))
         (raw nil))
    (unwind-protect
        (progn
          (when (buffer-live-p buffer)
            (setq raw (with-current-buffer buffer
                        (goto-char (point-min))
                        (re-search-forward "\r?\n\r?\n")
                        (buffer-substring-no-properties (point) (point-max)))))
          (when (and raw (not (string-empty-p raw)))
            (dsh-bridge-it--parse-json raw)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defconst dsh-bridge-it--png-1x1
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACXBIWXMAAAPoAAAD6AG1e1JrAAAADUlEQVQImWP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
  "Base64 of a valid 1x1 PNG the attachment store's decoder accepts.")

(ert-deftest dsh-bridge-it-attach-file ()
  "The live-Emacs seat of attachments: attach a file in the prompt buffer,
send, and prove the host staged it and stripped the tag.
Drives the real `C-c C-a' machinery (`dsh-bridge-attach-file' plus the
send-time tag parse) against the live fixture: the image must reach the
provider as an image block, and the logged prompt text must no longer carry
the tag line."
  (dsh-bridge-it--with-fixture
    (let ((png (make-temp-file "dsh-bridge-it" nil ".png")))
      (unwind-protect
          (progn
            (with-temp-file png
              (set-buffer-multibyte nil)
              (insert (base64-decode-string dsh-bridge-it--png-1x1)))
            (dsh-bridge-it--script-mock
             (vector (list :kind "text" :text "Saw it.")))
            (let ((session-id (dsh-bridge-it--create-session
                               (expand-file-name "../" dsh-bridge-it--directory))))
              (setq dsh-bridge-default-session session-id)
              (dsh-bridge-prompt)
              (insert "Look at this.\n")
              (dsh-bridge-attach-file (list png))
              (should (string-match-p "📎1" (dsh-bridge--prompt-header-line)))
              (dsh-bridge-send-and-exit)
              (should (dsh-bridge-it--wait-for-turns session-id 30000))
              ;; The tag is stripped from the text the host logged (the
              ;; newline that preceded the tag line remains part of the text).
              ;; Scope to our own prompt: /prompts also carries the injected
              ;; context messages, and AGENTS.md itself quotes the tag syntax.
              (let* ((result (dsh-bridge--request
                              "GET" (dsh-bridge--path "/prompts" session-id) nil))
                     (prompts (alist-get 'prompts (cdr result)))
                     (ours (seq-find (lambda (prompt)
                                       (equal (string-trim prompt) "Look at this."))
                                     prompts)))
                (should ours)
                (should-not (string-match-p "<#attachment" ours)))
              ;; The image reached the mock provider as an image block.
              (let* ((requests (alist-get 'requests
                                          (dsh-bridge-it--get "/mock-llm/requests")))
                     (blocks (seq-mapcat
                              (lambda (request)
                                (seq-mapcat (lambda (message)
                                              (alist-get 'content message))
                                            (alist-get 'messages request)))
                              requests)))
                (should (seq-some (lambda (block)
                                    (equal (alist-get 'type block) "image"))
                                  blocks)))))
        (delete-file png)))))

(provide 'dsh-bridge-it)
;;; dsh-bridge-it.el ends here
