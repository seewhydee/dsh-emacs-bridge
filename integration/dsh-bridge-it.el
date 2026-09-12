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
                   (lambda () (assoc session-id dsh-bridge--pending-questions))
                   15000))
          ;; The session is awaiting, not continuing.
          (should (assoc session-id dsh-bridge--pending-questions))))
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
     ;; Drop the listener before the fixture dies, so a later test that boots
     ;; its own fixture does not inherit a reconnect loop aimed at a dead port.
     (dsh-bridge-notifications-stop)
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

;;; Incremental DSH-View filling
;;
;; The unit suite (emacs/dsh-bridge-tests.el) pins the fill algorithm against
;; synthetic turn records; these tests drive it through the real pipeline: a
;; live mock turn commits segments one at a time, the plugin broadcasts
;; `replies-changed', Emacs refreshes the turn cache and splices the view.  The
;; mock parks the turn on an ask-user question after the first committed
;; segment, which makes the one-segment state deterministic to observe.

(defun dsh-bridge-it--notifications-start ()
  "Connect the live notification listener to the current fixture.
Stops a listener left latched to an earlier fixture first, so several
fixture-booting tests can share one Emacs process."
  (dsh-bridge-notifications-stop)
  (dsh-bridge-notifications-start))

(defun dsh-bridge-it--view (session-id)
  "The live DSH-View buffer showing SESSION-ID, or nil."
  (dsh-bridge--session-view session-id))

(defun dsh-bridge-it--view-text (session-id)
  "The text of SESSION-ID's live DSH-View buffer, or nil."
  (let ((buffer (dsh-bridge-it--view session-id)))
    (and buffer (with-current-buffer buffer (buffer-string)))))

(defun dsh-bridge-it--view-provenance (session-id)
  "SESSION-ID's DSH-View fill provenance plist, or nil."
  (let ((buffer (dsh-bridge-it--view session-id)))
    (and buffer (buffer-local-value 'dsh-bridge--view-provenance buffer))))

(defun dsh-bridge-it--turn-render (turn session-id)
  "Buffer text for the whole TURN record, or \"\" for nil.
A local composition of the package's body and suffix helpers (the package
renders a turn's body and terminal suffix separately for the incremental
fill, so it has no whole-turn renderer)."
  (if (null turn)
      ""
    (concat (dsh-bridge--view-turn-body turn)
            (dsh-bridge--view-turn-suffix turn session-id))))

(defun dsh-bridge-it--prompt-send (session-id text)
  "Send TEXT to SESSION-ID through the real prompt-buffer flow.
This is the `C-c C-c' path: it opens the DSH-View following the session and
shows the `(running...)' placeholder, which is what makes the first committed
reply tail."
  (setq dsh-bridge-default-session session-id)
  (dsh-bridge-prompt)
  (insert text)
  (dsh-bridge-send-and-exit))

(defun dsh-bridge-it--answer-pending (session-id label)
  "Answer SESSION-ID's pending ask-user question with option LABEL.
Posts through the bridge's own `/answer' route — the settlement the question
buffer's `C-c C-c' performs — so the turn can resume."
  (let ((entry (dsh-bridge--pending-question session-id)))
    (unless entry
      (error "dsh-bridge-it: session %s has no pending question" session-id))
    (let* ((questions (cdr entry))
           (question-id (alist-get 'id (car questions))))
      (dsh-bridge-it--post
       "/dsh-bridge/answer"
       (list (cons 'questionId (car entry))
             (cons 'sessionId session-id)
             (cons 'answers
                   (vector (list (cons 'id question-id)
                                 (cons 'selected (vector label))))))))))

(ert-deftest dsh-bridge-it-incremental-fill-append ()
  "A followed DSH-View splices a live turn's later segments in place.
The mock commits \"First segment.\" and then parks the turn on an ask-user
question, so the one-segment state is deterministic.  The test plants a
marker inside the rendered body, answers, and proves the second segment and
the completion furniture were spliced around it (a rebuild would collapse the
marker).  It also pins the first-reply tail after `C-c C-c' and the recorded
provenance against the live `/turns' epoch and `(step . time)' segments."
  (dsh-bridge-it--with-fixture
    (dsh-bridge-it--script-mock
     (vector
      (list :kind "tool-call" :name "ask_user_question"
            :text "First segment."
            :arguments (list :questions
                             (vector (list :id "q1"
                                           :question "Pause here"
                                           :options (vector (list :label "Go"))))))
      (list :kind "text" :text "Second segment.")))
    (let ((session-id (dsh-bridge-it--create-session
                       (expand-file-name "../" dsh-bridge-it--directory)))
          probe)
      (dsh-bridge-it--notifications-start)
      (dsh-bridge-it--prompt-send session-id "Go.")
      ;; The first committed segment refills the waiting view, which tails.
      (should (dsh-bridge-it--wait
               (lambda ()
                 (let ((text (dsh-bridge-it--view-text session-id)))
                   (and (assoc session-id dsh-bridge--pending-questions)
                        text
                        (string-match-p "First segment\\." text))))
               30000))
      (with-current-buffer (dsh-bridge-it--view session-id)
        (should (string-match-p "Awaiting your response" (buffer-string)))
        (should (equal (point) (point-max)))     ; the first reply tailed
        (let ((prov dsh-bridge--view-provenance))
          (should (equal (plist-get prov :turn) 1))
          (should (numberp (plist-get prov :epoch)))
          (should (equal (plist-get prov :epoch)
                         (dsh-bridge--turns-cache-epoch session-id)))
          (should (equal (length (plist-get prov :keys)) 1)))
        ;; Plant a marker inside the rendered body; a rebuild collapses it.
        (setq probe (copy-marker (+ (point-min) 4))))
      (dsh-bridge-it--answer-pending session-id "Go")
      ;; The turn resumes, commits its second segment, and completes.
      (should (dsh-bridge-it--wait
               (lambda ()
                 (let ((text (dsh-bridge-it--view-text session-id))
                       (prov (dsh-bridge-it--view-provenance session-id)))
                   (and text
                        (string-match-p "Second segment\\." text)
                        (null (plist-get prov :open)))))
               30000))
      (with-current-buffer (dsh-bridge-it--view session-id)
        (let* ((record (car (dsh-bridge--turns-cache-turns session-id)))
               (prov dsh-bridge--view-provenance))
          ;; Byte-identical to the reference render of the live record.
          (should (equal (buffer-string)
                         (dsh-bridge-it--turn-render record session-id)))
          (should (equal (plist-get prov :keys)
                         (mapcar (lambda (seg)
                                   (cons (alist-get 'step seg)
                                         (alist-get 'time seg)))
                                 (alist-get 'segments record))))
          (should-not (plist-get prov :open))
          (should (equal (length (plist-get prov :keys)) 2))
          (should (equal (point) (point-max)))
          ;; The body was never rewritten: the planted marker stayed put.
          (should (equal (marker-position probe) 5))
          (should-not (text-property-any (point-min) (point-max)
                                         'dsh-bridge-turn-marker t))))
      (set-marker probe nil))))

(ert-deftest dsh-bridge-it-incremental-fill-turn-swap ()
  "A following DSH-View rebuilds onto a newer turn instead of splicing.
After one completed turn, a second prompt's turn changes the shown record, so
the fill falls back to a full re-render: a marker planted in the old body
collapses, and the view lands at the new turn's tail."
  (dsh-bridge-it--with-fixture
    ;; The instant mock finishes this turn inside the blocking send;
    ;; `--after-prompt-view' must show the completed turn rather than strand a
    ;; `(running...)' placeholder (the regression this test pins).
    (dsh-bridge-it--script-mock
     (vector (list :kind "text" :text "Turn one.")))
    (let ((session-id (dsh-bridge-it--create-session
                       (expand-file-name "../" dsh-bridge-it--directory)))
          probe)
      (dsh-bridge-it--notifications-start)
      (dsh-bridge-it--prompt-send session-id "One.")
      (should (dsh-bridge-it--wait
               (lambda ()
                 (let ((text (dsh-bridge-it--view-text session-id))
                       (prov (dsh-bridge-it--view-provenance session-id)))
                   (and text
                        (string-match-p "Turn one\\." text)
                        (null (plist-get prov :open)))))
               30000))
      (with-current-buffer (dsh-bridge-it--view session-id)
        (should (equal (plist-get dsh-bridge--view-provenance :turn) 1))
        (setq probe (copy-marker (+ (point-min) 3))))
      ;; A second prompt starts turn 2 while the view still follows turn 1:
      ;; the newer record replaces the body wholesale.
      (dsh-bridge-it--script-mock
       (vector (list :kind "text" :text "Turn two.")))
      (dsh-bridge-send-text "Two." session-id)
      (should (dsh-bridge-it--wait
               (lambda ()
                 (let ((text (dsh-bridge-it--view-text session-id))
                       (prov (dsh-bridge-it--view-provenance session-id)))
                   (and text
                        (string-match-p "Turn two\\." text)
                        (null (plist-get prov :open))
                        (equal (plist-get prov :turn) 2))))
               30000))
      (with-current-buffer (dsh-bridge-it--view session-id)
        (let* ((record (car (dsh-bridge--turns-cache-turns session-id)))
               (prov dsh-bridge--view-provenance))
          (should (equal (plist-get prov :turn) 2))
          (should (equal (buffer-string)
                         (dsh-bridge-it--turn-render record session-id)))
          (should (equal (point) (point-max)))
          ;; The swap rebuilt the body, so the old marker collapsed.
          (should (equal (marker-position probe) (point-min)))))
      (set-marker probe nil))))

(provide 'dsh-bridge-it)
;;; dsh-bridge-it.el ends here
