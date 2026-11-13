;;; dsh-bridge-extras-tests.el --- ERT tests for the DSH item inspector  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>

;; This file is part of dsh-emacs-bridge.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dsh-bridge-extras)

(defun dsh-bridge-extras-tests--page (text &optional _next total _more)
  "Build one complete text payload for TEXT, with optional TOTAL bytes."
  (list (cons 'text text)
        (cons 'totalBytes (or total (string-bytes text)))))

(defun dsh-bridge-extras-tests--thinking-response (&optional text)
  "Build a thinking item containing TEXT."
  `((kind . "thinking") (sessionId . "s1") (turn . 3) (epoch . 2) (cursor . 20)
    (cwd . "/work") (seq . 4) (ord . 0) (step . 1) (time . 1000)
    (parts . ((reasoning . ,(dsh-bridge-extras-tests--page
                             (or text "complete reasoning\n")))))))

(defun dsh-bridge-extras-tests--tool-response (&optional orphan)
  "Build a logical tool item, or an orphan result when ORPHAN is non-nil."
  `((kind . ,(if orphan "tool-result" "tool"))
    (sessionId . "s1") (turn . 3) (epoch . 2) (cursor . 20) (cwd . "/work")
    (callId . "c1") (name . "edit") (step . 1)
    (settlement . ,(if orphan "orphan" "settled"))
    ,@(if orphan
          '((isError . :json-false)
            (content . ((blocks . []) (textBlocks . 1) (omittedBlocks . 0))))
        '((result . ((isError . :json-false)
                     (content . ((blocks . []) (textBlocks . 1) (omittedBlocks . 0)))))))
    (files . (((path . "/work/f.txt") (absolute . "/work/f.txt")
               (pathSource . "recorded") (status . "applied")
               (diff . ,(dsh-bridge-extras-tests--page
                         "File: /work/f.txt\n-old\n+new\n")))))
    (parts . (,@(unless orphan
                  `((arguments . ,(dsh-bridge-extras-tests--page
                                   "{\"file_path\":\"f.txt\"}"))))
              (result . ,(dsh-bridge-extras-tests--page "done\n"))))))

(defun dsh-bridge-extras-tests--file (absolute diff)
  "Build one file-change entry at ABSOLUTE with rendered DIFF page."
  (list (cons 'path absolute) (cons 'absolute absolute)
        (cons 'pathSource "recorded") (cons 'status "applied")
        (cons 'diff diff)))

(defun dsh-bridge-extras-tests--view (session turn lines)
  "Create a DSH-View buffer for SESSION at TURN showing LINES.
LINES is a list of (TEXT . ACTIVITY-KEY)."
  (let ((buffer (generate-new-buffer "*test-dsh-view*")))
    (with-current-buffer buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session session
                  dsh-bridge--view-turn turn
                  dsh-bridge--view-activity (and lines t))
      (let ((inhibit-read-only t))
        (dolist (line lines)
          (insert (propertize (car line) 'dsh-bridge-activity (cdr line)) "\n"))))
    buffer))

(defun dsh-bridge-extras-tests--turn (turn activity)
  "Build a completed turn record for TURN with ACTIVITY entries."
  `((turn . ,turn)
    (segments)
    (activity . ,activity)
    (endedAt . ,(* 1000 turn))
    (reason . ((kind . "completed")))))

(defmacro dsh-bridge-extras-tests--with-requests (responder &rest body)
  "Run BODY with async requests answered synchronously by RESPONDER.
RESPONDER receives the path and returns (STATUS . ALIST).  Return the
list of requests in invocation order."
  (declare (indent 1))
  `(let ((requests nil))
     (cl-letf (((symbol-function 'dsh-bridge--request-async)
                (lambda (method path payload callback)
                  (push (list method path payload) requests)
                  (funcall callback (funcall ,responder path)))))
       (prog1 (progn ,@body)
         (setq requests (nreverse requests))))
     requests))

(defmacro dsh-bridge-extras-tests--with-item (response &rest body)
  "Run BODY in a fresh inspector buffer containing RESPONSE."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "*test-dsh-item*")))
     (unwind-protect
         (with-current-buffer buffer
           (dsh-bridge-extras-mode)
           (setq dsh-bridge-extras--session "s1"
                 dsh-bridge-extras--turn 3
                 dsh-bridge-extras--selector '(:kind thinking :seq 4 :ord 0)
                 dsh-bridge-extras--generation 1)
           (dsh-bridge-extras--handle-item (cons 200 ,response))
           ,@body)
       (kill-buffer buffer))))

(ert-deftest dsh-bridge-extras-mode-wraps-long-lines ()
  "The inspector wraps long content rather than truncating it."
  (with-temp-buffer
    (dsh-bridge-extras-mode)
    (should visual-line-mode)
    (should word-wrap)
    (should-not truncate-lines)))

(ert-deftest dsh-bridge-extras-identity-at-point-selects-one-item ()
  "View activity identities map to thinking, logical tool, and orphan selectors."
  (with-temp-buffer
    (dsh-bridge-view-mode)
    (let ((inhibit-read-only t))
      (insert (propertize "think\n" 'dsh-bridge-activity '(4 . 1))
              (propertize "call\n" 'dsh-bridge-activity "c1")
              (propertize "orphan\n" 'dsh-bridge-activity '(tool-result . "c2"))))
    (goto-char (point-min))
    (should (equal (dsh-bridge-extras--identity-at-point)
                   '(:kind thinking :seq 4 :ord 1)))
    (forward-line 1)
    (should (equal (dsh-bridge-extras--identity-at-point)
                   '(:kind tool :call-id "c1")))
    (forward-line 1)
    (should (equal (dsh-bridge-extras--identity-at-point)
                   '(:kind tool-result :call-id "c2")))))

(ert-deftest dsh-bridge-extras-inspect-requires-an-activity-item ()
  "Session-only and ordinary-reply contexts never fall back to a turn inspector."
  (with-temp-buffer
    (should-error (dsh-bridge-extras-inspect-item) :type 'user-error))
  (with-temp-buffer
    (dsh-bridge-view-mode)
    (setq-local dsh-bridge--view-content-session "s1"
                dsh-bridge--view-turn 3)
    (should-error (dsh-bridge-extras-inspect-item) :type 'user-error)))

(ert-deftest dsh-bridge-extras-inspect-thinking-fetches-only-that-block ()
  "RET's thinking target fetches one concrete block, never an index or latest turn."
  (let ((dsh-bridge--sessions-cache nil))
    (with-temp-buffer
    (dsh-bridge-view-mode)
    (setq-local dsh-bridge--view-content-session "s1"
                dsh-bridge--view-turn 3)
    (let ((inhibit-read-only t)
          (requests nil))
      (insert (propertize "thinking\n" 'dsh-bridge-activity '(4 . 0)))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) buffer)))
        (setq requests
              (dsh-bridge-extras-tests--with-requests
                  (lambda (_path) (cons 200 (dsh-bridge-extras-tests--thinking-response)))
                (dsh-bridge-extras-inspect-item))))
      (unwind-protect
          (with-current-buffer dsh-bridge-extras-buffer-name
            (should (= (length requests) 1))
            (let ((path (cadr (car requests))))
              (should (string-match-p "/details/item?" path))
              (should (string-match-p "turn=3" path))
              (should (string-match-p "kind=thinking" path))
              (should (string-match-p "seq=4" path))
              (should (string-match-p "ord=0" path))
              (should-not (string-match-p "latest\\|epoch=\\|cursor=" path)))
            (should (equal (dsh-bridge-extras-session) "s1"))
            (should (equal (dsh-bridge--effective-session) "s1"))
            (should (equal (buffer-string)
                           (concat "Thinking — step 1\n"
                                   "Session      s1   Turn 3\n"
                                   "Directory    /work\n"
                                   "Observation  epoch 2, cursor 20\n\n"
                                   "complete reasoning\n")))
            (should-not (alist-get 'entries dsh-bridge-extras--item))
            (should buffer-read-only)
            (should-not (buffer-modified-p)))
        (kill-buffer dsh-bridge-extras-buffer-name))))))

(ert-deftest dsh-bridge-extras-header-shows-session-label ()
  "The header shows the session title, its raw id, and a describe button."
  (let ((dsh-bridge--sessions-cache
         '(((id . "s1") (title . "Review session") (live . t)))))
    (dsh-bridge-extras-tests--with-item
        (dsh-bridge-extras-tests--thinking-response)
      (should (string-match-p "^Session      Review session   Turn 3$"
                              (buffer-string)))
      (should (string-match-p "^Id           s1$" (buffer-string)))
      (goto-char (point-min))
      (search-forward "Review session")
      (let ((position (match-beginning 0))
            (button (button-at (match-beginning 0))))
        (should button)
        (should (equal (button-get button 'dsh-bridge-session-id) "s1"))
        (let (described)
          (cl-letf (((symbol-function 'dsh-bridge-describe-session)
                     (lambda (session) (setq described session))))
            (push-button position)
            (should (equal described "s1"))))))))

(ert-deftest dsh-bridge-extras-menu-and-keys ()
  "The inspector publishes the DSH Bridge menu and its session keys."
  (with-temp-buffer
    (dsh-bridge-extras-mode)
    (should (eq (lookup-key dsh-bridge-extras-mode-map (kbd "f"))
                #'dsh-bridge-extras-show-in-view))
    (should (eq (lookup-key dsh-bridge-extras-mode-map (kbd "RET"))
                #'dsh-bridge-extras-enter))
    (should (eq (lookup-key dsh-bridge-extras-mode-map (kbd "D"))
                #'dsh-bridge-extras-describe-session))
    (should (eq (lookup-key dsh-bridge-extras-mode-map (kbd "r"))
                #'dsh-bridge-extras-open-prompt))
    (should (eq (lookup-key dsh-bridge-extras-mode-map (kbd "l"))
                #'dsh-bridge-list-sessions))
    (let ((menu (lookup-key dsh-bridge-extras-mode-map [menu-bar]))
          found)
      (should (keymapp menu))
      (map-keymap (lambda (_key value)
                    (when (and (consp value)
                               (equal (nth 1 value) "DSH Bridge"))
                      (setq found t)))
                  menu)
      (should found))))

(ert-deftest dsh-bridge-extras-show-in-view-finds-activity-kinds ()
  "Show-in-view reaches thinking, tool, and orphan lines in the view."
  (let ((view (dsh-bridge-extras-tests--view
               "show-kinds" 3
               '(("thinking" . (4 . 0))
                 ("tool" . "c1")
                 ("orphan" . (tool-result . "c2"))))))
    (unwind-protect
        (dolist (case '(((:kind thinking :seq 4 :ord 0) . 1)
                        ((:kind tool :call-id "c1") . 2)
                        ((:kind tool-result :call-id "c2") . 3)))
          (with-temp-buffer
            (dsh-bridge-extras-mode)
            (setq-local dsh-bridge-extras--session "show-kinds"
                        dsh-bridge-extras--turn 3
                        dsh-bridge-extras--selector (car case))
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _) (set-buffer buffer))))
              (dsh-bridge-extras-show-in-view)))
          (with-current-buffer view
            (should (= (line-number-at-pos) (cdr case)))))
      (kill-buffer view))))

(ert-deftest dsh-bridge-extras-show-in-view-refills-cached-turn ()
  "Show-in-view enables activity and switches to the item's cached turn."
  (let* ((thinking '((kind . "thinking") (seq . 4) (ord . 0)
                     (step . 1) (summary . "cached thought")))
         (turn3 (dsh-bridge-extras-tests--turn 3 (list thinking)))
         (turn4 (dsh-bridge-extras-tests--turn 4 nil))
         (view (dsh-bridge-extras-tests--view "show-refill" 4 nil))
         (dsh-bridge--turns-cache
          (list (cons "show-refill" (cons nil (list turn4 turn3))))))
    (unwind-protect
        (progn
          (with-temp-buffer
            (dsh-bridge-extras-mode)
            (setq-local dsh-bridge-extras--session "show-refill"
                        dsh-bridge-extras--turn 3
                        dsh-bridge-extras--selector '(:kind thinking :seq 4 :ord 0))
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _) (set-buffer buffer))))
              (dsh-bridge-extras-show-in-view)))
          (with-current-buffer view
            (should (equal dsh-bridge--view-turn 3))
            (should (eq dsh-bridge--view-activity t))
            (should (= (line-number-at-pos) 1))
            (should (string-match-p "cached thought" (buffer-string)))))
      (kill-buffer view))))

(ert-deftest dsh-bridge-extras-show-in-view-reports-without-a-view ()
  "Show-in-view never opens or resumes a missing DSH-View."
  (let (said)
    (with-temp-buffer
      (dsh-bridge-extras-mode)
      (setq-local dsh-bridge-extras--session "show-missing"
                  dsh-bridge-extras--turn 3
                  dsh-bridge-extras--selector '(:kind thinking :seq 4 :ord 0))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq said (apply #'format format-string args)))))
        (dsh-bridge-extras-show-in-view)))
    (should (string-match-p "no DSH-View buffer" said))))

(ert-deftest dsh-bridge-extras-session-resolves-effective-session ()
  "The inspector's item session is the shared session resolution."
  (let ((dsh-bridge-pinned-target "pinned"))
    (with-temp-buffer
      (dsh-bridge-extras-mode)
      (setq-local dsh-bridge-extras--session "s1")
      (should (equal (dsh-bridge-extras-session) "s1"))
      (should (equal (dsh-bridge--effective-session) "s1"))
      (should (equal (dsh-bridge--effective-session nil t) "s1"))))
  ;; Outside the inspector, the accessor has nothing to report.
  (with-temp-buffer
    (should-not (dsh-bridge-extras-session))))

(ert-deftest dsh-bridge-extras-dispatcher-focuses-inspector-session ()
  "The dispatcher's focus follows the inspector's item session."
  (let ((dsh-bridge-pinned-target nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (dsh-bridge--dispatcher-roster 'ok)
        (dsh-bridge--focus nil)
        (transient--original-buffer nil))
    (with-temp-buffer
      (dsh-bridge-extras-mode)
      (setq-local dsh-bridge-extras--session "s1")
      (dsh-bridge--dispatcher-init nil)
      (should (equal (car dsh-bridge--focus) "s1"))
      (should (eq (cdr dsh-bridge--focus) 'buffer))
      (should (equal (dsh-bridge--focus-session) "s1")))))

(ert-deftest dsh-bridge-extras-tool-item-groups-call-result-and-diff ()
  "A logical tool item shows its own arguments, result, and diff only."
  (dsh-bridge-extras-tests--with-item (dsh-bridge-extras-tests--tool-response)
    (let ((text (buffer-string)))
      (should (string-match-p "^edit$" text))
      (should (string-match-p "^Arguments$" text))
      (should (string-match-p "\"file_path\": \"f.txt\"" text))
      (should (string-match-p "^Result$" text))
      (should (string-match-p "^done$" text))
      (should (string-match-p "^Changed files$" text))
      (should (string-match-p "^-old$" text))
      (should (string-match-p "^+new$" text))
      (should-not (string-match-p "Thinking\\|Tool calls\\|entries" text)))))

(ert-deftest dsh-bridge-extras-orphan-item-has-no-arguments ()
  "An orphan result never borrows a call's arguments."
  (dsh-bridge-extras-tests--with-item (dsh-bridge-extras-tests--tool-response t)
    (should (string-match-p "result (orphan)" (buffer-string)))
    (should (string-match-p "No call arguments (orphan tool result)\\."
                            (buffer-string)))
    (should (string-match-p "^Result$" (buffer-string)))
    (should-not (string-match-p "^Arguments$" (buffer-string)))))

(ert-deftest dsh-bridge-extras-tool-status-and-file-truncation-are-visible ()
  "Errors and host-reported omitted file changes remain visible."
  (dsh-bridge-extras-tests--with-item
      (let ((response (dsh-bridge-extras-tests--tool-response)))
        (setf (alist-get 'isError (alist-get 'result response)) t
              (alist-get 'droppedFiles response) 2)
        response)
    (should (string-match-p "Tool reported an error" (buffer-string)))
    (should (string-match-p "2 durable file change(s) omitted" (buffer-string)))))

(ert-deftest dsh-bridge-extras-pending-tool-is-labelled ()
  "A pending invocation shows its arguments and pending state, with no result."
  (dsh-bridge-extras-tests--with-item
      (let ((response (dsh-bridge-extras-tests--tool-response)))
        (setf (alist-get 'settlement response) "pending"
              (alist-get 'result response) nil
              (alist-get 'result (alist-get 'parts response)) nil
              (alist-get 'files response) nil)
        response)
    (should (string-match-p "^edit (pending)$" (buffer-string)))
    (should (string-match-p "^Arguments$" (buffer-string)))
    (should-not (string-match-p "^Result$" (buffer-string)))))

(ert-deftest dsh-bridge-extras-diff-refresh-keeps-point ()
  "A refresh after a changed diff keeps point at the same line."
  (dsh-bridge-extras-tests--with-item
      (let ((response (dsh-bridge-extras-tests--tool-response)))
        (setf (alist-get 'diff (car (alist-get 'files response)))
              (dsh-bridge-extras-tests--page "File: /work/f.txt\n-old\n"))
        response)
    (goto-char (point-min))
    (search-forward "-old")
    (let ((line (line-number-at-pos)))
      (dsh-bridge-extras-tests--with-requests
          (lambda (_path)
            (cons 200 (let ((response (dsh-bridge-extras-tests--tool-response)))
                        (setf (alist-get 'diff (car (alist-get 'files response)))
                              (dsh-bridge-extras-tests--page
                               "File: /work/f.txt\n-old\n+new\n"))
                        response)))
        (dsh-bridge-extras-refresh))
      (should (= (line-number-at-pos) line))
      (should (string-match-p "^+new$" (buffer-string))))))

(ert-deftest dsh-bridge-extras-deferred-item-prompts-then-loads-full ()
  "A deferred item asks once, then requests and renders the complete item."
  (let ((requests nil)
        (callback nil)
        (deferred (dsh-bridge-extras-tests--thinking-response "complete reasoning")))
    (setf (alist-get 'deferred deferred) t
          (alist-get 'totalBytes deferred) 300000
          (alist-get 'text (alist-get 'reasoning (alist-get 'parts deferred))) ""
          (alist-get 'totalBytes (alist-get 'reasoning (alist-get 'parts deferred))) 300000)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'dsh-bridge--request-async)
               (lambda (_method path _payload done)
                 (push path requests)
                 (setq callback done))))
      (dsh-bridge-extras-tests--with-item deferred
        (should (= (length requests) 1))
        (should (string-match-p "full=1" (car requests)))
        (should-not (string-match-p "part=\\|byteOffset=\\|epoch=\\|cursor="
                                    (car requests)))
        (funcall callback
                 (cons 200 (dsh-bridge-extras-tests--thinking-response
                            "complete reasoning")))
        (should (string-match-p "complete reasoning" (buffer-string)))
        (should-not (string-match-p "not loaded" (buffer-string)))
        (should dsh-bridge-extras--full-loaded)))))

(ert-deftest dsh-bridge-extras-deferred-item-declined-keeps-notice ()
  "Declining the full load leaves the size notice and sends no request."
  (let ((requests nil)
        (deferred (dsh-bridge-extras-tests--thinking-response "large")))
    (setf (alist-get 'deferred deferred) t
          (alist-get 'totalBytes deferred) 300000
          (alist-get 'text (alist-get 'reasoning (alist-get 'parts deferred))) "")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
              ((symbol-function 'dsh-bridge--request-async)
               (lambda (_method path _payload _done) (push path requests))))
      (dsh-bridge-extras-tests--with-item deferred
        (should-not requests)
        (should (string-match-p "not loaded" (buffer-string)))
        (should-not (string-match-p "reasoning" (buffer-string)))))))

(ert-deftest dsh-bridge-extras-refresh-full-loaded-requests-full ()
  "A refresh after a full load bypasses the confirmation probe."
  (dsh-bridge-extras-tests--with-item
      (dsh-bridge-extras-tests--thinking-response "short")
    (setq dsh-bridge-extras--full-loaded t)
    (let ((requests
           (dsh-bridge-extras-tests--with-requests
               (lambda (_path)
                 (cons 200 (dsh-bridge-extras-tests--thinking-response "short")))
             (dsh-bridge-extras-refresh))))
      (should (= (length requests) 1))
      (should (string-match-p "full=1" (cadr (car requests)))))))

(ert-deftest dsh-bridge-extras-refresh-re-resolves-the-same-item ()
  "Manual refresh uses no stale observation and resets the loaded content."
  (dsh-bridge-extras-tests--with-item (dsh-bridge-extras-tests--thinking-response "old")
    (let ((requests
           (dsh-bridge-extras-tests--with-requests
               (lambda (_path)
                 (cons 200 (dsh-bridge-extras-tests--thinking-response "new")))
             (dsh-bridge-extras-refresh))))
      (should (= (length requests) 1))
      (should (string-match-p "kind=thinking" (cadr (car requests))))
      (should-not (string-match-p "epoch=\\|cursor=" (cadr (car requests)))))
    (should (string-match-p "new" (buffer-string)))
    (should-not (string-match-p "old" (buffer-string)))))

(ert-deftest dsh-bridge-extras-failed-refresh-preserves-item ()
  "A failed refresh keeps the last successful item visible."
  (dsh-bridge-extras-tests--with-item (dsh-bridge-extras-tests--thinking-response "kept")
    (dsh-bridge-extras-tests--with-requests
        (lambda (_path) (cons 503 '((error . "down"))))
      (dsh-bridge-extras-refresh))
    (should (string-match-p "kept" (buffer-string)))
    (should (string-match-p "down" (buffer-string)))))

(ert-deftest dsh-bridge-extras-late-response-cannot-replace-new-item ()
  "A response from an earlier item generation is ignored."
  (let ((callbacks nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1"
                  dsh-bridge--view-turn 3)
      (let ((inhibit-read-only t))
        (insert (propertize "thinking\n" 'dsh-bridge-activity '(4 . 0))))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) buffer))
                ((symbol-function 'dsh-bridge--request-async)
                 (lambda (_method _path _payload callback)
                   (push callback callbacks))))
        (dsh-bridge-extras-inspect-item)
        (dsh-bridge-extras-inspect-item))
      (unwind-protect
          (with-current-buffer dsh-bridge-extras-buffer-name
            (let ((old (nth 1 callbacks))
                  (new (nth 0 callbacks)))
              (funcall old (cons 200 (dsh-bridge-extras-tests--thinking-response "old")))
              (should-not (string-match-p "old" (buffer-string)))
              (funcall new (cons 200 (dsh-bridge-extras-tests--thinking-response "new")))
              (should (string-match-p "new" (buffer-string)))))
        (kill-buffer dsh-bridge-extras-buffer-name)))))

(ert-deftest dsh-bridge-extras-killed-buffer-callback-is-inert ()
  "Completing a request after its inspector dies has no effect."
  (let ((callback nil)
        (buffer nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1"
                  dsh-bridge--view-turn 3)
      (let ((inhibit-read-only t))
        (insert (propertize "thinking\n" 'dsh-bridge-activity '(4 . 0))))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (target &rest _) (setq buffer target)))
                ((symbol-function 'dsh-bridge--request-async)
                 (lambda (_method _path _payload done) (setq callback done))))
        (dsh-bridge-extras-inspect-item)))
    (kill-buffer buffer)
    (should-not (funcall callback
                         (cons 200 (dsh-bridge-extras-tests--thinking-response))))))

(ert-deftest dsh-bridge-extras-json-is-pretty-printed ()
  "Valid JSON gets a readable presentation; invalid text stays verbatim."
  (with-temp-buffer
    (dsh-bridge-extras--insert-json "{\"b\":1,\"a\":[2]}")
    (should (string-match-p "\"b\": 1" (buffer-string)))
    (should-not (string-match-p "\\[raw\\]" (buffer-string))))
  (with-temp-buffer
    (dsh-bridge-extras--insert-json "not JSON")
    (should (equal (buffer-string) "not JSON\n"))))

(ert-deftest dsh-bridge-extras-diff-text-uses-diff-faces ()
  "Rendered diff lines are fontified without becoming an appliable patch."
  (with-temp-buffer
    (dsh-bridge-extras-mode)
    (let ((inhibit-read-only t))
      (dsh-bridge-extras--insert-diff-text "-old\n+new\n context\n" nil))
    (goto-char (point-min))
    (search-forward "-old")
    (should (eq (get-text-property (1- (point)) 'face)
                (if (facep 'diff-removed) 'diff-removed 'shadow)))
    (search-forward "+new")
    (should (eq (get-text-property (1- (point)) 'face)
                (if (facep 'diff-added) 'diff-added 'highlight)))))

(ert-deftest dsh-bridge-extras-file-lines-are-buttons ()
  "A changed-file line is a button reachable by mouse and RET."
  (dsh-bridge-extras-tests--with-item (dsh-bridge-extras-tests--tool-response)
    (goto-char (point-min))
    (search-forward "/work/f.txt")
    (let* ((position (match-beginning 0))
           (button (button-at position))
           (visited nil))
      (should button)
      (should (equal (button-get button 'path) "/work/f.txt"))
      (cl-letf (((symbol-function 'find-file)
                 (lambda (path &optional _wildcards) (setq visited path))))
        (push-button position)
        (should (equal visited "/work/f.txt"))))
    (goto-char (match-beginning 0))
    (let ((visited nil))
      (cl-letf (((symbol-function 'find-file)
                 (lambda (path &optional _wildcards) (setq visited path))))
        (dsh-bridge-extras-enter)
        (should (equal visited "/work/f.txt"))))))

(ert-deftest dsh-bridge-extras-markdown-unavailable-returns-nil ()
  "No Markdown installation means no error and verbatim caller fallback."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _file noerror)
               (if (eq feature 'markdown-mode) nil
                 (or noerror (signal 'file-missing (list feature)))))))
    (should-not (dsh-bridge-extras--fontify-markdown "**hi**"))))

(ert-deftest dsh-bridge-extras-markdown-transfers-only-faces ()
  "Markdown properties cannot inject keymaps, display, or invisibility."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _file noerror)
               (if (eq feature 'markdown-mode) t
                 (or noerror (signal 'file-missing (list feature))))))
            ((symbol-function 'gfm-mode) (lambda () (setq major-mode 'gfm-mode)))
            ((symbol-function 'font-lock-ensure)
             (lambda (&optional _beg _end)
               (add-text-properties (point-min) (point-max)
                                    '(face bold keymap (keymap (x . y))
                                      display "hidden" invisibility t read-only t)))))
    (let ((result (dsh-bridge-extras--fontify-markdown "hello")))
      (should (eq (get-text-property 0 'face result) 'bold))
      (should-not (get-text-property 0 'keymap result))
      (should-not (get-text-property 0 'display result))
      (should-not (get-text-property 0 'invisibility result))
      (should-not (get-text-property 0 'read-only result)))))

(ert-deftest dsh-bridge-extras-markdown-large-text-skips-fontification ()
  "Text over the byte bound is unfontified, not truncated."
  (let ((dsh-bridge-extras-markdown-byte-limit 4))
    (should-not (dsh-bridge-extras--fontify-markdown "longer than four"))))

(provide 'dsh-bridge-extras-tests)

;;; dsh-bridge-extras-tests.el ends here
