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

(defun dsh-bridge-extras-tests--page (text &optional next total more)
  "Build one direct page object for TEXT, NEXT, TOTAL, and MORE."
  (list (cons 'text text)
        (cons 'byteOffset 0)
        (cons 'nextByteOffset (or next (string-bytes text)))
        (cons 'totalBytes (or total (string-bytes text)))
        (cons 'hasMore (and more t))))

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
            (should (equal (buffer-string)
                           (concat "Thinking — step 1\n"
                                   "Session      s1   Turn 3\n"
                                   "Directory    /work\n"
                                   "Observation  epoch 2, cursor 20\n\n"
                                   "complete reasoning\n")))
            (should-not (alist-get 'entries dsh-bridge-extras--item))
            (should buffer-read-only)
            (should-not (buffer-modified-p)))
        (kill-buffer dsh-bridge-extras-buffer-name)))))

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

(ert-deftest dsh-bridge-extras-load-more-appends-one-part ()
  "L continues only the content part at point and preserves the others."
  (dsh-bridge-extras-tests--with-item
      (let ((response (dsh-bridge-extras-tests--thinking-response "first")))
        (setf (alist-get 'reasoning (alist-get 'parts response))
              (dsh-bridge-extras-tests--page "first" 5 10 t))
        response)
    (goto-char (point-min))
    (search-forward "first")
    (let ((requests
           (dsh-bridge-extras-tests--with-requests
               (lambda (_path)
                 (cons 200 `((parts . ((reasoning . ,(dsh-bridge-extras-tests--page
                                                     "-next" 10 10 nil)))))))
             (dsh-bridge-extras-load-more))))
      (should (= (length requests) 1))
      (let ((path (cadr (car requests))))
        (should (string-match-p "part=reasoning" path))
        (should (string-match-p "byteOffset=5" path))
        (should (string-match-p "epoch=2" path))
        (should (string-match-p "cursor=20" path))))
    (should (equal (plist-get (dsh-bridge-extras--part 'reasoning) :text)
                   "first-next"))))

(ert-deftest dsh-bridge-extras-load-more-diff-carries-file-index ()
  "A diff continuation identifies its file within the same observed tool item."
  (dsh-bridge-extras-tests--with-item
      (let ((response (dsh-bridge-extras-tests--tool-response)))
        (setf (alist-get 'diff (car (alist-get 'files response)))
              (dsh-bridge-extras-tests--page "File: /work/f.txt\n" 15 20 t))
        response)
    (goto-char (point-min))
    (search-forward "File:")
    (let ((requests nil))
      (setq requests
            (dsh-bridge-extras-tests--with-requests
                (lambda (_path)
                  (cons 200 (dsh-bridge-extras-tests--tool-response)))
              (dsh-bridge-extras-load-more)))
      (should (= (length requests) 1))
      (should (string-match-p "part=diff" (cadr (car requests))))
      (should (string-match-p "fileIndex=0" (cadr (car requests)))))))

(ert-deftest dsh-bridge-extras-diff-part-keeps-point-across-renders ()
  "L and g on a file diff leave point inside that same diff."
  (dsh-bridge-extras-tests--with-item
      (let ((response (dsh-bridge-extras-tests--tool-response)))
        (setf (alist-get 'diff (car (alist-get 'files response)))
              (dsh-bridge-extras-tests--page "File: /work/f.txt\n-old\n" 15 30 t))
        response)
    (goto-char (point-min))
    (search-forward "-old")
    (let ((line (line-number-at-pos)))
      (dsh-bridge-extras-tests--with-requests
          (lambda (_path)
            (cons 200 `((files . (,(dsh-bridge-extras-tests--file
                                    "/work/f.txt"
                                    (dsh-bridge-extras-tests--page "+new\n" 20 20 nil)))))))
        (dsh-bridge-extras-load-more))
      (should (= (line-number-at-pos) line))
      (dsh-bridge-extras-tests--with-requests
          (lambda (_path)
            (cons 200 (let ((response (dsh-bridge-extras-tests--tool-response)))
                        (setf (alist-get 'diff (car (alist-get 'files response)))
                              (dsh-bridge-extras-tests--page
                               "File: /work/f.txt\n-old\n+new\n" 20 20 nil))
                        response)))
        (dsh-bridge-extras-refresh))
      (should (= (line-number-at-pos) line))
      (should (string-match-p "^+new$" (buffer-string))))))

(ert-deftest dsh-bridge-extras-diff-notice-visits-its-own-file ()
  "A diff pagination notice carries its own file's absolute path."
  (dsh-bridge-extras-tests--with-item
      (let ((response (dsh-bridge-extras-tests--tool-response)))
        (setf (alist-get 'files response)
              (list (dsh-bridge-extras-tests--file
                     "/work/first.txt"
                     (dsh-bridge-extras-tests--page
                      "File: /work/first.txt\n-a\n" 15 30 t))
                    (dsh-bridge-extras-tests--file
                     "/work/second.txt"
                     (dsh-bridge-extras-tests--page
                      "File: /work/second.txt\n-b\n" 15 30 t))))
        response)
    (goto-char (point-min))
    (search-forward "File: /work/second.txt")
    (search-forward "more bytes")
    (should (equal (dsh-bridge-extras--part-at-point) '(diff 1)))
    (should (equal (dsh-bridge-extras--property-at-line 'dsh-bridge-extras-file)
                   "/work/second.txt"))
    (let ((visited nil))
      (cl-letf (((symbol-function 'find-file)
                 (lambda (path &optional _wildcards) (setq visited path))))
        (dsh-bridge-extras-visit-file))
      (should (equal visited "/work/second.txt")))))

(ert-deftest dsh-bridge-extras-pagination-notice-remains-actionable ()
  "The load-more notice belongs to the same content part as its body."
  (dsh-bridge-extras-tests--with-item
      (let ((response (dsh-bridge-extras-tests--thinking-response "first")))
        (setf (alist-get 'reasoning (alist-get 'parts response))
              (dsh-bridge-extras-tests--page "first" 5 10 t))
        response)
    (goto-char (point-min))
    (search-forward "more bytes")
    (should (equal (dsh-bridge-extras--part-at-point) 'reasoning))))

(ert-deftest dsh-bridge-extras-refresh-re-resolves-the-same-item ()
  "Manual refresh uses no stale observation and resets all part pages."
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

(ert-deftest dsh-bridge-extras-stale-page-preserves-loaded-text ()
  "A stale continuation reports an error without dropping earlier pages."
  (dsh-bridge-extras-tests--with-item
      (let ((response (dsh-bridge-extras-tests--thinking-response "first"))
            (state nil))
        (setf (alist-get 'reasoning (alist-get 'parts response))
              (dsh-bridge-extras-tests--page "first" 5 10 t))
        response)
    (goto-char (point-min))
    (search-forward "first")
    (dsh-bridge-extras-tests--with-requests
        (lambda (_path) (cons 409 '((error . "stale") (reason . "stale"))))
      (dsh-bridge-extras-load-more))
    (should (equal (plist-get (dsh-bridge-extras--part 'reasoning) :text) "first"))
    (should (string-match-p "stale" (buffer-string)))
    (should (string-match-p "press g to refresh" (buffer-string)))
    (should-not (string-match-p "press L to retry" (buffer-string)))))

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

(ert-deftest dsh-bridge-extras-json-is-pretty-printed-with-raw-access ()
  "Complete valid JSON gets a readable presentation and exact raw access."
  (with-temp-buffer
    (dsh-bridge-extras--insert-json "{\"b\":1,\"a\":[2]}" t)
    (should (string-match-p "\"b\": 1" (buffer-string)))
    (goto-char (point-min))
    (search-forward "[raw]")
    (let ((button (button-at (match-beginning 0))))
      (should button)
      (should (equal (button-get button 'raw-text) "{\"b\":1,\"a\":[2]}"))))
  (with-temp-buffer
    (dsh-bridge-extras--insert-json "not JSON" t)
    (should (equal (buffer-string) "not JSON\n"))))

(ert-deftest dsh-bridge-extras-partial-json-has-no-misleading-raw-button ()
  "Raw access waits until all argument pages are present."
  (with-temp-buffer
    (dsh-bridge-extras--insert-json "{\"b\":1}" nil)
    (should-not (string-match-p "\\[raw\\]" (buffer-string)))))

(ert-deftest dsh-bridge-extras-diff-text-uses-diff-faces ()
  "Rendered diff lines are fontified without becoming an appliable patch."
  (with-temp-buffer
    (dsh-bridge-extras-mode)
    (let ((inhibit-read-only t))
      (dsh-bridge-extras--insert-diff-text "-old\n+new\n context\n"))
    (goto-char (point-min))
    (search-forward "-old")
    (should (eq (get-text-property (1- (point)) 'face)
                (if (facep 'diff-removed) 'diff-removed 'shadow)))
    (search-forward "+new")
    (should (eq (get-text-property (1- (point)) 'face)
                (if (facep 'diff-added) 'diff-added 'highlight)))))

(ert-deftest dsh-bridge-extras-visit-file-uses-absolute-path ()
  "E visits the file metadata's absolute path."
  (dsh-bridge-extras-tests--with-item (dsh-bridge-extras-tests--tool-response)
    (goto-char (point-min))
    (search-forward "File:")
    (let ((visited nil))
      (cl-letf (((symbol-function 'find-file)
                 (lambda (path &optional _wildcards) (setq visited path))))
        (dsh-bridge-extras-visit-file))
      (should (equal visited "/work/f.txt")))))

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

(ert-deftest dsh-bridge-extras-raw-buffer-is-read-only-and-unmodified ()
  "The exact-text popup does not leave a modified buffer."
  (unwind-protect
      (progn
        (cl-letf (((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _) buffer)))
          (dsh-bridge-extras--show-raw "exact raw text"))
        (with-current-buffer dsh-bridge-extras--raw-buffer-name
          (should buffer-read-only)
          (should-not (buffer-modified-p))
          (should (equal (buffer-string) "exact raw text\n"))))
    (when (get-buffer dsh-bridge-extras--raw-buffer-name)
      (kill-buffer dsh-bridge-extras--raw-buffer-name))))

(provide 'dsh-bridge-extras-tests)

;;; dsh-bridge-extras-tests.el ends here
