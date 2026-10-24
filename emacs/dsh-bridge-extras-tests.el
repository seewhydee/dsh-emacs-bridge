;;; dsh-bridge-extras-tests.el --- ERT tests for the optional DSH inspectors  -*- lexical-binding: t; -*-

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

;;; Commentary:

;; ERT coverage for `dsh-bridge-extras'.  The no-eager-load and
;; generated-autoload checks live in the Makefile's fresh-process targets: a
;; test file that requires the extras library cannot make them order-dependent.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dsh-bridge-extras)

(defvar dsh-bridge-extras-tests--requests nil
  "Requests issued by the current test's request stub.")

(defvar dsh-bridge-extras-tests--responder nil
  "Function called by the request stub with PATH; returns (STATUS . ALIST) or nil.")

(defun dsh-bridge-extras-tests--stub-request (method path _payload callback)
  "Record METHOD/PATH and deliver the current test's response to CALLBACK."
  (push (list method path) dsh-bridge-extras-tests--requests)
  (let ((response (funcall dsh-bridge-extras-tests--responder path)))
    ;; `dsh-bridge--request-async' yields (STATUS . ALIST); tests write the
    ;; same pair as (list STATUS ALIST) for readability, so normalize here.
    (when response (funcall callback (cons (car response) (cadr response))))))

(defmacro dsh-bridge-extras-tests--with-requests (responder &rest body)
  "Run BODY with `dsh-bridge--request-async' replaced by RESPONDER."
  (declare (indent 1) (debug (form body)))
  `(let ((dsh-bridge-extras-tests--requests nil)
         (dsh-bridge-extras-tests--responder ,responder))
     (cl-letf (((symbol-function 'dsh-bridge--request-async)
                #'dsh-bridge-extras-tests--stub-request))
       ,@body)
     (nreverse dsh-bridge-extras-tests--requests)))

(defun dsh-bridge-extras-tests--index (&rest entries)
  "Build an index alist containing ENTRIES."
  (list (cons 'sessionId "s1")
        (cons 'turn 1)
        (cons 'epoch 2)
        (cons 'cursor 9)
        (cons 'open nil)
        (cons 'cwd default-directory)
        (cons 'entries entries)))

(defun dsh-bridge-extras-tests--thinking (seq ord summary &optional step)
  "Build a thinking index entry."
  (list (cons 'kind "thinking") (cons 'seq seq) (cons 'ord ord)
        (cons 'time 1000) (cons 'step (or step 0))
        (cons 'summary summary)))

(defun dsh-bridge-extras-tests--call (seq call-id name summary &optional settlement)
  "Build a tool-call index entry."
  (list (cons 'kind "tool-call") (cons 'seq seq) (cons 'time 1000)
        (cons 'step 1) (cons 'callId call-id) (cons 'name name)
        (cons 'summary summary)
        (cons 'settlement (or settlement "settled"))))

(defun dsh-bridge-extras-tests--result (seq call-id name &optional files is-error)
  "Build a tool-result index entry."
  (append (list (cons 'kind "tool-result") (cons 'seq seq) (cons 'time 1000)
                (cons 'step 1) (cons 'callId call-id) (cons 'name name)
                (cons 'settlement "settled"))
          (when is-error (list (cons 'isError t)))
          (when files (list (cons 'files files)))))

(defun dsh-bridge-extras-tests--file (path &optional status source)
  "Build a file-change summary."
  (list (cons 'path path) (cons 'absolute path)
        (cons 'pathSource (or source "recorded"))
        (cons 'status (or status "applied"))
        (cons 'fragmentCount 1)))

(defun dsh-bridge-extras-tests--inspector (index)
  "Create a read-only inspector buffer primed with INDEX."
  (let ((buffer (generate-new-buffer "*test-dsh-inspector*")))
    (with-current-buffer buffer
      (dsh-bridge-extras-mode)
      (setq dsh-bridge-extras--session "s1"
            dsh-bridge-extras--turn 1
            dsh-bridge-extras--request-turn 1
            dsh-bridge-extras--epoch 2
            dsh-bridge-extras--cursor 9
            dsh-bridge-extras--cwd default-directory
            dsh-bridge-extras--index index
            dsh-bridge-extras--details (make-hash-table :test #'equal)
            dsh-bridge-extras--inflight (make-hash-table :test #'equal)
            dsh-bridge-extras--stale-refreshed (make-hash-table :test #'equal)
            dsh-bridge-extras--expanded (make-hash-table :test #'equal)
            dsh-bridge-extras--selected nil
            dsh-bridge-extras--generation 1)
      (dsh-bridge-extras--render))
    buffer))

(defmacro dsh-bridge-extras-tests--with-inspector (index &rest body)
  "Run BODY in a fresh inspector buffer primed with INDEX."
  (declare (indent 1) (debug (form body)))
  `(let ((buffer (dsh-bridge-extras-tests--inspector ,index)))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (kill-buffer buffer))))

(defun dsh-bridge-extras-tests--point-at-key (key)
  "Move point to the header line for KEY; return non-nil on success."
  (goto-char (point-min))
  (dsh-bridge-extras--goto-key key))

(defun dsh-bridge-extras-tests--detail-response (kind text &rest extra)
  "Build a detail response for KIND with TEXT and EXTRA alist pairs."
  (list 200 (append (list (cons 'kind kind)
                          (cons 'text text)
                          (cons 'page (list (cons 'byteOffset 0)
                                            (cons 'nextByteOffset (length text))
                                            (cons 'totalBytes (length text))
                                            (cons 'hasMore nil))))
                    extra)))

;; -- Targeting ---------------------------------------------------------------

(ert-deftest dsh-bridge-extras-at-point-identity ()
  "At-point identity reads the baseline's activity and button properties."
  (with-temp-buffer
    (dsh-bridge-view-mode)
    (let ((inhibit-read-only t))
      (insert (propertize "line\n" 'dsh-bridge-activity '(4 . 2))))
    (goto-char (point-min))
    (should (equal (dsh-bridge-extras--identity-at-point)
                   (list :kind 'thinking :seq 4 :ord 2))))
  (with-temp-buffer
    (dsh-bridge-view-mode)
    (let ((inhibit-read-only t))
      (insert (propertize "line\n" 'dsh-bridge-activity "call-7")))
    (goto-char (point-min))
    (should (equal (dsh-bridge-extras--identity-at-point)
                   (list :kind 'tool-call :call-id "call-7"))))
  (with-temp-buffer
    (dsh-bridge-view-mode)
    (let ((inhibit-read-only t))
      (insert (propertize "line\n" 'dsh-bridge-activity '(tool-result . "call-8"))))
    (goto-char (point-min))
    (should (equal (dsh-bridge-extras--identity-at-point)
                   (list :kind 'tool-result :call-id "call-8")))))

(ert-deftest dsh-bridge-extras-resolve-target-keys ()
  "A target resolves to the matching entry key, including a file group."
  (let* ((file (dsh-bridge-extras-tests--file "/w/f.txt"))
         (index (dsh-bridge-extras-tests--index
                 (dsh-bridge-extras-tests--thinking 1 0 "think")
                 (dsh-bridge-extras-tests--result 2 "c1" "edit" (list file))))
         (thinking (dsh-bridge-extras--key-for-target
                    (list :kind 'thinking :seq 1 :ord 0) index))
         (file-key (dsh-bridge-extras--key-for-target
                    (list :kind 'file-diff :path "/w/f.txt") index)))
    (should (equal thinking '(thinking 1 0)))
    (should (equal file-key '(file-diff 2 nil)))
    (should (equal dsh-bridge-extras--focus-file "/w/f.txt"))))

(ert-deftest dsh-bridge-extras-inspect-opens-and-selects-shown-turn ()
  "Inspect-turn opens a read-only buffer and fetches the concrete turn."
  (let* ((index (dsh-bridge-extras-tests--index
                 (dsh-bridge-extras-tests--thinking 1 0 "think")))
         (requests
          (dsh-bridge-extras-tests--with-requests
              (lambda (_path) (list 200 index))
            (dsh-bridge-extras-inspect-turn nil "s1" 1))))
    (unwind-protect
        (with-current-buffer dsh-bridge-extras-buffer-name
          (should (derived-mode-p 'dsh-bridge-extras-mode))
          (should buffer-read-only)
          (should (equal dsh-bridge-extras--turn 1))
          (should (equal dsh-bridge-extras--epoch 2))
          (should (equal dsh-bridge-extras--cursor 9))
          (should (string-match-p "DSH Inspector" (buffer-string)))
          (should (string-match-p "think" (buffer-string)))
          (should (equal (length requests) 1))
          (should (string-match-p "turn=1" (cadr (car requests))))
          (should-not (string-match-p "latest" (cadr (car requests)))))
      (kill-buffer dsh-bridge-extras-buffer-name))))

(ert-deftest dsh-bridge-extras-inspect-from-view-uses-shown-turn-and-point ()
  "A DSH-View invocation targets the shown turn and the entry at point."
  (let* ((index (dsh-bridge-extras-tests--index
                 (dsh-bridge-extras-tests--thinking 1 0 "shown")
                 (dsh-bridge-extras-tests--thinking 2 0 "other")))
         (requests nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq dsh-bridge--view-content-session "s1"
            dsh-bridge--view-turn 1)
      (let ((inhibit-read-only t))
        (insert (propertize "shown\n" 'dsh-bridge-activity '(1 . 0)))
        (goto-char (point-min)))
      (setq requests
            (dsh-bridge-extras-tests--with-requests
                (lambda (_path) (list 200 index))
              (dsh-bridge-extras-inspect-turn nil "s1" nil))))
    (unwind-protect
        (with-current-buffer dsh-bridge-extras-buffer-name
          (should (equal (length requests) 1))
          (should (string-match-p "turn=1" (cadr (car requests))))
          (should (equal dsh-bridge-extras--selected '(thinking 1 0))))
      (kill-buffer dsh-bridge-extras-buffer-name))))

(ert-deftest dsh-bridge-extras-inspect-dispatcher-retarget-ignores-view-context ()
  "A dispatcher focus on another session selects that session's latest turn."
  (let ((view (generate-new-buffer "*test-dsh-view*"))
        (index (list (cons 'sessionId "s2") (cons 'turn 8)
                     (cons 'epoch 4) (cons 'cursor 20)
                     (cons 'entries
                          (list (dsh-bridge-extras-tests--thinking 9 0 "first")
                                (dsh-bridge-extras-tests--thinking 1 0 "target")))))
        (requests nil))
    (unwind-protect
        (progn
          (with-current-buffer view
            (dsh-bridge-view-mode)
            (setq dsh-bridge--view-content-session "s1"
                  dsh-bridge--view-turn 3)
            (let ((inhibit-read-only t))
              (insert (propertize "target\n" 'dsh-bridge-activity '(1 . 0))))
            (goto-char (point-min)))
          (let ((transient--prefix t)
                (transient--original-buffer view)
                (dsh-bridge--focus (cons "s2" 'cycled)))
            (with-temp-buffer
              (setq requests
                    (dsh-bridge-extras-tests--with-requests
                        (lambda (_path) (list 200 index))
                      (dsh-bridge-extras-inspect-turn)))))
          (with-current-buffer dsh-bridge-extras-buffer-name
            (should (equal dsh-bridge-extras--session "s2"))
            (should (equal dsh-bridge-extras--turn 8))
            (should (equal dsh-bridge-extras--selected '(thinking 9 0)))
            (should (string-match-p "turn=latest" (cadr (car requests))))
            (should-not (string-match-p "turn=3" (cadr (car requests))))))
      (when (buffer-live-p view) (kill-buffer view))
      (when (get-buffer dsh-bridge-extras-buffer-name)
        (kill-buffer dsh-bridge-extras-buffer-name)))))

(ert-deftest dsh-bridge-extras-inspect-prefix-retarget-ignores-view-context ()
  "A prefix-selected session never inherits the current view's turn or point."
  (let ((index (list (cons 'sessionId "s2") (cons 'turn 7)
                     (cons 'epoch 4) (cons 'cursor 20)
                     (cons 'entries
                          (list (dsh-bridge-extras-tests--thinking 9 0 "first")
                                (dsh-bridge-extras-tests--thinking 1 0 "target")))))
        (requests nil))
    (unwind-protect
        (with-temp-buffer
          (dsh-bridge-view-mode)
          (setq dsh-bridge--view-content-session "s1"
                dsh-bridge--view-turn 3)
          (let ((inhibit-read-only t))
            (insert (propertize "target\n" 'dsh-bridge-activity '(1 . 0))))
          (goto-char (point-min))
          (let ((current-prefix-arg '(4)))
            (cl-letf (((symbol-function 'dsh-bridge--read-session-id)
                       (lambda (_prompt) "s2")))
              (setq requests
                    (dsh-bridge-extras-tests--with-requests
                        (lambda (_path) (list 200 index))
                      (dsh-bridge-extras-inspect-turn '(4))))))
          (with-current-buffer dsh-bridge-extras-buffer-name
            (should (equal dsh-bridge-extras--session "s2"))
            (should (equal dsh-bridge-extras--turn 7))
            (should (equal dsh-bridge-extras--selected '(thinking 9 0)))
            (should (string-match-p "turn=latest" (cadr (car requests))))
            (should-not (string-match-p "turn=3" (cadr (car requests))))))
      (when (get-buffer dsh-bridge-extras-buffer-name)
        (kill-buffer dsh-bridge-extras-buffer-name)))))

(ert-deftest dsh-bridge-extras-inspect-without-session-refuses ()
  "Inspect-turn refuses rather than falling back to the last-active session."
  (cl-letf (((symbol-function 'dsh-bridge--session-for-command) (lambda (_prompt) nil)))
    (should-error (dsh-bridge-extras-inspect-turn nil nil 'latest) :type 'user-error)))

;; -- Disclosure, navigation, and read-only rendering --------------------------

(ert-deftest dsh-bridge-extras-toggle-fetches-and-renders ()
  "Toggling an entry fetches its detail and discloses it in place."
  (let* ((index (dsh-bridge-extras-tests--index
                 (dsh-bridge-extras-tests--thinking 1 0 "think")
                 (dsh-bridge-extras-tests--thinking 2 0 "second")))
         (requests nil))
    (dsh-bridge-extras-tests--with-inspector index
      (should (dsh-bridge-extras-tests--point-at-key '(thinking 1 0)))
      (setq requests
            (dsh-bridge-extras-tests--with-requests
                (lambda (_path) (dsh-bridge-extras-tests--detail-response
                                 "thinking" "complete reasoning\n"))
              (dsh-bridge-extras-toggle)))
      (should (gethash '(thinking 1 0) dsh-bridge-extras--expanded))
      (should (string-match-p "complete reasoning" (buffer-string)))
      (should (equal (length requests) 1))
      (should (string-match-p "kind=thinking" (cadr (car requests))))
      (should (string-match-p "ord=0" (cadr (car requests))))
      (should buffer-read-only))))

(ert-deftest dsh-bridge-extras-toggle-hides-without-new-request ()
  "Toggling an already-fetched entry hides it without another request."
  (let* ((index (dsh-bridge-extras-tests--index
                 (dsh-bridge-extras-tests--thinking 1 0 "think")))
         (detail (dsh-bridge-extras-tests--detail-response "thinking" "body\n")))
    (dsh-bridge-extras-tests--with-inspector index
      (puthash '(thinking 1 0)
               (list :response (cadr detail) :text "body\n" :next 0 :hasMore nil)
               dsh-bridge-extras--details)
      (puthash '(thinking 1 0) t dsh-bridge-extras--expanded)
      (dsh-bridge-extras--render)
      (should (string-match-p "body" (buffer-string)))
      (dsh-bridge-extras-tests--point-at-key '(thinking 1 0))
      (let ((requests (dsh-bridge-extras-tests--with-requests
                          (lambda (_path) (should nil))
                        (dsh-bridge-extras-toggle))))
        (should-not requests)
        (should-not (gethash '(thinking 1 0) dsh-bridge-extras--expanded))
        (should-not (string-match-p "body" (buffer-string)))))))

(ert-deftest dsh-bridge-extras-navigation-walks-headers ()
  "n/p move between entry headers and update the selected key."
  (let ((index (dsh-bridge-extras-tests--index
                (dsh-bridge-extras-tests--thinking 1 0 "one")
                (dsh-bridge-extras-tests--thinking 2 0 "two"))))
    (dsh-bridge-extras-tests--with-inspector index
      (dsh-bridge-extras--render)
      (dsh-bridge-extras-tests--point-at-key '(thinking 1 0))
      (dsh-bridge-extras-next-entry)
      (should (equal (dsh-bridge-extras--key-at-point) '(thinking 2 0)))
      (dsh-bridge-extras-previous-entry)
      (should (equal (dsh-bridge-extras--key-at-point) '(thinking 1 0))))))

(ert-deftest dsh-bridge-extras-refresh-refetches-expanded-details ()
  "A new observation clears bodies but refills still-expanded entries."
  (let* ((old (dsh-bridge-extras-tests--index
               (dsh-bridge-extras-tests--thinking 1 0 "kept")))
         (new (list (cons 'sessionId "s1") (cons 'turn 1) (cons 'epoch 3)
                    (cons 'cursor 10) (cons 'open nil)
                    (cons 'entries (list (dsh-bridge-extras-tests--thinking 1 0 "kept")))))
         (requests nil))
    (dsh-bridge-extras-tests--with-inspector old
      (puthash '(thinking 1 0) t dsh-bridge-extras--expanded)
      (puthash '(thinking 1 0)
               (list :response '((kind . "thinking")) :text "old body" :next 0 :hasMore nil)
               dsh-bridge-extras--details)
      (dsh-bridge-extras--render)
      (setq requests
            (dsh-bridge-extras-tests--with-requests
                (lambda (_path) (dsh-bridge-extras-tests--detail-response "thinking" "new body\n"))
              (dsh-bridge-extras--handle-index (cons 200 new) 1 "s1" 1)))
      (should (equal (length requests) 1))
      (should (string-match-p "/details/entry" (cadr (car requests))))
      (should (string-match-p "new body" (buffer-string)))
      (should-not (string-match-p "old body" (buffer-string))))))

(ert-deftest dsh-bridge-extras-failed-refresh-preserves-content ()
  "A failed refresh keeps the previous index and reports the failure."
  (let ((index (dsh-bridge-extras-tests--index
                (dsh-bridge-extras-tests--thinking 1 0 "kept"))))
    (dsh-bridge-extras-tests--with-inspector index
      (dsh-bridge-extras--render)
      (dsh-bridge-extras-tests--with-requests
          (lambda (_path) (list 503 '((error . "down"))))
        (dsh-bridge-extras-refresh))
      (should (equal dsh-bridge-extras--turn 1))
      (should (string-match-p "kept" (buffer-string))))))

(ert-deftest dsh-bridge-extras-failed-entry-shows-error ()
  "A failed detail request is shown without dropping the index."
  (let ((index (dsh-bridge-extras-tests--index
                (dsh-bridge-extras-tests--thinking 1 0 "kept"))))
    (dsh-bridge-extras-tests--with-inspector index
      (dsh-bridge-extras--render)
      (dsh-bridge-extras-tests--point-at-key '(thinking 1 0))
      (dsh-bridge-extras-tests--with-requests
          (lambda (_path) (list 404 '((error . "no entry"))))
        (dsh-bridge-extras-toggle))
      (should (string-match-p "no entry" (buffer-string)))
      (should (string-match-p "kept" (buffer-string))))))

(ert-deftest dsh-bridge-extras-stale-entry-refreshes-index ()
  "A 409 stale entry response triggers an index refresh."
  (let* ((index (dsh-bridge-extras-tests--index
                 (dsh-bridge-extras-tests--thinking 1 0 "kept")))
         (requests nil))
    (dsh-bridge-extras-tests--with-inspector index
      (dsh-bridge-extras--render)
      (dsh-bridge-extras-tests--point-at-key '(thinking 1 0))
      (setq requests
            (dsh-bridge-extras-tests--with-requests
                (lambda (path)
                  (if (string-match-p "/details/entry" path)
                      (list 409 '((error . "stale") (reason . "stale")))
                    (list 200 index)))
              (dsh-bridge-extras-toggle)))
      (should (>= (length requests) 2))
      (should (string-match-p "/details/entry" (cadr (car requests))))
      (should (seq-some (lambda (request)
                          (string-match-p "/details/turn" (cadr request)))
                        requests)))))

(ert-deftest dsh-bridge-extras-stale-index-response-is-ignored ()
  "An index response from an older generation never overwrites newer state."
  (let* ((old (dsh-bridge-extras-tests--index
               (dsh-bridge-extras-tests--thinking 1 0 "old")))
         (new (list (cons 'sessionId "s1") (cons 'turn 2) (cons 'epoch 3)
                    (cons 'cursor 12) (cons 'open nil)
                    (cons 'entries (list (dsh-bridge-extras-tests--thinking 5 0 "new"))))))
    (dsh-bridge-extras-tests--with-inspector old
      (dsh-bridge-extras--render)
      (setq dsh-bridge-extras--generation 2)
      (dsh-bridge-extras--handle-index (cons 200 old) 1 "s1" 1)
      (should (equal dsh-bridge-extras--turn 1))
      (dsh-bridge-extras--handle-index (cons 200 new) 2 "s1" 1)
      (should (equal dsh-bridge-extras--turn 2))
      (should (string-match-p "new" (buffer-string)))
      (should-not (string-match-p "old" (buffer-string))))))

(ert-deftest dsh-bridge-extras-refresh-drops-removed-expanded-entries ()
  "A turn change refills surviving entries but never removed expanded keys."
  (let* ((old (dsh-bridge-extras-tests--index
               (dsh-bridge-extras-tests--thinking 1 0 "removed")
               (dsh-bridge-extras-tests--thinking 2 0 "kept")))
         (new (list (cons 'sessionId "s1") (cons 'turn 2)
                    (cons 'epoch 3) (cons 'cursor 10)
                    (cons 'entries
                          (list (dsh-bridge-extras-tests--thinking 2 0 "kept")))))
         (requests nil))
    (dsh-bridge-extras-tests--with-inspector old
      (puthash '(thinking 1 0) t dsh-bridge-extras--expanded)
      (puthash '(thinking 2 0) t dsh-bridge-extras--expanded)
      (setq requests
            (dsh-bridge-extras-tests--with-requests
                (lambda (_path)
                  (dsh-bridge-extras-tests--detail-response "thinking" "new body\n"))
              (dsh-bridge-extras--handle-index (cons 200 new) 1 "s1" 1)))
      (should (equal (length requests) 1))
      (should (string-match-p "seq=2" (cadr (car requests))))
      (should-not (gethash '(thinking 1 0) dsh-bridge-extras--expanded))
      (should (gethash '(thinking 2 0) dsh-bridge-extras--expanded))
      (should (string-match-p "new body" (buffer-string)))
      (should-not (string-match-p "removed" (buffer-string))))))

(ert-deftest dsh-bridge-extras-stale-detail-cannot-clear-replacement ()
  "A stale callback leaves its replacement in flight and duplicate calls share it."
  (let ((index (dsh-bridge-extras-tests--index
                (dsh-bridge-extras-tests--thinking 1 0 "think")))
        (callbacks nil))
    (dsh-bridge-extras-tests--with-inspector index
      (cl-letf (((symbol-function 'dsh-bridge--request-async)
                 (lambda (_method _path _payload callback)
                   (setq callbacks (append callbacks (list callback))))))
        (dsh-bridge-extras--fetch-detail '(thinking 1 0))
        (dsh-bridge-extras--fetch-detail '(thinking 1 0))
        (should (equal (length callbacks) 1))
        (setq dsh-bridge-extras--generation 2
              dsh-bridge-extras--epoch 3
              dsh-bridge-extras--cursor 10
              dsh-bridge-extras--inflight (make-hash-table :test #'equal))
        (dsh-bridge-extras--fetch-detail '(thinking 1 0))
        (should (equal (length callbacks) 2))
        (funcall (car callbacks)
                 (cons 200 '((kind . "thinking") (text . "old"))))
        (should (gethash '(thinking 1 0) dsh-bridge-extras--inflight))
        (should-not (dsh-bridge-extras--detail '(thinking 1 0)))
        (funcall (cadr callbacks)
                 (cons 200 '((kind . "thinking") (text . "new"))))
        (should-not (gethash '(thinking 1 0) dsh-bridge-extras--inflight))
        (should (equal (plist-get (dsh-bridge-extras--detail '(thinking 1 0)) :text)
                       "new"))))))

(ert-deftest dsh-bridge-extras-killed-buffer-detail-callback-is-inert ()
  "Completing a detail request after its inspector dies has no effect."
  (let* ((index (dsh-bridge-extras-tests--index
                 (dsh-bridge-extras-tests--thinking 1 0 "think")))
         (buffer (dsh-bridge-extras-tests--inspector index))
         (callback nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'dsh-bridge--request-async)
                       (lambda (_method _path _payload done)
                         (setq callback done))))
              (dsh-bridge-extras--fetch-detail '(thinking 1 0))))
          (kill-buffer buffer)
          (should-not (buffer-live-p buffer))
          (should callback)
          (should-not (funcall callback
                               (cons 200 '((kind . "thinking") (text . "late"))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest dsh-bridge-extras-changing-stale-observations-stop-looping ()
  "Changing observations cannot cause a stale-refresh loop; explicit g can retry."
  (let* ((entry (dsh-bridge-extras-tests--thinking 1 0 "think"))
         (index (dsh-bridge-extras-tests--index entry))
         (refreshes 0)
         (responder
          (lambda (path)
            (if (string-match-p "/details/entry" path)
                (list 409 '((error . "stale") (reason . "stale")))
              (setq refreshes (1+ refreshes))
              (list 200 (list (cons 'sessionId "s1") (cons 'turn 1)
                              (cons 'epoch (+ 2 refreshes))
                              (cons 'cursor (+ 9 refreshes))
                              (cons 'entries (list entry)))))))
         (requests nil))
    (dsh-bridge-extras-tests--with-inspector index
      (dsh-bridge-extras-tests--point-at-key '(thinking 1 0))
      (setq requests
            (dsh-bridge-extras-tests--with-requests responder
              (dsh-bridge-extras-toggle)))
      (should (equal refreshes 1))
      (should (equal (cl-count-if
                      (lambda (request) (string-match-p "/details/entry" (cadr request)))
                      requests)
                     2))
      (should (string-match-p "observation moved; press g"
                              (or (plist-get (dsh-bridge-extras--detail '(thinking 1 0))
                                             :error)
                                  "")))
      (setq requests
            (append requests
                    (dsh-bridge-extras-tests--with-requests responder
                      (dsh-bridge-extras-refresh))))
      (should (equal refreshes 3))
      (should (equal (cl-count-if
                      (lambda (request) (string-match-p "/details/entry" (cadr request)))
                      requests)
                     4))
      (should (equal (cl-count-if
                      (lambda (request) (string-match-p "/details/turn" (cadr request)))
                      requests)
                     3)))))

;; -- Pagination --------------------------------------------------------------

(ert-deftest dsh-bridge-extras-load-more-appends-pages ()
  "L fetches the next page and appends it to the disclosed entry."
  (let ((index (dsh-bridge-extras-tests--index
                (dsh-bridge-extras-tests--thinking 1 0 "think")))
        (requests nil))
    (dsh-bridge-extras-tests--with-inspector index
      (puthash '(thinking 1 0)
               (list :response '((kind . "thinking"))
                     :text "first "
                     :next 6
                     :hasMore t)
               dsh-bridge-extras--details)
      (puthash '(thinking 1 0) t dsh-bridge-extras--expanded)
      (setq dsh-bridge-extras--selected '(thinking 1 0))
      (dsh-bridge-extras--render)
      (setq requests
            (dsh-bridge-extras-tests--with-requests
                (lambda (_path)
                  (list 200 (list (cons 'kind "thinking")
                                  (cons 'text "second")
                                  (cons 'page (list (cons 'nextByteOffset 12)
                                                    (cons 'hasMore nil))))))
              (dsh-bridge-extras-load-more)))
      (should (equal (length requests) 1))
      (should (string-match-p "byteOffset=6" (cadr (car requests))))
      (should (equal (plist-get (gethash '(thinking 1 0) dsh-bridge-extras--details) :text)
                     "first second"))
      (should (string-match-p "first second" (buffer-string))))))

(ert-deftest dsh-bridge-extras-page-error-preserves-pages-and-can-retry ()
  "A later-page error preserves loaded text, remaining bytes, and L retry."
  (let ((index (dsh-bridge-extras-tests--index
                (dsh-bridge-extras-tests--thinking 1 0 "think")))
        (requests nil))
    (dsh-bridge-extras-tests--with-inspector index
      (puthash '(thinking 1 0)
               (list :response '((kind . "thinking"))
                     :text "first page\n"
                     :next 11
                     :total 30
                     :hasMore t)
               dsh-bridge-extras--details)
      (puthash '(thinking 1 0) t dsh-bridge-extras--expanded)
      (setq dsh-bridge-extras--selected '(thinking 1 0))
      (dsh-bridge-extras--render)
      (should (string-match-p "19 more bytes" (buffer-string)))
      (setq requests
            (dsh-bridge-extras-tests--with-requests
                (lambda (_path) (list 503 '((error . "down"))))
              (dsh-bridge-extras-load-more)))
      (should (string-match-p "byteOffset=11" (cadr (car requests))))
      (should (string-match-p "first page" (buffer-string)))
      (should (string-match-p "Could not load more.*press L to retry"
                              (buffer-string)))
      (should (string-match-p "19 more bytes" (buffer-string)))
      (should-not (string-match-p "11 more bytes" (buffer-string)))
      (setq requests
            (dsh-bridge-extras-tests--with-requests
                (lambda (_path)
                  (list 200 (list (cons 'kind "thinking")
                                  (cons 'text "second")
                                  (cons 'page
                                        (list (cons 'nextByteOffset 17)
                                              (cons 'totalBytes 30)
                                              (cons 'hasMore t))))))
              (dsh-bridge-extras-load-more)))
      (should (string-match-p "byteOffset=11" (cadr (car requests))))
      (should (equal (plist-get (dsh-bridge-extras--detail '(thinking 1 0)) :text)
                     "first page\nsecond"))
      (should-not (plist-get (dsh-bridge-extras--detail '(thinking 1 0)) :error))
      (should (string-match-p "13 more bytes" (buffer-string))))))

;; -- Markdown ----------------------------------------------------------------

(ert-deftest dsh-bridge-extras-markdown-unavailable-uses-reasoning-face ()
  "Without Markdown mode, reasoning text is verbatim with the reasoning face."
  (should-not (dsh-bridge-extras--fontify-markdown "text"))
  (with-temp-buffer
    (dsh-bridge-extras--insert-markdown "verbatim `code`")
    (should (equal (buffer-string) "verbatim `code`\n"))
    (should (eq (get-text-property (point-min) 'face)
                'dsh-bridge-view-thinking-face))))

(ert-deftest dsh-bridge-extras-markdown-transfers-only-whitelisted-properties ()
  "The Markdown branch keeps face/font-lock-face and drops keymaps/display."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _file noerror)
               (if (eq feature 'markdown-mode) t
                 (or noerror (signal 'file-missing (list feature))))))
            ((symbol-function 'gfm-mode)
             (lambda () (setq major-mode 'gfm-mode)))
            ((symbol-function 'font-lock-ensure)
             (lambda (&optional _beg _end)
               (add-text-properties (point-min) (point-max)
                                    '(face bold
                                      keymap (keymap (x . y))
                                      display "hidden"
                                      invisibility t
                                      read-only t)))))
    (let ((result (dsh-bridge-extras--fontify-markdown "hello")))
      (should result)
      (should (eq (get-text-property 0 'face result) 'bold))
      (should-not (get-text-property 0 'font-lock-face result))
      (should-not (get-text-property 0 'keymap result))
      (should-not (get-text-property 0 'display result))
      (should-not (get-text-property 0 'invisibility result))
      (should-not (get-text-property 0 'read-only result)))))

(ert-deftest dsh-bridge-extras-markdown-large-text-skips-fontification ()
  "Text over the byte bound is returned unfontified, not truncated."
  (let ((dsh-bridge-extras-markdown-byte-limit 4))
    (should-not (dsh-bridge-extras--fontify-markdown "longer than four"))))

;; -- Diff rendering and file visits -----------------------------------------

(ert-deftest dsh-bridge-extras-diff-text-uses-diff-faces ()
  "Rendered diff lines are fontified without becoming an appliable patch."
  (with-temp-buffer
    (dsh-bridge-extras-mode)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dsh-bridge-extras--insert-diff-text
       "File: /w/f.txt\n  status: applied\n-b\n+c\n context\n"))
    (goto-char (point-min))
    (search-forward "-b")
    (should (eq (get-text-property (1- (point)) 'face)
                (if (facep 'diff-removed) 'diff-removed 'shadow)))
    (goto-char (point-min))
    (search-forward "+c")
    (should (eq (get-text-property (1- (point)) 'face)
                (if (facep 'diff-added) 'diff-added 'highlight)))))

(ert-deftest dsh-bridge-extras-visit-file-uses-absolute-path ()
  "e visits the file line's absolute path."
  (let ((visited nil))
    (cl-letf (((symbol-function 'find-file)
               (lambda (path &optional _wildcards) (setq visited path))))
      (with-temp-buffer
        (dsh-bridge-extras-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize "f.txt\n" 'dsh-bridge-extras-file "/w/f.txt")))
        (goto-char (point-min))
        (dsh-bridge-extras-visit-file)))
    (should (equal visited "/w/f.txt"))))

(ert-deftest dsh-bridge-extras-file-group-selects-path ()
  "A file group is expandable and its path line carries the file property."
  (let* ((file (dsh-bridge-extras-tests--file "/w/f.txt"))
         (index (dsh-bridge-extras-tests--index
                 (dsh-bridge-extras-tests--result 2 "c1" "edit" (list file)))))
    (dsh-bridge-extras-tests--with-inspector index
      (dsh-bridge-extras--render)
      (should (dsh-bridge-extras--goto-key '(file-diff 2 nil)))
      (should (equal (get-text-property (point) 'dsh-bridge-extras-entry)
                     '(file-diff 2 nil)))
      (goto-char (point-min))
      (should (search-forward "/w/f.txt" nil t))
      (should (equal (get-text-property (1- (point)) 'dsh-bridge-extras-file)
                     "/w/f.txt")))))

(ert-deftest dsh-bridge-extras-header-reports-truncated-index ()
  "The inspector makes entries dropped by the index bound visible."
  (let ((index (append (dsh-bridge-extras-tests--index
                        (dsh-bridge-extras-tests--thinking 1 0 "think"))
                       '((truncated . t) (droppedEntries . 3)))))
    (dsh-bridge-extras-tests--with-inspector index
      (should (string-match-p "index truncated; 3 older entries not shown"
                              (buffer-string))))))

(ert-deftest dsh-bridge-extras-json-is-pretty-printed-with-raw-access ()
  "Valid JSON gets a readable presentation, raw access, and verbatim fallback."
  (with-temp-buffer
    (dsh-bridge-extras--insert-json "{\"b\":1,\"a\":[2]}")
    (should (string-match-p "\"b\": 1" (buffer-string)))
    (should (string-match-p "\"a\": \\[" (buffer-string)))
    (goto-char (point-min))
    (search-forward "[raw]")
    (let ((button (button-at (match-beginning 0))))
      (should button)
      (should (equal (button-get button 'raw-text) "{\"b\":1,\"a\":[2]}"))))
  (with-temp-buffer
    (dsh-bridge-extras--insert-json "not JSON")
    (should (equal (buffer-string) "not JSON\n"))))

(ert-deftest dsh-bridge-extras-rendered-buffers-are-unmodified ()
  "Inspector renders and raw-text updates do not leave buffers modified."
  (let ((index (dsh-bridge-extras-tests--index
                (dsh-bridge-extras-tests--thinking 1 0 "think"))))
    (dsh-bridge-extras-tests--with-inspector index
      (set-buffer-modified-p t)
      (dsh-bridge-extras--render)
      (should-not (buffer-modified-p))))
  (unwind-protect
      (progn
        (cl-letf (((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _args) buffer)))
          (dsh-bridge-extras--show-raw "exact raw text"))
        (with-current-buffer dsh-bridge-extras--raw-buffer-name
          (should buffer-read-only)
          (should-not (buffer-modified-p))
          (should (equal (buffer-string) "exact raw text\n"))))
    (when (get-buffer dsh-bridge-extras--raw-buffer-name)
      (kill-buffer dsh-bridge-extras--raw-buffer-name))))

(provide 'dsh-bridge-extras-tests)

;;; dsh-bridge-extras-tests.el ends here
