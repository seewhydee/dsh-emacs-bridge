;;; dsh-bridge-tests.el --- ERT tests for dsh-bridge -*- lexical-binding: t; -*-

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

;; Run with:
;;   emacs --batch -L emacs -l emacs/dsh-bridge-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dsh-bridge)

;;; Low-level HTTP plumbing

(ert-deftest dsh-bridge-path-no-session ()
  (should (equal (dsh-bridge--path "/output" nil) "/output")))

(ert-deftest dsh-bridge-path-with-session ()
  (should (equal (dsh-bridge--path "/output" "session-1")
                 "/output?sessionId=session-1")))

(defmacro dsh-bridge-test--with-token-file (content &rest body)
  "Run BODY with `dsh-bridge-token-file' bound to a temp file holding CONTENT."
  (declare (indent 1))
  `(let* ((file (make-temp-file "dsh-bridge-token"))
          (dsh-bridge-token-file file))
     (unwind-protect
         (progn
           (with-temp-file file (insert ,content))
           ,@body)
       (delete-file file))))

(ert-deftest dsh-bridge-extra-headers-with-token ()
  (dsh-bridge-test--with-token-file "secret"
    (should (equal (dsh-bridge--extra-headers nil)
                   '(("Authorization" . "Bearer secret"))))))

(ert-deftest dsh-bridge-extra-headers-with-payload-and-token ()
  (dsh-bridge-test--with-token-file "secret"
    (should (equal (dsh-bridge--extra-headers '((text . "x")))
                   '(("Content-Type" . "application/json")
                     ("Authorization" . "Bearer secret"))))))

(ert-deftest dsh-bridge-extra-headers-no-token ()
  (let ((dsh-bridge-token-file "/nonexistent/dsh-bridge-token"))
    (should (equal (dsh-bridge--extra-headers nil) nil))))

(ert-deftest dsh-bridge-extra-headers-token-is-unibyte ()
  ;; A multibyte (even pure-ASCII) token header value poisons url-http's
  ;; request concatenation: a body containing non-ASCII bytes then fails
  ;; with "Multibyte text in HTTP request" (bug#23750).  The token is read
  ;; from the file as multibyte text, then coerced to unibyte.
  (dsh-bridge-test--with-token-file "secret"
    (dolist (pair (dsh-bridge--extra-headers '((text . "x"))))
      (should-not (multibyte-string-p (car pair)))
      (should-not (multibyte-string-p (cdr pair))))))

(ert-deftest dsh-bridge-error-message-http-status ()
  (should (equal (dsh-bridge--error-message nil 401 '((error . "unauthorized")))
                 "HTTP 401: unauthorized")))

(ert-deftest dsh-bridge-error-message-transport ()
  (should (equal (dsh-bridge--error-message '(:error "connection refused") nil nil)
                 "request failed: connection refused")))

(ert-deftest dsh-bridge-error-message-body-error ()
  (should (equal (dsh-bridge--error-message nil 200 '((error . "boom"))) "boom")))

(ert-deftest dsh-bridge-error-message-success ()
  (should (equal (dsh-bridge--error-message nil 200 '((ok . t))) nil)))

;;; Targeting: the effective-session rule and the default target

(ert-deftest dsh-bridge-effective-session-default-only ()
  "With no buffer session, the effective session is the default target."
  (let ((dsh-bridge-default-session "s1"))
    (with-temp-buffer
      (should (equal (dsh-bridge--effective-session) "s1")))))

(ert-deftest dsh-bridge-effective-session-nil-without-default ()
  "With no buffer session and no default target, the effective session is nil
(last-active)."
  (let ((dsh-bridge-default-session nil))
    (with-temp-buffer
      (should (null (dsh-bridge--effective-session))))))

(ert-deftest dsh-bridge-effective-session-prompt-binding-wins ()
  "A prompt-buffer binding beats the default target."
  (let ((dsh-bridge-default-session "default"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "bound")
      (should (equal (dsh-bridge--effective-session) "bound")))))

(ert-deftest dsh-bridge-effective-session-output-content-wins ()
  "The output buffer's shown session beats the default target."
  (let ((dsh-bridge-default-session "default"))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "shown")
      (should (equal (dsh-bridge--effective-session) "shown")))))

(ert-deftest dsh-bridge-set-default-target-local ()
  "`dsh-bridge-set-default-target' sets the Emacs-side default directly and
never POSTs /select (the host pin is gone)."
  (let ((dsh-bridge-default-session "old") (posts nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method path _payload)
                 (when (equal method "POST") (push path posts))
                 (cons 200 (list (cons 'sessions nil))))))
      (dsh-bridge-set-default-target "new"))
    (should (equal dsh-bridge-default-session "new"))
    (should-not (member "/select" posts))))

(ert-deftest dsh-bridge-clear-default-target-local ()
  "`dsh-bridge-clear-default-target' clears the default target, no host
round-trip."
  (let ((dsh-bridge-default-session "pinned"))
    (dsh-bridge-clear-default-target))
  (should (null dsh-bridge-default-session)))

(ert-deftest dsh-bridge-set-default-target-offers-saved-sessions ()
  "Completion offers live and saved sessions (plus the last-active choice)."
  (let ((table-seen nil)
        (dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda ()
                 '(((id . "live-1") (live . t) (cwd . "/a"))
                   ((id . "saved-1") (live . nil) (cwd . "/b")))))
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _rest)
                 (setq table-seen table)
                 "(last-active)")))
      (call-interactively #'dsh-bridge-set-default-target))
    (should (equal (all-completions "" table-seen)
                   '("live-1" "saved-1" "(last-active)")))))

(ert-deftest dsh-bridge-dispatcher-header-labels ()
  "The dispatcher header labels the effective session with the right qualifier.
A leading space (protecting the status glyph from the menu cursor) is
present iff the indicator style produces a glyph."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (dsh-bridge--session-status '(("s1" . idle)))
        (dsh-bridge-status-indicator 'geometric))
    ;; Bound buffer session: plain label.
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      ;; string-equal: the glyph carries face properties.
      (should (string-equal (dsh-bridge--dispatcher-header) " ● T")))
    ;; Default target: (default) qualifier.
    (with-temp-buffer
      (let ((dsh-bridge-default-session "s1"))
        (should (string-equal (dsh-bridge--dispatcher-header) " ● T (default)"))))
    ;; Resolved last-active: (last active) qualifier.
    (with-temp-buffer
      (let ((dsh-bridge-default-session nil)
            (dsh-bridge--last-resolved-active '("s1" . "T")))
        (should (string-equal (dsh-bridge--dispatcher-header)
                              " ● T (last active)"))))
    ;; Resolved last-active without a label: computed from the id.
    (with-temp-buffer
      (let ((dsh-bridge-default-session nil)
            (dsh-bridge--last-resolved-active '("s1" . nil)))
        (should (string-equal (dsh-bridge--dispatcher-header)
                              " ● T (last active)"))))
    ;; Nothing bound and nothing resolved: the cache's last-active live
    ;; session is named, with the (last active) qualifier.
    (with-temp-buffer
      (let ((dsh-bridge-default-session nil)
            (dsh-bridge--last-resolved-active nil))
        (should (string-equal (dsh-bridge--dispatcher-header) " ● T (last active)"))))
    ;; Nothing bound, resolved, or live: empty header.
    (with-temp-buffer
      (let ((dsh-bridge-default-session nil)
            (dsh-bridge--last-resolved-active nil)
            (dsh-bridge--sessions-cache nil))
        (should (string-equal (dsh-bridge--dispatcher-header) ""))))
    ;; With indicator style `none' there is no glyph, hence no leading space.
    (with-temp-buffer
      (let ((dsh-bridge-status-indicator 'none)
            (dsh-bridge-default-session "s1"))
        (should (string-equal (dsh-bridge--dispatcher-header) "T (default)"))))))

(ert-deftest dsh-bridge-warn-if-unknown-session ()
  "An unknown session emits the warning; a known session is silent."
  (let ((msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (let ((dsh-bridge--sessions-cache nil))
        (dsh-bridge--warn-if-unknown-session "s1"))
      (should (string-match-p "unknown session s1" msg))
      (setq msg nil)
      (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T")))))
        (dsh-bridge--warn-if-unknown-session "s1"))
      (should (null msg)))))

(ert-deftest dsh-bridge-send-text-records-last-resolved ()
  "A nil-target send records the host-resolved session for display."
  (let ((dsh-bridge-default-session nil)
        (dsh-bridge--last-resolved-active nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path payload callback)
                 (funcall callback nil
                          "{\"ok\":true,\"sessionId\":\"s1\",\"title\":\"T\"}"
                          200))))
      (dsh-bridge-send-text "hello"))
    (should (equal (car dsh-bridge--last-resolved-active) "s1"))
    (should (equal (cdr dsh-bridge--last-resolved-active) "T"))))

(ert-deftest dsh-bridge-explicit-target-does-not-record-last-resolved ()
  "An explicit target is not the host's last-active resolution; nothing is
recorded."
  (let ((dsh-bridge-default-session "s1")
        (dsh-bridge--last-resolved-active nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path payload callback)
                 (funcall callback nil
                          "{\"ok\":true,\"sessionId\":\"s1\",\"title\":\"T\"}"
                          200))))
      (dsh-bridge-send-text "hello"))
    (should (null dsh-bridge--last-resolved-active))))

;;; Session labels

(ert-deftest dsh-bridge-session-label-precedence ()
  "The label is the title, else the raw id; alist inputs work too."
  (let ((dsh-bridge--sessions-cache
         '(((id . "s1") (title . "T") (cwd . "/x"))
           ((id . "s2") (cwd . "/x/y")))))
    (should (equal (dsh-bridge--session-label "s1") "T"))
    (should (equal (dsh-bridge--session-label "s2") "s2"))
    (should (equal (dsh-bridge--session-label "missing") "missing"))
    (should (equal (dsh-bridge--session-label nil) "[Untitled Session]"))
    ;; Session data alists are accepted directly (no cache lookup).
    (should (equal (dsh-bridge--session-label '((id . "s3") (title . "T3"))) "T3"))
    (should (equal (dsh-bridge--session-label '((id . "s4"))) "s4"))
    ;; NO-DEFAULT suppresses the \"[Untitled Session]\" final fallback, so an
    ;; untitled alist with an id still labels as the id but one without an id
    ;; (or no session at all) labels as nil: the completing-read candidate.  A
    ;; real title still wins under NO-DEFAULT.
    (should (equal (dsh-bridge--session-label '((id . "s4")) t) "s4"))
    (should (equal (dsh-bridge--session-label '((id . "s7") (title . "T7")) t) "T7"))
    (should (null (dsh-bridge--session-label '((cwd . "/x")) t)))
    (should (null (dsh-bridge--session-label nil t)))
    ;; ADD-FALLBACK-FACE marks only fallback labels (raw id / untitled), never
    ;; a real title.
    (should (eq (get-text-property
                 0 'face (dsh-bridge--session-label '((id . "s5")) nil t))
                'dsh-bridge-untitled-face))
    (should (eq (get-text-property
                 0 'face (dsh-bridge--session-label nil nil t))
                'dsh-bridge-untitled-face))
    (should-not (get-text-property
                 0 'face (dsh-bridge--session-label '((id . "s6") (title . "T6")) nil t)))))

(ert-deftest dsh-bridge-workspace-label ()
  "The workspace label is the title, else the cwd basename, else the cwd."
  (should (equal (dsh-bridge--workspace-label '((workspace . "proj") (cwd . "/x/y")))
                 "proj"))
  (should (equal (dsh-bridge--workspace-label '((cwd . "/x/y"))) "y"))
  (should (equal (dsh-bridge--workspace-label '((cwd . "/x/"))) "x"))
  (should (equal (dsh-bridge--workspace-label '((cwd . "/"))) "/"))
  (should (equal (dsh-bridge--workspace-label '((id . "i"))) "")))

;;; Text senders

(ert-deftest dsh-bridge-send-draft-posts-to-draft ()
  "send-draft POSTs the text (and the effective session) to /draft."
  (let ((captured nil)
        (dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (method path payload _callback)
                 (setq captured (list method path payload)))))
      (dsh-bridge-send-draft "hello"))
    (should (equal (car captured) "POST"))
    (should (equal (cadr captured) "/draft"))
    (should (equal (cdr (assoc 'text (caddr captured))) "hello"))
    (should (equal (cdr (assoc 'sessionId (caddr captured))) "s1"))))

(ert-deftest dsh-bridge-send-draft-override-wins-over-default ()
  "An explicit session override beats the default target in the /draft payload."
  (let ((captured nil)
        (dsh-bridge-default-session "pin"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (method path payload _callback)
                 (setq captured (list method path payload)))))
      (dsh-bridge-send-draft "hello" "override"))
    (should (equal (cadr captured) "/draft"))
    (should (equal (cdr (assoc 'sessionId (caddr captured))) "override"))))

(ert-deftest dsh-bridge-send-draft-keeps-prompt-text ()
  "A successful draft push leaves the prompt buffer alone; the buffer is
blanked when a new composition starts, not when a draft is sent."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_m _p _pl cb) (funcall cb nil "{\"sessionId\":\"s1\"}" 200))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-prompt*")
        (dsh-bridge-prompt-mode)
        (insert "prompt text")
        (dsh-bridge-send-draft "prompt text")
        (should (equal (buffer-string) "prompt text")))
      ;; A draft from any other buffer likewise leaves it untouched.
      (with-current-buffer (get-buffer-create "*dsh-bridge-prompt*")
        (erase-buffer)
        (insert "unrelated unsent text"))
      (with-temp-buffer
        (dsh-bridge-send-draft "region from elsewhere"))
      (with-current-buffer "*dsh-bridge-prompt*"
        (should (equal (buffer-string) "unrelated unsent text")))))
  (kill-buffer "*dsh-bridge-prompt*"))

(ert-deftest dsh-bridge-send-text-override-wins-over-default ()
  "An explicit session override beats the default target in the /send payload."
  (let ((captured nil)
        (dsh-bridge-default-session "pin"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path payload _callback)
                 (setq captured payload))))
      (dsh-bridge-send-text "hi" "override"))
    (should (equal (cdr (assoc 'sessionId captured)) "override"))))

(ert-deftest dsh-bridge-send-text-no-target-omits-session ()
  "With neither a default target nor an override, no sessionId key is sent."
  (let ((captured nil)
        (dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path payload _callback)
                 (setq captured payload))))
      (dsh-bridge-send-text "hi"))
    (should (equal (cdr (assoc 'text captured)) "hi"))
    (should (null (assoc 'sessionId captured)))))

(ert-deftest dsh-bridge-send-sends-region-when-active ()
  "`dsh-bridge-send' sends the region when one is active, without asking."
  (let ((transient-mark-mode t) captured)
    (with-temp-buffer
      (insert "before region after")
      (goto-char 8)
      (set-mark (point-max))
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload)))
                ;; The guard must not fire for a region send.
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "dsh-bridge: guard asked for a region"))))
        (call-interactively #'dsh-bridge-send)))
    (should (equal (cdr (assoc 'text captured)) "region after"))))

(ert-deftest dsh-bridge-send-whole-buffer-no-confirm ()
  "A whole-buffer send proceeds without asking for confirmation."
  (let ((asked nil) captured)
    (with-temp-buffer
      (insert "whole")
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload)))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq asked t) t)))
        (dsh-bridge-send)))
    (should (null asked))
    (should (equal (cdr (assoc 'text captured)) "whole"))))

(ert-deftest dsh-bridge-draft-whole-buffer-confirms ()
  "A whole-buffer draft asks y-or-n-p first (guard symmetry with send)."
  (let ((asked nil) captured)
    (with-temp-buffer
      (insert "whole")
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload)))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq asked t) t)))
        (dsh-bridge-draft)))
    (should asked)
    (should (equal (cdr (assoc 'text captured)) "whole"))))

(ert-deftest dsh-bridge-send-active-region-in-read-only-works ()
  "A region in a read-only buffer is sendable."
  (let ((transient-mark-mode t) captured)
    (with-temp-buffer
      (insert "alpha beta")
      (dsh-bridge-view-mode)
      (goto-char 7)
      (set-mark (point-max))
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload))))
        (dsh-bridge-send)))
    (should (equal (cdr (assoc 'text captured)) "beta"))))

(ert-deftest dsh-bridge-send-prefix-override ()
  "With a prefix argument, send targets the completing-read session for this
call only, leaving the default target untouched."
  (let ((transient-mark-mode t)
        (current-prefix-arg t)
        (captured nil)
        (dsh-bridge-default-session "pin"))
    (with-temp-buffer
      (insert "text")
      (goto-char (point-min))
      (set-mark (point-max))
      (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
                 (lambda () '(((id . "live-1") (live . t)))))
                ((symbol-function 'completing-read)
                 (lambda (_prompt _table &rest _) "live-1"))
                ((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path payload _callback)
                   (setq captured payload))))
        (call-interactively #'dsh-bridge-send)))
    (should (equal (cdr (assoc 'sessionId captured)) "live-1"))
    (should (equal (cdr (assoc 'text captured)) "text"))
    (should (equal dsh-bridge-default-session "pin"))))

;;; Fetch and the output buffer

(ert-deftest dsh-bridge-fetch-uses-default-target ()
  "`dsh-bridge-fetch' requests /turns with the default target when the
current buffer has no session of its own."
  (let ((dsh-bridge-default-session "s1")
        (captured nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method path _payload _callback)
                 (setq captured path))))
      (dsh-bridge-fetch))
    (should (equal captured "/turns?sessionId=s1"))))

(ert-deftest dsh-bridge-fetch-populates-output ()
  "Fetch writes the newest turn into *dsh-bridge-output* in `dsh-bridge-view-mode'."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          (concat "{\"sessionId\":\"s1\",\"turns\":["
                                  "{\"turn\":2,\"startedAt\":1000,\"segments\":["
                                  "{\"text\":\"reply text\",\"time\":1000000,\"step\":1}]}]}")
                          200)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons nil nil))))
      (dsh-bridge-fetch))
    (let ((buf (get-buffer "*dsh-bridge-output*")))
      (should buf)
      (with-current-buffer buf
        (should (equal (buffer-string) "reply text"))
        (should (eq major-mode 'dsh-bridge-view-mode))
        (should buffer-read-only)
        (should (equal dsh-bridge--view-content-session "s1"))
        (should (equal dsh-bridge--view-turn 2))
        (should (string-match-p " s1" (format "%s" header-line-format)))
        (should (string-match-p "· " (format "%s" header-line-format)))))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-fetch-peek-labels-content-session ()
  "A peek/override fetch labels the output buffer with the content's session,
not the default target."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          (concat "{\"sessionId\":\"s2\",\"turns\":["
                                  "{\"turn\":3,\"startedAt\":1000,\"segments\":["
                                  "{\"text\":\"other reply\",\"time\":1000000,\"step\":1}]}]}")
                          200)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons nil nil))))
      (dsh-bridge-fetch "s2"))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal (buffer-string) "other reply"))
      (should (equal dsh-bridge--view-content-session "s2"))
      (should (string-match-p " s2" (format "%s" header-line-format)))
      (should-not (string-match-p " s1" (format "%s" header-line-format)))
      (should-not (string-match-p "target:" (format "%s" header-line-format))))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-fetch-seeds-status ()
  "Fetch seeds the tracker from /turns' running flag: true -> running,
false -> idle.  JSON `false' decodes to nil (see `dsh-bridge--parse-json-body'),
so the check must compare against t, not truthiness (a regression: a
`running:false' session used to be seeded `running' and show amber)."
  (dolist (case (list (cons (concat "{\"sessionId\":\"s1\",\"turns\":[],"
                                    "\"running\":true}")
                            'running)
                      (cons (concat "{\"sessionId\":\"s1\",\"turns\":[],"
                                    "\"running\":false}")
                            'idle)))
    (let ((dsh-bridge-default-session "s1")
          (dsh-bridge--session-status nil))
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path _payload callback)
                   (funcall callback nil (car case) 200)))
                ((symbol-function 'dsh-bridge--request)
                 (lambda (&rest _) (cons nil nil))))
        (dsh-bridge-fetch "s1"))
      (should (eq (dsh-bridge--status-state "s1") (cdr case)))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-apply-session-directory ()
  "The helper sets default-directory (trailing slash), with cache fallback."
  (with-temp-buffer
    (dsh-bridge--apply-session-directory "s1" "/home/user/proj")
    (should (equal default-directory "/home/user/proj/")))
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (cwd . "/cache/dir")))))
    (with-temp-buffer
      (dsh-bridge--apply-session-directory "s1" nil)
      (should (equal default-directory "/cache/dir/"))))
  (with-temp-buffer
    (let ((before default-directory))
      (dsh-bridge--apply-session-directory "s1" nil)
      (should (equal default-directory before)))))

(ert-deftest dsh-bridge-fetch-sets-output-directory ()
  "Fetch sets the output buffer's default-directory to the session cwd."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          (concat "{\"sessionId\":\"s1\",\"cwd\":\"/w/sess1\","
                                  "\"turns\":[{\"turn\":2,\"startedAt\":1000,"
                                  "\"segments\":[{\"text\":\"reply\",\"time\":1000000,\"step\":1}]}]}")
                          200)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons nil nil))))
      (dsh-bridge-fetch))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal default-directory "/w/sess1/"))
      (should (equal (buffer-string) "reply")))
    (kill-buffer "*dsh-bridge-output*")))

;;; The prompt buffer: session binding, header, history

(ert-deftest dsh-bridge-set-prompt-session-sets-directory ()
  "Binding the prompt buffer sets its default-directory from the cache."
  (when (get-buffer "*dsh-bridge-prompt*")
    (kill-buffer "*dsh-bridge-prompt*"))
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (cwd . "/w/sess1") (live . t)))))
    (with-current-buffer (get-buffer-create "*dsh-bridge-prompt*")
      (dsh-bridge-prompt-mode)
      (cl-letf (((symbol-function 'dsh-bridge--refresh-prompt-metadata)
                 #'ignore))
        (dsh-bridge-set-prompt-session "s1")
        (should (equal default-directory "/w/sess1/")))))
  (kill-buffer "*dsh-bridge-prompt*"))

(ert-deftest dsh-bridge-set-prompt-session-requires-prompt-mode ()
  "`dsh-bridge-set-prompt-session' refuses to run outside DSH-Prompt buffers."
  (with-temp-buffer
    (should-error (dsh-bridge-set-prompt-session "s1") :type 'user-error)))

(ert-deftest dsh-bridge-set-default-target-sets-prompt-directory ()
  "Setting the default target re-points an unbound prompt buffer's directory."
  (when (get-buffer "*dsh-bridge-prompt*")
    (kill-buffer "*dsh-bridge-prompt*"))
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (cwd . "/w/sess1") (live . t))))
        (dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions) (lambda () nil)))
      (with-current-buffer (get-buffer-create "*dsh-bridge-prompt*")
        (dsh-bridge-prompt-mode))
      (dsh-bridge-set-default-target "s1")
      (with-current-buffer "*dsh-bridge-prompt*"
        (should (equal default-directory "/w/sess1/")))))
  (kill-buffer "*dsh-bridge-prompt*"))

(ert-deftest dsh-bridge-prompt-mode-basics ()
  "The prompt mode derives from text-mode in a markdown-less environment and
binds the compose keys plus fetch/set-session/list."
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (should (eq major-mode 'dsh-bridge-prompt-mode))
    (should (provided-mode-derived-p major-mode 'text-mode))
    (should (eq (car-safe header-line-format) :eval)))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-c"))
              #'dsh-bridge-send-and-exit))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-d"))
              #'dsh-bridge-draft))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-k"))
              #'dsh-bridge-erase-prompt))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-f"))
              #'dsh-bridge-fetch))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-s"))
              #'dsh-bridge-set-prompt-session))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-l"))
              #'dsh-bridge-list-sessions))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "M-p"))
              #'dsh-bridge-prompt-previous-history))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "M-n"))
              #'dsh-bridge-prompt-next-history)))

(ert-deftest dsh-bridge-prompt-header-session-label ()
  "The prompt header names the effective session, without qualifiers."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (dsh-bridge--session-status nil))
    ;; Bound buffer session: plain label (header refreshes after binding).
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (should (string-match-p " T$" (dsh-bridge--prompt-header-line))))
    (with-temp-buffer
      (let ((dsh-bridge-default-session "s1"))
        (dsh-bridge-prompt-mode)
        (should (string-match-p " T$" (dsh-bridge--prompt-header-line)))
        (should-not (string-match-p "(default)"
                                    (dsh-bridge--prompt-header-line)))))
    (with-temp-buffer
      (let ((dsh-bridge-default-session nil)
            (dsh-bridge--last-resolved-active nil)
            (dsh-bridge-status-indicator 'geometric))
        (dsh-bridge-prompt-mode)
        ;; Nothing bound and nothing resolved: the header shows only the status.
        (should (string-match-p "●" (dsh-bridge--prompt-header-line)))
        (should-not (string-match-p "Untitled"
                                    (dsh-bridge--prompt-header-line)))))))

(ert-deftest dsh-bridge-set-prompt-session-binds ()
  "`C-c C-s' rebinds the current DSH-Prompt buffer's session."
  (let ((dsh-bridge-default-session "default"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (cl-letf (((symbol-function 'dsh-bridge--read-session-id)
                 (lambda (_prompt _pseudo) "live-1"))
                ((symbol-function 'dsh-bridge--refresh-prompt-metadata)
                 #'ignore))
        (call-interactively #'dsh-bridge-set-prompt-session))
      (should (equal dsh-bridge--prompt-session "live-1")))))

(ert-deftest dsh-bridge-prompt-history-navigation ()
  "M-p/M-n cycle the prompt buffer through the session's prompt history."
  (let ((dsh-bridge-default-session "s1"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (_method _path _payload)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'prompts
                                         (list "third" "second" "first")))))))
        (insert "my draft")
        ;; M-p: newest prompt, draft saved.
        (dsh-bridge-prompt-previous-history)
        (should (equal (buffer-string) "third"))
        (should (equal dsh-bridge--prompt-draft "my draft"))
        (should (equal dsh-bridge--prompt-history-index 0))
        ;; M-p again: older, then oldest, then stays.
        (dsh-bridge-prompt-previous-history)
        (should (equal (buffer-string) "second"))
        (dsh-bridge-prompt-previous-history)
        (should (equal (buffer-string) "first"))
        (dsh-bridge-prompt-previous-history)
        (should (equal (buffer-string) "first"))
        ;; M-n walks back to the newest, then restores the draft.
        (dsh-bridge-prompt-next-history)
        (should (equal (buffer-string) "second"))
        (dsh-bridge-prompt-next-history)
        (should (equal (buffer-string) "third"))
        (dsh-bridge-prompt-next-history)
        (should (equal (buffer-string) "my draft"))
        (should (null dsh-bridge--prompt-history-index))))))

(ert-deftest dsh-bridge-prompt-history-fetches ()
  "M-p fetches the effective session's prompts from the host when not cached."
  (let ((dsh-bridge-default-session "s1"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (method path _payload)
                   (should (equal method "GET"))
                   (should (equal path "/prompts?sessionId=s1"))
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'prompts (list "new" "old")))))))
        (dsh-bridge-prompt-previous-history))
      (should (equal (buffer-string) "new"))
      (should (equal (cdr (assoc "s1" dsh-bridge--prompt-history))
                     (list "new" "old"))))))

(ert-deftest dsh-bridge-prompt-history-no-prompts ()
  "M-p with an empty session history reports it and leaves the buffer alone."
  (let ((dsh-bridge-default-session "s1"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (_method _path _payload)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'prompts '()))))))
        (insert "draft")
        (dsh-bridge-prompt-previous-history)
        (should (equal (buffer-string) "draft"))
        (should (null dsh-bridge--prompt-history-index))))))

(ert-deftest dsh-bridge-prompt-history-record-send ()
  "A recorded send prepends the text and returns the buffer to the draft slot."
  (setq dsh-bridge--prompt-history '(("s1" "old")))
  (when (get-buffer "*dsh-bridge-prompt*")
    (kill-buffer "*dsh-bridge-prompt*"))
  (let ((buf (get-buffer-create "*dsh-bridge-prompt*")))
    (with-current-buffer buf
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (setq-local dsh-bridge--prompt-history-index 1))
    (dsh-bridge--prompt-history-record-send "s1" "just sent")
    (should (equal (cdr (assoc "s1" dsh-bridge--prompt-history))
                   (list "just sent" "old")))
    (with-current-buffer buf
      (should (null dsh-bridge--prompt-history-index)))
    (kill-buffer buf)))

(ert-deftest dsh-bridge-prompt-history-edited-blocks-walk ()
  "Editing a history entry blocks walking until it is sent or reverted."
  (let ((dsh-bridge-default-session "s1"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (_m _p _pl)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'prompts (list "new" "old")))))))
        (insert "draft")
        (dsh-bridge-prompt-previous-history)
        (insert " edited")
        (dsh-bridge-prompt-previous-history)
        (should (equal (buffer-string) "new edited"))
        (dsh-bridge-prompt-next-history)
        (should (equal (buffer-string) "new edited"))))))

(ert-deftest dsh-bridge-prompt-revert-history ()
  "`revert-buffer' restores an edited history entry, or returns to the
draft when the entry shown is pristine."
  (let ((dsh-bridge-default-session "s1"))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (should (eq revert-buffer-function #'dsh-bridge--revert-prompt-buffer))
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (_m _p _pl)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'prompts (list "new" "old")))))))
        (insert "my draft")
        (dsh-bridge-prompt-previous-history)
        ;; Edited entry: revert restores the pristine text.
        (insert " edited")
        (revert-buffer nil t)
        (should (equal (buffer-string) "new"))
        (should (equal dsh-bridge--prompt-history-index 0))
        ;; Pristine entry: revert returns to the draft.
        (revert-buffer nil t)
        (should (equal (buffer-string) "my draft"))
        (should (null dsh-bridge--prompt-history-index))))))

(ert-deftest dsh-bridge-send-text-records-history ()
  "A successful send records the prompt into the session history cache."
  (let ((dsh-bridge-default-session "s1")
        (dsh-bridge--prompt-history nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path payload callback)
                 (funcall callback nil
                          "{\"ok\":true,\"sessionId\":\"s1\",\"title\":\"T\"}"
                          200))))
      (dsh-bridge-send-text "hello"))
    (should (equal (cdr (assoc "s1" dsh-bridge--prompt-history))
                   (list "hello")))))

;;; The view buffers

(ert-deftest dsh-bridge-view-mode-basics ()
  "The view mode is read-only and binds g/q/r/w/i/l plus M-p/M-n — and no
compose/fetch/targeting verbs."
  (with-temp-buffer
    (dsh-bridge-view-mode)
    (should buffer-read-only)
    (should (eq major-mode 'dsh-bridge-view-mode)))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "g")) #'revert-buffer))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "q")) #'quit-window))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "r")) #'dsh-bridge-reply))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "w"))
              #'dsh-bridge-copy-reply))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "i"))
              #'dsh-bridge-receive))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "l"))
              #'dsh-bridge-list-sessions))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "M-p"))
              #'dsh-bridge-view-previous-reply))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "M-n"))
              #'dsh-bridge-view-next-reply))
  (dolist (key '("s" "d" "f" "t" "u"))
    (should-not (eq (lookup-key dsh-bridge-view-mode-map (kbd key))
                    (cadr (assoc key dsh-bridge--verb-suffixes))))))

(ert-deftest dsh-bridge-view-mode-gfm ()
  "When markdown-mode is loadable, the view mode derives from gfm-view-mode for
GFM rendering (read-only, native code-block font-locking); the bridge's own
keys win over the inherited markdown view map, which also contributes bare
outline navigation (p/n/f/b/u)."
  (when (require 'markdown-mode nil t)
    (with-temp-buffer
      (insert "# Heading\n")
      (dsh-bridge-view-mode)
      (should (derived-mode-p 'gfm-mode))
      (should font-lock-defaults)
      (should markdown-fontify-code-blocks-natively)
      (should buffer-read-only)
      ;; Effective bindings: the bridge's keys override the inherited
      ;; gfm-view-mode chain (which binds q to `kill-this-buffer' and
      ;; M-n/M-p to link navigation).
      (should (eq (key-binding (kbd "M-p")) #'dsh-bridge-view-previous-reply))
      (should (eq (key-binding (kbd "M-n")) #'dsh-bridge-view-next-reply))
      (should (eq (key-binding (kbd "g")) #'revert-buffer))
      (should (eq (key-binding (kbd "q")) #'quit-window))
      ;; gfm-view-mode's own map contributes bare outline navigation.
      (should (eq (key-binding (kbd "p")) #'markdown-outline-previous))
      (should (eq (key-binding (kbd "n")) #'markdown-outline-next)))))

(ert-deftest dsh-bridge-reply-binds-shown-session ()
  "`dsh-bridge-reply' in the output buffer binds the prompt to the shown
session and never touches the default target."
  (let ((dsh-bridge-default-session "target")
        (dsh-bridge--sessions-cache '(((id . "shown") (live . t))))
        (bound nil) (popped nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "shown")
      (cl-letf (((symbol-function 'dsh-bridge--prompt-buffer)
                 (lambda (id) (setq bound id)
                         (get-buffer-create "*dsh-bridge-prompt*")))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buf action) (setq popped (list buf action)))))
        (dsh-bridge-reply))
      (should (equal bound "shown"))
      (should (equal dsh-bridge-default-session "target"))
      (should (equal (car popped) (get-buffer-create "*dsh-bridge-prompt*")))
      (should (equal (cadr popped) dsh-bridge-prompt-display-action)))))

(ert-deftest dsh-bridge-reply-not-live-message ()
  "Reply to an unknown session gives the unknown-session message, no resume
attempt."
  (let ((dsh-bridge--sessions-cache nil)
        (bound nil) (msg nil) (resumed nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "gone")
      (cl-letf (((symbol-function 'dsh-bridge--prompt-buffer)
                 (lambda (id) (setq bound id)))
                ((symbol-function 'dsh-bridge--resume-session)
                 (lambda (id) (setq resumed id) nil))
                ((symbol-function 'message)
                 (lambda (&rest args) (setq msg (apply #'format args)))))
        (dsh-bridge-reply))
      (should (null bound))
      (should (null resumed))
      (should (string-match-p "unknown session gone" msg)))))

(ert-deftest dsh-bridge-reply-resume-failure-keeps-host-message ()
  "A failed resume's host error is not overwritten by the not-known message."
  (let ((dsh-bridge--sessions-cache '(((id . "saved-1") (live . nil))))
        (bound nil) (msg nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "saved-1")
      (cl-letf (((symbol-function 'dsh-bridge--prompt-buffer)
                 (lambda (id) (setq bound id)))
                ((symbol-function 'dsh-bridge--resume-session)
                 (lambda (_id) (message "dsh-bridge: HTTP 409: subagent-owned") nil))
                ((symbol-function 'message)
                 (lambda (&rest args) (setq msg (apply #'format args)))))
        (dsh-bridge-reply))
      (should (null bound))
      (should (string-match-p "HTTP 409" msg)))))

(ert-deftest dsh-bridge-copy-reply ()
  "`dsh-bridge-copy-reply' copies the whole reply without a region."
  (with-temp-buffer
    (insert "the reply")
    (dsh-bridge-view-mode)
    (setq-local dsh-bridge--view-content-session "s1")
    (dsh-bridge-copy-reply)
    (should (equal (current-kill 0) "the reply"))))

(ert-deftest dsh-bridge-copy-reply-raw-markdown ()
  "`dsh-bridge-copy-reply' copies the original Markdown source, not the
rendered text, when the view buffer derives from `gfm-view-mode' (which hides
markup and installs `filter-buffer-substring-function')."
  (when (require 'markdown-mode nil t)
    (with-temp-buffer
      (insert "# Title\n\nSome **bold** text.\n")
      (dsh-bridge-view-mode)
      (when (derived-mode-p 'gfm-mode)
        (font-lock-ensure)
        ;; Sanity: markup hiding really is in effect.
        (should (text-property-any (point-min) (point-max)
                                   'invisible 'markdown-markup))
        (dsh-bridge-copy-reply)
        (should (equal (current-kill 0) "# Title\n\nSome **bold** text.\n"))))))

(ert-deftest dsh-bridge-copy-reply-whole-turn ()
  "`dsh-bridge-copy-reply' kills the shown turn's raw Markdown — its segments
joined by blank lines, without the divider lines — when the turn is cached."
  (let ((dsh-bridge--turns-cache (list (cons "s1" dsh-bridge-test--view-turns)))
        (turn (nth 0 dsh-bridge-test--view-turns)))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((inhibit-read-only t))
        (insert (dsh-bridge--view-turn-render turn)))
      (setq-local dsh-bridge--view-turn (alist-get 'turn turn))
      (dsh-bridge-copy-reply)
      (should (equal (current-kill 0) "newest first\n\nnewest second")))))

(ert-deftest dsh-bridge-copy-reply-turn-not-cached ()
  "`dsh-bridge-copy-reply' falls back to the buffer text when the shown turn
is no longer in the cached turn list (e.g. after a compaction)."
  ;; The cache holds only turns 20 and 10; the view still shows turn 30.
  (let ((dsh-bridge--turns-cache
         (list (cons "s1" (cdr dsh-bridge-test--view-turns))))
        (rendered (dsh-bridge--view-turn-render
                   (nth 0 dsh-bridge-test--view-turns))))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((inhibit-read-only t)) (insert rendered))
      (setq-local dsh-bridge--view-turn 30)
      (dsh-bridge-copy-reply)
      (should (equal (current-kill 0) rendered)))))

;;; Receive (the DSH→Emacs push; the outbox is invisible transport)

(defconst dsh-bridge-test--receive-response
  (cons 200
        (list (cons 'entries
                    (list (list (cons 'id "e1")
                                (cons 'sessionId "s1")
                                (cons 'source "message-action")
                                (cons 'text "older")
                                (cons 'ts 1000000))
                          (list (cons 'id "e2")
                                (cons 'sessionId "s2")
                                (cons 'source "message-action")
                                (cons 'text "newest")
                                (cons 'ts 2000000))))
              (cons 'overflowed nil))))

(ert-deftest dsh-bridge-receive-shows-newest-and-acks-all ()
  "Receive displays the newest pending entry in the output buffer and acks
every collected id."
  (let (acked-payload)
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (cond
                  ((equal method "GET") dsh-bridge-test--receive-response)
                  ((equal method "POST") (setq acked-payload payload)
                   (cons 200 (list (cons 'ok t))))
                  (t (cons 404 (list (cons 'error "unexpected"))))))))
      (dsh-bridge-receive))
    (should (equal acked-payload '((ids . ("e1" "e2")))))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal (buffer-string) "newest"))
      (should (equal dsh-bridge--view-content-session "s2"))
      (should (string-match-p "s2 ·" (format "%s" header-line-format)))
      (should (string-match-p " · " (format "%s" header-line-format))))))

(ert-deftest dsh-bridge-receive-multiple-messages-message ()
  "Several pending entries produce the honest 'received' message."
  (let ((msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cond ((equal method "GET") dsh-bridge-test--receive-response)
                       (t (cons 200 (list (cons 'ok t)))))))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge-receive))
    (should (string-match-p "2 messages received from DSH" msg))))

(ert-deftest dsh-bridge-receive-pops-by-default ()
  "With `dsh-bridge-receive-pop' (the default), receive selects the output
buffer."
  (let ((popped nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cond ((equal method "GET") dsh-bridge-test--receive-response)
                       (t (cons 200 (list (cons 'ok t)))))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq popped t))))
      (dsh-bridge-receive))
    (should popped)))

(ert-deftest dsh-bridge-receive-does-not-pop-when-disabled ()
  "With `dsh-bridge-receive-pop' nil, receive fills the output buffer without
selecting it."
  (let ((popped nil)
        (dsh-bridge-receive-pop nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cond ((equal method "GET") dsh-bridge-test--receive-response)
                       (t (cons 200 (list (cons 'ok t)))))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq popped t))))
      (dsh-bridge-receive))
    (should (null popped))))

(ert-deftest dsh-bridge-receive-nothing-pending ()
  "With nothing pending, receive says so and leaves the output alone."
  (let ((msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cons 200 (list (cons 'entries nil)))))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge-receive))
    (should (string-match-p "nothing to receive" msg))))

(ert-deftest dsh-bridge-receive-sets-workspace-best-effort ()
  "Receive points the output buffer at the session's workspace when known."
  (let ((dsh-bridge--sessions-cache '(((id . "s2") (cwd . "/w/sess2") (live . t)))))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cond ((equal method "GET") dsh-bridge-test--receive-response)
                       (t (cons 200 (list (cons 'ok t))))))))
      (dsh-bridge-receive))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal default-directory "/w/sess2/")))))

;;; Turn navigation (M-p / M-n in the output buffer)

;; Navigation and view fixtures use turn records shaped like
;; `GET /dsh-bridge/turns' entries (see `dsh-bridge--turns-cache').

(defun dsh-bridge-test--view-segment (text &optional time step)
  "A turn-record segment alist for TEXT at TIME (default 1000) or STEP (default 1)."
  (list (cons 'text text)
        (cons 'time (or time 1000))
        (cons 'step (or step 1))))

(defun dsh-bridge-test--view-turn (turn started-at segments &optional ended-at reason)
  "A turn-record alist: TURN number, STARTED-AT ms-epoch, SEGMENTS oldest first.
The turn is open (running) unless ENDED-AT is given; REASON defaults to
\"completed\"."
  (let ((record (list (cons 'turn turn)
                      (cons 'startedAt started-at)
                      (cons 'segments segments))))
    (if ended-at
        (append record (list (cons 'endedAt ended-at)
                             (cons 'reason (or reason "completed"))))
      record)))

;; The canonical s1 turn list for the navigation tests: three completed turns,
;; newest first.  Turn 30 has two segments (to exercise divider rendering in
;; navigation); its elapsed is 2s, turn 20's 4s, turn 10's 3s.
(defconst dsh-bridge-test--view-turns
  (list
   (dsh-bridge-test--view-turn 30 3000000
     (list (dsh-bridge-test--view-segment "newest first" 3000500 1)
           (dsh-bridge-test--view-segment "newest second" 3001000 2))
     3002000)
   (dsh-bridge-test--view-turn 20 2000000
     (list (dsh-bridge-test--view-segment "middle" 2001000 1))
     2004000)
   (dsh-bridge-test--view-turn 10 1000000
     (list (dsh-bridge-test--view-segment "oldest" 1001000 1))
     1003000))
  "Three-turn fixture, newest first: turn 30 (two segments), turn 20, turn 10.")

(defconst dsh-bridge-test--turns-response
  (cons 200
        (list (cons 'sessionId "s1")
              (cons 'turns dsh-bridge-test--view-turns))))

(defconst dsh-bridge-test--view-newest-rendered
  (dsh-bridge--view-turn-render (nth 0 dsh-bridge-test--view-turns)))

(defconst dsh-bridge-test--view-middle-rendered
  (dsh-bridge--view-turn-render (nth 1 dsh-bridge-test--view-turns)))

(defconst dsh-bridge-test--view-oldest-rendered
  (dsh-bridge--view-turn-render (nth 2 dsh-bridge-test--view-turns)))

(ert-deftest dsh-bridge-view-turn-navigation ()
  "M-p/M-n cycle the output buffer through the session's turns, newest first.
A turn renders as the whole run from a prompt to a reply — every segment it
committed, separated by `(continuing…)' divider blocks and closed by an
elapsed-time divider."
  (let ((dsh-bridge--turns-cache (list (cons "s1" dsh-bridge-test--view-turns)))
        (newest (nth 0 dsh-bridge-test--view-turns)))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((inhibit-read-only t))
        (insert (dsh-bridge--view-turn-render newest))
        (setq-local dsh-bridge--view-turn (alist-get 'turn newest)))
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (method path _payload)
                   (should (equal method "GET"))
                   (should (equal path "/turns?sessionId=s1"))
                   dsh-bridge-test--turns-response)))
        ;; First M-p from rest (the newest turn): step one older.
        (dsh-bridge-view-previous-reply)
        (should (equal (buffer-string) dsh-bridge-test--view-middle-rendered))
        (should (equal dsh-bridge--view-turn-index 1))
        (should (string-match-p " (2/3)" (format "%s" header-line-format)))
        ;; Older, then at the oldest it stays.
        (dsh-bridge-view-previous-reply)
        (should (equal (buffer-string) dsh-bridge-test--view-oldest-rendered))
        (should (equal dsh-bridge--view-turn-index 2))
        (dsh-bridge-view-previous-reply)
        (should (equal (buffer-string) dsh-bridge-test--view-oldest-rendered))
        ;; M-n walks back toward the newest, then enters turn-following.
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) dsh-bridge-test--view-middle-rendered))
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) dsh-bridge-test--view-newest-rendered))
        (should (equal dsh-bridge--view-turn-index 0))
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) dsh-bridge-test--view-newest-rendered))
        (should (eq dsh-bridge--view-follow t))
        (should (null dsh-bridge--view-turn-index))))))

(ert-deftest dsh-bridge-view-turn-navigation-no-turns ()
  "With no turns, M-p reports it and leaves the buffer alone."
  (let ((dsh-bridge--turns-cache nil)
        (msg nil))
    (with-temp-buffer
      (insert "content")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (_method _path _payload)
                   (cons 200 (list (cons 'sessionId "s1") (cons 'turns nil)))))
                ((symbol-function 'message)
                 (lambda (&rest args) (setq msg (apply #'format args)))))
        (dsh-bridge-view-previous-reply))
      (should (equal (buffer-string) "content"))
      (should (string-match-p "no turns" msg)))))

(ert-deftest dsh-bridge-fetch-resets-turn-navigation ()
  "Fetching a fresh turn resets turn navigation to rest: no mid-browse index,
and the view is bound to the fetched turn's number."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          (concat "{\"sessionId\":\"s1\",\"turns\":["
                                  "{\"turn\":2,\"startedAt\":1000,\"segments\":["
                                  "{\"text\":\"fresh\",\"time\":1000000,\"step\":1}]}]}")
                          200)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons nil nil))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-turn-index 2))
      (dsh-bridge-fetch)
      (with-current-buffer "*dsh-bridge-output*"
        (should (equal (buffer-string) "fresh"))
        (should (null dsh-bridge--view-turn-index))
        (should (equal dsh-bridge--view-turn 2)))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-turn-render-dividers ()
  "A turn renders its segments joined by GFM-safe `(continuing…)' dividers, and
a completed turn closes with an elapsed-time divider (spelled reason when not
`completed')."
  (let ((multi (dsh-bridge-test--view-turn 30 3000000
                (list (dsh-bridge-test--view-segment "a" 3000500 1)
                      (dsh-bridge-test--view-segment "b" 3001000 2))
                3002000))
        (open (dsh-bridge-test--view-turn 40 4000000
               (list (dsh-bridge-test--view-segment "growing" 4001000 1))))
        (aborted (dsh-bridge-test--view-turn 50 5000000
                  (list (dsh-bridge-test--view-segment "partial" 5001000 1))
                  5001000 "aborted")))
    ;; Two segments, closed after 2s.
    (should (equal (dsh-bridge--view-turn-render multi)
                   "a\n\n---\n\n(continuing…)\n\nb\n\n---\n\n(2s elapsed)"))
    ;; An open (running) turn has no closing divider.
    (should (equal (dsh-bridge--view-turn-render open) "growing"))
    ;; A non-completed end reason is spelled out alongside the elapsed time.
    (should (equal (dsh-bridge--view-turn-render aborted)
                   "partial\n\n---\n\n(1s elapsed · interrupted)"))
    ;; nil renders empty.
    (should (equal (dsh-bridge--view-turn-render nil) ""))))

(ert-deftest dsh-bridge-view-fill-append-preserves-point ()
  "Refilling a growing turn preserves point when the old content is a strict
prefix of the new (a segment was appended); replacing the turn resets point."
  (let ((one (dsh-bridge-test--view-turn 7 7000000
              (list (dsh-bridge-test--view-segment "first" 7001000 1))))
        (two (dsh-bridge-test--view-turn 7 7000000
              (list (dsh-bridge-test--view-segment "first" 7001000 1)
                    (dsh-bridge-test--view-segment "second" 7002000 2))))
        (other (dsh-bridge-test--view-turn 8 8000000
                (list (dsh-bridge-test--view-segment "other turn" 8001000 1)))))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (dsh-bridge--view-fill "s1" one nil nil t)
      ;; Read a middle position of the first segment, then append.
      (goto-char 3)
      (dsh-bridge--view-fill "s1" two nil nil t t)
      (should (equal (point) 3))
      (should (equal (buffer-string)
                     (concat (dsh-bridge--view-turn-render one)
                             "\n\n---\n\n(continuing…)\n\nsecond")))
      ;; A different turn is a swap, not an append: point goes to the top.
      (dsh-bridge--view-fill "s1" other nil nil t)
      (should (equal (point) (point-min))))))

;;; The sessions list

(ert-deftest dsh-bridge-sessions-keymap ()
  "RET/r open, t sets the default target, u clears it, f peeks, v toggles
archived visibility, R renames, d archives, + creates, W renames the workspace,
and p is previous-line again."
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "RET"))
              #'dsh-bridge-open-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "r"))
              #'dsh-bridge-open-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "t"))
              #'dsh-bridge-set-default-target-at-point))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "u"))
              #'dsh-bridge-clear-default-target))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "f"))
              #'dsh-bridge-peek-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "v"))
              #'dsh-bridge-toggle-archived-sessions))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "R"))
              #'dsh-bridge-rename-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "d"))
              #'dsh-bridge-archive-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "+"))
              #'dsh-bridge-create-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "W"))
              #'dsh-bridge-rename-workspace))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "w"))
              #'dsh-bridge-copy-session-id))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "D"))
              #'dsh-bridge-describe-session))
  ;; `p' inherits previous-line from tabulated-list-mode again.
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "p"))
              #'previous-line)))

(ert-deftest dsh-bridge-open-session-binds-prompt-not-default ()
  "RET binds the prompt buffer to the row's session; the default target is
untouched."
  (let ((dsh-bridge--sessions-cache '(((id . "live-1") (live . t) (cwd . "/w"))))
        (dsh-bridge-default-session "default")
        (bound nil) (popped nil))
    ;; `tabulated-list-get-id' is a defsubst: byte-compilation inlines it,
    ;; so cl-letf cannot mock it.  Stand point on a real tabulated-list-id
    ;; text property instead.
    (cl-letf (((symbol-function 'dsh-bridge--prompt-buffer)
               (lambda (id) (setq bound id)
                       (get-buffer-create "*dsh-bridge-prompt*")))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq popped t))))
      (with-temp-buffer
        (insert (propertize "live-1 row" 'tabulated-list-id "live-1"))
        (goto-char (point-min))
        (dsh-bridge-open-session)))
    (should (equal bound "live-1"))
    (should (equal dsh-bridge-default-session "default"))
    (should popped)))

(ert-deftest dsh-bridge-open-session-not-live-message ()
  "RET on an unknown id reports the unknown-session message, with no resume
attempt."
  (let ((dsh-bridge--sessions-cache nil)
        (bound nil) (msg nil) (resumed nil))
    (cl-letf (((symbol-function 'dsh-bridge--prompt-buffer)
               (lambda (id) (setq bound id)))
              ((symbol-function 'dsh-bridge--resume-session)
               (lambda (id) (setq resumed id) nil))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (with-temp-buffer
        (insert (propertize "gone row" 'tabulated-list-id "gone"))
        (goto-char (point-min))
        (dsh-bridge-open-session)))
    (should (null bound))
    (should (null resumed))
    (should (string-match-p "unknown session gone" msg))))

(ert-deftest dsh-bridge-open-session-resume-failure-keeps-host-message ()
  "RET on a saved row whose resume fails keeps the host's error message."
  (let ((dsh-bridge--sessions-cache '(((id . "saved-1") (live . nil))))
        (bound nil) (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--prompt-buffer)
               (lambda (id) (setq bound id)))
              ((symbol-function 'dsh-bridge--resume-session)
               (lambda (_id) (message "dsh-bridge: HTTP 409: subagent-owned") nil))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (with-temp-buffer
        (insert (propertize "saved-1 row" 'tabulated-list-id "saved-1"))
        (goto-char (point-min))
        (dsh-bridge-open-session)))
    (should (null bound))
    (should (string-match-p "HTTP 409" msg))))

(ert-deftest dsh-bridge-open-session-resumes-saved ()
  "RET on a saved row resumes it first, then binds the prompt buffer."
  (let ((dsh-bridge--sessions-cache '(((id . "saved-1") (live . nil))))
        (bound nil) (popped nil) (resumed nil))
    (cl-letf (((symbol-function 'dsh-bridge--resume-session)
               (lambda (id) (setq resumed id) t))
              ((symbol-function 'dsh-bridge--prompt-buffer)
               (lambda (id) (setq bound id)
                       (get-buffer-create "*dsh-bridge-prompt*")))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq popped t))))
      (with-temp-buffer
        (insert (propertize "saved-1 row" 'tabulated-list-id "saved-1"))
        (goto-char (point-min))
        (dsh-bridge-open-session)))
    (should (equal resumed "saved-1"))
    (should (equal bound "saved-1"))
    (should popped)))

(ert-deftest dsh-bridge-set-default-target-at-point ()
  "`t' sets the default target to the row's session."
  (let ((dsh-bridge--sessions-cache '(((id . "live-1") (live . t))))
        (dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge-set-default-target)
               (lambda (id) (setq dsh-bridge-default-session id))))
      (with-temp-buffer
        (insert (propertize "live-1 row" 'tabulated-list-id "live-1"))
        (goto-char (point-min))
        (dsh-bridge-set-default-target-at-point)))
    (should (equal dsh-bridge-default-session "live-1"))))

(ert-deftest dsh-bridge-list-sessions-columns-and-marker ()
  "The session list shows marker/S/Session/Age/Workspace columns."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-default-session "live-1")
        (dsh-bridge-status-indicator 'geometric))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda ()
                 (let ((sessions
                        '(((id . "live-1") (live . t) (running . t) (title . "First live")
                           (cwd . "/a") (lastActive . 1700000000000)
                           (workspace . "WS A") (workspaceId . "w1"))
                          ((id . "saved-1") (live . nil) (title . "A saved one") (cwd . "/b")
                           (createdAt . 1690000000000)))))
                   (setq dsh-bridge--sessions-cache sessions)
                   sessions)))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions))
    (let ((buf (get-buffer "*dsh-bridge-sessions*")))
      (should buf)
      (should (= (length (buffer-local-value 'tabulated-list-format buf)) 5))
      (should (equal (buffer-local-value 'tabulated-list-sort-key buf)
                     '("Age" . t)))
      (let* ((entries (buffer-local-value 'tabulated-list-entries buf))
             (live (assoc "live-1" entries))
             (saved (assoc "saved-1" entries))
             (live-cells (cadr live))
             (saved-cells (cadr saved)))
        (should live)
        (should saved)
        ;; Default-target marker (index 0): "*" + face for the default target.
        (should (equal (aref live-cells 0) "*"))
        (should (eq (get-text-property 0 'face (aref live-cells 0))
                    'dsh-bridge-default-target-face))
        (should (equal (aref saved-cells 0) " "))
        ;; Status cell (index 1): the state glyph — filled square for running
        ;; (amber), `?' for saved (no live agent).
        (should (equal (aref live-cells 1) "■"))
        (should (equal (aref saved-cells 1) "?"))
        ;; Session name (index 2): unaltered name; cold rows have no face now.
        (should (equal (aref live-cells 2) "First live"))
        (should (equal (aref saved-cells 2) "A saved one"))
        ;; Age (index 3) carries the raw activity timestamp.
        (should (equal (get-text-property 0 'dsh-bridge-age-ts
                                          (aref live-cells 3))
                       1700000000000))
        (should (equal (get-text-property 0 'dsh-bridge-age-ts
                                          (aref saved-cells 3))
                       1690000000000))
        ;; Workspace (index 4) is the workspace title, else the cwd basename.
        (should (equal (aref live-cells 4) "WS A"))
        (should (equal (aref saved-cells 4) "b"))))))

(ert-deftest dsh-bridge-list-sessions-emoji-status-column ()
  "Under the `emoji' indicator the status column is two columns wide.
Emoji glyphs are double-width; in a one-column cell
`tabulated-list-print-col' would cover the glyph with an ellipsis
`display' property, so the row must print it unelided."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-default-session nil)
        (dsh-bridge-status-indicator 'emoji))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda ()
                 (let ((sessions
                        '(((id . "live-1") (live . t) (running . nil) (title . "First live")
                           (lastActive . 1700000000000) (workspace . "WS A")))))
                   (setq dsh-bridge--sessions-cache sessions)
                   sessions)))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions))
    (let ((buf (get-buffer "*dsh-bridge-sessions*")))
      (should buf)
      (should (= (nth 1 (aref (buffer-local-value 'tabulated-list-format buf) 1))
                 2))
      (with-current-buffer buf
        (goto-char (point-min))
        (should (search-forward "🟢" nil t))
        ;; The printed glyph must not be hidden behind an ellipsis display.
        (should-not (get-text-property (1- (point)) 'display))))))

(ert-deftest dsh-bridge-session-cell-untitled ()
  "The session cell shows the title, or the raw id (untitled face) otherwise.
The cell is `dsh-bridge--session-label' with the fallback-face argument."
  (let ((dsh-bridge--session-status nil)
        (a '((id . "aaaaaa") (live . t) (cwd . "/x")))
        (b '((id . "bbbbbb") (live . t) (title . "B"))))
    ;; The Session column is index 2 of the entry's cell vector.
    (let ((a-cell (aref (cadr (dsh-bridge--session-entry a)) 2))
          (b-cell (aref (cadr (dsh-bridge--session-entry b)) 2)))
      (should (string= a-cell "aaaaaa"))
      (should (eq (get-text-property 0 'face a-cell)
                  'dsh-bridge-untitled-face))
      (should (string= b-cell "B"))
      (should-not (get-text-property 0 'face b-cell)))))

(ert-deftest dsh-bridge-list-sessions-shows-ids-when-enabled ()
  "With `dsh-bridge-show-session-ids' non-nil, an Id column appears."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-default-session nil)
        (dsh-bridge-show-session-ids t))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda () '(((id . "live-1") (live . t) (cwd . "/a")))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions))
    (let ((buf (get-buffer "*dsh-bridge-sessions*")))
      (should (= (length (buffer-local-value 'tabulated-list-format buf)) 6))
      (let* ((entries (buffer-local-value 'tabulated-list-entries buf))
             (cells (cadr (assoc "live-1" entries))))
        (should (equal (aref cells 5) "live-1"))))))

(ert-deftest dsh-bridge-sessions-archived-toggle ()
  "The `v' toggle shows/hides archived sessions; live and cold rows stay visible."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda ()
                 '(((id . "live-1") (live . t) (cwd . "/a"))
                   ((id . "saved-1") (live . nil) (cwd . "/b"))
                   ((id . "arch-1") (live . nil) (archived . t) (cwd . "/c")))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions)
      (let ((buf (get-buffer "*dsh-bridge-sessions*")))
        ;; Default: archived hidden.
        (let ((entries (buffer-local-value 'tabulated-list-entries buf)))
          (should (assoc "live-1" entries))
          (should (assoc "saved-1" entries))
          (should-not (assoc "arch-1" entries)))
        ;; Toggle on: archived shown too.
        (with-current-buffer buf (dsh-bridge-toggle-archived-sessions))
        (let ((entries (buffer-local-value 'tabulated-list-entries buf)))
          (should (assoc "arch-1" entries)))
        ;; Toggle off: archived hidden again.
        (with-current-buffer buf (dsh-bridge-toggle-archived-sessions))
        (let ((entries (buffer-local-value 'tabulated-list-entries buf)))
          (should-not (assoc "arch-1" entries)))))))

(ert-deftest dsh-bridge-session-visible-p ()
  "Visibility depends only on the archived flag and the archived toggle."
  (let ((dsh-bridge--sessions-archived-p nil))
    (should (dsh-bridge--session-visible-p '((live . t) (cwd . "/a"))))
    (should (dsh-bridge--session-visible-p '((live . nil) (cwd . "/b"))))
    (should-not (dsh-bridge--session-visible-p '((live . nil) (archived . t)))))
  (let ((dsh-bridge--sessions-archived-p t))
    (should (dsh-bridge--session-visible-p '((live . nil) (archived . t))))
    (should (dsh-bridge--session-visible-p '((live . t) (cwd . "/a"))))))

(ert-deftest dsh-bridge-rename-session-sends-row-id ()
  "Rename from the sessions list sends the row's session id and prompted title."
  (let ((calls nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt &optional _default) "New title"))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) calls)
                 (cons 200 (list (cons 'ok t))))))
      (with-temp-buffer
        (insert (propertize "s1 row" 'tabulated-list-id "s1"))
        (goto-char (point-min))
        (dsh-bridge-rename-session)))
    (let ((rename (cadr (assoc "/sessions/rename"
                               (mapcar (lambda (c) (list (cadr c) c)) calls)))))
      (should rename)
      (should (equal (car rename) "POST"))
      (should (equal (cdr (assoc 'sessionId (caddr rename))) "s1"))
      (should (equal (cdr (assoc 'title (caddr rename))) "New title")))))

(ert-deftest dsh-bridge-archive-session-marshals-args ()
  "Archive confirms, then POSTs the session id to /sessions/archive."
  (let ((calls nil) (msg nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) t))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) calls)
                 (cons 200 (list (cons 'ok t)))))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (with-temp-buffer
        (insert (propertize "s1 row" 'tabulated-list-id "s1"))
        (goto-char (point-min))
        (dsh-bridge-archive-session)))
    (let ((archive (cadr (assoc "/sessions/archive"
                                (mapcar (lambda (c) (list (cadr c) c)) calls)))))
      (should archive)
      (should (equal (car archive) "POST"))
      (should (equal (cdr (assoc 'sessionId (caddr archive))) "s1"))
      (should (string-match-p "archived session" msg)))))

(ert-deftest dsh-bridge-archive-session-aborts-on-no ()
  "Archive declines without a request when the user answers no."
  (let ((called nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (setq called (list method path payload))
                 (cons 200 (list (cons 'ok t))))))
      (with-temp-buffer
        (insert (propertize "s1 row" 'tabulated-list-id "s1"))
        (goto-char (point-min))
        (dsh-bridge-archive-session)))
    (should (null called))))

(ert-deftest dsh-bridge-rename-workspace-marshals-args ()
  "Rename-workspace POSTs the row's workspace id and new title."
  (let ((dsh-bridge--sessions-cache
         '(((id . "s1") (workspaceId . "w1") (workspace . "WS"))))
        (calls nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt &optional _default) "New WS"))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) calls)
                 (cons 200 (list (cons 'ok t))))))
      (with-temp-buffer
        (insert (propertize "s1 row" 'tabulated-list-id "s1"))
        (goto-char (point-min))
        (dsh-bridge-rename-workspace)))
    (let ((rename (cadr (assoc "/workspaces/rename"
                               (mapcar (lambda (c) (list (cadr c) c)) calls)))))
      (should rename)
      (should (equal (cdr (assoc 'workspaceId (caddr rename))) "w1"))
      (should (equal (cdr (assoc 'title (caddr rename))) "New WS")))))

(ert-deftest dsh-bridge-create-session-marshals-args ()
  "Create GETs /workspaces, then POSTs the chosen workspace and binds the new
session as default target."
  (let ((called nil) (bound-target nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _table &optional _pred _req) "WS B"))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) called)
                 (if (equal path "/workspaces")
                     (cons 200
                           (list (cons 'workspaces
                                       (list (list (cons 'id "w1") (cons 'title "WS A"))
                                             (list (cons 'id "w2") (cons 'title "WS B"))))))
                   (cons 201 (list (cons 'sessionId "s-new"))))))
              ((symbol-function 'dsh-bridge--fetch-sessions) (lambda () nil))
              ((symbol-function 'dsh-bridge--refresh-sessions-buffer) (lambda () nil))
              ((symbol-function 'dsh-bridge-set-default-target)
               (lambda (id) (setq bound-target id))))
      (dsh-bridge-create-session))
    (let ((get (cdr (assoc "/workspaces" (mapcar (lambda (c) (list (cadr c) c)) called))))
          (create (cadr (assoc "/sessions/create"
                               (mapcar (lambda (c) (list (cadr c) c)) called)))))
      (should get)
      (should create)
      (should (equal (cdr (assoc 'workspaceId (caddr create))) "w2"))
      (should (equal bound-target "s-new")))))

(ert-deftest dsh-bridge-create-session-empty-workspaces ()
  "A 200 with an empty workspace list still offers \"New workspace…\"."
  (let ((called nil) (table-seen nil) (bound-target nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt table &rest _rest)
                 (setq table-seen table)
                 "New workspace…"))
              ((symbol-function 'read-directory-name)
               (lambda (&rest _) default-directory))
              ((symbol-function 'read-string)
               (lambda (&rest _) ""))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) called)
                 (if (equal path "/workspaces")
                     (cons 200 (list (cons 'workspaces nil)))
                   (cons 201 (list (cons 'sessionId "s-new"))))))
              ((symbol-function 'dsh-bridge--fetch-sessions) (lambda () nil))
              ((symbol-function 'dsh-bridge--refresh-sessions-buffer) (lambda () nil))
              ((symbol-function 'dsh-bridge-set-default-target)
               (lambda (id) (setq bound-target id))))
      (dsh-bridge-create-session))
    (should (member "New workspace…" table-seen))
    (let ((create (cadr (assoc "/sessions/create"
                               (mapcar (lambda (c) (list (cadr c) c)) called)))))
      (should create)
      (should (equal (cdr (assoc 'path (caddr create))) default-directory)))
    (should (equal bound-target "s-new"))))

(ert-deftest dsh-bridge-create-session-rejects-non-directory ()
  "A \"New workspace…\" path that is not a directory is a user error, no POST."
  (let ((called nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "New workspace…"))
              ((symbol-function 'read-directory-name)
               (lambda (&rest _) "/nonexistent-dsh-bridge-test-dir/"))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path payload)
                 (push (list method path payload) called)
                 (cons 200 (list (cons 'workspaces nil))))))
      (should-error (dsh-bridge-create-session) :type 'user-error))
    (should-not (assoc "/sessions/create"
                       (mapcar (lambda (c) (list (cadr c) c)) called)))))

(ert-deftest dsh-bridge-status-glyph-session-states ()
  "The status glyph reflects the session state under the geometric indicator:
a filled circle for an idle live session, a filled square for a running one,
`?' for saved (cold) sessions and for unknown ids."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache
         '(((id . "s-run") (live . t) (running . t))
           ((id . "s-idle") (live . t) (running . nil))
           ((id . "s-cold") (live . nil))))
        (dsh-bridge-status-indicator 'geometric))
    (should (string= (dsh-bridge--status-glyph "s-run") "■"))
    (should (string= (dsh-bridge--status-glyph "s-idle") "●"))
    (should (string= (dsh-bridge--status-glyph "s-cold") "?"))
    (should (string= (dsh-bridge--status-glyph "s-unknown") "?"))))

(ert-deftest dsh-bridge-relative-age ()
  "Ages match DSH's buckets (now/min/h/d/mo/y)."
  (let ((now 1700000000))
    (should (equal (dsh-bridge--relative-age (* now 1000) now) "now"))
    (should (equal (dsh-bridge--relative-age (* (- now 90) 1000) now) "1min"))
    (should (equal (dsh-bridge--relative-age (* (- now 7200) 1000) now) "2h"))
    (should (equal (dsh-bridge--relative-age (* (- now 86400) 1000) now) "1d"))
    (should (equal (dsh-bridge--relative-age (* (- now (* 45 86400)) 1000) now) "1mo"))
    (should (equal (dsh-bridge--relative-age (* (- now (* 400 86400)) 1000) now) "1y"))))

(ert-deftest dsh-bridge-sessions-revert-refetches ()
  "`g' in the sessions buffer re-fetches the list from the host."
  (let ((dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda () '(((id . "live-1") (live . t) (cwd . "/a")))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda () '(((id . "live-2") (live . t) (cwd . "/b")))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (with-current-buffer (get-buffer "*dsh-bridge-sessions*")
        (revert-buffer t t)))
    (let ((entries (buffer-local-value 'tabulated-list-entries
                                       (get-buffer "*dsh-bridge-sessions*"))))
      (should (assoc "live-2" entries))
      (should-not (assoc "live-1" entries)))))

;;; Plugin management: probe, diagnosis, install/uninstall

(defun dsh-bridge-test--mock-response (status body)
  "Return a mock url-http response buffer with STATUS and BODY."
  (let ((buf (generate-new-buffer " *dsh-bridge-mock*")))
    (with-current-buffer buf
      (insert (format "HTTP/1.1 %s OK\r\n\r\n" status))
      (insert body)
      (set (make-local-variable 'url-http-response-status) status))
    buf))

(ert-deftest dsh-bridge-bridge-status-running ()
  "A 200 naming dsh-emacs-bridge with the package version means running."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response
                  200 (format "{\"name\":\"dsh-emacs-bridge\",\"version\":\"%s\"}"
                              dsh-bridge-version)))))
      (should (eq (dsh-bridge--bridge-status) 'running))
      (should (eq dsh-bridge--bridge-status-cache nil)))))

(ert-deftest dsh-bridge-bridge-status-incompatible ()
  "A version mismatch (or no reported version) means incompatible."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response
                  200 "{\"name\":\"dsh-emacs-bridge\",\"version\":\"0.0.0-test\"}"))))
      (should (eq (dsh-bridge--bridge-status) 'incompatible)))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response
                  200 "{\"name\":\"dsh-emacs-bridge\",\"version\":null}"))))
      (should (eq (dsh-bridge--bridge-status) 'incompatible)))))

(ert-deftest dsh-bridge-bridge-status-wrong-name ()
  "A 200 naming something else is not the bridge plugin."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response
                  200 "{\"name\":\"something-else\",\"version\":\"1.2.3\"}"))))
      (should (eq (dsh-bridge--bridge-status) 'not-running)))))

(ert-deftest dsh-bridge-bridge-status-html-body ()
  "A 200 with an HTML body (a catch-all SPA fallback) is not the plugin."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response 200 "<html><body>app</body></html>"))))
      (should (eq (dsh-bridge--bridge-status) 'not-running)))))

(ert-deftest dsh-bridge-bridge-status-404 ()
  "A 404 means the plugin is not loaded (the static-file fallback)."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response 404 ""))))
      (should (eq (dsh-bridge--bridge-status) 'not-running)))))

(ert-deftest dsh-bridge-bridge-status-forbidden ()
  "A 403 is reported distinctly from not-loaded."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (dsh-bridge-test--mock-response 403 "{\"error\":\"forbidden\"}"))))
      (should (eq (dsh-bridge--bridge-status) 'forbidden)))))

(ert-deftest dsh-bridge-bridge-status-unreachable ()
  "A transport failure means `dsh web' is unreachable."
  (let ((dsh-bridge--bridge-status-cache nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _) nil)))
      (should (eq (dsh-bridge--bridge-status) 'unreachable)))))

(ert-deftest dsh-bridge-bridge-status-cached ()
  "`dsh-bridge--ensure-plugin' caches the probe result per session."
  (let ((dsh-bridge--bridge-status-cache nil) (calls 0)
        (dsh-bridge--plugin-diagnosed nil))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (setq calls (1+ calls))
                 (dsh-bridge-test--mock-response
                  200 (format "{\"name\":\"dsh-emacs-bridge\",\"version\":\"%s\"}"
                              dsh-bridge-version)))))
      (dsh-bridge--ensure-plugin)
      (dsh-bridge--ensure-plugin)
      (should (= calls 1))
      (should (eq dsh-bridge--bridge-status-cache 'running)))
    (dsh-bridge--note-request-failure)
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _)
                 (setq calls (1+ calls))
                 (dsh-bridge-test--mock-response
                  200 (format "{\"name\":\"dsh-emacs-bridge\",\"version\":\"%s\"}"
                              dsh-bridge-version)))))
      (dsh-bridge--ensure-plugin)
      (should (= calls 2))
      (should (eq dsh-bridge--bridge-status-cache 'running)))
    ;; Do not leak the cached state into later tests.
    (setq dsh-bridge--bridge-status-cache nil)))

(ert-deftest dsh-bridge-note-request-failure ()
  "A 404 drops the cache only when it contradicts the cached state."
  (let ((dsh-bridge--bridge-status-cache 'running))
    (dsh-bridge--note-request-failure)
    (should (null dsh-bridge--bridge-status-cache)))
  (let ((dsh-bridge--bridge-status-cache 'not-running))
    (dsh-bridge--note-request-failure)
    (should (eq dsh-bridge--bridge-status-cache 'not-running)))
  (let ((dsh-bridge--bridge-status-cache 'running))
    (dsh-bridge--note-request-failure)
    (should (null dsh-bridge--bridge-status-cache))))

(ert-deftest dsh-bridge-plugin-install-state-manifest ()
  "The profile manifest decides installed state: dependencies or bundles."
  (let ((dsh-bridge-profile "web")
        (home (make-temp-file "dsh-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-bridge--dsh-home) (lambda () home)))
          (make-directory (expand-file-name "profiles/web" home) t)
          ;; In dependencies.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "{\"dependencies\":{\"dsh-emacs-bridge\":\"file:.\"}}"))
          (should (eq (dsh-bridge--plugin-install-state) 'installed))
          ;; In dsh.profile.bundles.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "{\"dsh\":{\"profile\":{\"bundles\":[\"dsh-emacs-bridge\"]}}}"))
          (should (eq (dsh-bridge--plugin-install-state) 'installed))
          ;; Neither.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "{}"))
          (should (eq (dsh-bridge--plugin-install-state) 'not-installed))
          ;; Invalid JSON.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "not json"))
          (should (eq (dsh-bridge--plugin-install-state) 'not-installed)))
      (delete-directory home t))))

(ert-deftest dsh-bridge-dsh-command-config-overrides ()
  "The defcustom wins over auto-detection."
  (let ((dsh-bridge-dsh-command '("npx" "--yes" "@deepseek-ai/dsh")))
    (should (equal (dsh-bridge--dsh-command)
                   '("npx" "--yes" "@deepseek-ai/dsh")))))

(ert-deftest dsh-bridge-dsh-command-string-split ()
  "A string setting is split shell-style; a list stays verbatim."
  (let ((dsh-bridge-dsh-command "npx --yes @deepseek-ai/dsh"))
    (should (equal (dsh-bridge--dsh-command)
                   '("npx" "--yes" "@deepseek-ai/dsh"))))
  (let ((dsh-bridge-dsh-command "node \"/path with space/bin.js\""))
    (should (equal (dsh-bridge--dsh-command)
                   '("node" "/path with space/bin.js"))))
  (let ((dsh-bridge-dsh-command "/usr/local/bin/dsh"))
    (should (equal (dsh-bridge--dsh-command) '("/usr/local/bin/dsh")))))

(ert-deftest dsh-bridge-dsh-command-auto-detect ()
  "Auto-detection falls back PATH -> npm global bin -> npx."
  ;; dsh on PATH wins.
  (let ((dsh-bridge-dsh-command nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "dsh") "dsh"))))
      (should (equal (dsh-bridge--dsh-command) '("dsh")))))
  ;; npm global bin is found when dsh isn't on PATH.
  (let ((dsh-bridge-dsh-command nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "npm") "npm")))
              ((symbol-function 'process-lines)
               (lambda (&rest _) '("/fake/prefix")))
              ((symbol-function 'file-executable-p)
               (lambda (file) (string-suffix-p "bin/dsh" file))))
      (should (equal (dsh-bridge--dsh-command) '("/fake/prefix/bin/dsh")))))
  ;; Neither dsh nor a global bin: npx fallback.
  (let ((dsh-bridge-dsh-command nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "npx") "npx"))))
      (should (equal (dsh-bridge--dsh-command) '("npx" "--yes" "@deepseek-ai/dsh")))))
  ;; Nothing available.
  (let ((dsh-bridge-dsh-command nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
      (should (null (dsh-bridge--dsh-command))))))

(ert-deftest dsh-bridge-ensure-plugin-running-noop ()
  "A running plugin needs no diagnosis and produces no message."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'running))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--ensure-plugin))
    (should (null msg))
    (should (null dsh-bridge--plugin-diagnosed))))

(ert-deftest dsh-bridge-ensure-plugin-incompatible-offers-reinstall ()
  "An incompatible (version-mismatched) plugin offers a reinstall."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil)
        (offered nil) (msg nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'incompatible))
              ;; The reinstall offer fires regardless of the profile state.
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'no-profile))
              ((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'y-or-n-p)
               (lambda (question)
                 (setq offered question)
                 nil))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--ensure-plugin))
    (should (string-match-p "Reinstall" offered))
    (should (string-match-p "install aborted" msg))))

(ert-deftest dsh-bridge-ensure-plugin-offers-when-missing ()
  "Not-running + not installed + `ask' offers; declining latches."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (offered nil) (msg nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'not-running))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'not-installed))
              ((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq offered t) nil))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--ensure-plugin))
    (should offered)
    (should (string-match-p "install aborted" msg))
    ;; The diagnosis is latched: a second call does not re-prompt.
    (let ((offered 0))
      (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
                 (lambda () 'not-running))
                ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'not-installed))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq offered (1+ offered)) nil))
                ((symbol-function 'message) (lambda (&rest _) nil)))
        (dsh-bridge--ensure-plugin))
      (should (= offered 0)))))

(ert-deftest dsh-bridge-ensure-plugin-installs-on-yes ()
  "Accepting the offer starts the asynchronous install."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (installed nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'not-running))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'not-installed))
              ((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'dsh-bridge--install-plugin-async)
               (lambda (dir) (setq installed dir)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge--ensure-plugin))
    (should (equal installed "/tmp/plugin"))))

(ert-deftest dsh-bridge-ensure-plugin-installed-not-loaded ()
  "Not-running + installed says to restart, with no offer."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'not-running))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'installed))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--ensure-plugin))
    (should (string-match-p "restart" msg))))

(ert-deftest dsh-bridge-ensure-plugin-unreachable ()
  "Unreachable + installed reports the server is down, no offer."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'unreachable))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'installed))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--ensure-plugin))
    (should (string-match-p "no bridge is running" msg))))

(ert-deftest dsh-bridge-ensure-plugin-unreachable-not-installed ()
  "Unreachable + not installed still offers (installing needs no server)."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil) (offered nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'unreachable))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'not-installed))
              ((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq offered t) nil))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge--ensure-plugin))
    (should offered)))

(ert-deftest dsh-bridge-ensure-plugin-no-dsh-no-offer ()
  "No profile and no real CLI: point at installing DSH, with no offer.
This is the case the npx fallback must not paper over: downloading the
whole CLI to install a plugin for a DSH the user never set up."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil)
        (offered nil) (err-msg nil)
        (dsh-bridge-dsh-command nil))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'unreachable))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'no-profile))
              ((symbol-function 'dsh-bridge--dsh-installed-p) (lambda () nil))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq offered t) nil)))
      (condition-case err
          (dsh-bridge--ensure-plugin)
        (user-error (setq err-msg (error-message-string err)))))
    (should-not offered)
    (should (string-match-p "no DSH installation found" err-msg))))

(ert-deftest dsh-bridge-ensure-plugin-no-profile-but-cli-offers ()
  "No profile but a real CLI (DSH exists, profile never created): offer."
  (let ((dsh-bridge--bridge-status-cache nil) (dsh-bridge--plugin-diagnosed nil)
        (offered nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--bridge-status)
               (lambda () 'unreachable))
              ((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'no-profile))
              ((symbol-function 'dsh-bridge--dsh-installed-p) (lambda () t))
              ((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq offered t) nil))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge--ensure-plugin))
    (should offered)))

(ert-deftest dsh-bridge-plugin-install-state-tri-state ()
  "The profile probe distinguishes installed / not-installed / no-profile."
  (let ((dsh-bridge-profile "web")
        (home (make-temp-file "dsh-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-bridge--dsh-home) (lambda () home)))
          ;; No profile directory at all.
          (should (eq (dsh-bridge--plugin-install-state) 'no-profile))
          ;; Profile directory without a manifest.
          (make-directory (expand-file-name "profiles/web" home) t)
          (should (eq (dsh-bridge--plugin-install-state) 'not-installed))
          ;; Manifest without the plugin.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "{}"))
          (should (eq (dsh-bridge--plugin-install-state) 'not-installed))
          ;; Manifest with the plugin.
          (with-temp-file (expand-file-name "profiles/web/package.json" home)
            (insert "{\"dependencies\":{\"dsh-emacs-bridge\":\"file:.\"}}"))
          (should (eq (dsh-bridge--plugin-install-state) 'installed)))
      (delete-directory home t))))

(ert-deftest dsh-bridge-validate-plugin-install ()
  "`--dump-config' success means the profile composes."
  (let ((dsh-bridge-profile "web")
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest args)
                 (if (member "--dump-config" args) 0 1))))
      (should (dsh-bridge--validate-plugin-install)))
    (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 1)))
      (should-not (dsh-bridge--validate-plugin-install)))))

(ert-deftest dsh-bridge-install-plugin-sync ()
  "The internal install runs pnpm via `dsh plugin add', and needs pnpm."
  (let ((dsh-bridge-profile "web") (argv nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "found"))
              ((symbol-function 'call-process)
               (lambda (&rest args) (setq argv args) 0)))
      (should (dsh-bridge--install-plugin "/tmp/plugin"))
      (should (equal (seq-filter #'stringp argv)
                     '("dsh" "plugin" "--profile" "web" "add" "file:/tmp/plugin"))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "found"))
              ((symbol-function 'call-process) (lambda (&rest _) 1)))
      (should-not (dsh-bridge--install-plugin "/tmp/plugin")))
    ;; Missing pnpm aborts without invoking dsh.
    (let ((called nil))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (prog) (unless (equal prog "pnpm") "found")))
                ((symbol-function 'call-process)
                 (lambda (&rest _) (setq called t) 0)))
        (should-not (dsh-bridge--install-plugin "/tmp/plugin"))
        (should-not called)))))

(ert-deftest dsh-bridge-install-plugin-interactive ()
  "The interactive install validates and says to restart on success."
  (let ((dsh-bridge-profile "web") (msg nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--plugin-directory) (lambda () "/tmp/plugin"))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'dsh-bridge--install-plugin) (lambda (_) t))
              ((symbol-function 'dsh-bridge--validate-plugin-install) (lambda () t))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge-install-plugin))
    (should (string-match-p "restart" msg))))

(ert-deftest dsh-bridge-install-sentinel-chains-validation ()
  "The async install sentinel chains into async validation."
  (let ((dsh-bridge-profile "web") (validated nil))
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'dsh-bridge--validate-plugin-install-async)
               (lambda () (setq validated t)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge--install-sentinel 'fake-process "finished\n"))
    (should validated)))

(ert-deftest dsh-bridge-install-sentinel-failure ()
  "A failed async install reports the failure and skips validation."
  (let ((validated nil) (msg nil))
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 1))
              ((symbol-function 'dsh-bridge--validate-plugin-install-async)
               (lambda () (setq validated t)))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--install-sentinel 'fake-process "finished\n"))
    (should-not validated)
    (should (string-match-p "failed" msg))))

(ert-deftest dsh-bridge-validate-sentinel-reports ()
  "The validation sentinel reports composition success and failure."
  (let ((msg nil))
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--validate-sentinel 'fake-process "finished\n"))
    (should (string-match-p "restart" msg)))
  (let ((msg nil))
    (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 1))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge--validate-sentinel 'fake-process "finished\n"))
    (should (string-match-p "uninstall-plugin" msg))))

(ert-deftest dsh-bridge-uninstall-skips-when-not-installed ()
  "Uninstall pre-checks the manifest and skips pnpm otherwise."
  (let ((called nil))
    (cl-letf (((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'not-installed))
              ((symbol-function 'call-process)
               (lambda (&rest _) (setq called t) 0))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge-uninstall-plugin))
    (should-not called)))

(ert-deftest dsh-bridge-uninstall-runs-remove ()
  "Uninstall runs `dsh plugin remove dsh-emacs-bridge' when installed."
  (let ((dsh-bridge-profile "web") (argv nil)
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'installed))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'call-process)
               (lambda (&rest args) (setq argv args) 0))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge-uninstall-plugin))
    (let ((strings (seq-filter #'stringp argv)))
      (should (member "remove" strings))
      (should (member "dsh-emacs-bridge" strings)))))

(ert-deftest dsh-bridge-uninstall-remove-failure ()
  "A failing `remove' (exit status 1) signals an error, not false success.
Exit statuses are integers and 1 is truthy, so this guards the `zerop'."
  (let ((dsh-bridge-profile "web")
        (dsh-bridge-dsh-command '("dsh")))
    (cl-letf (((symbol-function 'dsh-bridge--plugin-install-state) (lambda () 'installed))
              ((symbol-function 'executable-find)
               (lambda (prog) (and (equal prog "pnpm") "found")))
              ((symbol-function 'call-process) (lambda (&rest _) 1))
              ((symbol-function 'display-buffer) (lambda (&rest _) nil))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (should-error (dsh-bridge-uninstall-plugin) :type 'user-error))))

(ert-deftest dsh-bridge-plugin-directory-source-load ()
  "plugin-directory returns nil-or-a-dir (never signals) off load-path.
Loading by path from a source checkout makes `locate-library' nil; the helper
must fall back to the loaded file and never call `file-name-directory' on nil."
  (cl-letf (((symbol-function 'locate-library) (lambda (&rest _) nil)))
    (let ((dir (dsh-bridge--plugin-directory)))   ; must not signal
      (should (or (null dir) (stringp dir))))))

;;; Dispatcher and menus

(ert-deftest dsh-bridge-dispatcher-suffixes ()
  "Every verb is a dispatcher suffix; reply/open is `r' (not `p'), the inbox
(`i') and the `S' mnemonic are gone, and targeting lives on `t'/`u'."
  (dolist (spec dsh-bridge--verb-suffixes)
    (should (transient-get-suffix 'dsh-bridge (car spec))))
  (should (transient-get-suffix 'dsh-bridge "r"))
  (should (transient-get-suffix 'dsh-bridge "t"))
  (should (transient-get-suffix 'dsh-bridge "u"))
  ;; `transient-get-suffix' signals when the key is absent.
  (dolist (absent '("p" "i" "S"))
    (should-not (condition-case nil
                    (progn (transient-get-suffix 'dsh-bridge absent) t)
                  (error nil)))))

(ert-deftest dsh-bridge-mode-menus ()
  "Each dsh-bridge mode installs a menu-bar menu."
  (let ((key (vector 'menu-bar (intern "dsh bridge"))))
    (dolist (map (list dsh-bridge-sessions-mode-map
                       dsh-bridge-view-mode-map
                       dsh-bridge-prompt-mode-map))
      (should (lookup-key map key)))))

;;; SSE machinery (unchanged behavior)

(ert-deftest dsh-bridge-chunked-decode ()
  "HTTP/1.1 chunked transfer encoding is decoded byte-for-byte."
  (let ((decoded (dsh-bridge--chunked-decode
                  (string-to-unibyte "5\r\nhello\r\n0\r\n\r\n"))))
    (should (equal (car decoded) (string-to-unibyte "hello")))
    (should (equal (cdr decoded) "")))
  ;; An incomplete chunk is held back whole for the next call.
  (let ((decoded (dsh-bridge--chunked-decode (string-to-unibyte "5\r\nhel"))))
    (should (equal (car decoded) ""))
    (should (equal (cdr decoded) (string-to-unibyte "5\r\nhel"))))
  ;; Multibyte UTF-8 payloads are framed by their byte length.
  (let ((decoded (dsh-bridge--chunked-decode
                  (encode-coding-string "3\r\n…\r\n0\r\n\r\n" 'utf-8))))
    (should (equal (decode-coding-string (car decoded) 'utf-8) "…"))
    (should (equal (cdr decoded) ""))))

(ert-deftest dsh-bridge-sse-parse ()
  "SSE `data:' frames are decoded; non-data lines and partial frames are handled."
  (let ((result (dsh-bridge--sse-parse "")))
    (should (null (car result)))
    (should (equal (cdr result) "")))
  (let ((result (dsh-bridge--sse-parse "retry: 5000\n\n")))
    (should (null (car result)))
    (should (equal (cdr result) "")))
  (let ((result (dsh-bridge--sse-parse "data: {\"kind\":\"outbox\"}\n\n")))
    (should (equal (car result) '(((kind . "outbox")))))
    (should (equal (cdr result) "")))
  ;; No trailing blank line yet: held back.
  (let ((result (dsh-bridge--sse-parse "data: {\"kind\":\"outbox\"}")))
    (should (null (car result)))
    (should (equal (cdr result) "data: {\"kind\":\"outbox\"}")))
  ;; Several events in one buffer.
  (let ((result (dsh-bridge--sse-parse
                 "data: {\"kind\":\"draft\"}\n\ndata: {\"kind\":\"outbox\"}\n\n")))
    (should (equal (car result) '(((kind . "draft")) ((kind . "outbox")))))
    (should (equal (cdr result) ""))))

(ert-deftest dsh-bridge-sse-parse-utf8-straddle ()
  "A `data:' payload whose UTF-8 character straddles a chunk boundary decodes.
Framing is done on raw bytes, so a split character is never decoded
prematurely; the payload is decoded only at the point of consumption."
  (let* ((p1 (unibyte-string
              #x64 #x61 #x74 #x61 #x3a #x20 #x7b #x22 #x6d #x73 #x67 #x22 #x3a #x22 #xC3)) ; ...\xC3
         (p2 (unibyte-string #xA9 #x22 #x7d #x0a #x0a)))                       ; "\xA9\"}\n\n
    ;; First read: payload is incomplete (no blank line), held back as raw bytes.
    (let* ((init (dsh-bridge--sse-parse p1))
           (acc (cdr init)))
      (should (null (car init)))
      (should (equal acc p1))
      ;; Second read: concatenate the raw remainder with the new bytes, then frame.
      (let* ((parsed (dsh-bridge--sse-parse (concat acc p2)))
             (events (car parsed)))
        (should (equal (length events) 1))
        (let ((msg (alist-get 'msg (car events))))
          (should (equal msg "é"))
          (should (equal (encode-coding-string msg 'utf-8)
                         (unibyte-string #xC3 #xA9))))))))

(ert-deftest dsh-bridge-sse-decode-roundtrip ()
  "A full chunked SSE body decodes to an outbox notice."
  (let* ((payload "data: {\"kind\":\"outbox\"}\n\n")
         (size (length (encode-coding-string payload 'utf-8)))
         (raw (encode-coding-string
               (concat (format "%x\r\n" size) payload "\r\n0\r\n\r\n")
               'utf-8)))
    (let* ((decoded (dsh-bridge--chunked-decode raw))
           (parsed (dsh-bridge--sse-parse (car decoded))))
      (should (equal (car parsed) '(((kind . "outbox"))))))))

;;; Turn notifications, session status, and the header line

(ert-deftest dsh-bridge-status-unknown-fallback ()
  "With no tracker and no session row, the status is unknown; the row's
`running' flag is a seed when the tracker has no opinion."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil))
    (should (eq (dsh-bridge--status-state "s1") 'unknown)))
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (live . t) (running . t)))))
    (should (eq (dsh-bridge--status-state "s1") 'running)))
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (live . t) (running . nil)))))
    (should (eq (dsh-bridge--status-state "s1") 'idle))))

(ert-deftest dsh-bridge-status-glyph ()
  "The status glyph reflects the indicator type and the session state."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil)
        (dsh-bridge-status-indicator 'geometric))
    (should (string= (dsh-bridge--status-glyph nil) "?"))
    (dsh-bridge--status-set "s1" 'idle)
    (should (string= (dsh-bridge--status-glyph "s1") "●"))
    (dsh-bridge--status-set "s1" 'running)
    (should (string= (dsh-bridge--status-glyph "s1") "■")))
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil)
        (dsh-bridge-status-indicator 'text))
    (dsh-bridge--status-set "s1" 'idle)
    (should (string= (dsh-bridge--status-glyph "s1") "✓")))
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil)
        (dsh-bridge-status-indicator 'none))
    (should (string= (dsh-bridge--status-glyph "s1") ""))))

(ert-deftest dsh-bridge-notification-turn-events ()
  "The notification dispatch updates the tracker for start/complete frames."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil))
    (dsh-bridge--notification-handle-events
     '(((kind . "turn-start") (sessionId . "s1"))))
    (should (eq (dsh-bridge--status-state "s1") 'running))
    (dsh-bridge--notification-handle-events
     '(((kind . "turn-complete") (sessionId . "s1") (reason . "completed"))))
    (should (eq (dsh-bridge--status-state "s1") 'idle))))

(ert-deftest dsh-bridge-view-position ()
  "The view position is newest-first (k/n) over the session's turns, at rest
and while cycling; content without a turn identity (a pushed message) or a
turn no longer cached shows nothing."
  (let ((dsh-bridge--turns-cache (list (cons "s1" dsh-bridge-test--view-turns))))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      ;; At rest on the middle turn (turn 20, index 1): (2/3).
      (setq-local dsh-bridge--view-turn 20)
      (setq-local dsh-bridge--view-turn-index nil)
      (should (equal (dsh-bridge--view-turn-position) " (2/3)"))
      ;; Cycling by index, newest first.
      (setq-local dsh-bridge--view-turn-index 0)
      (should (equal (dsh-bridge--view-turn-position) " (1/3)"))
      (setq-local dsh-bridge--view-turn-index 2)
      (should (equal (dsh-bridge--view-turn-position) " (3/3)"))
      ;; At rest on a turn no longer cached (e.g. after a compaction) or on raw
      ;; pushed content: no indicator.
      (setq-local dsh-bridge--view-turn-index nil)
      (setq-local dsh-bridge--view-turn 999)
      (should (equal (dsh-bridge--view-turn-position) ""))
      (setq-local dsh-bridge--view-turn nil)
      (should (equal (dsh-bridge--view-turn-position) ""))
      ;; Turn-following reads (latest/n), pinned to the newest turn.
      (setq-local dsh-bridge--view-turn 30)
      (setq-local dsh-bridge--view-follow t)
      (should (equal (dsh-bridge--view-turn-position) " (latest/3)"))
      (setq-local dsh-bridge--view-follow nil))))

(ert-deftest dsh-bridge-view-header-provenance ()
  "The output header separates the session and time with `·', for both fetches
and pushed messages."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (dsh-bridge-status-indicator 'geometric))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (setq-local dsh-bridge--view-timestamp "14:22:05")
      (setq-local dsh-bridge--view-received-at nil)
      (should (string-match-p "· 14:22:05" (dsh-bridge--view-header-line)))
      (should-not (string-match-p "↓" (dsh-bridge--view-header-line)))
      (setq-local dsh-bridge--view-received-at 2000000)
      (should (string-match-p "· " (dsh-bridge--view-header-line)))
      (should-not (string-match-p "↓" (dsh-bridge--view-header-line))))))

(ert-deftest dsh-bridge-view-header-percent-escaped ()
  "A `%' in the session title is escaped for `header-line-format'."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "50% done") (live . t)))))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (setq-local dsh-bridge--view-timestamp "14:22:05")
      (setq-local dsh-bridge--view-received-at nil)
      (should (string-match-p (regexp-quote "50%% done")
                              (dsh-bridge--view-header-line))))))

(ert-deftest dsh-bridge-prompt-sent-marker ()
  "The prompt header's `✓ sent' marker appears after a send and clears on edit."
  (let ((dsh-bridge--last-sent '(("s1" . ("hello" . 1234567.0)))))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (erase-buffer)
      (insert "hello")
      (should (string-match-p "sent" (dsh-bridge--prompt-sent-marker "s1")))
      (erase-buffer)
      (insert "hello!")
      (should (equal (dsh-bridge--prompt-sent-marker "s1") "")))))

(ert-deftest dsh-bridge-send-and-exit-resend-guard ()
  "C-c C-c confirms before an identical re-send to the same session;
declining aborts, and edited text sends without asking."
  (let ((dsh-bridge-prompt-resend-confirm t)
        (dsh-bridge--last-sent '(("s1" . ("hello" . 1234567.0))))
        (asked nil) (sent nil))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (cl-letf (((symbol-function 'dsh-bridge-send-text)
                 (lambda (text &rest _) (setq sent text)))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (setq asked t) nil)))
        ;; Identical text: the guard fires; declining aborts the send.
        (insert "hello")
        (should-error (dsh-bridge-send-and-exit) :type 'user-error)
        (should asked)
        (should (null sent))
        ;; Edited text: no guard, sends.
        (setq asked nil)
        (insert "!")
        (dsh-bridge-send-and-exit)
        (should (null asked))
        (should (equal sent "hello!"))))))

(ert-deftest dsh-bridge-turn-reason-phrase ()
  "The turn-end reason kind maps to a truthful human verb."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T")))))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "completed")
                   "session \"T\" finished"))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "aborted")
                   "session \"T\" interrupted"))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "error")
                   "session \"T\" failed"))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "max-tokens")
                   "session \"T\" stopped at the token limit"))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "blocked")
                   "session \"T\" blocked"))
    (should (equal (dsh-bridge--turn-reason-phrase "s1" "bogus")
                   "session \"T\" ended"))))

(ert-deftest dsh-bridge-send-exit-pops-view ()
  "The send-and-exit success branch shows the output buffer in turn-following
state (rather than burying): the user lands on the live view after sending.
The prompt buffer is cleared and the sent text stays in the prompt history."
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*"))
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (setq-local dsh-bridge--prompt-session "s1")
    (let ((shown nil)
          (dsh-bridge--session-status nil))
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq shown t)))
                ((symbol-function 'dsh-bridge--request)
                 (lambda (_m _p _pl)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'turns (list (dsh-bridge-test--view-turn 2 1000
                                                      (list (dsh-bridge-test--view-segment "latest"))))))))))
        (dsh-bridge--prompt-exit "s1"))
      (should shown)
      (with-current-buffer (get-buffer "*dsh-bridge-output*")
        (should (equal dsh-bridge--view-content-session "s1"))
        (should (eq dsh-bridge--view-follow t))
        (should (equal dsh-bridge--view-turn 2))
        (should (equal (buffer-string) "latest")))))
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*")))

;;; Prompt-buffer model selection and context occupancy

(ert-deftest dsh-bridge-prompt-model-label ()
  "The model segment reads the catalog display name, with fallbacks."
  (let ((dsh-bridge--session-models
         '(("s1" (current . ((provider . "p") (model . "m")))
            (groups . (((id . "p") (name . "P")
                        (models . (((id . "m") (name . "Model M")))))))))))
    (should (equal (dsh-bridge--prompt-model-label "s1") "Model M")))
  (let ((dsh-bridge--session-models
         '(("s1" (current . ((provider . "p") (model . "x")))
            (groups . (((id . "p") (name . "P") (models . (((id . "m") (name . "M")))))))))))
    (should (equal (dsh-bridge--prompt-model-label "s1") "x")))
  (let ((dsh-bridge--session-models nil))
    (should (null (dsh-bridge--prompt-model-label "s1")))))

(ert-deftest dsh-bridge-prompt-context-label ()
  "The context segment applies the DSH percent formula, clamps, and rounds."
  (let ((dsh-bridge--session-context '(("s1" . (45000 . 100000)))))
    (should (equal (dsh-bridge--prompt-context-label "s1") "45%")))
  (let ((dsh-bridge--session-context '(("s1" . (150000 . 100000)))))
    (should (equal (dsh-bridge--prompt-context-label "s1") "100%")))
  (let ((dsh-bridge--session-context '(("s1" . (1 . 3)))))
    (should (equal (dsh-bridge--prompt-context-label "s1") "33%")))
  (let ((dsh-bridge--session-context nil))
    (should (null (dsh-bridge--prompt-context-label "s1")))))

(ert-deftest dsh-bridge-prompt-header-model-context ()
  "The header appends model and context segments when cached, and omits them
when the caches are empty."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (dsh-bridge--last-sent nil)
        (dsh-bridge--session-models
         '(("s1" (current . ((provider . "p") (model . "m")))
            (groups . (((id . "p") (name . "P")
                        (models . (((id . "m") (name . "Model M"))))))))))
        (dsh-bridge--session-context '(("s1" . (45000 . 100000)))))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (let ((header (dsh-bridge--prompt-header-line)))
        (should (string-match-p "Model M" header))
        ;; `header-line-format' interprets `%' constructs even in `:eval'
        ;; results, so the header string must carry the escaped form.
        (should (string-match-p (regexp-quote "45%%") header)))))
  (let ((dsh-bridge--session-models nil)
        (dsh-bridge--session-context nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    (with-temp-buffer
      (dsh-bridge-prompt-mode)
      (setq-local dsh-bridge--prompt-session "s1")
      (should-not (string-match-p " · " (dsh-bridge--prompt-header-line))))))

(ert-deftest dsh-bridge-model-catalog ()
  "The catalog flattens provider groups into provider/model triples."
  (let ((data '((groups .
                  (((id . "p1") (name . "P1")
                    (models . (((id . "m1") (name . "M1"))
                               ((id . "m2") (name . "M2")))))
                   ((id . "p2") (name . "P2")
                    (models . (((id . "m3") (name . "M3"))))))))))
    (let ((catalog (dsh-bridge--model-catalog data)))
      (should (equal (mapcar #'car catalog) '("p1/m1" "p1/m2" "p2/m3")))
      (should (equal (cadr (assoc "p1/m2" catalog)) "p1"))
      (should (equal (alist-get 'id (caddr (assoc "p2/m3" catalog))) "m3")))))

(ert-deftest dsh-bridge-fetch-models-cache ()
  "fetch-models caches per session and force-refreshes."
  (let ((dsh-bridge--session-models nil) (calls 0))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method path _payload)
                 (setq calls (1+ calls))
                 (should (equal method "GET"))
                 (should (equal path "/models?sessionId=s1"))
                 (cons 200 '((current . ((provider . "p") (model . "m")))
                             (groups . nil))))))
      (dsh-bridge--fetch-models "s1")
      (dsh-bridge--fetch-models "s1")
      (should (= calls 1))
      (dsh-bridge--fetch-models "s1" t)
      (should (= calls 2)))))

(ert-deftest dsh-bridge-fetch-context ()
  "fetch-context seeds the cache once and skips when cached."
  (let ((dsh-bridge--session-context nil) (calls 0))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (setq calls (1+ calls))
                 (cons 200 '((usedTokens . 45) (contextWindow . 100000))))))
      (should (equal (dsh-bridge--fetch-context "s1") (cons 45 100000)))
      (dsh-bridge--fetch-context "s1")
      (should (= calls 1)))))

(ert-deftest dsh-bridge-notification-context ()
  "A context SSE frame folds into the session-context cache."
  (let ((dsh-bridge--session-context nil))
    (dsh-bridge--notification-handle-events
     '(((kind . "context") (sessionId . "s1") (usedTokens . 45) (contextWindow . 100000))))
    (should (equal (assoc "s1" dsh-bridge--session-context) '("s1" 45 . 100000)))))

(ert-deftest dsh-bridge-notification-turn-frames-refresh-models ()
  "Turn frames force-refresh a cached session's model entry, and leave
uncached sessions alone.  `run-at-time' is stubbed to run immediately."
  (let ((dsh-bridge--session-models '(("s1" . ((current . ((provider . "p") (model . "m")))))))
        (dsh-bridge--session-status nil)
        (refetched nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat fn &rest args) (apply fn args)))
              ((symbol-function 'dsh-bridge--fetch-models)
               (lambda (id force) (push (cons id force) refetched)))
              ((symbol-function 'dsh-bridge--status-event-render) #'ignore)
              ((symbol-function 'dsh-bridge--turn-complete-act) #'ignore))
      (dsh-bridge--notification-handle-events
       '(((kind . "turn-start") (sessionId . "s1"))
         ((kind . "turn-complete") (sessionId . "s1"))
         ((kind . "turn-complete") (sessionId . "s2"))))
      (should (equal refetched '(("s1" . t) ("s1" . t)))))))

(ert-deftest dsh-bridge-notification-turn-start-refreshes-turns ()
  "A turn-start frame schedules a turn-cache refresh so the View `(k/n)'
counter tracks the live turn list during a turn, not only after it completes."
  (let ((dsh-bridge--session-status nil)
        (refreshed nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat fn &rest args) (apply fn args)))
              ((symbol-function 'dsh-bridge--status-event-render) #'ignore)
              ((symbol-function 'dsh-bridge--models-event-refresh) #'ignore)
              ((symbol-function 'dsh-bridge--view-turns-cache-refresh)
               (lambda (id) (push id refreshed))))
      (dsh-bridge--notification-handle-events
       '(((kind . "turn-start") (sessionId . "s1"))))
      (should (equal refreshed '("s1"))))))

(ert-deftest dsh-bridge-notification-replies-changed-refreshes ()
  "A replies-changed frame schedules a turn-cache refresh for the session."
  (let ((refreshed nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat fn &rest args) (apply fn args)))
              ((symbol-function 'dsh-bridge--view-turns-cache-refresh)
               (lambda (id) (push id refreshed))))
      (dsh-bridge--notification-handle-events
       '(((kind . "replies-changed") (sessionId . "s1"))))
      (should (equal refreshed '("s1"))))))

(ert-deftest dsh-bridge-status-reprint-row-repaints-cell ()
  "Reprinting a sessions-list row repaints a changed status cell in place."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-status-indicator 'geometric)
        (dsh-bridge--sessions-cache
         '(((id . "s1") (live . t) (running . nil) (lastActive . 0))))
        (dsh-bridge--session-status nil))
    (with-current-buffer (get-buffer-create "*dsh-bridge-sessions*")
      (dsh-bridge-sessions-mode)
      (setq tabulated-list-format (dsh-bridge--sessions-format))
      (setq tabulated-list-sort-key '("Age" . t))
      (setq tabulated-list-entries (dsh-bridge--sessions-entries))
      (tabulated-list-init-header)
      (tabulated-list-print t)
      (should (string-match-p "●" (buffer-string)))
      (dsh-bridge--status-set "s1" 'running)
      (dsh-bridge--status-reprint-row "s1")
      (should (string-match-p "■" (buffer-string)))
      (should-not (string-match-p "●" (buffer-string))))
    (kill-buffer "*dsh-bridge-sessions*")))

(ert-deftest dsh-bridge-view-next-reply-at-newest-enters-follow ()
  "M-n at the newest turn enters turn-following state (acting like \"turn 0\"),
even when newer turns have arrived mid-walk, and announces it."
  (let* ((newest-open (dsh-bridge-test--view-turn 40 4000000
                       (list (dsh-bridge-test--view-segment "newest2" 4001000 1))))
         (turns (cons newest-open dsh-bridge-test--view-turns))
         (dsh-bridge--turns-cache (list (cons "s1" turns)))
         (msg nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((inhibit-read-only t))
        (insert (dsh-bridge--view-turn-render newest-open))
        (setq-local dsh-bridge--view-turn (alist-get 'turn newest-open)))
      (setq-local dsh-bridge--view-turn-index 0)
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest args) (setq msg (apply #'format args))))
                ((symbol-function 'dsh-bridge--request)
                 (lambda (_method _path _payload)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'turns turns))))))
        (dsh-bridge-view-next-reply))
      (should (equal (buffer-string) (dsh-bridge--view-turn-render newest-open)))
      (should (eq dsh-bridge--view-follow t))
      (should (null dsh-bridge--view-turn-index))
      (should (string-match-p "following the newest turn" msg)))))

(ert-deftest dsh-bridge-view-turns-cache-refresh-recomputes-index ()
  "A turn-cache refresh recomputes a cycling view's index from the shown turn's
number, so the `(k/n)' counter stays honest when newer turns arrive."
  (let* ((newest-open (dsh-bridge-test--view-turn 40 4000000
                       (list (dsh-bridge-test--view-segment "newest2" 4001000 1))))
         (new-turns (cons newest-open dsh-bridge-test--view-turns))
         (dsh-bridge--turns-cache (list (cons "s1" dsh-bridge-test--view-turns))))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (cons 200 (list (cons 'sessionId "s1")
                                 (cons 'turns new-turns))))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        ;; Cycling on turn 20, at index 1 of the 3-turn list.
        (setq-local dsh-bridge--view-turn 20)
        (setq-local dsh-bridge--view-turn-index 1)
        (dsh-bridge--view-turns-cache-refresh "s1")
        (should (equal (cdr (assoc "s1" dsh-bridge--turns-cache)) new-turns))
        ;; Turn 20 now sits at index 2 in the refreshed list.
        (should (eq dsh-bridge--view-turn-index 2)))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-turns-cache-refresh-vanished-turn-rests ()
  "When the shown turn vanished from the refreshed list (a compaction replaced
it), a cycling view drops its index to at-rest rather than pointing at an
unrelated turn; the buffer text is untouched."
  (let ((new-turns (list (nth 0 dsh-bridge-test--view-turns)
                         (nth 2 dsh-bridge-test--view-turns)))
        (dsh-bridge--turns-cache (list (cons "s1" dsh-bridge-test--view-turns))))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (cons 200 (list (cons 'sessionId "s1")
                                 (cons 'turns new-turns))))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        (let ((inhibit-read-only t)) (insert "browsing turn 20"))
        (setq-local dsh-bridge--view-turn 20)
        (setq-local dsh-bridge--view-turn-index 1)
        (dsh-bridge--view-turns-cache-refresh "s1")
        (should (equal (cdr (assoc "s1" dsh-bridge--turns-cache)) new-turns))
        (should (null dsh-bridge--view-turn-index))
        (should (equal (buffer-string) "browsing turn 20")))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-turns-cache-refresh-empty-list-clears ()
  "A `/turns' response with an explicit empty turn list replaces the cached
entry (the session genuinely has no turns, e.g. after a full compaction); a
response without a `turns' field (an error body) leaves the cache alone."
  (let ((dsh-bridge--turns-cache (list (cons "s1" dsh-bridge-test--view-turns))))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (cons 200 (list (cons 'sessionId "s1") (cons 'turns nil))))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        (setq-local dsh-bridge--view-turn 20)
        (setq-local dsh-bridge--view-turn-index 1)
        (dsh-bridge--view-turns-cache-refresh "s1")
        ;; The entry survives as empty, and the cycling view rests.
        (should (assoc "s1" dsh-bridge--turns-cache))
        (should (null (cdr (assoc "s1" dsh-bridge--turns-cache))))
        (should (null dsh-bridge--view-turn-index)))
      (kill-buffer "*dsh-bridge-output*")))
  (let ((dsh-bridge--turns-cache (list (cons "s1" dsh-bridge-test--view-turns))))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (cons 404 (list (cons 'error "unknown session"))))))
      (should (null (dsh-bridge--turns-cache-fetch "s1"))))
    (should (equal (cdr (assoc "s1" dsh-bridge--turns-cache))
                   dsh-bridge-test--view-turns))))

(ert-deftest dsh-bridge-view-next-reply-from-rest-steps-to-newer ()
  "M-n at rest refreshes the turn list and steps to a newer turn when one has
arrived (new turns land at the head)."
  (let* ((newest-open (dsh-bridge-test--view-turn 40 4000000
                       (list (dsh-bridge-test--view-segment "brand-new" 4001000 1))))
         (new-turns (cons newest-open dsh-bridge-test--view-turns))
         (stale-turns (list (nth 0 dsh-bridge-test--view-turns)
                            (nth 1 dsh-bridge-test--view-turns)))
         (shown (nth 0 dsh-bridge-test--view-turns))
         (dsh-bridge--turns-cache (list (cons "s1" stale-turns))))
    (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (dsh-bridge--view-turn-render shown))
        (setq-local dsh-bridge--view-turn (alist-get 'turn shown)))
      (setq-local dsh-bridge--view-turn-index nil)
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (_method _path _payload)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'turns new-turns))))))
        (dsh-bridge--view-newer-turn-from-rest))
      (should (equal (buffer-string) (dsh-bridge--view-turn-render newest-open)))
      ;; The shown turn is the new newest: its index is 0.
      (should (eq dsh-bridge--view-turn-index 0)))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-view-next-reply-from-rest-at-newest ()
  "M-n at rest when the shown turn is still the newest enters turn-following
state (\"turn 0\") and announces it."
  (let* ((newest (nth 0 dsh-bridge-test--view-turns))
         (dsh-bridge--turns-cache (list (cons "s1" dsh-bridge-test--view-turns)))
         (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (cons 200 (list (cons 'sessionId "s1")
                                 (cons 'turns dsh-bridge-test--view-turns)))))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (dsh-bridge--view-turn-render newest))
          (setq-local dsh-bridge--view-turn (alist-get 'turn newest)))
        (setq-local dsh-bridge--view-turn-index nil)
        (dsh-bridge--view-newer-turn-from-rest)
        (should (equal (buffer-string) (dsh-bridge--view-turn-render newest)))
        (should (eq dsh-bridge--view-follow t))
        (should (null dsh-bridge--view-turn-index))
        (should (string-match-p "following the newest turn" msg)))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-next-reply-from-rest-not-found ()
  "M-n at rest reports no newer turns when the shown content has no turn
identity (e.g. a pushed message that is not a committed turn segment), and
leaves the buffer and index untouched."
  (let ((dsh-bridge--turns-cache (list (cons "s1" dsh-bridge-test--view-turns)))
        (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (cons 200 (list (cons 'sessionId "s1")
                                 (cons 'turns dsh-bridge-test--view-turns)))))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        (let ((inhibit-read-only t)) (erase-buffer) (insert "a pushed message"))
        (setq-local dsh-bridge--view-turn nil)
        (setq-local dsh-bridge--view-turn-index nil)
        (dsh-bridge--view-newer-turn-from-rest)
        (should (equal (buffer-string) "a pushed message"))
        (should (null dsh-bridge--view-turn-index))
        (should (string-match-p "no newer turns" msg)))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-prompt-history-position ()
  "The prompt-history position is newest-first (k/n), absent at rest."
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (setq-local dsh-bridge--prompt-session "s1")
    (setq dsh-bridge--prompt-history '(("s1" "new" "mid" "old")))
    (setq-local dsh-bridge--prompt-history-index nil)
    (should (equal (dsh-bridge--prompt-history-position) ""))
    (setq-local dsh-bridge--prompt-history-index 0)
    (should (equal (dsh-bridge--prompt-history-position) " (1/3)"))
    (setq-local dsh-bridge--prompt-history-index 2)
    (should (equal (dsh-bridge--prompt-history-position) " (3/3)"))))

(ert-deftest dsh-bridge-session-update-last-active ()
  "A turn frame's `time' folds into the session cache's `lastActive'; a missing
time is a no-op and an unknown id is ignored."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (lastActive . 1) (live . t)))))
    (dsh-bridge--session-update-last-active "s1" 99)
    (should (equal (alist-get 'lastActive (dsh-bridge--session-for-id "s1")) 99))
    (dsh-bridge--session-update-last-active "s1" nil)
    (should (equal (alist-get 'lastActive (dsh-bridge--session-for-id "s1")) 99))
    (dsh-bridge--session-update-last-active "s2" 5)
    (should (null (dsh-bridge--session-for-id "s2")))))

(ert-deftest dsh-bridge-view-displayed-sessions-row-not ()
  "Point on a row in the DSH-Sessions list is NOT \"looking\": a tabulated-list
buffer is a navigation surface, and cursor position must not redirect the
turn-boundary messages."
  (when (get-buffer "*dsh-bridge-output*") (kill-buffer "*dsh-bridge-output*"))
  (when (get-buffer "*dsh-bridge-prompt*") (kill-buffer "*dsh-bridge-prompt*"))
  (with-current-buffer (get-buffer-create "*dsh-bridge-sessions*")
    (dsh-bridge-sessions-mode)
    (let ((inhibit-read-only t))
      (insert (propertize "s1 row" 'tabulated-list-id "s1")))
    (goto-char (point-min))
    (should-not (dsh-bridge--view-displayed-p "s1"))
    (should-not (dsh-bridge--view-displayed-p "s2")))
  (kill-buffer "*dsh-bridge-sessions*"))

(ert-deftest dsh-bridge-view-displayed-p-visible-window ()
  "A DSH-View shows a session on-screen only when the buffer is displayed in a
window; a hidden view showing the session does not count as \"looking\"."
  (when (get-buffer "*dsh-bridge-output*") (kill-buffer "*dsh-bridge-output*"))
  (when (get-buffer "*dsh-bridge-prompt*") (kill-buffer "*dsh-bridge-prompt*"))
  (when (get-buffer "*dsh-bridge-sessions*") (kill-buffer "*dsh-bridge-sessions*"))
  (let ((window (selected-window))
        (previous (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
          (dsh-bridge-view-mode)
          (setq-local dsh-bridge--view-content-session "s1")
          ;; Hidden (not in a window): not looking.
          (should-not (dsh-bridge--view-displayed-p "s1"))
          ;; Displayed in the selected window: looking.
          (set-window-buffer window (current-buffer))
          (should (dsh-bridge--view-displayed-p "s1"))
          (should-not (dsh-bridge--view-displayed-p "s2")))
      (set-window-buffer window previous)
      (kill-buffer "*dsh-bridge-output*"))))

;;; Live turn feedback: turn-following state, elapsed ticker, boundary echo,
;;; blank-on-send, and the follow auto-refill.

(ert-deftest dsh-bridge-view-follow-enter ()
  "Turn-following shows the newest turn (resetting any mid-browse index) and
declares itself following (so the follow helper sees it)."
  (let* ((newest (nth 0 dsh-bridge-test--view-turns))
         (dsh-bridge--turns-cache (list (cons "s1" dsh-bridge-test--view-turns)))
         (dsh-bridge--session-status nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_m _p _pl)
                 (cons 200 (list (cons 'sessionId "s1")
                                 (cons 'turns dsh-bridge-test--view-turns))))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        (setq-local dsh-bridge--view-turn-index 1)
        (dsh-bridge--view-follow-enter)
        (should (eq dsh-bridge--view-follow t))
        (should (null dsh-bridge--view-turn-index))
        (should (equal (buffer-string) (dsh-bridge--view-turn-render newest)))))
    (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-follow-navigation-interactions ()
  "M-p leaves turn-following (stepping older); M-n while following is a no-op."
  (let* ((newest (nth 0 dsh-bridge-test--view-turns))
         (middle (nth 1 dsh-bridge-test--view-turns))
         (dsh-bridge--turns-cache (list (cons "s1" dsh-bridge-test--view-turns)))
         (dsh-bridge--session-status nil)
         (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_m _p _pl)
                 (cons 200 (list (cons 'sessionId "s1")
                                 (cons 'turns dsh-bridge-test--view-turns)))))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        (setq-local dsh-bridge--view-follow t)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (dsh-bridge--view-turn-render newest))
          (setq-local dsh-bridge--view-turn (alist-get 'turn newest)))
        ;; M-n while following is a no-op.
        (dsh-bridge-view-next-reply)
        (should (eq dsh-bridge--view-follow t))
        (should (string-match-p "already following" msg))
        ;; M-p leaves follow and steps one older.
        (dsh-bridge-view-previous-reply)
        (should-not dsh-bridge--view-follow)
        (should (equal (buffer-string) (dsh-bridge--view-turn-render middle)))))
    (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-elapsed-label ()
  "The elapsed segment renders only for a running session with a known
turn-start time; it degrades to nil on a mid-turn attach (no t0), when idle, or
when the ticker is disabled."
  ;; Running with a recorded start time ~now => ~00:00.
  (let ((dsh-bridge--session-status nil))
    (let ((dsh-bridge--session-status `(("s1" running . ,(* 1000 (float-time))))))
      (should (string-match-p "⏱ 00:0[01]"
                              (dsh-bridge--view-elapsed-label "s1"))))
    ;; Running but no turn-start frame (mid-turn attach): start time nil.
    (let ((dsh-bridge--session-status '(("s1" running))))
      (should (null (dsh-bridge--view-elapsed-label "s1"))))
    ;; Idle: omitted.
    (let ((dsh-bridge--session-status '(("s1" idle . nil))))
      (should (null (dsh-bridge--view-elapsed-label "s1"))))
    ;; Disabled ticker: omitted even while running.
    (let ((dsh-bridge--session-status `(("s1" running . ,(* 1000 (float-time)))))
          (dsh-bridge-view-elapsed-ticker nil))
      (should (null (dsh-bridge--view-elapsed-label "s1"))))))

(ert-deftest dsh-bridge-turn-boundary-echo ()
  "Turn boundaries echo for the session the user is looking at: 'is thinking…'
on turn-start, and the reason phrase on turn-complete."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (dsh-bridge-turn-boundary-echo t)
        (dsh-bridge-turn-complete 'refetch)
        (msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args))))
              ((symbol-function 'dsh-bridge--view-displayed-p) (lambda (_id) t))
              ((symbol-function 'dsh-bridge--status-event-render) #'ignore)
              ((symbol-function 'dsh-bridge--models-event-refresh) #'ignore)
              ((symbol-function 'run-at-time) (lambda (&rest _)))
              ((symbol-function 'dsh-bridge--view-turns-cache-refresh) #'ignore)
              ((symbol-function 'dsh-bridge--session-view) (lambda (_id) nil)))
      (dsh-bridge--notification-handle-events
       '(((kind . "turn-start") (sessionId . "s1") (time . 1))))
      (should (string-match-p "is thinking…" msg))
      (setq msg nil)
      (dsh-bridge--notification-handle-events
       '(((kind . "turn-complete") (sessionId . "s1") (reason . "completed"))))
      (should (string-match-p "T" msg))
      (should (string-match-p "finished" msg)))))

(ert-deftest dsh-bridge-send-text-optimistic-running ()
  "A successful send marks the session running before any SSE turn-start frame,
re-renders the surfaces, and announces it."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (msg nil)
        (rendered nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_m _p _pl cb) (funcall cb nil "{\"sessionId\":\"s1\"}" 200)))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args))))
              ((symbol-function 'dsh-bridge--status-event-render)
               (lambda (id) (push id rendered)))
              ((symbol-function 'dsh-bridge--prompt-history-record-send) #'ignore))
      (dsh-bridge-send-text "hello" "s1"))
    (should (eq (dsh-bridge--status-state "s1") 'running))
    (should (equal rendered '("s1")))
    (should (string-match-p "thinking…" msg))))

(ert-deftest dsh-bridge-prompt-blank ()
  "`dsh-bridge--prompt-blank' clears the prompt buffer and resets its navigation,
so the next reply starts blank (the sent text remains in history)."
  (with-current-buffer (get-buffer-create "*dsh-bridge-prompt*")
    (dsh-bridge-prompt-mode)
    (let ((inhibit-read-only t)) (insert "old prompt"))
    (setq-local dsh-bridge--prompt-history-index 1)
    (setq-local dsh-bridge--prompt-draft "draft")
    (dsh-bridge--prompt-blank)
    (should (equal (buffer-string) ""))
    (should (null dsh-bridge--prompt-history-index))
    (should (null dsh-bridge--prompt-draft))
    (should-not (buffer-modified-p)))
  (kill-buffer "*dsh-bridge-prompt*"))

(ert-deftest dsh-bridge-prompt-buffer-confirms-before-erasing ()
  "Preparing a prompt buffer asks before erasing modified text, and
silently erases unmodified text (e.g. kept from a previous send)."
  (when (get-buffer "*dsh-bridge-prompt*")
    (kill-buffer "*dsh-bridge-prompt*"))
  (cl-letf (((symbol-function 'dsh-bridge--refresh-prompt-metadata) #'ignore))
    (with-current-buffer (dsh-bridge--prompt-buffer "s1")
      (insert "unsent text"))
    ;; Answering "no" keeps the modified text.
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (dsh-bridge--prompt-buffer "s1"))
    (with-current-buffer "*dsh-bridge-prompt*"
      (should (equal (buffer-string) "unsent text")))
    ;; Answering "yes" erases it.
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (dsh-bridge--prompt-buffer "s1"))
    (with-current-buffer "*dsh-bridge-prompt*"
      (should (equal (buffer-string) "")))
    ;; Unmodified text is erased without asking.
    (with-current-buffer "*dsh-bridge-prompt*"
      (insert "kept from a previous send")
      (set-buffer-modified-p nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_) (error "should not ask"))))
      (dsh-bridge--prompt-buffer "s1"))
    (with-current-buffer "*dsh-bridge-prompt*"
      (should (equal (buffer-string) ""))))
  (kill-buffer "*dsh-bridge-prompt*"))

(ert-deftest dsh-bridge-prompt-buffer-reuses-renamed-buffer ()
  "A renamed DSH-Prompt buffer bound to the session is reused, not replaced."
  (when (get-buffer "*dsh-bridge-prompt*")
    (kill-buffer "*dsh-bridge-prompt*"))
  (with-current-buffer (get-buffer-create "*dsh-bridge-prompt*")
    (dsh-bridge-prompt-mode)
    (setq-local dsh-bridge--prompt-session "s1")
    (rename-buffer "prompt-s1" t))
  (cl-letf (((symbol-function 'dsh-bridge--refresh-prompt-metadata) #'ignore))
    (should (eq (dsh-bridge--prompt-buffer "s1") (get-buffer "prompt-s1")))
    ;; A different session does not reuse it; it gets the canonical buffer.
    (should (eq (dsh-bridge--prompt-buffer "s2")
                (get-buffer "*dsh-bridge-prompt*"))))
  (kill-buffer "prompt-s1")
  (kill-buffer "*dsh-bridge-prompt*"))

(ert-deftest dsh-bridge-prompt-binds-effective-session ()
  "`dsh-bridge-prompt' prepares the prompt buffer for the current buffer's
effective session (the dispatcher's `r' continues the shown conversation)."
  (let ((dsh-bridge-default-session "target")
        (got nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "shown")
      (cl-letf (((symbol-function 'dsh-bridge--prompt-buffer)
                 (lambda (id) (setq got id)
                         (get-buffer-create "*dsh-bridge-prompt*")))
                ((symbol-function 'pop-to-buffer) #'ignore))
        (dsh-bridge-prompt)))
    (should (equal got "shown"))
    (kill-buffer "*dsh-bridge-prompt*")))

(ert-deftest dsh-bridge-replies-changed-refills-following ()
  "A replies-changed frame appends the new segment to the shown turn of every
turn-following view; the frame runs one turn-cache refresh (one `/turns'
round-trip) and no per-view request."
  (let* ((before (dsh-bridge-test--view-turn 7 7000000
                  (list (dsh-bridge-test--view-segment "old" 7001000 1))))
         (after (dsh-bridge-test--view-turn 7 7000000
                 (list (dsh-bridge-test--view-segment "old" 7001000 1)
                       (dsh-bridge-test--view-segment "new" 7002000 2))))
         (requests 0))
    (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (setq-local dsh-bridge--view-follow t)
      (dsh-bridge--view-fill "s1" before nil nil t))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_t _r fn &rest args) (apply fn args)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (method path _payload)
                 (setq requests (1+ requests))
                 (should (equal method "GET"))
                 (should (equal path "/turns?sessionId=s1"))
                 (cons 200 (list (cons 'sessionId "s1")
                                 (cons 'turns (list after)))))))
      (dsh-bridge--notification-handle-events
       '(((kind . "replies-changed") (sessionId . "s1"))))
      (should (= requests 1))
      (with-current-buffer "*dsh-bridge-output*"
        (should (equal (buffer-string) (dsh-bridge--view-turn-render after)))))))

(ert-deftest dsh-bridge-replies-changed-refills-all-following-views ()
  "Every DSH-View buffer following the session is refilled, not just one; a
non-following view of the same session is left alone.  The frame fetches the
turn list once for all views (the shared cache refresh), never once per
following view."
  (let* ((before (dsh-bridge-test--view-turn 7 7000000
                  (list (dsh-bridge-test--view-segment "old" 7001000 1))))
         (after (dsh-bridge-test--view-turn 7 7000000
                 (list (dsh-bridge-test--view-segment "old" 7001000 1)
                       (dsh-bridge-test--view-segment "new" 7002000 2))))
         (requests 0))
    (dolist (buf (list "*dsh-bridge-output*" "*dsh-bridge-output-2*"))
      (with-current-buffer (get-buffer-create buf)
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        (setq-local dsh-bridge--view-follow t)
        (dsh-bridge--view-fill "s1" before nil nil t)))
    (with-current-buffer (get-buffer-create "*dsh-bridge-output-3*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((inhibit-read-only t)) (erase-buffer) (insert "browsing")))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_t _r fn &rest args) (apply fn args)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (setq requests (1+ requests))
                 (cons 200 (list (cons 'sessionId "s1")
                                 (cons 'turns (list after)))))))
      (dsh-bridge--notification-handle-events
       '(((kind . "replies-changed") (sessionId . "s1"))))
      (should (= requests 1))
      (with-current-buffer "*dsh-bridge-output*"
        (should (equal (buffer-string) (dsh-bridge--view-turn-render after))))
      (with-current-buffer "*dsh-bridge-output-2*"
        (should (equal (buffer-string) (dsh-bridge--view-turn-render after))))
      (with-current-buffer "*dsh-bridge-output-3*"
        (should (equal (buffer-string) "browsing"))))
    (dolist (b '("*dsh-bridge-output*" "*dsh-bridge-output-2*"
                 "*dsh-bridge-output-3*"))
      (when (buffer-live-p (get-buffer b))
        (kill-buffer b)))))

(ert-deftest dsh-bridge-turn-complete-refetch-one-fetch ()
  "The deferred turn-complete refetch fills every shown, non-cycling view
with the completed turn — appending its closing divider — fetching `/turns'
once for all of them."
  (let ((dsh-bridge--session-status nil)
        (fetches 0))
    (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((inhibit-read-only t)) (erase-buffer) (insert "old-1")))
    (with-current-buffer (get-buffer-create "*dsh-bridge-output-2*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (setq-local dsh-bridge--view-follow t)
      (let ((inhibit-read-only t)) (erase-buffer) (insert "old-2")))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (setq fetches (1+ fetches))
                 (funcall callback nil
                          (concat "{\"sessionId\":\"s1\",\"turns\":["
                                  "{\"turn\":7,\"startedAt\":7000000,"
                                  "\"endedAt\":7003000,\"reason\":\"completed\","
                                  "\"segments\":[{\"text\":\"new\","
                                  "\"time\":7001000,\"step\":1}]}]}")
                          200)))
              ((symbol-function 'dsh-bridge--status-set) #'ignore)
              ((symbol-function 'dsh-bridge--apply-session-directory) #'ignore))
      (dsh-bridge--turn-complete-refetch "s1")
      (should (= fetches 1))
      (dolist (b '("*dsh-bridge-output*" "*dsh-bridge-output-2*"))
        (with-current-buffer b
          ;; The completed turn renders with its closing elapsed divider.
          (should (equal (buffer-string) "new\n\n---\n\n(3s elapsed)")))))
    (dolist (b '("*dsh-bridge-output*" "*dsh-bridge-output-2*"))
      (when (buffer-live-p (get-buffer b))
        (kill-buffer b)))))

(ert-deftest dsh-bridge-view-ticker-survives-view-kill ()
  "Killing one ticking DSH-View keeps the shared elapsed ticker running for
the surviving views (the kill hook re-evaluates the ticker after the dying
buffer is gone); killing the last ticking view cancels the timer."
  (let ((dsh-bridge--session-status '(("s1" running . 1000)))
        (dsh-bridge--view-ticker-timer nil)
        (w2 (split-window))
        (w1 (selected-window)))
    (cl-letf (((symbol-function 'dsh-bridge--view-turns-refresh) #'ignore)
              ((symbol-function 'dsh-bridge--apply-session-directory) #'ignore))
      ;; Real `dsh-bridge--view-fill' wiring: mode, state, and the local
      ;; kill hook that re-evaluates the shared ticker.
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge--view-fill "s1" "tick-1" nil)
        (set-window-buffer w1 (current-buffer)))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output-2*")
        (dsh-bridge--view-fill "s1" "tick-2" nil)
        (set-window-buffer w2 (current-buffer))))
    (unwind-protect
        (progn
          (dsh-bridge--view-ticker-ensure)
          (should (timerp dsh-bridge--view-ticker-timer))
          ;; Kill one view; the deferred re-evaluation (simulated by
          ;; draining the queue only after the buffer is dead) must keep
          ;; the ticker for the survivor.
          (let ((pending nil))
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (_t _r fn &rest args)
                         (push (lambda () (apply fn args)) pending))))
              (kill-buffer "*dsh-bridge-output-2*")
              (dolist (fn (nreverse pending)) (funcall fn))))
          (should (timerp dsh-bridge--view-ticker-timer))
          ;; Kill the last view; the deferred re-evaluation cancels.
          (let ((pending nil))
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (_t _r fn &rest args)
                         (push (lambda () (apply fn args)) pending))))
              (kill-buffer "*dsh-bridge-output*")
              (dolist (fn (nreverse pending)) (funcall fn))))
          (should-not (timerp dsh-bridge--view-ticker-timer)))
      (when (timerp dsh-bridge--view-ticker-timer)
        (cancel-timer dsh-bridge--view-ticker-timer))
      (dolist (b '("*dsh-bridge-output*" "*dsh-bridge-output-2*"))
        (when (buffer-live-p (get-buffer b))
          (kill-buffer b)))
      (when (window-live-p w2)
        (delete-window w2)))))

;;; Ask-user questions: registry, awaiting glyph, and the question buffer.

(ert-deftest dsh-bridge-ask-user-arrive-and-glyph ()
  "An ask-user frame records a pending question, lights the awaiting glyph, and
spells out 'awaiting your answer' in the shown view header.  A repeat frame
for the same question id (the plugin's reconnect replay) refreshes the stored
copy silently instead of duplicating the registry entry."
  (let ((dsh-bridge--pending-questions nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (messages 0))
    (cl-letf (((symbol-function 'message) (lambda (&rest _) (cl-incf messages)))
              ((symbol-function 'dsh-bridge--status-event-render) #'ignore))
      (dsh-bridge--ask-user-arrive "s1" "q1" '(( (id . "q1") (question . "Go?") )))
      (dsh-bridge--ask-user-arrive "s1" "q1" '(( (id . "q1") (question . "Go? v2") ))))
    (should (equal messages 1))
    (should (equal (length (cdr (assoc "s1" dsh-bridge--pending-questions))) 1))
    (should (dsh-bridge--session-awaiting-p "s1"))
    (let ((dsh-bridge-status-indicator 'emoji))
      (should (string= (dsh-bridge--status-glyph "s1") "⏳")))
    (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (should (string-match-p "awaiting your answer" (dsh-bridge--view-header-line))))
    (dsh-bridge--ask-user-session-clear "s1")
    (should-not (dsh-bridge--session-awaiting-p "s1"))
    ;; The defensive clear also banners the live question buffer.
    (with-current-buffer (dsh-bridge--question-find-buffer "q1")
      (should dsh-bridge--question-dead)
      (should (string-match-p "cancelled" (buffer-string))))
    (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
      (kill-buffer "*dsh-bridge-output*"))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))))

(ert-deftest dsh-bridge-ask-user-resolved ()
  "A resolved frame retires the pending question and banners the question buffer."
  (let ((dsh-bridge--pending-questions nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    (cl-letf (((symbol-function 'message) (lambda (&rest _) nil))
              ((symbol-function 'dsh-bridge--status-event-render) #'ignore))
      (dsh-bridge--ask-user-arrive "s1" "q1" '(( (id . "q1") (question . "Go?") )))
      (dsh-bridge--ask-user-resolved "s1" "q1" "answered"))
    (should-not (dsh-bridge--session-awaiting-p "s1"))
    (with-current-buffer (get-buffer "*dsh-bridge-question: T*")
      (should dsh-bridge--question-dead)
      (should (string-match-p "answered elsewhere" (buffer-string))))
    (when (buffer-live-p (get-buffer "*dsh-bridge-question: T*"))
      (kill-buffer "*dsh-bridge-question: T*"))))

(ert-deftest dsh-bridge-question-toggle-radio ()
  "Option marking is radio behavior for single-select questions, and reopening
the buffer for the same question keeps the marks (bury-then-return flow)."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (questions '(( (id . "q1") (question . "Go?")
                       (options . (((label . "Yes")) ((label . "No")))) )))
        (buffer nil))
    (setq buffer (dsh-bridge--question-buffer "s1" "q1" questions))
    (with-current-buffer buffer
      (goto-char (point-min))
      (re-search-forward "1\\. Yes")
      (goto-char (line-beginning-position))
      (dsh-bridge--question-toggle-at-point)
      (should (equal (cdr (assoc "q1" dsh-bridge--question-selection)) '("Yes")))
      (re-search-forward "2\\. No")
      (goto-char (line-beginning-position))
      (dsh-bridge--question-toggle-at-point)
      (should (equal (cdr (assoc "q1" dsh-bridge--question-selection)) '("No")))
      ;; A digit key toggles the nth option of the block at point (batch mode
      ;; cannot drive key macros, so the command's key lookup is mocked).
      (cl-letf (((symbol-function 'this-command-keys) (lambda () "1")))
        (dsh-bridge--question-toggle-number))
      (should (equal (cdr (assoc "q1" dsh-bridge--question-selection)) '("Yes"))))
    ;; Reopening via `a' finds the same buffer without wiping the marks.
    (should (eq (dsh-bridge--question-buffer "s1" "q1" questions) buffer))
    (with-current-buffer buffer
      (should (equal (cdr (assoc "q1" dsh-bridge--question-selection)) '("Yes")))
      (should (string-match-p "\\[x\\] 1\\. Yes" (buffer-string))))
    (kill-buffer buffer)))

(ert-deftest dsh-bridge-question-validate-and-submit ()
  "Submission POSTs alist-shaped answers to /dsh-bridge/answer — the wire shape
the apiproxy validates (regression: plist-style lists encode as junk JSON)."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (posted nil))
    (with-current-buffer
        (dsh-bridge--question-buffer "s1" "q1"
          '(( (id . "q1") (question . "Go?") (options . (((label . "Yes")) ((label . "No")))) )))
      (goto-char (point-min))
      (re-search-forward "1\\. Yes")
      (goto-char (line-beginning-position))
      (dsh-bridge--question-toggle-at-point)
      (should (equal (dsh-bridge--question-validate)
                     (list (list (cons 'id "q1") (cons 'selected (vector "Yes"))))))
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_m _p payload cb)
                   (setq posted payload)
                   (funcall cb nil "{\"accepted\":true}" 200))))
        (dsh-bridge--question-submit))
      (should (equal (alist-get 'questionId posted) "q1"))
      (should (equal (alist-get 'sessionId posted) "s1"))
      (should (equal (json-encode (list (cons 'answers (alist-get 'answers posted))))
                     "{\"answers\":[{\"id\":\"q1\",\"selected\":[\"Yes\"]}]}"))
      ;; An accepted submit retires the buffer.
      (should dsh-bridge--question-dead)
      (should (string-match-p "answered elsewhere" (buffer-string))))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))))

(ert-deftest dsh-bridge-question-custom-wire-shape ()
  "A single-select custom answer travels with an empty `selected' array and a
`custom' string; a multi-select custom answer may accompany marked options —
the two shapes the apiproxy's `matchesQuestions' accepts."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    ;; Single-select: a custom answer supersedes the marks.
    (with-current-buffer
        (dsh-bridge--question-buffer "s1" "q1"
          '(( (id . "q1") (question . "Go?") (options . (((label . "Yes")) ((label . "No")))) )))
      (goto-char (point-min))
      (re-search-forward "c\\. Type a custom answer")
      (goto-char (line-beginning-position))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "because reasons")))
        (dsh-bridge--question-toggle-at-point))
      (should (equal (json-encode (list (cons 'answers (dsh-bridge--question-validate))))
                     "{\"answers\":[{\"id\":\"q1\",\"selected\":[],\"custom\":\"because reasons\"}]}")))
    ;; Multi-select: marks and custom travel together.
    (with-current-buffer
        (dsh-bridge--question-buffer "s1" "q2"
          '(( (id . "q2") (question . "Pick?") (multiSelect . t)
              (options . (((label . "A")) ((label . "B")))) )))
      (goto-char (point-min))
      (re-search-forward "1\\. A")
      (goto-char (line-beginning-position))
      (dsh-bridge--question-toggle-at-point)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "and C")))
        (dsh-bridge--question-custom-answer "q2"))
      (should (equal (json-encode (list (cons 'answers (dsh-bridge--question-validate))))
                     "{\"answers\":[{\"id\":\"q2\",\"selected\":[\"A\"],\"custom\":\"and C\"}]}")))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))
    (when (dsh-bridge--question-find-buffer "q2")
      (kill-buffer (dsh-bridge--question-find-buffer "q2")))))

(ert-deftest dsh-bridge-question-skip ()
  "Skipping settles a question with an empty selection and clears its marks;
unskipping leaves the question unsettled again."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    (with-current-buffer
        (dsh-bridge--question-buffer "s1" "q1"
          '(( (id . "q1") (question . "Go?") (options . (((label . "Yes")))) )))
      (goto-char (point-min))
      (re-search-forward "1\\. Yes")
      (goto-char (line-beginning-position))
      (dsh-bridge--question-toggle-at-point)
      (dsh-bridge--question-skip)
      (should (null (cdr (assoc "q1" dsh-bridge--question-selection))))
      (should (string-match-p "Question 1 of 1 — skipped" (buffer-string)))
      (should (equal (json-encode (list (cons 'answers (dsh-bridge--question-validate))))
                     "{\"answers\":[{\"id\":\"q1\",\"selected\":[]}]}"))
      (dsh-bridge--question-skip)
      (should (null (dsh-bridge--question-validate))))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))))

(ert-deftest dsh-bridge-question-renders-detail ()
  "A plan-review question's `detail' (the reviewed artifact) is rendered."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    (with-current-buffer
        (dsh-bridge--question-buffer "s1" "q1"
          '(( (id . "q1") (question . "Execute this plan?")
              (detail . "## Plan\n\n1. Do the thing")
              (intent . ((kind . "plan-review") (approve . "Approve")))
              (options . (((label . "Approve")) ((label . "Refuse")))) )))
      (should (string-match-p "## Plan" (buffer-string)))
      (should (string-match-p "1\\. Do the thing" (buffer-string))))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))))

(provide 'dsh-bridge-tests)
;;; dsh-bridge-tests.el ends here
