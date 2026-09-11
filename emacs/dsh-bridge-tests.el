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

;; The plugin install/uninstall code lives in the optional companion library;
;; load it so the plugin-management tests below can drive it.
(require 'dsh-bridge-install)

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
                 (cons 200
                       '(((id . "live-1") (live . t) (cwd . "/a"))
                         ((id . "saved-1") (live . nil) (cwd . "/b"))))))
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
  (let ((dsh-bridge--sessions-cache
         '(((id . "s1") (title . "T") (live . t) (running . t))))
        ;; The tracker outranks the row's `running' flag for a live session,
        ;; so the idle glyph below proves the tracker entry is consulted.
        (dsh-bridge--session-status '(("s1" idle)))
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

(ert-deftest dsh-bridge-send-text-missing-response-session ()
  "A response without a `sessionId' falls back to the requested target; with
neither, the send is still reported but no session state is touched."
  ;; Explicit target: the fallback keeps the normal bookkeeping.
  (let ((dsh-bridge-default-session "s1")
        (dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (dsh-bridge--prompt-history nil)
        (dsh-bridge--last-sent nil)
        (sent 'uncalled)
        (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil "{\"ok\":true}" 200)))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge-send-text "hello" nil (lambda (id) (setq sent id))))
    (should (equal sent "s1"))
    (should (eq (dsh-bridge--status-state "s1") 'running))
    (should (string-match-p "prompt sent" msg)))
  ;; No target at all: the host named no session, so nothing is tracked or
  ;; rendered, but the prompt is still reported as sent.
  (let ((dsh-bridge-default-session nil)
        (dsh-bridge--session-status nil)
        (sent 'uncalled)
        (msg nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil "{\"ok\":true}" 200)))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge-send-text "hello" nil (lambda (id) (setq sent id))))
    (should (null sent))
    (should (null dsh-bridge--session-status))
    (should (string-match-p "no session" msg))))

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
                 (lambda () (cons 200 '(((id . "live-1") (live . t))))))
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
                                  "{\"turn\":2,\"startedAt\":1000,\"endedAt\":2000,\"reason\":\"completed\",\"segments\":["
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
                                  "{\"turn\":3,\"startedAt\":1000,\"endedAt\":2000,\"reason\":\"completed\",\"segments\":["
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

(ert-deftest dsh-bridge-fetch-running-turn-follows ()
  "A fetch whose newest turn is still running turns on following: the view
then grows in place as further segments commit."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          (concat "{\"sessionId\":\"s1\",\"running\":true,\"turns\":["
                                  "{\"turn\":5,\"startedAt\":1000,\"segments\":["
                                  "{\"text\":\"partial reply\",\"time\":1000000,\"step\":1}]}]}")
                          200)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons nil nil))))
      (dsh-bridge-fetch))
    (let ((buf (get-buffer "*dsh-bridge-output*")))
      (should buf)
      (with-current-buffer buf
        (should (equal dsh-bridge--view-content-session "s1"))
        (should (equal dsh-bridge--view-turn 5))
        (should (eq dsh-bridge--view-follow t))
        (should (null dsh-bridge--view-turn-index))
        (should (string-prefix-p "partial reply" (buffer-string)))
        (should (string-match-p "latest" (format "%s" header-line-format)))))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-fetch-idle-turn-stays-snapshot ()
  "A fetch of a completed (idle) newest turn does not turn on following."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          (concat "{\"sessionId\":\"s1\",\"running\":false,\"turns\":["
                                  "{\"turn\":5,\"startedAt\":1000,\"endedAt\":2000,\"reason\":\"completed\",\"segments\":["
                                  "{\"text\":\"final reply\",\"time\":1000000,\"step\":1}]}]}")
                          200)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons nil nil))))
      (dsh-bridge-fetch))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal (buffer-string) "final reply"))
      (should (null dsh-bridge--view-follow)))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-fetch-caches-whole-turn-list ()
  "A fetch records the response's whole `turns' array (newest first) as the
cache entry, including the shown newest turn, so the position count and
later incremental requests see every turn."
  (let ((dsh-bridge-default-session "s1")
        (dsh-bridge--turns-cache nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          (concat "{\"sessionId\":\"s1\",\"running\":false,\"turns\":["
                                  "{\"turn\":3,\"startedAt\":1000,\"endedAt\":2000,\"reason\":\"completed\",\"segments\":["
                                  "{\"text\":\"newest\",\"time\":1000000,\"step\":1}]},"
                                  "{\"turn\":2,\"startedAt\":900,\"endedAt\":1900,\"reason\":\"completed\",\"segments\":["
                                  "{\"text\":\"older\",\"time\":900000,\"step\":1}]}]}")
                          200)))
              ((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons nil nil))))
      (dsh-bridge-fetch))
    (let ((cached (dsh-bridge--turns-cache-turns "s1")))
      (should (= (length cached) 2))
      (should (equal (alist-get 'turn (car cached)) 3))
      (should (equal (alist-get 'turn (cadr cached)) 2)))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-fetch-last-resolved-recording ()
  "A nil-target fetch records the host-resolved session for display; an
explicit target is not the host's resolution, so nothing is recorded."
  (dolist (case (list (cons nil t) (cons "s1" nil)))
    (let ((dsh-bridge-default-session (car case))
          (dsh-bridge--last-resolved-active nil))
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_method _path _payload callback)
                   (funcall callback nil
                            "{\"sessionId\":\"s1\",\"title\":\"T\",\"turns\":[]}"
                            200)))
                ((symbol-function 'dsh-bridge--request)
                 (lambda (&rest _) (cons nil nil))))
        (dsh-bridge-fetch))
      (if (cdr case)
          (should (equal dsh-bridge--last-resolved-active '("s1" . "T")))
        (should (null dsh-bridge--last-resolved-active)))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-fetch-missing-session-id-signals ()
  "A `/turns' response without a sessionId is a protocol error: the view is
not opened and no guessed target is used."
  (let ((dsh-bridge-default-session "s1"))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil "{\"turns\":[]}" 200))))
      (should-error (dsh-bridge-fetch) :type 'error))))

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
                                  "\"turns\":[{\"turn\":2,\"startedAt\":1000,\"endedAt\":2000,\"reason\":\"completed\","
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
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-a"))
              #'dsh-bridge-attach-file))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-d"))
              #'dsh-bridge-draft))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-k"))
              #'dsh-bridge-erase-prompt))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-f"))
              #'dsh-bridge-fetch))
  (should (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "C-c C-m"))
              #'dsh-bridge-select-model))
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
  "The view mode is read-only and binds g/q/r/w/B/i/l plus M-p/M-n — and no
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
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "B"))
              #'dsh-bridge-fork-turn))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "i"))
              #'dsh-bridge-receive))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "l"))
              #'dsh-bridge-list-sessions))
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "D"))
              #'dsh-bridge-describe-session))
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

;;; Fork (branch) a turn

(defun dsh-bridge-test--fork-record (turn end-seq)
  "A completed turn record for TURN carrying END-SEQ as its fork anchor."
  (append (dsh-bridge-test--view-turn
           turn 1000 (list (dsh-bridge-test--view-segment "reply" 1100 1)) 1200)
          (list (cons 'endSeq end-seq))))

(ert-deftest dsh-bridge-fork-turn-posts-ended-turn-and-opens-child ()
  "`B' forks the shown completed turn at its endSeq and opens the child.
The round trip posts the shown session id and the record's `endSeq' to
POST /fork, then opens the child's view and prompt."
  (let ((dsh-bridge--turns-cache
         (dsh-bridge-test--view-cache (list (dsh-bridge-test--fork-record 30 42))))
        (seen nil) (fetched nil) (prompted nil) (popped nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (setq-local dsh-bridge--view-turn 30)
      ;; A non-nil index keeps the turn refresh off the wire: the seeded cache
      ;; is authoritative, so only the fork request is issued.
      (setq-local dsh-bridge--view-turn-index 0)
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (method path payload)
                   (setq seen (list method path payload))
                   (cons 201 '((ok . t) (sessionId . "child")))))
                ((symbol-function 'dsh-bridge-fetch)
                 (lambda (id same-window) (setq fetched (list id same-window))))
                ((symbol-function 'dsh-bridge--prompt-buffer)
                 (lambda (id) (setq prompted id)
                         (get-buffer-create "*dsh-bridge-prompt*")))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buf &optional action) (setq popped (list buf action)))))
        (dsh-bridge-fork-turn))
      (should (equal (car seen) "POST"))
      (should (equal (cadr seen) "/fork"))
      (should (equal (alist-get 'sessionId (caddr seen)) "s1"))
      (should (equal (alist-get 'atSeq (caddr seen)) 42))
      (should (equal fetched '("child" t)))
      (should (equal prompted "child"))
      (should (equal (car popped) (get-buffer-create "*dsh-bridge-prompt*")))
      (should (equal (cadr popped) dsh-bridge-prompt-display-action)))))

(ert-deftest dsh-bridge-fork-turn-refuses-open-turn ()
  "An open (still running) shown turn is refused: it has no `endSeq' anchor.
No request is issued."
  (let ((dsh-bridge--turns-cache
         (dsh-bridge-test--view-cache
          (list (dsh-bridge-test--view-turn
                 30 1000 (list (dsh-bridge-test--view-segment "partial" 1100 1))))))
        (requested nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (setq-local dsh-bridge--view-turn 30)
      (setq-local dsh-bridge--view-turn-index 0)
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (&rest _) (setq requested t))))
        (should-error (dsh-bridge-fork-turn) :type 'user-error))
      (should-not requested))))

(ert-deftest dsh-bridge-fork-turn-refuses-pushed-message ()
  "A shown message with no turn identity is refused; no request is issued."
  (let ((dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns))
        (requested nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (setq-local dsh-bridge--view-turn nil)
      (setq-local dsh-bridge--view-turn-index 0)
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (&rest _) (setq requested t))))
        (should-error (dsh-bridge-fork-turn) :type 'user-error))
      (should-not requested))))

(ert-deftest dsh-bridge-fork-turn-refuses-outside-view ()
  "The command is a DSH-View verb; elsewhere it is a user error."
  (with-temp-buffer
    (should-error (dsh-bridge-fork-turn) :type 'user-error)))

(ert-deftest dsh-bridge-fork-turn-echoes-host-error ()
  "A failed fork echoes the host's error and opens nothing."
  (let ((dsh-bridge--turns-cache
         (dsh-bridge-test--view-cache (list (dsh-bridge-test--fork-record 30 42))))
        (fetched nil) (msg nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (setq-local dsh-bridge--view-turn 30)
      (setq-local dsh-bridge--view-turn-index 0)
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (&rest _) (cons 409 '((error . "not completed")))))
                ((symbol-function 'dsh-bridge-fetch)
                 (lambda (&rest _) (setq fetched t)))
                ((symbol-function 'message)
                 (lambda (&rest args) (setq msg (apply #'format args)))))
        (dsh-bridge-fork-turn))
      (should-not fetched)
      (should (string-match-p "not completed" msg)))))

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
  (let ((dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns))
        (turn (nth 0 dsh-bridge-test--view-turns)))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((inhibit-read-only t))
        (insert (dsh-bridge-test--view-turn-render turn)))
      (setq-local dsh-bridge--view-turn (alist-get 'turn turn))
      (dsh-bridge-copy-reply)
      (should (equal (current-kill 0) "newest first\n\nnewest second")))))

(ert-deftest dsh-bridge-copy-reply-turn-not-cached ()
  "`dsh-bridge-copy-reply' falls back to the buffer text when the shown turn
is no longer in the cached turn list (e.g. after a compaction)."
  ;; The cache holds only turns 20 and 10; the view still shows turn 30.
  (let ((dsh-bridge--turns-cache
         (dsh-bridge-test--view-cache (cdr dsh-bridge-test--view-turns)))
        (rendered (dsh-bridge-test--view-turn-render
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

(ert-deftest dsh-bridge-receive-missing-session-id-uses-buffer-session ()
  "An outbox entry without a `sessionId' falls back to the current buffer's
session and reports the missing id."
  (let ((msgs nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cond ((equal method "GET")
                        (cons 200 (list (cons 'entries
                                              (list (list (cons 'id "e1")
                                                          (cons 'text "pushed")
                                                          (cons 'ts 1000000)))))))
                       (t (cons 200 (list (cons 'ok t)))))))
              ((symbol-function 'message)
               (lambda (&rest args) (push (apply #'format args) msgs))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s9")
        (dsh-bridge-receive)))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal (buffer-string) "pushed"))
      (should (equal dsh-bridge--view-content-session "s9")))
    (should (seq-some (lambda (m) (string-match-p "without a session id" m)) msgs))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-receive-missing-session-id-defaults-to-output ()
  "With no session id and no buffer session, receive fills the default output
buffer and reports the missing id."
  (let ((msgs nil)
        (dsh-bridge--sessions-cache nil))
    (when (get-buffer "*dsh-bridge-output*")
      (kill-buffer "*dsh-bridge-output*"))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (method _path _payload)
                 (cond ((equal method "GET")
                        (cons 200 (list (cons 'entries
                                              (list (list (cons 'id "e1")
                                                          (cons 'text "orphan")
                                                          (cons 'ts 1000000)))))))
                       (t (cons 200 (list (cons 'ok t)))))))
              ((symbol-function 'message)
               (lambda (&rest args) (push (apply #'format args) msgs))))
      (with-temp-buffer
        (dsh-bridge-receive)))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal (buffer-string) "orphan"))
      (should (null dsh-bridge--view-content-session)))
    (should (seq-some (lambda (m) (string-match-p "without a session id" m)) msgs))
    (kill-buffer "*dsh-bridge-output*")))

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
              (cons 'turns dsh-bridge-test--view-turns)
              (cons 'epoch 0)
              (cons 'incremental nil))))

;; The package renders a turn's body and terminal suffix separately (the
;; incremental fill needs them apart), so the whole-turn render the tests
;; assert against is composed here.

(defun dsh-bridge-test--view-turn-render (turn &optional session-id)
  "Buffer text for the whole TURN record, or \"\" for nil.
A test-local composition of `dsh-bridge--view-turn-body' and
`dsh-bridge--view-turn-suffix'."
  (if (null turn)
      ""
    (concat (dsh-bridge--view-turn-body turn)
            (dsh-bridge--view-turn-suffix turn session-id))))

(defconst dsh-bridge-test--view-newest-rendered
  (dsh-bridge-test--view-turn-render (nth 0 dsh-bridge-test--view-turns)))

(defconst dsh-bridge-test--view-middle-rendered
  (dsh-bridge-test--view-turn-render (nth 1 dsh-bridge-test--view-turns)))

(defconst dsh-bridge-test--view-oldest-rendered
  (dsh-bridge-test--view-turn-render (nth 2 dsh-bridge-test--view-turns)))

(defun dsh-bridge-test--view-cache (turns &optional epoch)
  "A `dsh-bridge--turns-cache' alist for session \"s1\": TURNS (newest first)
at EPOCH (default 0)."
  (list (cons "s1" (cons (or epoch 0) turns))))

(defun dsh-bridge-test--turns-response-alist (turns &optional epoch incremental)
  "A `/turns' response alist: TURNS (default the fixture list) at EPOCH
(default 0), with INCREMENTAL true only when requested."
  (list (cons 'sessionId "s1")
        (cons 'turns (or turns dsh-bridge-test--view-turns))
        (cons 'epoch (or epoch 0))
        (cons 'incremental (and incremental t))))

(ert-deftest dsh-bridge-view-turn-navigation ()
  "M-p/M-n cycle the output buffer through the session's turns, newest first.
A turn renders as the whole run from a prompt to a reply — its committed
segments joined by `---' horizontal rules, the finished turn ending cleanly
after its last segment."
  (let ((dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns))
        (newest (nth 0 dsh-bridge-test--view-turns)))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((inhibit-read-only t))
        (insert (dsh-bridge-test--view-turn-render newest))
        (setq-local dsh-bridge--view-turn (alist-get 'turn newest)))
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (method path _payload)
                   (should (equal method "GET"))
                   ;; The seeded cache makes the refresh incremental.
                   (should (string-prefix-p "/turns?sessionId=s1&"
                                            path))
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
        ;; M-n walks back toward the newest; arriving there resumes
        ;; turn-following.
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) dsh-bridge-test--view-middle-rendered))
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) dsh-bridge-test--view-newest-rendered))
        (should (eq dsh-bridge--view-follow t))
        (should (null dsh-bridge--view-turn-index))
        (should (string-match-p " (latest/3)" (format "%s" header-line-format)))))))

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
  (let ((dsh-bridge-default-session "s1")
        (dsh-bridge--turns-cache nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          (concat "{\"sessionId\":\"s1\",\"turns\":["
                                  "{\"turn\":2,\"startedAt\":1000,\"endedAt\":2000,\"reason\":\"completed\",\"segments\":["
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
  "A turn renders its segments joined by GFM horizontal-rule dividers.  A
running turn ends with the propertized `(continuing...)' marker; a completed
turn ends cleanly after its last segment."
  (let ((multi (dsh-bridge-test--view-turn 30 3000000
                (list (dsh-bridge-test--view-segment "a" 3000500 1)
                      (dsh-bridge-test--view-segment "b" 3001000 2))
                3002000))
        (open (dsh-bridge-test--view-turn 40 4000000
               (list (dsh-bridge-test--view-segment "growing" 4001000 1))))
        (open-multi (dsh-bridge-test--view-turn 41 4100000
                     (list (dsh-bridge-test--view-segment "a" 4100500 1)
                           (dsh-bridge-test--view-segment "b" 4101000 2))))
        (aborted (dsh-bridge-test--view-turn 50 5000000
                  (list (dsh-bridge-test--view-segment "partial" 5001000 1))
                  5001000 "aborted"))
        (marker dsh-bridge--view-running-marker))
    ;; Two segments, completed: rule-only boundary, no label, no footer.
    (should (equal (dsh-bridge-test--view-turn-render multi) "a\n\n---\nb"))
    ;; A running turn ends with the marker after its last segment.
    (should (equal (dsh-bridge-test--view-turn-render open)
                   (concat "growing\n\n" marker)))
    (should (equal (dsh-bridge-test--view-turn-render open-multi)
                   (concat "a\n\n---\nb\n\n" marker)))
    ;; The marker is propertized, so it reads as furniture, never model text.
    (let ((rendered (dsh-bridge-test--view-turn-render open)))
      (should (text-property-any 0 (length rendered)
                                 'dsh-bridge-turn-marker t rendered))
      (should (eq (get-text-property 0 'face marker)
                  'dsh-bridge-view-marker-face)))
    ;; A completed turn — even an abnormal one — ends cleanly.
    (should (equal (dsh-bridge-test--view-turn-render aborted) "partial"))
    ;; nil renders empty.
    (should (equal (dsh-bridge-test--view-turn-render nil) ""))))

(ert-deftest dsh-bridge-view-fill-append-preserves-point ()
  "Refilling a growing turn splices: point inside the earlier content
survives, while point parked at the end follows the new tail.  Replacing the
shown turn resets point."
  (let* ((one (dsh-bridge-test--view-turn 7 7000000
              (list (dsh-bridge-test--view-segment "first" 7001000 1))))
        (two (dsh-bridge-test--view-turn 7 7000000
              (list (dsh-bridge-test--view-segment "first" 7001000 1)
                    (dsh-bridge-test--view-segment "second" 7002000 2))))
        (other (dsh-bridge-test--view-turn 8 8000000
                (list (dsh-bridge-test--view-segment "other turn" 8001000 1))))
        (dsh-bridge--turns-cache (dsh-bridge-test--view-cache (list two one))))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (dsh-bridge--view-fill "s1" one nil nil t)
      ;; Read a middle position of the first segment, then append.
      (goto-char 3)
      (dsh-bridge--view-fill "s1" two nil nil t t)
      (should (equal (point) 3))
      (should (equal (buffer-string) (dsh-bridge-test--view-turn-render two)))
      ;; Point parked at the very end follows the new tail rather than
      ;; staying behind the appended segment.
      (goto-char (point-max))
      (dsh-bridge--view-fill "s1" two nil nil t t)
      (should (equal (point) (point-max)))
      (should (equal (buffer-string) (dsh-bridge-test--view-turn-render two)))
      ;; A different turn is a swap, not an append: point goes to the top.
      (dsh-bridge--view-fill "s1" other nil nil t)
      (should (equal (point) (point-min))))))

(ert-deftest dsh-bridge-view-fill-splices-and-tails ()
  "An append leaves earlier text byte-identical and tails the window when
point sits at the end; completion drops the terminal marker and its blank
line without resetting point.  The spliced body always equals the reference
render."
  (let* ((seg1 (dsh-bridge-test--view-segment "first" 7001000 1))
         (seg2 (dsh-bridge-test--view-segment "second" 7002000 2))
         (open (dsh-bridge-test--view-turn 7 7000000 (list seg1)))
         (two (dsh-bridge-test--view-turn 7 7000000 (list seg1 seg2)))
         (done (dsh-bridge-test--view-turn 7 7000000 (list seg1 seg2) 7003000))
         (dsh-bridge--turns-cache
          (dsh-bridge-test--view-cache (list done two open))))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (dsh-bridge--view-fill "s1" open nil nil t)
      (setq-local dsh-bridge--view-follow t)
      (goto-char (point-max))
      (dsh-bridge--view-fill "s1" two nil nil t t)
      (should (equal (buffer-string) (dsh-bridge-test--view-turn-render two "s1")))
      (should (equal (point) (point-max)))
      (should (equal (how-many "(continuing\\.\\.\\.)" (point-min) (point-max))
                     1))
      ;; A mid-body reader is untouched by the next append.
      (goto-char 3)
      (dsh-bridge--view-fill "s1" two nil nil t t)
      (should (equal (point) 3))
      ;; Completion drops the marker and its blank line, keeping the tail.
      (goto-char (point-max))
      (dsh-bridge--view-fill "s1" done nil nil t t)
      (should (equal (buffer-string) (dsh-bridge-test--view-turn-render done "s1")))
      (should (equal (point) (point-max)))
      (should-not (text-property-any (point-min) (point-max)
                                     'dsh-bridge-turn-marker t)))))

(ert-deftest dsh-bridge-view-fill-falls-back-on-divergence ()
  "Every provenance mismatch rebuilds the whole body instead of splicing.
A text marker planted in the body survives a splice and collapses to
`point-min' on a rebuild, which distinguishes the two."
  (let* ((seg1 (dsh-bridge-test--view-segment "first" 7001000 1))
         (seg2 (dsh-bridge-test--view-segment "second" 7002000 2))
         (one (dsh-bridge-test--view-turn 7 7000000 (list seg1)))
         (two (dsh-bridge-test--view-turn 7 7000000 (list seg1 seg2)))
         (gap (dsh-bridge-test--view-turn 7 7000000 (list seg2)))
         (other (dsh-bridge-test--view-turn 8 8000000 (list seg1)))
         (dsh-bridge--turns-cache (dsh-bridge-test--view-cache (list two one))))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-follow t)
      (cl-labels ((refill (turn)
                    (dsh-bridge--view-fill "s1" turn nil nil t t)
                    (equal (buffer-string)
                           (dsh-bridge-test--view-turn-render turn "s1"))))
        ;; Control: equal epoch and a prefix -> splice keeps the marker.
        (refill one)
        (let ((probe (copy-marker 3)))
          (should (refill two))
          (should (equal (marker-position probe) 3))
          (set-marker probe nil))
        ;; Epoch changed -> rebuild.
        (refill one)
        (let ((probe (copy-marker 3))
              (dsh-bridge--turns-cache
               (dsh-bridge-test--view-cache (list two one) 1)))
          (should (refill two))
          (should (equal (marker-position probe) (point-min)))
          (set-marker probe nil))
        ;; Non-numeric epoch -> rebuild.
        (refill one)
        (let ((probe (copy-marker 3))
              (dsh-bridge--turns-cache
               (list (cons "s1" (cons nil (list two one))))))
          (should (refill two))
          (should (equal (marker-position probe) (point-min)))
          (set-marker probe nil))
        ;; A segment-key gap -> rebuild.
        (refill one)
        (let ((probe (copy-marker 3)))
          (should (refill gap))
          (should (equal (marker-position probe) (point-min)))
          (set-marker probe nil))
        ;; Buffer drift -> rebuild.
        (refill one)
        (let ((probe (copy-marker 3)))
          (let ((inhibit-read-only t))
            (goto-char (point-min))
            (delete-char 1))
          (should (refill two))
          (should (equal (marker-position probe) (point-min)))
          (set-marker probe nil))
        ;; A different turn -> rebuild.
        (refill one)
        (let ((probe (copy-marker 3)))
          (should (refill other))
          (should (equal (marker-position probe) (point-min)))
          (set-marker probe nil))))))

(ert-deftest dsh-bridge-view-fill-provenance ()
  "A record fill records the render provenance, a splice extends it, and the
waiting placeholder clears it."
  (let* ((seg1 (dsh-bridge-test--view-segment "first" 7001000 1))
         (seg2 (dsh-bridge-test--view-segment "second" 7002000 2))
         (one (dsh-bridge-test--view-turn 7 7000000 (list seg1)))
         (two (dsh-bridge-test--view-turn 7 7000000 (list seg1 seg2)))
         (dsh-bridge--turns-cache (dsh-bridge-test--view-cache (list two one))))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (dsh-bridge--view-fill "s1" one nil nil t)
      (let ((prov dsh-bridge--view-provenance))
        (should (equal (plist-get prov :session) "s1"))
        (should (equal (plist-get prov :epoch) 0))
        (should (equal (plist-get prov :turn) 7))
        (should (plist-get prov :open))
        (should (equal (plist-get prov :keys) '((1 . 7001000))))
        (should (equal (plist-get prov :body-length) 5))
        (should (> (plist-get prov :tail-length) 0)))
      (dsh-bridge--view-fill "s1" two nil nil t t)
      (let ((prov dsh-bridge--view-provenance))
        (should (equal (plist-get prov :keys)
                       '((1 . 7001000) (2 . 7002000))))
        (should (equal (plist-get prov :body-length)
                       (length (dsh-bridge--view-turn-body two))))
        (should (plist-get prov :open)))
      ;; A waiting placeholder is not a reconcilable body.
      (dsh-bridge--view-waiting-fill "s1" 7)
      (should-not dsh-bridge--view-provenance))))

(ert-deftest dsh-bridge-view-fill-follow-flip-tails ()
  "A followed view flipping to a newer turn rebuilds and lands at the tail,
not the top: the flip is a provenance-mismatch rebuild under follow."
  (let* ((one (dsh-bridge-test--view-turn 7 7000000
               (list (dsh-bridge-test--view-segment "first" 7001000 1))))
         (newer (dsh-bridge-test--view-turn 8 8000000
                  (list (dsh-bridge-test--view-segment "next" 8001000 1))))
         (dsh-bridge--turns-cache (dsh-bridge-test--view-cache (list newer one))))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (dsh-bridge--view-fill "s1" one nil nil t t)
      (setq-local dsh-bridge--view-follow t)
      (goto-char (point-min))
      (dsh-bridge--view-fill "s1" newer nil nil t t)
      (should (equal (buffer-string) (dsh-bridge-test--view-turn-render newer "s1")))
      (should (equal (point) (point-max))))))

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
                   (cons 200 sessions))))
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
                   (cons 200 sessions))))
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
               (lambda () (cons 200 '(((id . "live-1") (live . t) (cwd . "/a"))))))
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
                 (cons 200
                       '(((id . "live-1") (live . t) (cwd . "/a"))
                         ((id . "saved-1") (live . nil) (cwd . "/b"))
                         ((id . "arch-1") (live . nil) (archived . t) (cwd . "/c"))))))
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
      ;; The answer arrives in `read-directory-name' form (here an abbreviated
      ;; `~' path), so it must be expanded before it reaches the host.
      (should (equal (cdr (assoc 'path (caddr create)))
                     (expand-file-name default-directory))))
    (should (equal bound-target "s-new"))))

(ert-deftest dsh-bridge-create-session-expands-new-workspace-path ()
  "A `~'-relative new-workspace answer is expanded before it is POSTed.
The host's workspace registry rejects a path that is not fully qualified."
  (let ((called nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "New workspace…"))
              ((symbol-function 'read-directory-name)
               (lambda (&rest _) "~/dsh-bridge-test-dir/"))
              ;; Accept only the expanded form, so an unexpanded `~' answer
              ;; would fail the existing-directory check and never POST.
              ((symbol-function 'file-directory-p)
               (lambda (dir) (equal dir (expand-file-name "~/dsh-bridge-test-dir/"))))
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
               (lambda (id) nil)))
      (dsh-bridge-create-session))
    (let ((create (cadr (assoc "/sessions/create"
                               (mapcar (lambda (c) (list (cadr c) c)) called)))))
      (should create)
      (should (equal (cdr (assoc 'path (caddr create)))
                     (expand-file-name "~/dsh-bridge-test-dir/"))))))

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
               (lambda () (cons 200 '(((id . "live-1") (live . t) (cwd . "/a"))))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda () (cons 200 '(((id . "live-2") (live . t) (cwd . "/b"))))))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (with-current-buffer (get-buffer "*dsh-bridge-sessions*")
        (revert-buffer t t)))
    (let ((entries (buffer-local-value 'tabulated-list-entries
                                       (get-buffer "*dsh-bridge-sessions*"))))
      (should (assoc "live-2" entries))
      (should-not (assoc "live-1" entries)))))

(ert-deftest dsh-bridge-fetch-sessions-empty-roster-is-success ()
  "A 200 `{sessions: []}' decodes to an empty roster that still counts as
success: the fetch returns (200 . nil), clears the stale sessions cache, and
empties the status tracker (a wiped roster must not linger)."
  (let ((dsh-bridge--sessions-cache '(((id . "old") (live . t))))
        (dsh-bridge--session-status '(("old" idle))))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (&rest _) (cons 200 (list (cons 'sessions nil))))))
      (let ((fetch (dsh-bridge--fetch-sessions)))
        (should (eq (car fetch) 200))
        (should (null (cdr fetch)))))
    (should (null dsh-bridge--sessions-cache))
    (should (null dsh-bridge--session-status))))

(ert-deftest dsh-bridge-fetch-sessions-seeds-cache-and-status ()
  "A 200 with sessions returns them and reseeds the cache and status tracker."
  (let ((dsh-bridge--sessions-cache nil)
        (dsh-bridge--session-status nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (&rest _)
                 (cons 200
                       (list (cons 'sessions
                                   (list (list (cons 'id "s1") (cons 'live t)
                                               (cons 'running t))
                                         (list (cons 'id "s2") (cons 'live t)))))))))
      (let ((fetch (dsh-bridge--fetch-sessions)))
        (should (eq (car fetch) 200))
        (should (= (length (cdr fetch)) 2))))
    (should (equal (mapcar (lambda (s) (alist-get 'id s))
                           dsh-bridge--sessions-cache)
                   '("s1" "s2")))
    (should (eq (dsh-bridge--status-state "s1") 'running))
    (should (eq (dsh-bridge--status-state "s2") 'idle))))

(ert-deftest dsh-bridge-fetch-sessions-failure-keeps-cache ()
  "A failed fetch (HTTP error or transport failure) is reported and leaves
the cached roster and tracker untouched."
  (dolist (case (list (cons 500 (list (cons 'error "boom")))
                      (cons nil nil)))
    (let ((dsh-bridge--sessions-cache '(((id . "old") (live . t)))))
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (&rest _) case)))
        (let ((fetch (dsh-bridge--fetch-sessions)))
          (should (eq (car fetch) (car case)))
          (should (null (cdr fetch)))))
      (should (equal dsh-bridge--sessions-cache
                     '(((id . "old") (live . t))))))))

(ert-deftest dsh-bridge-list-sessions-empty-roster-opens-list ()
  "An empty roster still opens the session list: an empty tabulated buffer,
so the list's actions (`+' create, `g' re-fetch, `v' archived visibility)
stay available instead of a bare error message."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda () (cons 200 nil)))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (dsh-bridge-list-sessions))
    (let ((buf (get-buffer "*dsh-bridge-sessions*")))
      (should buf)
      (should (eq (buffer-local-value 'major-mode buf)
                  'dsh-bridge-sessions-mode))
      (should (null (buffer-local-value 'tabulated-list-entries buf)))
      ;; The column header is still in place, so the layout renders.
      (should (buffer-local-value 'tabulated-list-format buf)))))

(ert-deftest dsh-bridge-list-sessions-failed-fetch-no-buffer ()
  "A failed roster fetch reports an error and opens no sessions buffer."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (let ((msg nil)
        (dsh-bridge-default-session nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-sessions)
               (lambda () (cons nil nil)))
              ((symbol-function 'message)
               (lambda (&rest args) (setq msg (apply #'format args)))))
      (dsh-bridge-list-sessions))
    (should (string-match-p "failed to fetch sessions" msg))
    (should-not (get-buffer "*dsh-bridge-sessions*"))))

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

(ert-deftest dsh-bridge-load-install-library-missing ()
  "The install library is reported absent, without signaling, when unfindable.
This is the optional-library contract: `dsh-bridge.el' must keep working when
`dsh-bridge-install.el' is not installed."
  (cl-letf (((symbol-function 'require) (lambda (&rest _) nil))
            ((symbol-function 'locate-library) (lambda (&rest _) nil))
            ((symbol-function 'symbol-file) (lambda (&rest _) nil)))
    (should-not (dsh-bridge--load-install-library))))

(ert-deftest dsh-bridge-ensure-plugin-no-install-library ()
  "With the install library absent, diagnosis warns but does not offer."
  (let ((dsh-bridge--bridge-status-cache 'not-running)
        (dsh-bridge--plugin-diagnosed nil)
        (warned nil))
    (cl-letf (((symbol-function 'dsh-bridge--load-install-library)
               (lambda () nil))
              ((symbol-function 'display-warning)
               (lambda (&rest args) (setq warned args)))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (ert-fail "must not offer an install"))))
      (dsh-bridge--ensure-plugin))
    (should warned)
    (should (eq dsh-bridge--bridge-status-cache 'not-running))))

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
  (let ((dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns)))
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
The just-sent prompt has not committed any content yet, so the view is erased
to the `(running...)' placeholder and remembers the abandoned (previous
newest) turn, so only a genuinely newer turn's content replaces it."
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*"))
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (setq-local dsh-bridge--prompt-session "s1")
    (let ((shown nil)
          (dsh-bridge--turns-cache nil)
          (dsh-bridge--session-status nil))
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq shown t)))
                ((symbol-function 'dsh-bridge--request)
                 (lambda (_m _p _pl)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'turns (list (dsh-bridge-test--view-turn
                                                       2 1000
                                                       (list (dsh-bridge-test--view-segment "latest"))
                                                       2000))))))))
        (dsh-bridge--prompt-exit "s1"))
      (should shown)
      (with-current-buffer (get-buffer "*dsh-bridge-output*")
        (should (equal dsh-bridge--view-content-session "s1"))
        (should (eq dsh-bridge--view-follow t))
        (should (equal dsh-bridge--view-waiting 2))
        (should (null dsh-bridge--view-turn))
        (should (equal (buffer-string) dsh-bridge--view-running-placeholder)))))
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-send-exit-shows-already-running-turn ()
  "When the session was already running at send time (a queued second send),
prompt-exit shows the open turn live instead of erasing to the placeholder:
its committed content is what the user should be watching."
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*"))
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (setq-local dsh-bridge--prompt-session "s1")
    (let* ((running (dsh-bridge-test--view-turn
                     2 1000
                     (list (dsh-bridge-test--view-segment "streaming"))))
           (shown nil)
           (dsh-bridge--turns-cache nil)
           (dsh-bridge--session-status nil))
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq shown t)))
                ((symbol-function 'dsh-bridge--request)
                 (lambda (_m _p _pl)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'turns (list running)))))))
        (dsh-bridge--prompt-exit "s1"))
      (should shown)
      (with-current-buffer (get-buffer "*dsh-bridge-output*")
        (should (equal dsh-bridge--view-content-session "s1"))
        (should (eq dsh-bridge--view-follow t))
        (should (null dsh-bridge--view-waiting))
        (should (equal dsh-bridge--view-turn 2))
        (should (equal (buffer-string)
                       (dsh-bridge-test--view-turn-render running))))))
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-send-exit-shows-turn-finished-during-send ()
  "A turn that commits (or finishes) while the blocking send is on the wire is
shown rather than hidden behind a `(running...)' placeholder the waiting gate
could never replace.  `--after-prompt-view' recognizes it as this send's turn
by its `startedAt'."
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*"))
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (setq-local dsh-bridge--prompt-session "s1")
    (let* ((sent-at 5000)
           (finished (dsh-bridge-test--view-turn
                      2 5001
                      (list (dsh-bridge-test--view-segment "done"))
                      5002))
           (shown nil)
           (dsh-bridge--turns-cache nil)
           (dsh-bridge--session-status nil))
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq shown t)))
                ((symbol-function 'dsh-bridge--request)
                 (lambda (_m _p _pl)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'turns (list finished)))))))
        (dsh-bridge--prompt-exit "s1" nil sent-at))
      (should shown)
      (with-current-buffer (get-buffer "*dsh-bridge-output*")
        (should (equal dsh-bridge--view-content-session "s1"))
        (should (eq dsh-bridge--view-follow t))
        (should (null dsh-bridge--view-waiting))
        (should (equal dsh-bridge--view-turn 2))
        (should (equal (buffer-string)
                       (dsh-bridge-test--view-turn-render finished "s1")))
        (should (equal (point) (point-max))))))
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-send-exit-waits-when-newest-turn-precedes-send ()
  "A completed turn that began before the send is the abandoned turn: the view
still gets the `(running...)' placeholder, and only a strictly newer turn may
replace it (the regression guard for the fix above)."
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*"))
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (setq-local dsh-bridge--prompt-session "s1")
    (let* ((sent-at 5000)
           (previous (dsh-bridge-test--view-turn
                      2 1000
                      (list (dsh-bridge-test--view-segment "latest"))
                      2000))
           (shown nil)
           (dsh-bridge--turns-cache nil)
           (dsh-bridge--session-status nil))
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq shown t)))
                ((symbol-function 'dsh-bridge--request)
                 (lambda (_m _p _pl)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'turns (list previous)))))))
        (dsh-bridge--prompt-exit "s1" nil sent-at))
      (should shown)
      (with-current-buffer (get-buffer "*dsh-bridge-output*")
        (should (eq dsh-bridge--view-follow t))
        (should (equal dsh-bridge--view-waiting 2))
        (should (null dsh-bridge--view-turn))
        (should (equal (buffer-string) dsh-bridge--view-running-placeholder)))))
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-send-and-exit-passes-send-instant ()
  "The success callback carries the send instant to `--prompt-exit', so
`--after-prompt-view' can tell this send's turn from the abandoned one."
  (dsh-bridge-test--kill-prompt-buffer)
  (let ((captured 'unset)
        (dsh-bridge-prompt-resend-confirm nil)
        (dsh-bridge--prompt-session "s1"))
    (with-current-buffer (get-buffer-create "*dsh-bridge-prompt*")
      (dsh-bridge-prompt-mode)
      (insert "hello")
      (cl-letf (((symbol-function 'dsh-bridge-send-text)
                 (lambda (_text &optional _session-id on-success _attachments)
                   (when on-success (funcall on-success "s1"))))
                ((symbol-function 'dsh-bridge--prompt-exit)
                 (lambda (&rest args) (setq captured args))))
        (dsh-bridge-send-and-exit))
      (should (equal (car captured) "s1"))
      (should (integerp (nth 2 captured)))
      (should (> (nth 2 captured) 0)))
    (dsh-bridge-test--kill-prompt-buffer)))

(defun dsh-bridge-test--prompt-exit-two-windows (steal hint)
  "Set up a prompt window below a view window and run `dsh-bridge--prompt-exit'.
STEAL, when non-nil, makes the stubbed `dsh-bridge--after-prompt-view' pop to
the view before returning, simulating a process filter (an outbox push) that
moves window selection during the synchronous send.  HINT, when non-nil, passes
the invoking window to `dsh-bridge--prompt-exit'; otherwise it is omitted so
the prompt's window must be found by buffer.  Returns the prompt buffer and the
view buffer; the caller must unwind the window configuration."
  (let ((view (get-buffer-create "*dsh-bridge-output*"))
        (prompt (get-buffer-create "*dsh-bridge-prompt*"))
        w1 w2)
    (with-current-buffer view
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1"))
    (with-current-buffer prompt
      (dsh-bridge-prompt-mode))
    (delete-other-windows)
    (setq w1 (selected-window))
    (set-window-buffer w1 view)
    (setq w2 (split-window w1 nil 'below))
    (set-window-buffer w2 prompt)
    (select-window w2)
    (cl-letf (((symbol-function 'dsh-bridge--after-prompt-view)
               (lambda (_id &optional _sent-at)
                 (when steal
                   ;; Mimic a process filter popping the view during the
                   ;; fetch: window selection moves, but the current buffer
                   ;; is restored around the filter call.
                   (save-current-buffer (pop-to-buffer view)))
                 view)))
      (with-current-buffer prompt
        (if hint
            (dsh-bridge--prompt-exit "s1" w2)
          (dsh-bridge--prompt-exit "s1"))))
    (list prompt view)))

(defun dsh-bridge-test--assert-prompt-window-quit (steal hint)
  "Run the two-window prompt-exit scenario and assert the prompt window is gone."
  (let ((config (current-window-configuration)))
    (unwind-protect
        (let ((pair (dsh-bridge-test--prompt-exit-two-windows steal hint)))
          (should-not (get-buffer-window (nth 0 pair)))
          (should (eq (window-buffer) (nth 1 pair))))
      (set-window-configuration config)
      (dolist (b '("*dsh-bridge-output*" "*dsh-bridge-prompt*"))
        (when (buffer-live-p (get-buffer b)) (kill-buffer b))))))

(ert-deftest dsh-bridge-prompt-exit-quits-prompt-window-when-selection-moves ()
  "C-c C-c removes the prompt window even when window selection moves to the
DSH-View while the synchronous send runs (e.g. an outbox push pops the view).
The prompt window is identified by buffer, so the stale-selection check that
used to strand it on screen no longer applies."
  (dsh-bridge-test--assert-prompt-window-quit t t))

(ert-deftest dsh-bridge-prompt-exit-finds-prompt-window-without-hint ()
  "Without the invoking-window hint, `dsh-bridge--prompt-exit' still finds the
prompt's window by buffer when selection has moved away."
  (dsh-bridge-test--assert-prompt-window-quit t nil))

(ert-deftest dsh-bridge-prompt-exit-quits-prompt-window-without-steal ()
  "The normal case still quits the prompt's window when the view is already
shown and selection never moves."
  (dsh-bridge-test--assert-prompt-window-quit nil t))

(ert-deftest dsh-bridge-send-and-exit-captures-window-before-send ()
  "The invoking window is captured before the synchronous POST, so window
selection moving during the send cannot strand the prompt on screen."
  (let ((config (current-window-configuration))
        (view (get-buffer-create "*dsh-bridge-output*"))
        (prompt (get-buffer-create "*dsh-bridge-prompt*"))
        (dsh-bridge-default-session nil)
        (dsh-bridge--last-resolved-active nil)
        (dsh-bridge--last-sent nil)
        (dsh-bridge-prompt-resend-confirm nil)
        w1 w2)
    (unwind-protect
        (progn
          (with-current-buffer view
            (dsh-bridge-view-mode)
            (setq-local dsh-bridge--view-content-session "s1"))
          (with-current-buffer prompt
            (dsh-bridge-prompt-mode)
            (insert "hi")
            (setq-local dsh-bridge--prompt-session "s1"))
          (delete-other-windows)
          (setq w1 (selected-window))
          (set-window-buffer w1 view)
          (setq w2 (split-window w1 nil 'below))
          (set-window-buffer w2 prompt)
          (select-window w2)
          (cl-letf (((symbol-function 'dsh-bridge--call)
                     (lambda (_method _path _payload callback)
                       ;; Steal selection during the POST, then answer.
                       (save-current-buffer (pop-to-buffer view))
                       (funcall callback nil "{\"sessionId\":\"s1\"}" 200)))
                    ((symbol-function 'dsh-bridge--after-prompt-view)
                     (lambda (_id &optional _sent-at) view)))
            (with-current-buffer prompt
              (dsh-bridge-send-and-exit)))
          (should-not (get-buffer-window prompt))
          (should (eq (window-buffer) view)))
      (set-window-configuration config)
      (dolist (b '("*dsh-bridge-output*" "*dsh-bridge-prompt*"))
        (when (buffer-live-p (get-buffer b)) (kill-buffer b))))))

(ert-deftest dsh-bridge-view-waiting-state ()
  "The waiting state shows the `(running...)' placeholder, has no `(k/n)'
position (it is not a turn), and accepts only content from a turn newer than
the abandoned one; a fresh session (nothing abandoned) accepts any turn."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--pending-questions nil)
        (dsh-bridge--turns-cache (dsh-bridge-test--view-cache
                                  (list (dsh-bridge-test--view-turn 2 1000 nil 2000)))))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (dsh-bridge--view-waiting-fill "s1" 2)
      ;; The placeholder is propertized furniture.
      (should (equal (buffer-string) dsh-bridge--view-running-placeholder))
      (should (text-property-any (point-min) (point-max)
                                 'dsh-bridge-running t))
      (should (eq dsh-bridge--view-waiting 2))
      (should (eq dsh-bridge--view-follow t))
      ;; Not a turn, so no position segment.
      (should (equal (dsh-bridge--view-turn-position) ""))
      (should-not (string-match-p "(latest/" (format "%s" header-line-format)))
      ;; Newer content is accepted; the abandoned turn's own is not.
      (should (dsh-bridge--view-waiting-accept-p 3))
      (should-not (dsh-bridge--view-waiting-accept-p 2))
      (should-not (dsh-bridge--view-waiting-accept-p nil)))
    ;; A fresh session (nothing abandoned) accepts any turn.
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (dsh-bridge--view-waiting-fill "s1" nil)
      (should (eq dsh-bridge--view-waiting t))
      (should (dsh-bridge--view-waiting-accept-p 1)))))

(ert-deftest dsh-bridge-view-waiting-awaiting-note ()
  "A waiting view with a pending ask-user question shows the awaiting note
instead of the `(running...)' placeholder: the fresh turn may ask before it
commits any text.  Resolving the question restores the placeholder."
  (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
    (kill-buffer "*dsh-bridge-output*"))
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--pending-questions
         (dsh-bridge-test--pending-ask "s1" "Approve this plan?")))
    (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (dsh-bridge--view-waiting-fill "s1" 2)
      (should (string-match-p "Awaiting your response:" (buffer-string)))
      (should-not (string-match-p "(running\\.\\.\\.)" (buffer-string)))
      (should (text-property-any (point-min) (point-max)
                                 'dsh-bridge-awaiting t)))
    ;; No pending question: back to the plain placeholder.
    (let ((dsh-bridge--pending-questions nil))
      (dsh-bridge--view-await-refresh "s1"))
    (with-current-buffer "*dsh-bridge-output*"
      (should (string-match-p "(running\\.\\.\\.)" (buffer-string)))
      (should-not (string-match-p "Awaiting your response:" (buffer-string)))))
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

(ert-deftest dsh-bridge-select-model-annotation-separated ()
  "Model completion annotations are separated from the candidate by a space,
and a model with no display name gets no annotation."
  (let ((annotation nil))
    (cl-letf (((symbol-function 'dsh-bridge--fetch-models)
               (lambda (&rest _)
                 '((current . ((provider . "p1") (model . "m1")))
                   (groups . (((id . "p1")
                               (models . (((id . "m1") (name . "M1"))
                                          ((id . "m2"))))))))))
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (setq annotation
                       (completion-metadata-get (funcall table "" nil 'metadata)
                                                'annotation-function))
                 "p1/m1"))
              ((symbol-function 'dsh-bridge--select-model-apply)
               (lambda (&rest _) t)))
      (dsh-bridge-select-model))
    (should annotation)
    (should (equal (funcall annotation "p1/m1") " M1"))
    (should (null (funcall annotation "p1/m2")))))

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
              ;; The deferred turn-cache refresh would issue a real request
              ;; for any session an earlier test left in the global turns
              ;; cache; stub it like the sibling turn-start test does.
              ((symbol-function 'dsh-bridge--view-turns-cache-refresh) #'ignore)
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
         (dsh-bridge--turns-cache (dsh-bridge-test--view-cache turns))
         (msg nil))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((inhibit-read-only t))
        (insert (dsh-bridge-test--view-turn-render newest-open))
        (setq-local dsh-bridge--view-turn (alist-get 'turn newest-open)))
      (setq-local dsh-bridge--view-turn-index 0)
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest args) (setq msg (apply #'format args))))
                ((symbol-function 'dsh-bridge--request)
                 (lambda (_method _path _payload)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'turns turns))))))
        (dsh-bridge-view-next-reply))
      (should (equal (buffer-string) (dsh-bridge-test--view-turn-render newest-open)))
      (should (eq dsh-bridge--view-follow t))
      (should (null dsh-bridge--view-turn-index))
      (should (string-match-p "following the newest turn" msg)))))

(ert-deftest dsh-bridge-view-turns-cache-refresh-recomputes-index ()
  "A turn-cache refresh recomputes a cycling view's index from the shown turn's
number, so the `(k/n)' counter stays honest when newer turns arrive."
  (let* ((newest-open (dsh-bridge-test--view-turn 40 4000000
                       (list (dsh-bridge-test--view-segment "newest2" 4001000 1))))
         (new-turns (cons newest-open dsh-bridge-test--view-turns))
         (dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns)))
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
        (should (equal (dsh-bridge--turns-cache-turns "s1") new-turns))
        ;; Turn 20 now sits at index 2 in the refreshed list.
        (should (eq dsh-bridge--view-turn-index 2)))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-turns-cache-refresh-vanished-turn-rests ()
  "When the shown turn vanished from the refreshed list (a compaction replaced
it), a cycling view drops its index to at-rest rather than pointing at an
unrelated turn; the buffer text is untouched."
  (let ((new-turns (list (nth 0 dsh-bridge-test--view-turns)
                         (nth 2 dsh-bridge-test--view-turns)))
        (dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns)))
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
        (should (equal (dsh-bridge--turns-cache-turns "s1") new-turns))
        (should (null dsh-bridge--view-turn-index))
        (should (equal (buffer-string) "browsing turn 20")))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-turns-cache-refresh-empty-list-clears ()
  "A `/turns' response with an explicit empty turn list replaces the cached
entry (the session genuinely has no turns, e.g. after a full compaction); a
response without a `turns' field (an error body) leaves the cache alone."
  (let ((dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns)))
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
        (should (null (dsh-bridge--turns-cache-turns "s1")))
        (should (null dsh-bridge--view-turn-index)))
      (kill-buffer "*dsh-bridge-output*")))
  (let ((dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns)))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (cons 404 (list (cons 'error "unknown session"))))))
      (should (null (dsh-bridge--turns-cache-fetch "s1"))))
    (should (equal (dsh-bridge--turns-cache-turns "s1")
                   dsh-bridge-test--view-turns))))

(ert-deftest dsh-bridge-turns-cache-store-ignores-stale-same-epoch-response ()
  "A slow, out-of-order `/turns' response must not shrink the cache within an
equal epoch: the visible turn list only grows, so an older newest turn is
ignored (otherwise a later refill could revert a DSH-View to an older turn).
A changed epoch, an unknown epoch, and an explicit empty list still replace."
  (let* ((t1 (dsh-bridge-test--view-turn
              1 1000 (list (dsh-bridge-test--view-segment "a" 1001 1))))
         (t2 (dsh-bridge-test--view-turn
              2 2000 (list (dsh-bridge-test--view-segment "b" 2001 1))))
         (t3 (dsh-bridge-test--view-turn
              3 3000 (list (dsh-bridge-test--view-segment "c" 3001 1))))
         (turns (lambda () (dsh-bridge--turns-cache-turns "s1")))
         (dsh-bridge--turns-cache nil))
    (dsh-bridge--turns-cache-store "s1" (list t2 t1) 5)
    ;; Stale same-epoch response: ignored.
    (dsh-bridge--turns-cache-store "s1" (list t1) 5)
    (should (equal (funcall turns) (list t2 t1)))
    (should (equal (dsh-bridge--turns-cache-epoch "s1") 5))
    ;; A newer same-epoch response still updates.
    (dsh-bridge--turns-cache-store "s1" (list t3 t2 t1) 5)
    (should (equal (funcall turns) (list t3 t2 t1)))
    ;; A changed epoch replaces even with an older newest turn.
    (dsh-bridge--turns-cache-store "s1" (list t1) 6)
    (should (equal (funcall turns) (list t1)))
    ;; A non-numeric epoch cannot anchor the guarantee: replace.
    (dsh-bridge--turns-cache-store "s1" (list t3) nil)
    (should (equal (funcall turns) (list t3)))
    ;; An explicit empty list is still the documented known-empty snapshot.
    (dsh-bridge--turns-cache-store "s1" nil 6)
    (should (assoc "s1" dsh-bridge--turns-cache))
    (should (null (funcall turns)))))

;;; Phase 2: incremental `/turns' fetch and cache merge (epoch + since)

(ert-deftest dsh-bridge-turns-cache-fetch-incremental-merge ()
  "An incremental `/turns' response — the boundary turn grown by a segment,
plus a brand-new turn — merges into the cached list: the response is
prepended and the cached turns at or above `since' (the boundary head) are
dropped.  The fetch request carried `since' = the newest cached turn and the
stored `epoch'; the response epoch is stored."
  (let* ((cached-7 (dsh-bridge-test--view-turn 7 7000000
                    (list (dsh-bridge-test--view-segment "old" 7001000 1))))
         (grown-7 (dsh-bridge-test--view-turn 7 7000000
                   (list (dsh-bridge-test--view-segment "old" 7001000 1)
                         (dsh-bridge-test--view-segment "new" 7002000 2))))
         (new-8 (dsh-bridge-test--view-turn 8 8000000
                 (list (dsh-bridge-test--view-segment "new turn" 8001000 1))))
         (older-5 (dsh-bridge-test--view-turn 5 5000000
                   (list (dsh-bridge-test--view-segment "older" 5001000 1))))
         (dsh-bridge--turns-cache
          (dsh-bridge-test--view-cache (list cached-7 older-5) 3))
         (paths nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method path _payload)
                 (push path paths)
                 ;; Respond with the incremental suffix for the asked `since':
                 ;; the newest cached turn is 7 (then 8 after the first merge).
                 (if (string-match-p "since=8" path)
                     (cons 200 (dsh-bridge-test--turns-response-alist
                                (list new-8) 3 t))
                   (cons 200 (dsh-bridge-test--turns-response-alist
                              (list new-8 grown-7) 3 t))))))
      (dsh-bridge--view-turns-cache-refresh "s1")
      ;; First request names since=7 (newest cached) and the stored epoch.
      (should (equal (car paths) "/turns?sessionId=s1&since=7&epoch=3"))
      ;; Boundary turn replaced in full, newer turn prepended, older kept.
      (should (equal (dsh-bridge--turns-cache-turns "s1")
                     (list new-8 grown-7 older-5)))
      (should (equal (dsh-bridge--turns-cache-epoch "s1") 3))
      ;; Idempotent: a second incremental fetch (now since=8) changes nothing.
      (dsh-bridge--view-turns-cache-refresh "s1")
      (should (equal (dsh-bridge--turns-cache-turns "s1")
                     (list new-8 grown-7 older-5)))
      (should (string-match-p "since=8" (car paths))))))

(ert-deftest dsh-bridge-view-turns-cache-refresh-incremental-keeps-index ()
  "An incremental merge recomputes a mid-browse index against the merged list:
cycling on an older turn, the shown turn's `(k/n)' position stays honest."
  (let* ((cached-7 (dsh-bridge-test--view-turn 7 7000000
                    (list (dsh-bridge-test--view-segment "old" 7001000 1))))
         (grown-7 (dsh-bridge-test--view-turn 7 7000000
                   (list (dsh-bridge-test--view-segment "old" 7001000 1)
                         (dsh-bridge-test--view-segment "new" 7002000 2))))
         (new-8 (dsh-bridge-test--view-turn 8 8000000
                 (list (dsh-bridge-test--view-segment "new turn" 8001000 1))))
         (older-5 (dsh-bridge-test--view-turn 5 5000000
                   (list (dsh-bridge-test--view-segment "older" 5001000 1))))
         (dsh-bridge--turns-cache
          (dsh-bridge-test--view-cache (list cached-7 older-5) 3)))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (cons 200 (dsh-bridge-test--turns-response-alist
                            (list new-8 grown-7) 3 t)))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        ;; Cycling on turn 5, at index 1 of the 2-turn cache.
        (setq-local dsh-bridge--view-turn 5)
        (setq-local dsh-bridge--view-turn-index 1)
        (dsh-bridge--view-turns-cache-refresh "s1")
        ;; The merged list is [8, 7, 5]; turn 5 recomputes to index 2.
        (should (eq dsh-bridge--view-turn-index 2))
        (should (string-match-p " (3/3)" (format "%s" header-line-format))))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-turns-cache-fetch-stale-since-replaces-fully ()
  "An incremental response whose oldest turn is not the `since' sent (a
stale-since corner) is treated as full: the entry is replaced, never merged."
  (let* ((cached-7 (dsh-bridge-test--view-turn 7 7000000
                    (list (dsh-bridge-test--view-segment "old" 7001000 1))))
         (older-5 (dsh-bridge-test--view-turn 5 5000000
                   (list (dsh-bridge-test--view-segment "older" 5001000 1))))
         (replacement (dsh-bridge-test--view-turn 9 9000000
                       (list (dsh-bridge-test--view-segment "replacement"
                                                             9001000 1))))
         (dsh-bridge--turns-cache
          (dsh-bridge-test--view-cache (list cached-7 older-5) 3)))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (cons 200 (dsh-bridge-test--turns-response-alist
                            (list replacement) 3 t)))))
      (dsh-bridge--turns-cache-fetch "s1")
      ;; Oldest returned turn 9 != since 7: full replace, no merge.
      (should (equal (dsh-bridge--turns-cache-turns "s1") (list replacement))))))

(ert-deftest dsh-bridge-turns-cache-fetch-full-replaces-on-full-response ()
  "A non-incremental response (the host fell back, e.g. an epoch mismatch)
replaces the whole entry and records the new epoch."
  (let* ((cached-7 (dsh-bridge-test--view-turn 7 7000000
                    (list (dsh-bridge-test--view-segment "old" 7001000 1))))
         (older-5 (dsh-bridge-test--view-turn 5 5000000
                   (list (dsh-bridge-test--view-segment "older" 5001000 1))))
         (fresh (dsh-bridge-test--view-turn 11 11000000
                 (list (dsh-bridge-test--view-segment "fresh history"
                                                       11001000 1))))
         (dsh-bridge--turns-cache
          (dsh-bridge-test--view-cache (list cached-7 older-5) 3)))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (cons 200 (dsh-bridge-test--turns-response-alist
                            (list fresh) 9 nil)))))
      (dsh-bridge--view-turns-cache-refresh "s1")
      (should (equal (dsh-bridge--turns-cache-turns "s1") (list fresh)))
      (should (equal (dsh-bridge--turns-cache-epoch "s1") 9)))))

(ert-deftest dsh-bridge-turns-cache-known-empty-repopulates ()
  "A known-empty entry (full compaction) is authoritative until a forced
refresh returns content again — the epoch is kept and then updated."
  (let* ((cached-7 (dsh-bridge-test--view-turn 7 7000000
                    (list (dsh-bridge-test--view-segment "old" 7001000 1))))
         (older-5 (dsh-bridge-test--view-turn 5 5000000
                   (list (dsh-bridge-test--view-segment "older" 5001000 1))))
         (fresh-8 (dsh-bridge-test--view-turn 8 8000000
                   (list (dsh-bridge-test--view-segment "fresh" 8001000 1))))
         (calls 0)
         (dsh-bridge--turns-cache
          (dsh-bridge-test--view-cache (list cached-7 older-5) 3)))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_method _path _payload)
                 (setq calls (1+ calls))
                 (if (= calls 1)
                     ;; Explicit empty list at epoch 4: evict to known-empty.
                     (cons 200 (list (cons 'sessionId "s1") (cons 'turns nil)
                                     (cons 'epoch 4) (cons 'incremental nil)))
                   ;; Forced refresh with content again, epoch 5.
                   (cons 200 (dsh-bridge-test--turns-response-alist
                              (list fresh-8) 5 nil))))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        ;; First refresh: the entry survives as known-empty at epoch 4.
        (dsh-bridge--view-turns-cache-refresh "s1")
        (should (assoc "s1" dsh-bridge--turns-cache))
        (should (null (dsh-bridge--turns-cache-turns "s1")))
        (should (equal (dsh-bridge--turns-cache-epoch "s1") 4))
        ;; The view has no turns to navigate; position shows nothing.
        (should (equal (dsh-bridge--view-turn-position) ""))
        ;; A forced refresh refetches and repopulates.
        (dsh-bridge--view-turns-cache-refresh "s1")
        (should (equal (dsh-bridge--turns-cache-turns "s1") (list fresh-8)))
        (should (equal (dsh-bridge--turns-cache-epoch "s1") 5)))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-next-reply-from-rest-steps-to-newer ()
  "M-n at rest refreshes the turn list and steps to a newer turn when one has
arrived (new turns land at the head); landing on the newest resumes following."
  (let* ((newest-open (dsh-bridge-test--view-turn 40 4000000
                       (list (dsh-bridge-test--view-segment "brand-new" 4001000 1))))
         (new-turns (cons newest-open dsh-bridge-test--view-turns))
         (stale-turns (list (nth 0 dsh-bridge-test--view-turns)
                            (nth 1 dsh-bridge-test--view-turns)))
         (shown (nth 0 dsh-bridge-test--view-turns))
         (dsh-bridge--turns-cache (dsh-bridge-test--view-cache stale-turns)))
    (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (dsh-bridge-test--view-turn-render shown))
        (setq-local dsh-bridge--view-turn (alist-get 'turn shown)))
      (setq-local dsh-bridge--view-turn-index nil)
      (cl-letf (((symbol-function 'dsh-bridge--request)
                 (lambda (_method _path _payload)
                   (cons 200 (list (cons 'sessionId "s1")
                                   (cons 'turns new-turns))))))
        (dsh-bridge-view-next-reply))
      (should (equal (buffer-string) (dsh-bridge-test--view-turn-render newest-open)))
      ;; Reaching the new newest resumes following rather than pinning it.
      (should (eq dsh-bridge--view-follow t))
      (should (null dsh-bridge--view-turn-index)))
    (kill-buffer "*dsh-bridge-output*")))

(ert-deftest dsh-bridge-view-next-reply-from-rest-at-newest ()
  "M-n at rest when the shown turn is still the newest enters turn-following
state (\"turn 0\") and announces it."
  (let* ((newest (nth 0 dsh-bridge-test--view-turns))
         (dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns))
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
          (insert (dsh-bridge-test--view-turn-render newest))
          (setq-local dsh-bridge--view-turn (alist-get 'turn newest)))
        (setq-local dsh-bridge--view-turn-index nil)
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) (dsh-bridge-test--view-turn-render newest)))
        (should (eq dsh-bridge--view-follow t))
        (should (null dsh-bridge--view-turn-index))
        (should (string-match-p "following the newest turn" msg)))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-next-reply-from-rest-not-found ()
  "M-n at rest reports no newer turns when the shown content has no turn
identity (e.g. a pushed message that is not a committed turn segment), and
leaves the buffer and index untouched."
  (let ((dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns))
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
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) "a pushed message"))
        (should (null dsh-bridge--view-turn-index))
        (should (string-match-p "no newer turns" msg)))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-next-reply-auto-follows-at-newest ()
  "M-n onto the newest turn resumes following directly: cycling up from the
second-newest turn needs no extra M-n (the pinned `(1/X)' stop is gone)."
  (let* ((dsh-bridge--turns-cache
          (dsh-bridge-test--view-cache dsh-bridge-test--view-turns))
         (dsh-bridge-view-follow-at-newest t))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_m _p _pl)
                 (cons 200 (list (cons 'sessionId "s1")
                                 (cons 'turns dsh-bridge-test--view-turns))))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert dsh-bridge-test--view-middle-rendered))
        ;; Mid-cycle at index 1 (the newest-but-one turn): M-n follows.
        (setq-local dsh-bridge--view-turn 20)
        (setq-local dsh-bridge--view-turn-index 1)
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) dsh-bridge-test--view-newest-rendered))
        (should (eq dsh-bridge--view-follow t))
        (should (null dsh-bridge--view-turn-index)))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-next-reply-follow-at-newest-off-pins ()
  "With `dsh-bridge-view-follow-at-newest' nil, M-n onto the newest turn pins
it at `(1/X)' (index 0, not following); a further M-n turns following on."
  (let* ((dsh-bridge--turns-cache
          (dsh-bridge-test--view-cache dsh-bridge-test--view-turns))
         (dsh-bridge-view-follow-at-newest nil))
    (cl-letf (((symbol-function 'dsh-bridge--request)
               (lambda (_m _p _pl)
                 (cons 200 (list (cons 'sessionId "s1")
                                 (cons 'turns dsh-bridge-test--view-turns))))))
      (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
        (dsh-bridge-view-mode)
        (setq-local dsh-bridge--view-content-session "s1")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert dsh-bridge-test--view-middle-rendered))
        (setq-local dsh-bridge--view-turn 20)
        (setq-local dsh-bridge--view-turn-index 1)
        ;; Pinned at the newest: shown at (1/X), not following.
        (dsh-bridge-view-next-reply)
        (should (equal (buffer-string) dsh-bridge-test--view-newest-rendered))
        (should (equal dsh-bridge--view-turn-index 0))
        (should-not dsh-bridge--view-follow)
        ;; One more M-n turns following on.
        (dsh-bridge-view-next-reply)
        (should (eq dsh-bridge--view-follow t))
        (should (null dsh-bridge--view-turn-index)))
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
         (dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns))
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
        (should (equal (buffer-string) (dsh-bridge-test--view-turn-render newest)))))
    (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-follow-navigation-interactions ()
  "M-p leaves turn-following (stepping older); M-n while following is a no-op."
  (let* ((newest (nth 0 dsh-bridge-test--view-turns))
         (middle (nth 1 dsh-bridge-test--view-turns))
         (dsh-bridge--turns-cache (dsh-bridge-test--view-cache dsh-bridge-test--view-turns))
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
          (insert (dsh-bridge-test--view-turn-render newest))
          (setq-local dsh-bridge--view-turn (alist-get 'turn newest)))
        ;; M-n while following is a no-op.
        (dsh-bridge-view-next-reply)
        (should (eq dsh-bridge--view-follow t))
        (should (string-match-p "already following" msg))
        ;; M-p leaves follow and steps one older.
        (dsh-bridge-view-previous-reply)
        (should-not dsh-bridge--view-follow)
        (should (equal (buffer-string) (dsh-bridge-test--view-turn-render middle)))))
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
      (should (string-match-p "is running..." msg))
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
    (should (string-match-p "prompt sent" msg))))

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
  (let* ((dsh-bridge--turns-cache nil)
         (before (dsh-bridge-test--view-turn 7 7000000
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
        (should (equal (buffer-string) (dsh-bridge-test--view-turn-render after)))))))

(ert-deftest dsh-bridge-replies-changed-refills-all-following-views ()
  "Every DSH-View buffer following the session is refilled, not just one; a
non-following view of the same session is left alone.  The frame fetches the
turn list once for all views (the shared cache refresh), never once per
following view."
  (let* ((dsh-bridge--turns-cache nil)
         (before (dsh-bridge-test--view-turn 7 7000000
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
        (should (equal (buffer-string) (dsh-bridge-test--view-turn-render after))))
      (with-current-buffer "*dsh-bridge-output-2*"
        (should (equal (buffer-string) (dsh-bridge-test--view-turn-render after))))
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
        (dsh-bridge--turns-cache nil)
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
          (should (equal (buffer-string) "new")))))
    (dolist (b '("*dsh-bridge-output*" "*dsh-bridge-output-2*"))
      (when (buffer-live-p (get-buffer b))
        (kill-buffer b)))))

(ert-deftest dsh-bridge-turn-complete-refetch-waiting-newer ()
  "A view waiting on a just-sent prompt accepts the completion refetch's
content when the completed turn is genuinely newer than the abandoned one:
the reply replaces the `(running...)' placeholder and the waiting state ends."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--turns-cache nil)
        (calls 0))
    (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (dsh-bridge--view-waiting-fill "s1" 2)
      (should (equal (buffer-string) dsh-bridge--view-running-placeholder)))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (setq calls (1+ calls))
                 (funcall callback nil
                          (concat "{\"sessionId\":\"s1\",\"turns\":["
                                  "{\"turn\":3,\"startedAt\":3000000,"
                                  "\"endedAt\":3009000,\"reason\":\"completed\","
                                  "\"segments\":[{\"text\":\"the reply\","
                                  "\"time\":3001000,\"step\":1}]}]}")
                          200)))
              ((symbol-function 'dsh-bridge--status-set) #'ignore)
              ((symbol-function 'dsh-bridge--apply-session-directory) #'ignore))
      (dsh-bridge--turn-complete-refetch "s1")
      (should (= calls 1))
      (with-current-buffer "*dsh-bridge-output*"
        ;; Turn 3 is newer than the abandoned turn 2: accepted.
        (should (equal (buffer-string) "the reply"))
        (should (equal dsh-bridge--view-turn 3))
        (should (null dsh-bridge--view-waiting))))
    (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-turn-complete-refetch-waiting-textless-blanks ()
  "When the sent turn completes without producing any newer content, the
completion refetch clears the waiting view to blank (idle) rather than
resurrecting the abandoned turn: `(running...)' gives way to nothing."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--turns-cache nil))
    (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (dsh-bridge--view-waiting-fill "s1" 2))
    ;; The response still names turn 2 as newest: no newer content was ever
    ;; committed, so the turn was textless.
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_method _path _payload callback)
                 (funcall callback nil
                          (concat "{\"sessionId\":\"s1\",\"turns\":["
                                  "{\"turn\":2,\"startedAt\":2000000,"
                                  "\"endedAt\":2009000,\"reason\":\"completed\","
                                  "\"segments\":[{\"text\":\"old\","
                                  "\"time\":2001000,\"step\":1}]}]}")
                          200)))
              ((symbol-function 'dsh-bridge--status-set) #'ignore)
              ((symbol-function 'dsh-bridge--apply-session-directory) #'ignore))
      (dsh-bridge--turn-complete-refetch "s1"))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal (buffer-string) ""))
      (should (null dsh-bridge--view-turn))
      (should (null dsh-bridge--view-waiting)))
    (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
      (kill-buffer "*dsh-bridge-output*"))))

(ert-deftest dsh-bridge-view-follow-refill-waiting-gate ()
  "A waiting view is refilled by `replies-changed' only with a turn newer than
the abandoned one: a still-running abandoned turn (or nothing newer) keeps the
`(running...)' placeholder and the waiting state; a newer turn replaces it."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--turns-cache nil))
    ;; Case 1: the cache's newest is still the abandoned turn 2 (open, no new
    ;; content committed): the placeholder survives the refill.
    (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (dsh-bridge--view-waiting-fill "s1" 2))
    (let ((dsh-bridge--turns-cache
           (dsh-bridge-test--view-cache
            (list (dsh-bridge-test--view-turn 2 2000000
                    (list (dsh-bridge-test--view-segment "old" 2001000 1)))))))
      (dsh-bridge--view-follow-refill "s1"))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal (buffer-string) dsh-bridge--view-running-placeholder))
      (should (equal dsh-bridge--view-waiting 2)))
    ;; Case 2: a newer turn (3) has started producing: it replaces the
    ;; placeholder and clears the waiting state.
    (let ((dsh-bridge--turns-cache
           (dsh-bridge-test--view-cache
            (list (dsh-bridge-test--view-turn 3 3000000
                    (list (dsh-bridge-test--view-segment "fresh" 3001000 1)))))))
      (dsh-bridge--view-follow-refill "s1"))
    (with-current-buffer "*dsh-bridge-output*"
      (should (equal (buffer-string) "fresh\n\n(continuing...)"))
      (should (null dsh-bridge--view-waiting)))
    (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
      (kill-buffer "*dsh-bridge-output*"))))

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
      (should (string-match-p "no longer pending" (buffer-string))))
    (when (buffer-live-p (get-buffer "*dsh-bridge-output*"))
      (kill-buffer "*dsh-bridge-output*"))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))))

(ert-deftest dsh-bridge-ask-user-resolved ()
  "A resolved frame retires the pending question and banners the question buffer.
The banner stands on its own line, and the resolved buffer no longer claims the
session is waiting for an answer."
  (let ((dsh-bridge--pending-questions nil)
        (dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    (cl-letf (((symbol-function 'message) (lambda (&rest _) nil))
              ((symbol-function 'dsh-bridge--status-event-render) #'ignore))
      (dsh-bridge--ask-user-arrive "s1" "q1" '(( (id . "q1") (question . "Go?") )))
      (dsh-bridge--ask-user-resolved "s1" "q1" "answered"))
    (should-not (dsh-bridge--session-awaiting-p "s1"))
    (with-current-buffer (get-buffer "*dsh-bridge-question: T*")
      (should dsh-bridge--question-dead)
      (should (string-match-p
               "\\`This question was answered elsewhere (not in this buffer)\\.\n"
               (buffer-string)))
      (should-not (string-match-p "is waiting for your answer" (buffer-string))))
    (when (buffer-live-p (get-buffer "*dsh-bridge-question: T*"))
      (kill-buffer "*dsh-bridge-question: T*"))))

(ert-deftest dsh-bridge-ask-user-resolved-after-local-submit ()
  "A resolved frame that outruns the submit POST's own response banners the
buffer with what this buffer did — the answer was sent here, not elsewhere —
and the late callback settling afterwards does not banner a second time."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (pending-cb nil))
    (with-current-buffer
        (dsh-bridge--question-buffer "s1" "q1"
          '(( (id . "q1") (question . "Go?") (options . (((label . "Yes")))) )))
      (goto-char (point-min))
      (re-search-forward "1\\. Yes")
      (goto-char (line-beginning-position))
      (dsh-bridge--question-toggle-at-point)
      ;; The POST is in flight: capture its callback without calling it, the
      ;; way a slow response leaves it while the SSE frame arrives.
      (cl-letf (((symbol-function 'dsh-bridge--call)
                 (lambda (_m _p _payload cb) (setq pending-cb cb))))
        (dsh-bridge--question-submit))
      (should (functionp pending-cb))
      ;; The host's resolved frame lands before the response does.
      (dsh-bridge--ask-user-resolved "s1" "q1" "answered")
      (should dsh-bridge--question-dead)
      (should-not (string-match-p "answered elsewhere" (buffer-string)))
      (should (string-match-p "\\`Your answer was sent\\.\n" (buffer-string)))
      (should-not (string-match-p "is waiting for your answer" (buffer-string)))
      ;; A re-render of the resolved buffer keeps the banner and the header out.
      (dsh-bridge--question-rerender-at-point)
      (should (string-match-p "\\`Your answer was sent\\.\n" (buffer-string)))
      (should-not (string-match-p "is waiting for your answer" (buffer-string)))
      ;; The response callback settling afterwards must not banner again.
      (funcall pending-cb nil "{\"accepted\":true}" 200)
      (should (equal (how-many "Your answer was sent\\." (point-min) (point-max)) 1)))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))))

(defun dsh-bridge-test--pending-ask (session question)
  "A `dsh-bridge--pending-questions' registry with one QUESTION for SESSION."
  (list (cons session
              (list (cons "q1"
                          (list (list (cons 'id "q1") (cons 'question question))))))))

(ert-deftest dsh-bridge-view-awaiting-tail ()
  "While SESSION-ID has a pending ask-user question, a running turn's tail
reads as the awaiting note instead of `(continuing...)', quoting the question
and naming the live `dsh-bridge-answer' binding; completion drops the tail."
  (let* ((open (dsh-bridge-test--view-turn 7 7000000
                (list (dsh-bridge-test--view-segment "progress" 7001000 1))))
         (done (dsh-bridge-test--view-turn 7 7000000
                (list (dsh-bridge-test--view-segment "progress" 7001000 1))
                8000000 "completed")))
    (with-temp-buffer
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (let ((dsh-bridge--pending-questions
             (dsh-bridge-test--pending-ask "s1" "Approve this plan?")))
        (let ((rendered (dsh-bridge-test--view-turn-render open "s1")))
          (should (string-prefix-p "progress\n\n" rendered))
          (should (string-match-p "Awaiting your response:" rendered))
          (should (string-match-p (regexp-quote "Approve this plan?") rendered))
          (should (string-match-p
                   (concat "press " (regexp-quote (dsh-bridge--view-answer-key)))
                   rendered))
          (should-not (string-match-p "(continuing\\.\\.\\.)" rendered))
          (should (text-property-any 0 (length rendered)
                                     'dsh-bridge-awaiting t rendered)))
        ;; The same turn without a pending ask keeps the continuing marker.
        (let ((dsh-bridge--pending-questions nil))
          (should (string-match-p "(continuing\\.\\.\\.)"
                                  (dsh-bridge-test--view-turn-render open "s1")))))
      ;; A completed turn shows no tail even while a question is pending.
      (let ((dsh-bridge--pending-questions
             (dsh-bridge-test--pending-ask "s1" "Approve this plan?")))
        (should (equal (dsh-bridge-test--view-turn-render done "s1") "progress"))))))

(ert-deftest dsh-bridge-view-awaiting-note-variants ()
  "The awaiting note leads with the question text, its count, or a fallback,
and quotes the answer key from the real `dsh-bridge-answer' binding."
  (with-temp-buffer
    (dsh-bridge-view-mode)
    (setq-local dsh-bridge--view-content-session "s1")
    ;; Single question: quoted text plus the action.
    (let ((dsh-bridge--pending-questions
           (dsh-bridge-test--pending-ask "s1" "Approve this plan?")))
      (should (equal (dsh-bridge--view-awaiting-note "s1")
                     (concat "(Awaiting your response: “Approve this plan?” — "
                             "press " (dsh-bridge--view-answer-key)
                             " to view and answer)"))))
    ;; Several questions under one ask: the count tells the user what to expect.
    (let ((dsh-bridge--pending-questions
           (list (cons "s1"
                       (list (cons "q1"
                                   (list (list (cons 'id "q1") (cons 'question "One?"))
                                         (list (cons 'id "q2") (cons 'question "Two?")))))))))
      (should (string-match-p "Awaiting your response: 2 questions"
                              (dsh-bridge--view-awaiting-note "s1"))))
    ;; Whitespace-only question text: a plain invitation.
    (let ((dsh-bridge--pending-questions
           (dsh-bridge-test--pending-ask "s1" "   ")))
      (should (string-match-p "view the question"
                              (dsh-bridge--view-awaiting-note "s1"))))))

(ert-deftest dsh-bridge-view-await-question-text-normalizes ()
  "Question text for the note is single-line, free of double quotes, and
truncated to about 72 columns."
  (should (equal (dsh-bridge--view-await-question-text "say \"hi\"\nthere")
                 "say hi there"))
  (should (equal (dsh-bridge--view-await-question-text
                  (make-string 200 ?x))
                 (concat (make-string 69 ?x) "..."))))

(ert-deftest dsh-bridge-view-awaiting-ask-frames-refresh-tail ()
  "An ask-user frame flips a following view's running marker to the awaiting
note; its resolution flips it back to `(continuing...)'."
  (when (get-buffer "*dsh-bridge-sessions*")
    (kill-buffer "*dsh-bridge-sessions*"))
  (when (get-buffer "*dsh-bridge-output*")
    (kill-buffer "*dsh-bridge-output*"))
  (let* ((open (dsh-bridge-test--view-turn 7 7000000
                (list (dsh-bridge-test--view-segment "progress" 7001000 1))))
         (dsh-bridge--turns-cache (dsh-bridge-test--view-cache (list open)))
         (dsh-bridge--pending-questions nil)
         (dsh-bridge--session-status nil))
    (with-current-buffer (get-buffer-create "*dsh-bridge-output*")
      (dsh-bridge-view-mode)
      (setq-local dsh-bridge--view-content-session "s1")
      (setq-local dsh-bridge--view-follow t)
      (dsh-bridge--view-fill "s1" open nil nil t)
      (should (string-match-p "(continuing\\.\\.\\.)" (buffer-string))))
    (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
      (dsh-bridge--notification-handle-events
       '(((kind . "ask-user") (sessionId . "s1") (questionId . "q1")
          (questions . (((id . "q1") (question . "Approve this plan?")))))))
      (with-current-buffer "*dsh-bridge-output*"
        (should (string-match-p "Awaiting your response:" (buffer-string)))
        (should-not (string-match-p "(continuing\\.\\.\\.)" (buffer-string))))
      (dsh-bridge--notification-handle-events
       '(((kind . "ask-user-resolved") (sessionId . "s1") (questionId . "q1")
          (outcome . "answered"))))
      (with-current-buffer "*dsh-bridge-output*"
        (should (string-match-p "(continuing\\.\\.\\.)" (buffer-string)))))
    (kill-buffer "*dsh-bridge-output*")
    (when (buffer-live-p (get-buffer "*dsh-bridge-question: s1*"))
      (kill-buffer "*dsh-bridge-question: s1*"))))

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
the apiproxy validates (regression: plist-style lists encode as junk JSON).  An
accepted submit banners the buffer as sent and buries it, like sending from
DSH-Prompt."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (posted nil)
        (buried nil))
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
                   (funcall cb nil "{\"accepted\":true}" 200)))
                ((symbol-function 'bury-buffer)
                 (lambda (&optional buffer) (setq buried (or buffer (current-buffer))))))
        (dsh-bridge--question-submit))
      (should (equal (alist-get 'questionId posted) "q1"))
      (should (equal (alist-get 'sessionId posted) "s1"))
      (should (equal (json-encode (list (cons 'answers (alist-get 'answers posted))))
                     "{\"answers\":[{\"id\":\"q1\",\"selected\":[\"Yes\"]}]}"))
      ;; An accepted submit retires the buffer and buries it.
      (should dsh-bridge--question-dead)
      (should (eq buried (current-buffer)))
      (should (string-match-p "Your answer was sent\\." (buffer-string))))
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

(ert-deftest dsh-bridge-question-render-explains-keys ()
  "The question buffer itself explains how to work it — which key selects an
option, where a custom answer is typed, and how to submit — instead of leaving
that to the mode docstring."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    (with-current-buffer
        (dsh-bridge--question-buffer "s1" "q1"
          '(( (id . "q1") (question . "Go?") (options . (((label . "Yes")))) )))
      (should (string-match-p "Mark an option with RET" (buffer-string)))
      (should (string-match-p "read in the minibuffer" (buffer-string)))
      (should (string-match-p "Session \"T\" is waiting for your answer"
                              (buffer-string)))
      (should (string-match-p "C-c C-c submits" (buffer-string)))
      (should (string-match-p "C-c C-k declines" (buffer-string))))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))))

(ert-deftest dsh-bridge-question-custom-row-is-an-action ()
  "The custom-answer row reads as an action, not a checkbox: it carries no
`[ ]' bracket (which would suggest it must be marked before typing), says the
text is read via RET/`c', and once answered shows the stored text together with
how to edit or clear it."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    (with-current-buffer
        (dsh-bridge--question-buffer "s1" "q1"
          '(( (id . "q1") (question . "Go?") (options . (((label . "Yes")))) )))
      (should (string-match-p "^      c\\. Type a custom answer" (buffer-string)))
      (should (string-match-p "RET here or `c'" (buffer-string)))
      (should-not (string-match-p "\\[.\\] c\\." (buffer-string)))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "because reasons")))
        (dsh-bridge--question-custom-answer "q1"))
      (should (string-match-p "Custom answer: because reasons" (buffer-string)))
      (should (string-match-p "RET to edit; empty clears" (buffer-string)))
      (should-not (string-match-p "\\[.\\] c\\." (buffer-string))))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))))

(ert-deftest dsh-bridge-question-fontification ()
  "The ask-user buffer faces its structure: heading, question text, furniture,
option labels, the selected mark, and the skip suffix.  Each face is set as
both `face' and `font-lock-face' so it shows with font-lock off and survives a
font-lock pass."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    (with-current-buffer
        (dsh-bridge--question-buffer "s1" "q1"
          '(( (id . "q1") (header . "Group") (question . "Go?")
              (options . (((label . "Yes") (description . "sure"))
                          ((label . "No")))) )))
      (dolist (face '(dsh-bridge-question-heading-face
                      dsh-bridge-question-text-face
                      dsh-bridge-question-furniture-face
                      dsh-bridge-question-option-face))
        (should (text-property-any (point-min) (point-max) 'face face))
        (should (text-property-any (point-min) (point-max) 'font-lock-face face)))
      ;; Marking an option faces its box and label as selected.
      (goto-char (point-min))
      (re-search-forward "1\\. Yes")
      (goto-char (line-beginning-position))
      (dsh-bridge--question-toggle-at-point)
      (should (string-match-p "\\[x\\] 1\\. Yes" (buffer-string)))
      (goto-char (point-min))
      (should (re-search-forward "\\[x\\]" nil t))
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'dsh-bridge-question-selected-face))
      ;; Skipping faces the suffix.
      (dsh-bridge--question-skip)
      (goto-char (point-min))
      (should (re-search-forward "— skipped" nil t))
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'dsh-bridge-question-skip-face)))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))))

(ert-deftest dsh-bridge-question-banner-faces ()
  "The resolution banner takes the face matching its outcome: sent, cancelled,
or elsewhere/stale."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t))))
        (cases '((sent . dsh-bridge-question-banner-sent-face)
                 (cancelled . dsh-bridge-question-banner-cancelled-face)
                 (elsewhere . dsh-bridge-question-banner-elsewhere-face)
                 (stale . dsh-bridge-question-banner-elsewhere-face))))
    (dolist (case cases)
      (let* ((question-id (format "q-%s" (car case)))
             (buffer (dsh-bridge--question-buffer
                      "s1" question-id '(( (id . "q1") (question . "Go?") )))))
        (with-current-buffer buffer
          (dsh-bridge--question-mark-resolved question-id "A banner." (car case))
          (should dsh-bridge--question-dead)
          (should (eq (get-text-property (point-min) 'face) (cdr case))))
        (kill-buffer buffer)))))

(ert-deftest dsh-bridge-question-detail-fontification ()
  "The `detail' block carries the detail face, and — when markdown-mode is
installed — is fontified as Markdown over that block face."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    (with-current-buffer
        (dsh-bridge--question-buffer "s1" "q1"
          '(( (id . "q1") (question . "Execute?")
              (detail . "## Plan\n\nSome **bold** step")
              (intent . ((kind . "plan-review") (approve . "Approve")))
              (options . (((label . "Approve")))) )))
      (should (text-property-any (point-min) (point-max)
                                 'face 'dsh-bridge-question-detail-face))
      (when (require 'markdown-mode nil t)
        (goto-char (point-min))
        (should (re-search-forward "^## Plan" nil t))
        ;; Markdown's own heading face wins over the block fallback.
        (should-not (eq (get-text-property (match-beginning 0) 'face)
                        'dsh-bridge-question-detail-face))))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))))

(ert-deftest dsh-bridge-question-row-affordance ()
  "Option and custom rows are mouse targets: `mouse-face', a `help-echo', and a
keymap whose mouse-1 binding toggles the row under the click."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "T") (live . t)))))
    (with-current-buffer
        (dsh-bridge--question-buffer "s1" "q1"
          '(( (id . "q1") (question . "Go?")
              (options . (((label . "Yes")) ((label . "No")))) )))
      (goto-char (point-min))
      (should (re-search-forward "^  \\[ \\] 1\\. Yes" nil t))
      (let ((row (line-beginning-position)))
        (should (eq (get-text-property row 'mouse-face) 'highlight))
        (should (string-match-p "toggle" (get-text-property row 'help-echo)))
        (should (eq (lookup-key (get-text-property row 'keymap) [mouse-1])
                    #'dsh-bridge--question-click))
        ;; A synthetic click event at the row toggles it.  The posn window must
        ;; actually show this buffer, as it would for a real click.
        (save-window-excursion
          (set-window-buffer (selected-window) (current-buffer))
          (dsh-bridge--question-click
           (list 'mouse-1 (list (selected-window) row)))))
      (should (equal (cdr (assoc "q1" dsh-bridge--question-selection)) '("Yes"))))
    (when (dsh-bridge--question-find-buffer "q1")
      (kill-buffer (dsh-bridge--question-find-buffer "q1")))))

;;; Session report (DSH-Describe)

(defun dsh-bridge-test--describe-report (id &optional extra)
  "A canned `/session' report alist for ID, with EXTRA taking precedence."
  (append
   extra
   (list (cons 'sessionId id)
         (cons 'live t)
         (cons 'running nil)
         (cons 'basis "observation")
         (cons 'missing nil)
         (cons 'title (format "Title %s" id))
         (cons 'cwd "/tmp")
         (cons 'workspace "tmp")
         (cons 'createdAt 1700000000000)
         (cons 'lastActive 1700000100000)
         (cons 'lastPromptAt 1700000050000)
         (cons 'isSeeded nil)
         (cons 'agentPreset "default")
         (cons 'model (list (cons 'provider "p") (cons 'model "m")))
         (cons 'modelName "Model M")
         (cons 'permissions
               (list (cons 'currentValue "workspace-write")
                     (cons 'options
                           (list (list (cons 'value "workspace-write")
                                       (cons 'name "Workspace write")
                                       (cons 'description "Can edit."))))))
         (cons 'stats
               (list (cons 'turns 12) (cons 'steps 48)
                     (cons 'llmMs 133400) (cons 'toolMs 18200)
                     (cons 'ttftMs 35728) (cons 'ttftSteps 44)
                     (cons 'decodeMs 104000) (cons 'decodeTokens 12345)))
         (cons 'tokens
               (list (cons 'uncachedInputTokens 45678) (cons 'outputTokens 12345)
                     (cons 'cacheReadTokens 1234567) (cons 'cacheWriteTokens 23456)))
         (cons 'context
               (list (cons 'pressureTokens 120000) (cons 'projectedTokens 123456)
                     (cons 'contextWindow 200000)))
         (cons 'breakdown
               (list (cons 'systemTokens 3000) (cons 'toolsTokens 12000)
                     (cons 'messageTokens 108000))))))

(defmacro dsh-bridge-test--with-describe (extra &rest body)
  "Run BODY with `dsh-bridge--request' returning a canned report plus EXTRA.
The report echoes the id named in the request path, so following a
parent-session link describes the parent."
  (declare (indent 1))
  `(let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "cached") (live . t)
                                        (cwd . "/tmp")))))
     (unwind-protect
         (cl-letf (((symbol-function 'dsh-bridge--request)
                    (lambda (_method path &rest _)
                      (let ((id (if (string-match "sessionId=\\([^&]+\\)" path)
                                    (match-string 1 path)
                                  "s1")))
                        (cons 200 (dsh-bridge-test--describe-report id ,extra))))))
           ,@body)
       (when (get-buffer dsh-bridge-describe-buffer-name)
         (kill-buffer dsh-bridge-describe-buffer-name)))))

(ert-deftest dsh-bridge-describe-mode-basics ()
  "DSH-Describe is a read-only help-mode buffer with the bridge keys."
  (with-temp-buffer
    (dsh-bridge-describe-mode)
    (should buffer-read-only)
    (should (derived-mode-p 'help-mode))
    (should (eq major-mode 'dsh-bridge-describe-mode)))
  (should (eq (lookup-key dsh-bridge-describe-mode-map (kbd "w"))
              #'dsh-bridge--describe-copy-id))
  (should (eq (lookup-key dsh-bridge-describe-mode-map (kbd "f"))
              #'dsh-bridge--describe-open-view))
  (should (eq (lookup-key dsh-bridge-describe-mode-map (kbd "o"))
              #'dsh-bridge--describe-open-prompt))
  (should (eq (lookup-key dsh-bridge-describe-mode-map (kbd "D")) #'revert-buffer))
  ;; Help mode's own keys remain reachable.
  (should (eq (lookup-key dsh-bridge-describe-mode-map (kbd "l")) #'help-go-back))
  (should (eq (lookup-key dsh-bridge-describe-mode-map (kbd "r")) #'help-go-forward)))

(ert-deftest dsh-bridge-describe-session-renders-report ()
  "The report renders the identity, stats, tokens, and context sections."
  (dsh-bridge-test--with-describe nil
    (dsh-bridge-describe-session "s1")
    (with-current-buffer dsh-bridge-describe-buffer-name
      (should (derived-mode-p 'help-mode))
      (should buffer-read-only)
      (should (equal dsh-bridge--describe-session "s1"))
      (let ((text (buffer-string)))
        (should (string-match-p "DSH session Title s1" text))
        (should (string-match-p "Turns / steps\\s-+12 / 48" text))
        (should (string-match-p "2m 13\\.4s" text))
        (should (string-match-p "Cache hit\\s-+96\\.4%" text))
        (should (string-match-p "118\\.7 tok/s" text))
        (should (string-match-p "Next request\\s-+123,456 / 200,000 (61\\.7%)" text))
        (should (string-match-p "Workspace write" text))
        (should (string-match-p "Model M" text)))
      ;; Sections are help-mode pages; the form feed stays in the buffer so
      ;; `n'/`p' page navigation works, but its `^L' glyph is display-hidden.
      (should (string-match-p "\f" (buffer-string)))
      (goto-char (point-min))
      (should (search-forward "\f" nil t))
      (should (equal (get-text-property (1- (point)) 'display) ""))
      ;; The delimiter's own line is the single blank line between sections:
      ;; exactly one newline separates the previous row from the form feed.
      (should (string-match-p "\n\f\n" (buffer-string)))
      (should-not (string-match-p "\n\n\f" (buffer-string)))
      (should (next-button (point-min))))))

(ert-deftest dsh-bridge-describe-session-buffer-session ()
  "The describe buffer's affinity is the described session."
  (dsh-bridge-test--with-describe nil
    (dsh-bridge-describe-session "s1")
    (with-current-buffer dsh-bridge-describe-buffer-name
      (should (equal (dsh-bridge--buffer-session) "s1"))
      (should (equal (dsh-bridge--effective-session) "s1")))))

(ert-deftest dsh-bridge-describe-session-id-button-copies ()
  "The Id row's button copies the raw session id."
  (dsh-bridge-test--with-describe nil
    (dsh-bridge-describe-session "s1")
    (with-current-buffer dsh-bridge-describe-buffer-name
      (goto-char (point-min))
      (search-forward "Id")
      (search-forward "s1")
      (let ((button (button-at (match-beginning 0))))
        (should button)
        (push-button (match-beginning 0))
        (should (equal (car kill-ring) "s1"))))))

(ert-deftest dsh-bridge-describe-session-parent-xref-navigates ()
  "A parent-session xref describes the parent, and `l' returns."
  (dsh-bridge-test--with-describe '((parentSession . "parent"))
    (dsh-bridge-describe-session "s1")
    (with-current-buffer dsh-bridge-describe-buffer-name
      (goto-char (point-min))
      (search-forward "parent")
      (push-button (match-beginning 0))
      (should (equal dsh-bridge--describe-session "parent"))
      (help-go-back)
      (should (equal dsh-bridge--describe-session "s1")))))

(ert-deftest dsh-bridge-describe-session-leaves-help-buffer-alone ()
  "Rendering from a non-help buffer does not touch *Help*."
  (let ((help (get-buffer "*Help*"))
		(before (and (get-buffer "*Help*")
					 (with-current-buffer "*Help*" (buffer-string)))))
	(dsh-bridge-test--with-describe nil
	  (with-temp-buffer
		(dsh-bridge-describe-session "s1"))
	  (if help
		  (should (equal (with-current-buffer "*Help*" (buffer-string)) before))
		(should (not (get-buffer "*Help*")))))))

(ert-deftest dsh-bridge-describe-session-action-buttons-push-no-history ()
  "Action buttons act without entering the help xref history."
  (dsh-bridge-test--with-describe nil
	(dsh-bridge-describe-session "s1")
	(with-current-buffer dsh-bridge-describe-buffer-name
	  (let ((stack help-xref-stack)
			(item help-xref-stack-item))
		(goto-char (point-min))
		(search-forward "[Copy id]")
		(push-button (match-beginning 0))
		(should (equal (car kill-ring) "s1"))
		(should (eq help-xref-stack-item item))
		(should (equal help-xref-stack stack))))))

(ert-deftest dsh-bridge-describe-session-transport-failure-degrades ()
  "A transport failure names its own reason, not a duplicated label."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "cached title") (live . t)))))
	(unwind-protect
		(cl-letf (((symbol-function 'dsh-bridge--request)
				   (lambda (&rest _) (cons nil nil))))
		  (dsh-bridge-describe-session "s1")
		  (with-current-buffer dsh-bridge-describe-buffer-name
			(let ((text (buffer-string)))
			  (should (string-match-p
					   "Report unavailable: request failed or timed out" text))
			  (should (string-match-p "DSH session cached title" text)))))
	  (when (get-buffer dsh-bridge-describe-buffer-name)
		(kill-buffer dsh-bridge-describe-buffer-name)))))

(ert-deftest dsh-bridge-describe-session-failure-resolves-id-safely ()
  "The failure path unwraps the last-active cons and tolerates no id at all."
  (let ((dsh-bridge--sessions-cache nil)
		(dsh-bridge--last-resolved-active '("s9" . "last active")))
	(unwind-protect
		(cl-letf (((symbol-function 'dsh-bridge--request)
				   (lambda (&rest _) (cons nil nil))))
		  (dsh-bridge-describe-session)
		  (with-current-buffer dsh-bridge-describe-buffer-name
			(should (equal dsh-bridge--describe-session "s9"))
			(goto-char (point-min))
			(search-forward "Id")
			(search-forward "s9")
			(should (button-at (match-beginning 0)))))
	  (when (get-buffer dsh-bridge-describe-buffer-name)
		(kill-buffer dsh-bridge-describe-buffer-name))))
  (let ((dsh-bridge--sessions-cache nil)
		(dsh-bridge--last-resolved-active nil))
	(unwind-protect
		(cl-letf (((symbol-function 'dsh-bridge--request)
				   (lambda (&rest _) (cons nil nil))))
		  (dsh-bridge-describe-session)
		  (with-current-buffer dsh-bridge-describe-buffer-name
			(should (not dsh-bridge--describe-session))
			(should (string-match-p "\\((unknown)\\)" (buffer-string)))))
	  (when (get-buffer dsh-bridge-describe-buffer-name)
		(kill-buffer dsh-bridge-describe-buffer-name)))))

(ert-deftest dsh-bridge-describe-session-revert-refetches ()
  "`g' re-fetches the report and preserves point."
  (let ((dsh-bridge--sessions-cache nil)
        (titles '("first" "second")))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-bridge--request)
                   (lambda (&rest _)
                     (cons 200
                           (dsh-bridge-test--describe-report
                            "s1" (list (cons 'title (pop titles))))))))
          (dsh-bridge-describe-session "s1")
          (with-current-buffer dsh-bridge-describe-buffer-name
            (should (string-match-p "DSH session first" (buffer-string)))
            (goto-char (point-min))
            (forward-line 3)
            (let ((point (point)))
              (revert-buffer)
              (should (string-match-p "DSH session second" (buffer-string)))
              (should (= (point) point)))))
      (when (get-buffer dsh-bridge-describe-buffer-name)
        (kill-buffer dsh-bridge-describe-buffer-name)))))

(ert-deftest dsh-bridge-describe-session-failure-degrades ()
  "A failed request still opens the report with the cached facts and reason."
  (let ((dsh-bridge--sessions-cache '(((id . "s1") (title . "cached title") (live . t)))))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-bridge--request)
                   (lambda (&rest _) (cons 500 '((error . "boom"))))))
          (dsh-bridge-describe-session "s1")
          (with-current-buffer dsh-bridge-describe-buffer-name
            (let ((text (buffer-string)))
              (should (string-match-p "Report unavailable: HTTP 500: boom" text))
              (should (string-match-p "DSH session cached title" text))
              (should (string-match-p "(unavailable)" text)))))
      (when (get-buffer dsh-bridge-describe-buffer-name)
        (kill-buffer dsh-bridge-describe-buffer-name)))))

(ert-deftest dsh-bridge-describe-session-uses-effective-session ()
  "Called from a DSH-View buffer, the report targets that buffer's session."
  (let ((dsh-bridge--sessions-cache '(((id . "s9") (title . "view session") (live . t))))
        (path nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'dsh-bridge--request)
                     (lambda (_method p &rest _)
                       (setq path p)
                       (cons 200 (dsh-bridge-test--describe-report "s9")))))
            (with-temp-buffer
              (dsh-bridge-view-mode)
              (setq-local dsh-bridge--view-content-session "s9")
              (call-interactively #'dsh-bridge-describe-session)))
          (should (equal path "/session?sessionId=s9")))
      (when (get-buffer dsh-bridge-describe-buffer-name)
        (kill-buffer dsh-bridge-describe-buffer-name)))))

(ert-deftest dsh-bridge-describe-session-link-properties ()
  "A header-line session label is a clickable describe link."
  (let ((label (dsh-bridge--session-link "Title" "s1")))
    (should (equal (get-text-property 0 'mouse-face label) 'highlight))
    (should (equal (get-text-property 0 'help-echo label)
                   "mouse-1: describe this session"))
    (should (equal (get-text-property 0 'dsh-bridge-session-id label) "s1"))
    (should (eq (lookup-key (get-text-property 0 'keymap label) [header-line mouse-1])
                #'dsh-bridge-describe-session-at-mouse)))
  ;; A nil session or empty label is left alone.
  (should (equal (dsh-bridge--session-link "Title" nil) "Title"))
  (should (equal (dsh-bridge--session-link "" "s1") "")))

(ert-deftest dsh-bridge-describe-session-at-mouse-describes ()
  "The header-line mouse handler reads the id and describes it."
  (let ((label (dsh-bridge--session-link "Title" "s1"))
		(got nil))
	(cl-letf (((symbol-function 'dsh-bridge-describe-session)
			   (lambda (id) (setq got id))))
	  ;; A real header-line click's position names no buffer point; the id
	  ;; travels on the clicked string, as (STRING . STR-POS).
	  (dsh-bridge-describe-session-at-mouse
	   (list 'mouse-1
			 (list (selected-window) 'header-line '(0 . 0) 0 (cons label 0))))
	  (should (equal got "s1")))))

(ert-deftest dsh-bridge-format-helpers ()
  "The report's number, duration, percent, and time formatters."
  (should (equal (dsh-bridge--format-number 1234567) "1,234,567"))
  (should (equal (dsh-bridge--format-number 0) "0"))
  (should (equal (dsh-bridge--format-number -1234) "-1,234"))
  (should (equal (dsh-bridge--format-number nil) "—"))
  (should (equal (dsh-bridge--format-duration 450) "450 ms"))
  (should (equal (dsh-bridge--format-duration 12300) "12.3 s"))
  (should (equal (dsh-bridge--format-duration 133400) "2m 13.4s"))
  (should (equal (dsh-bridge--format-duration nil) "—"))
  (should (equal (dsh-bridge--format-percent 1 4) "25.0%"))
  (should-not (dsh-bridge--format-percent 1 0))
  (should (equal (dsh-bridge--format-time nil) "—")))

(ert-deftest dsh-bridge-describe-entry-points ()
  "The report is reachable from the transient and the view/sessions maps."
  (should (eq (lookup-key dsh-bridge-view-mode-map (kbd "D"))
              #'dsh-bridge-describe-session))
  (should (eq (lookup-key dsh-bridge-sessions-mode-map (kbd "D"))
              #'dsh-bridge-describe-session))
  (should (eq (cadr (dsh-bridge--layout-verb "D")) #'dsh-bridge-describe-session))
  (should-not (eq (lookup-key dsh-bridge-prompt-mode-map (kbd "D"))
                  #'dsh-bridge-describe-session)))

(ert-deftest dsh-bridge-describe-auto-refresh-schedules ()
  "A visible report for the completed turn's session schedules a refresh.
Another session, an invisible report, or the option off does not."
  (dsh-bridge-test--with-describe nil
    (dsh-bridge-describe-session "s1")
    (let ((scheduled nil))
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) t))
                ((symbol-function 'run-at-time)
                 (lambda (_secs _repeat function &rest args)
                   (setq scheduled (cons function args)))))
        (dsh-bridge--describe-maybe-refresh "s1")
        (should scheduled))
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) t))
                ((symbol-function 'run-at-time)
                 (lambda (&rest _) (ert-fail "scheduled for another session"))))
        (dsh-bridge--describe-maybe-refresh "other"))
      (let ((dsh-bridge-describe-auto-refresh nil))
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) t))
                  ((symbol-function 'run-at-time)
                   (lambda (&rest _) (ert-fail "scheduled with the option off"))))
          (dsh-bridge--describe-maybe-refresh "s1"))))))

;;; Attachments

(defun dsh-bridge-test--temp-file (name content)
  "Create a temporary file called NAME holding CONTENT; return its path."
  (let ((file (make-temp-file (concat "dsh-bridge-" name))))
    (with-temp-file file (insert content))
    file))

(defun dsh-bridge-test--kill-prompt-buffer ()
  "Kill the shared DSH-Prompt buffer when it is live."
  (let ((buffer (get-buffer "*dsh-bridge-prompt*")))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(ert-deftest dsh-bridge-attachment-format-roundtrip ()
  "Tag values round-trip paths and names containing quotes and backslashes."
  (let* ((path "/tmp/a \"quoted\" \\ file.png")
         (name "weird \"name\"")
         (tag (dsh-bridge--attachment-format path name))
         (parsed (dsh-bridge--parse-attachments (concat tag "\nbody\n"))))
    (should (equal (cdr parsed) (list (list :path path :name name))))
    (should (equal (car parsed) "body\n"))))

(ert-deftest dsh-bridge-parse-attachments-order-and-malformed ()
  "Tag lines are extracted in order and removed from the text; a tag with a
relative `filename' is malformed and stays as text."
  (let* ((one (dsh-bridge--attachment-format "/tmp/one.txt"))
         (two (dsh-bridge--attachment-format "/tmp/two.png" "shot.png"))
         (parsed (dsh-bridge--parse-attachments
                  (concat "lead\n" one "\nmiddle\n" two "\ntail\n"))))
    (should (equal (cdr parsed)
                   (list (list :path "/tmp/one.txt" :name nil)
                         (list :path "/tmp/two.png" :name "shot.png"))))
    (should (equal (car parsed) "lead\nmiddle\ntail\n")))
  (let ((parsed (dsh-bridge--parse-attachments
                 "<#attachment filename=\"rel.txt\">\nbody")))
    (should (null (cdr parsed)))
    (should (equal (car parsed) "<#attachment filename=\"rel.txt\">\nbody"))))

(ert-deftest dsh-bridge-attach-file-inserts-tag ()
  "`dsh-bridge-attach-file' inserts one tag line per attached file."
  (dsh-bridge-test--kill-prompt-buffer)
  (let ((file (dsh-bridge-test--temp-file "one.txt" "hello")))
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
          (with-temp-buffer
            (dsh-bridge-prompt-mode)
            (dsh-bridge-attach-file (list file))
            (should (= (dsh-bridge--attachment-count) 1))
            (should (string-match-p (regexp-quote file) (buffer-string)))))
      (delete-file file)
      (dsh-bridge-test--kill-prompt-buffer))))

(ert-deftest dsh-bridge-attach-file-refuses-directory ()
  "A directory is not an attachable file."
  (dsh-bridge-test--kill-prompt-buffer)
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (should-error (dsh-bridge-attach-file (list temporary-file-directory))
                  :type 'user-error))
  (dsh-bridge-test--kill-prompt-buffer))

(ert-deftest dsh-bridge-attach-file-dired-marks ()
  "In Dired, the marked files are all attached."
  (dsh-bridge-test--kill-prompt-buffer)
  (let ((first (dsh-bridge-test--temp-file "dired-a.txt" "a"))
        (second (dsh-bridge-test--temp-file "dired-b.txt" "b")))
    (unwind-protect
        (cl-letf (((symbol-function 'dired-get-marked-files)
                   (lambda (&rest _) (list first second)))
                  ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
          (with-temp-buffer
            (setq major-mode 'dired-mode)
            (call-interactively #'dsh-bridge-attach-file))
          (with-current-buffer "*dsh-bridge-prompt*"
            (should (= (dsh-bridge--attachment-count) 2))))
      (delete-file first)
      (delete-file second)
      (dsh-bridge-test--kill-prompt-buffer))))

(ert-deftest dsh-bridge-attach-buffer-file-stages-visiting-file ()
  "`dsh-bridge-attach-buffer-file' attaches the buffer's visited file."
  (dsh-bridge-test--kill-prompt-buffer)
  (let ((file (dsh-bridge-test--temp-file "visited.txt" "x")))
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
          (with-temp-buffer
            (setq buffer-file-name file)
            (dsh-bridge-attach-buffer-file))
          (with-current-buffer "*dsh-bridge-prompt*"
            (should (= (dsh-bridge--attachment-count) 1))
            (should (string-match-p (regexp-quote file) (buffer-string)))))
      (delete-file file)
      (dsh-bridge-test--kill-prompt-buffer))))

(ert-deftest dsh-bridge-attach-buffer-file-refuses-non-file ()
  "A buffer that visits no file cannot attach one."
  (with-temp-buffer
    (should-error (dsh-bridge-attach-buffer-file) :type 'user-error)))

(ert-deftest dsh-bridge-clear-attachments-removes-tags ()
  "`dsh-bridge-clear-attachments' removes tag lines but keeps the text."
  (dsh-bridge-test--kill-prompt-buffer)
  (let ((file (dsh-bridge-test--temp-file "clear.txt" "x")))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*dsh-bridge-prompt*")
          (dsh-bridge-prompt-mode)
          (insert "keep me\n")
          (dsh-bridge--insert-attachment-tag file)
          (dsh-bridge-clear-attachments)
          (should (= (dsh-bridge--attachment-count) 0))
          (should (equal (buffer-string) "keep me\n")))
      (delete-file file)
      (dsh-bridge-test--kill-prompt-buffer))))

(ert-deftest dsh-bridge-send-and-exit-carries-attachments ()
  "A send uploads the tag lines and strips them from the sent text; success
removes them from the kept text."
  (dsh-bridge-test--kill-prompt-buffer)
  (let ((file (dsh-bridge-test--temp-file "shot.png" "pngbytes"))
        (captured nil)
        (dsh-bridge-prompt-resend-confirm nil)
        (dsh-bridge--prompt-session "s1")
        (dsh-bridge--last-sent nil))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*dsh-bridge-prompt*")
          (dsh-bridge-prompt-mode)
          (insert "look at this\n")
          (dsh-bridge--insert-attachment-tag file)
          (cl-letf (((symbol-function 'dsh-bridge-send-text)
                     (lambda (text &optional session-id on-success attachments)
                       (setq captured (list text session-id attachments))
                       (when on-success (funcall on-success "s1"))))
                    ((symbol-function 'dsh-bridge--prompt-exit)
                     (lambda (&rest _) nil)))
            (dsh-bridge-send-and-exit))
          (should (equal (car captured) "look at this\n"))
          (should (equal (cadr captured) "s1"))
          (should (equal (caddr captured) (list (list :path file :name nil))))
          (should (= (dsh-bridge--attachment-count) 0))
          (should (equal (buffer-string) "look at this\n")))
      (delete-file file)
      (dsh-bridge-test--kill-prompt-buffer))))

(ert-deftest dsh-bridge-send-and-exit-attachment-only ()
  "A prompt with no text but an attachment is allowed."
  (dsh-bridge-test--kill-prompt-buffer)
  (let ((file (dsh-bridge-test--temp-file "only.txt" "x"))
        (captured 'uncalled)
        (dsh-bridge-prompt-resend-confirm nil)
        (dsh-bridge--prompt-session "s1"))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*dsh-bridge-prompt*")
          (dsh-bridge-prompt-mode)
          (dsh-bridge--insert-attachment-tag file)
          (cl-letf (((symbol-function 'dsh-bridge-send-text)
                     (lambda (text &optional _session-id on-success _attachments)
                       (setq captured text)
                       (when on-success (funcall on-success "s1"))))
                    ((symbol-function 'dsh-bridge--prompt-exit)
                     (lambda (&rest _) nil)))
            (dsh-bridge-send-and-exit))
          (should (equal captured "")))
      (delete-file file)
      (dsh-bridge-test--kill-prompt-buffer))))

(ert-deftest dsh-bridge-send-and-exit-empty-signals ()
  "Neither text nor attachments is an error."
  (with-temp-buffer
    (dsh-bridge-prompt-mode)
    (should-error (dsh-bridge-send-and-exit) :type 'user-error)))

(ert-deftest dsh-bridge-send-and-exit-failure-keeps-attachments ()
  "A failed send leaves the tag lines in place for a retry."
  (dsh-bridge-test--kill-prompt-buffer)
  (let ((file (dsh-bridge-test--temp-file "keep.txt" "x"))
        (dsh-bridge-prompt-resend-confirm nil)
        (dsh-bridge--prompt-session "s1"))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*dsh-bridge-prompt*")
          (dsh-bridge-prompt-mode)
          (insert "text\n")
          (dsh-bridge--insert-attachment-tag file)
          (cl-letf (((symbol-function 'dsh-bridge-send-text)
                     (lambda (&rest _) nil)))
            (dsh-bridge-send-and-exit))
          (should (= (dsh-bridge--attachment-count) 1)))
      (delete-file file)
      (dsh-bridge-test--kill-prompt-buffer))))

(ert-deftest dsh-bridge-draft-strips-attachments ()
  "A draft push drops the tag lines and pushes text only."
  (dsh-bridge-test--kill-prompt-buffer)
  (let ((file (dsh-bridge-test--temp-file "draft.txt" "x"))
        (captured nil)
        (dsh-bridge-default-session "s1"))
    (unwind-protect
        (with-temp-buffer
          (dsh-bridge-prompt-mode)
          (insert "text\n")
          (dsh-bridge--insert-attachment-tag file)
          (cl-letf (((symbol-function 'dsh-bridge-send-draft)
                     (lambda (text &optional _session-id) (setq captured text)))
                    ((symbol-function 'message) (lambda (&rest _) nil)))
            (dsh-bridge-draft))
          (should (equal captured "text\n")))
      (delete-file file)
      (dsh-bridge-test--kill-prompt-buffer))))

(ert-deftest dsh-bridge-send-carries-tags ()
  "`dsh-bridge-send' parses tag lines from its region or buffer."
  (let ((file (dsh-bridge-test--temp-file "send.txt" "x"))
        (captured nil)
        (dsh-bridge-default-session "s1"))
    (unwind-protect
        (with-temp-buffer
          (insert "text\n")
          (dsh-bridge--insert-attachment-tag file)
          (cl-letf (((symbol-function 'dsh-bridge-send-text)
                     (lambda (text &optional _session-id _on-success attachments)
                       (setq captured (list text attachments)))))
            (dsh-bridge-send))
          (should (equal (car captured) "text\n"))
          (should (equal (cadr captured) (list (list :path file :name nil)))))
      (delete-file file))))

(ert-deftest dsh-bridge-send-attaches-only-tags-inside-region ()
  "Sending a region attaches only the tag lines inside the region."
  (let ((inside (dsh-bridge-test--temp-file "inside.txt" "i"))
        (outside (dsh-bridge-test--temp-file "outside.txt" "o"))
        (captured nil)
        (dsh-bridge-default-session "s1"))
    (unwind-protect
        (with-temp-buffer
          ;; Batch Emacs has Transient Mark mode off, and `use-region-p'
          ;; requires it.
          (transient-mark-mode 1)
          (insert "lead\n")
          (dsh-bridge--insert-attachment-tag outside)
          (let ((start (point)) end)
            (insert "body\n")
            (dsh-bridge--insert-attachment-tag inside)
            (setq end (point))
            (insert "tail\n")
            (set-mark start)
            (goto-char end)
            (setq mark-active t))
          (cl-letf (((symbol-function 'dsh-bridge-send-text)
                     (lambda (text &optional _session-id _on-success attachments)
                       (setq captured (list text attachments)))))
            (dsh-bridge-send))
          (should (equal (car captured) "body\n"))
          (should (equal (cadr captured) (list (list :path inside :name nil)))))
      (delete-file inside)
      (delete-file outside))))

(ert-deftest dsh-bridge-attach-file-binds-invoking-session ()
  "Attaching from a session-carrying buffer creates the prompt buffer
bound to the invoking buffer's effective session, not to the default."
  (dsh-bridge-test--kill-prompt-buffer)
  (let ((file (dsh-bridge-test--temp-file "bind.txt" "x"))
        (dsh-bridge-default-session nil))
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
          (with-temp-buffer
            (setq major-mode 'dsh-bridge-view-mode)
            (setq dsh-bridge--view-content-session "view-session-42")
            (dsh-bridge-attach-file (list file)))
          (with-current-buffer "*dsh-bridge-prompt*"
            (should (equal dsh-bridge--prompt-session "view-session-42"))))
      (delete-file file)
      (dsh-bridge-test--kill-prompt-buffer))))

(ert-deftest dsh-bridge-send-text-skips-history-for-attachment-only ()
  "An attachment-only send records no history entry and leaves
`dsh-bridge--last-sent' alone; a text send still records both."
  (let ((dsh-bridge--session-status nil)
        (dsh-bridge--sessions-cache nil)
        (dsh-bridge--prompt-history nil)
        (dsh-bridge--last-sent nil))
    (cl-letf (((symbol-function 'dsh-bridge--call)
               (lambda (_m _p _pl cb) (funcall cb nil "{\"sessionId\":\"s1\"}" 200)))
              ((symbol-function 'dsh-bridge--status-event-render) #'ignore)
              ((symbol-function 'message) #'ignore))
      (dsh-bridge-send-text "" "s1" nil '((:path "/tmp/x.png" :name nil)))
      (should (null dsh-bridge--prompt-history))
      (should (null dsh-bridge--last-sent))
      (dsh-bridge-send-text "hello" "s1")
      (should (equal (cdr (assoc "s1" dsh-bridge--prompt-history)) '("hello")))
      (should (equal (caar dsh-bridge--last-sent) "s1")))))

(ert-deftest dsh-bridge-prompt-header-attachment-count ()
  "The header shows a `📎N' segment only while tags are present."
  (dsh-bridge-test--kill-prompt-buffer)
  (let ((file (dsh-bridge-test--temp-file "hdr.txt" "x"))
        (dsh-bridge--sessions-cache nil)
        (dsh-bridge--session-status nil))
    (unwind-protect
        (with-temp-buffer
          (dsh-bridge-prompt-mode)
          (insert "text\n")
          (should-not (string-match-p "📎" (dsh-bridge--prompt-header-line)))
          (dsh-bridge--insert-attachment-tag file)
          (should (string-match-p "📎1" (dsh-bridge--prompt-header-line))))
      (delete-file file))))

(provide 'dsh-bridge-tests)
;;; dsh-bridge-tests.el ends here
