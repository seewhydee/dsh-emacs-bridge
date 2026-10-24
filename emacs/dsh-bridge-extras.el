;;; dsh-bridge-extras.el --- Optional DSH inspectors for the Emacs bridge  -*- lexical-binding: t; -*-

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

;; Optional companion library to `dsh-bridge'.  The baseline library never
;; requires this file; it is loaded by its own entry point (or explicitly), and
;; adds a read-only turn inspector for complete committed reasoning, generic
;; tool-call details, and durable per-call applied diffs.
;;
;; The inspector fetches full detail only on demand through the bridge's
;; read-only `/details/*' routes.  It never inserts expandable detail into a
;; DSH-View buffer and never changes the view's provenance or splice rules.
;; One inspector buffer at a time is enough: the baseline's session/turn caches
;; are reused read-only, and every asynchronous response is checked against the
;; buffer's captured session, turn, observation pair, and request generation.

;;; Code:

(require 'dsh-bridge)
(require 'json)
(require 'url-util)
(require 'button)
(require 'subr-x)

;; Autoloaded by Markdown mode; declared for the byte-compiler without a
;; load-time dependency.
(declare-function markdown-mode "markdown-mode")
(declare-function gfm-mode "markdown-mode")
(declare-function font-lock-ensure "font-lock" (&optional beg end))

(defgroup dsh-bridge-extras nil
  "Optional detailed inspectors for the DSH Emacs bridge."
  :group 'dsh-bridge)

(defcustom dsh-bridge-extras-buffer-name "*DSH Inspector*"
  "Name of the read-only DSH turn-detail inspector buffer."
  :type 'string
  :group 'dsh-bridge-extras)

(defcustom dsh-bridge-extras-markdown-byte-limit 65536
  "Maximum UTF-8 bytes of reasoning text to fontify as Markdown.
Above this bound the text is displayed verbatim, without Markdown
fontification, rather than being truncated or dropped."
  :type 'natnum
  :group 'dsh-bridge-extras)

(defcustom dsh-bridge-extras-markdown-line-limit 2000
  "Maximum lines of reasoning text to fontify as Markdown."
  :type 'natnum
  :group 'dsh-bridge-extras)

(defface dsh-bridge-extras-heading-face
  '((t :inherit font-lock-keyword-face))
  "Face for the inspector's title line."
  :group 'dsh-bridge-extras)

(defface dsh-bridge-extras-section-face
  '((t :inherit font-lock-function-name-face))
  "Face for an inspector section heading."
  :group 'dsh-bridge-extras)

(defface dsh-bridge-extras-file-face
  '((t :inherit link))
  "Face for a file path in the inspector."
  :group 'dsh-bridge-extras)

(defface dsh-bridge-extras-note-face
  '((t :inherit shadow))
  "Face for inspector metadata and notices."
  :group 'dsh-bridge-extras)

(defface dsh-bridge-extras-code-face
  '((t :inherit font-lock-string-face))
  "Face for pretty-printed JSON in the inspector."
  :group 'dsh-bridge-extras)

(defface dsh-bridge-extras-error-face
  '((t :inherit error))
  "Face for failed tool results and inspector errors."
  :group 'dsh-bridge-extras)

(defface dsh-bridge-extras-pending-face
  '((t :inherit warning))
  "Face for an unsettled tool call."
  :group 'dsh-bridge-extras)

;;; Mode and buffer state

(defvar-keymap dsh-bridge-extras-mode-map
  :doc "Keymap for `dsh-bridge-extras-mode'."
  :parent special-mode-map
  "TAB" #'dsh-bridge-extras-toggle
  "RET" #'dsh-bridge-extras-toggle
  "n" #'dsh-bridge-extras-next-entry
  "p" #'dsh-bridge-extras-previous-entry
  "g" #'dsh-bridge-extras-refresh
  "e" #'dsh-bridge-extras-visit-file
  "L" #'dsh-bridge-extras-load-more
  "q" #'quit-window)

(define-derived-mode dsh-bridge-extras-mode special-mode "DSH-Inspector"
  "Major mode for the optional DSH turn-detail inspector.
The buffer is read-only.  It lists the visible reasoning blocks, tool
calls and results, and per-call applied file diffs of one DSH turn.
\\[dsh-bridge-extras-toggle] discloses an entry and lazily fetches its
complete detail; \\[dsh-bridge-extras-next-entry] and
\\[dsh-bridge-extras-previous-entry] walk entries;
\\[dsh-bridge-extras-visit-file] visits the file at point;
\\[dsh-bridge-extras-load-more] fetches the next text page;
\\[dsh-bridge-extras-refresh] re-fetches the index.
\\{dsh-bridge-extras-mode-map}"
  (setq buffer-read-only t))

(defvar-local dsh-bridge-extras--session nil
  "The session id shown by this inspector buffer.")

(defvar-local dsh-bridge-extras--turn nil
  "The concrete turn number shown by this inspector buffer, or nil.")

(defvar-local dsh-bridge-extras--request-turn nil
  "The turn selector used for the next index refresh: a number or `latest'.")

(defvar-local dsh-bridge-extras--epoch nil
  "The observation's surface replacement-generation count.")

(defvar-local dsh-bridge-extras--cursor nil
  "The observation's terminal log cursor.")

(defvar-local dsh-bridge-extras--cwd nil
  "The session's effective working directory at observation time.")

(defvar-local dsh-bridge-extras--index nil
  "The last successful `/details/turn' response alist, or nil.")

(defvar-local dsh-bridge-extras--status nil
  "A status/notice line to show above the inspector body, or nil.")

(defvar-local dsh-bridge-extras--details nil
  "Hash table: entry key -> a plist describing its fetched detail.
The plist keys are `:response' (the alist), `:text' (accumulated
text pages), `:next' (the next byte offset), `:total' (total bytes),
`:hasMore', and `:error'.")

(defvar-local dsh-bridge-extras--expanded nil
  "Hash table: entry key -> non-nil when its detail is disclosed.")

(defvar-local dsh-bridge-extras--inflight nil
  "Hash table: entry key -> non-nil while its detail request is in flight.")

(defvar-local dsh-bridge-extras--stale-refreshed nil
  "Hash table: entry key -> non-nil once a stale read refreshed the index.
A second stale read of the same key stores an error instead of refreshing
again, so a persistently stale host cannot make refresh and disclosure
spin against each other.")

(defvar-local dsh-bridge-extras--selected nil
  "The entry key at point, or the entry to select after a re-render.")

(defvar-local dsh-bridge-extras--initial-target nil
  "The at-point identity to select when the first index arrives.")

(defvar-local dsh-bridge-extras--focus-file nil
  "A file path to put point on after rendering, or nil.")

(defvar-local dsh-bridge-extras--generation 0
  "Monotonic request generation for this inspector buffer.")

(defvar dsh-bridge-extras--raw-buffer-name "*DSH Inspector Raw*"
  "Name of the buffer that shows exact raw entry text.")

;;; Small helpers

(defun dsh-bridge-extras--kind-of (alist)
  "The interned `kind' of an index/detail ALIST."
  (intern (or (alist-get 'kind alist) "")))

(defun dsh-bridge-extras--entry-key (entry)
  "The inspector key of index ENTRY."
  (list (dsh-bridge-extras--kind-of entry)
        (alist-get 'seq entry)
        (alist-get 'ord entry)))

(defun dsh-bridge-extras--file-key (entry)
  "The file-diff key for a result index ENTRY."
  (list 'file-diff (alist-get 'seq entry) nil))

(defun dsh-bridge-extras--key-kind (key)
  "The kind part of inspector KEY."
  (car-safe key))

(defun dsh-bridge-extras--key-seq (key)
  "The seq part of inspector KEY."
  (nth 1 key))

(defun dsh-bridge-extras--key-ord (key)
  "The reasoning ordinal part of inspector KEY, or nil."
  (nth 2 key))

(defun dsh-bridge-extras--entries ()
  "The index entries of the current inspector, or nil."
  (and dsh-bridge-extras--index (alist-get 'entries dsh-bridge-extras--index)))

(defun dsh-bridge-extras--request-failed-p (status)
  "Whether HTTP STATUS is an error."
  (or (null status) (>= status 400)))

(defun dsh-bridge-extras--error-message (status alist)
  "A user-facing message for a failed request STATUS and ALIST."
  (cond
   ((null status) "host unreachable")
   ((numberp status)
    (format "HTTP %s: %s" status
            (or (alist-get 'error alist)
                (alist-get 'reason alist)
                "request failed")))
   (t "request failed")))

(defun dsh-bridge-extras--property-string-at (property)
  "The value of text PROPERTY at point, or at the start of the line."
  (or (get-text-property (point) property)
      (save-excursion
        (beginning-of-line)
        (get-text-property (point) property))))

(defun dsh-bridge-extras--key-at-point ()
  "The inspector key at point, or nil."
  (dsh-bridge-extras--property-string-at 'dsh-bridge-extras-entry))

;;; Query paths and requests

(defun dsh-bridge-extras--query (pairs)
  "Encode PAIRS (a list of (NAME . VALUE)) as a query string."
  (mapconcat (lambda (pair)
               (concat (url-hexify-string (car pair)) "="
                       (url-hexify-string (cdr pair))))
             pairs "&"))

(defun dsh-bridge-extras--turn-path (session turn)
  "The `/details/turn' path for SESSION and TURN."
  (concat "/details/turn?"
          (dsh-bridge-extras--query
           `(("sessionId" . ,session)
             ("turn" . ,(if (eq turn 'latest) "latest" (number-to-string turn)))))))

(defun dsh-bridge-extras--entry-path (session turn epoch cursor key byte-offset)
  "The `/details/entry' path for one inspector KEY at BYTE-OFFSET."
  (let ((kind (dsh-bridge-extras--key-kind key))
        (seq (dsh-bridge-extras--key-seq key))
        (ord (dsh-bridge-extras--key-ord key)))
    (concat "/details/entry?"
            (dsh-bridge-extras--query
             (append
              `(("sessionId" . ,session)
                ("turn" . ,(number-to-string turn))
                ("epoch" . ,(number-to-string epoch))
                ("cursor" . ,(number-to-string cursor))
                ("kind" . ,(symbol-name kind))
                ("seq" . ,(number-to-string seq)))
              (when (and (eq kind 'thinking) (numberp ord))
                `(("ord" . ,(number-to-string ord))))
              (when (and (numberp byte-offset) (> byte-offset 0))
                `(("byteOffset" . ,(number-to-string byte-offset)))))))))

(defun dsh-bridge-extras--fetch-index (buffer session turn target)
  "Fetch the detail index for SESSION and TURN into BUFFER.
TARGET is the at-point identity to select once the index arrives."
  (with-current-buffer buffer
    (setq dsh-bridge-extras--generation (1+ dsh-bridge-extras--generation))
    (let ((generation dsh-bridge-extras--generation))
      (setq dsh-bridge-extras--session session
            dsh-bridge-extras--request-turn turn
            dsh-bridge-extras--initial-target target
            dsh-bridge-extras--status "Loading index...")
      (dsh-bridge-extras--render)
      (dsh-bridge--request-async
       "GET" (dsh-bridge-extras--turn-path session turn) nil
       (lambda (result)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (and (= generation dsh-bridge-extras--generation)
                        (equal session dsh-bridge-extras--session))
               (dsh-bridge-extras--handle-index result generation session turn)))))))))

(defun dsh-bridge-extras--handle-index (result generation session turn)
  "Apply an index RESULT fetched at GENERATION for SESSION and TURN."
  (ignore turn)
  (let ((status (car result))
        (alist (cdr result)))
    (cond
     ((not (eq status 200))
      (let ((message (dsh-bridge-extras--error-message status alist)))
        (if (null dsh-bridge-extras--index)
            (progn
              (setq dsh-bridge-extras--status
                    (format "Could not load this turn: %s" message)
                    dsh-bridge-extras--index nil)
              (dsh-bridge-extras--render))
          ;; Preserve the last successful index; only the echo area reports
          ;; the failed refresh, so a transient host error never blanks content.
          (setq dsh-bridge-extras--status nil)
          (dsh-bridge-extras--render)
          (message "dsh-bridge-extras: refresh failed: %s" message))))
     (t
      (when (= generation dsh-bridge-extras--generation)
        (let* ((new-turn (alist-get 'turn alist))
               (new-epoch (alist-get 'epoch alist))
               (new-cursor (alist-get 'cursor alist))
               (changed (or (not (equal new-turn dsh-bridge-extras--turn))
                            (not (equal new-epoch dsh-bridge-extras--epoch))
                            (not (equal new-cursor dsh-bridge-extras--cursor)))))
          ;; Details belong to one observation: a new epoch/cursor can change
          ;; every identity, so never render an old body under a new header.
          (when (or changed (not (equal session dsh-bridge-extras--session)))
            (setq dsh-bridge-extras--details (make-hash-table :test #'equal)
                  dsh-bridge-extras--inflight (make-hash-table :test #'equal)))
          (setq dsh-bridge-extras--index alist
                dsh-bridge-extras--turn new-turn
                dsh-bridge-extras--epoch new-epoch
                dsh-bridge-extras--cursor new-cursor
                dsh-bridge-extras--cwd (alist-get 'cwd alist)
                dsh-bridge-extras--status nil)
          (when (and (numberp new-turn) dsh-bridge-extras--request-turn)
            (setq dsh-bridge-extras--request-turn new-turn))
          (when dsh-bridge-extras--cwd
            (dsh-bridge--apply-session-directory session dsh-bridge-extras--cwd))
          (dsh-bridge-extras--retain-current-entries)
          (let ((resolved (dsh-bridge-extras--key-for-target
                           dsh-bridge-extras--initial-target alist)))
            (setq dsh-bridge-extras--selected
                  (or resolved (dsh-bridge-extras--first-key alist))
                  dsh-bridge-extras--initial-target nil))
          (dsh-bridge-extras--render)
          (dsh-bridge-extras--fetch-missing-details)))))))

(defun dsh-bridge-extras--retain-current-entries ()
  "Discard disclosure state for entries absent from the current index."
  (let ((current (make-hash-table :test #'equal))
        (removed nil))
    (dolist (entry (dsh-bridge-extras--entries))
      (puthash (dsh-bridge-extras--entry-key entry) t current)
      (when (and (eq (dsh-bridge-extras--kind-of entry) 'tool-result)
                 (alist-get 'files entry))
        (puthash (dsh-bridge-extras--file-key entry) t current)))
    (maphash (lambda (key _value)
               (unless (gethash key current)
                 (push key removed)))
             dsh-bridge-extras--expanded)
    (dolist (key removed)
      (remhash key dsh-bridge-extras--expanded))))

(defun dsh-bridge-extras--fetch-missing-details ()
  "Fetch details for expanded entries whose cached body was invalidated.
A refresh that changes the observation clears detail bodies; disclosure
state survives for entries still present, so their bodies must be refilled."
  (let ((keys nil))
    (maphash (lambda (key _value) (push key keys)) dsh-bridge-extras--expanded)
    (dolist (key keys)
      (unless (or (dsh-bridge-extras--detail key)
                  (gethash key dsh-bridge-extras--inflight))
        (dsh-bridge-extras--fetch-detail key)))))

(defun dsh-bridge-extras--first-key (alist)
  "The first selectable entry key in ALIST, or nil."
  (let (result)
    (dolist (entry (alist-get 'entries alist) result)
      (unless result (setq result (dsh-bridge-extras--entry-key entry))))))

;;; At-point targeting

(defun dsh-bridge-extras--identity-at-point ()
  "Describe the DSH-View entry or changed file at point, or nil.
The result is a plist with `:kind' and the identity fields the index
needs (`:seq', `:ord', `:call-id', or `:path')."
  (when (derived-mode-p 'dsh-bridge-view-mode)
    (let ((activity (dsh-bridge-extras--property-string-at 'dsh-bridge-activity))
          (button (button-at (point))))
      (cond
       ((and (consp activity) (eq (car activity) 'tool-result))
        (list :kind 'tool-result :call-id (cdr activity)))
       ((consp activity)
        (list :kind 'thinking :seq (car activity) :ord (cdr activity)))
       ((stringp activity)
        (list :kind 'tool-call :call-id activity))
       ((and button (button-get button 'path))
        (list :kind 'file-diff :path (button-get button 'path)))
       (t
        (save-excursion
          (beginning-of-line)
          (let ((button (button-at (point))))
            (when (and button (button-get button 'path))
              (list :kind 'file-diff :path (button-get button 'path))))))))))

(defun dsh-bridge-extras--file-matches-p (path file)
  "Whether changed-file PATH names the index FILE."
  (let ((recorded (alist-get 'path file))
        (absolute (alist-get 'absolute file)))
    (or (equal path recorded)
        (equal (expand-file-name path) (and absolute (expand-file-name absolute)))
        (equal (file-name-nondirectory path)
               (and recorded (file-name-nondirectory recorded))))))

(defun dsh-bridge-extras--resolve-target (target alist)
  "Resolve an at-point TARGET against index ALIST to one entry key."
  (when (consp target)
    (pcase (plist-get target :kind)
      ('thinking
       (let ((seq (plist-get target :seq))
             (ord (plist-get target :ord)))
         (seq-find (lambda (entry)
                     (and (eq (dsh-bridge-extras--kind-of entry) 'thinking)
                          (equal (alist-get 'seq entry) seq)
                          (equal (alist-get 'ord entry) ord)))
                   (alist-get 'entries alist))))
      ('tool-call
       (let ((call-id (plist-get target :call-id)))
         (seq-find (lambda (entry)
                     (and (eq (dsh-bridge-extras--kind-of entry) 'tool-call)
                          (equal (alist-get 'callId entry) call-id)))
                   (alist-get 'entries alist))))
      ('tool-result
       (let ((call-id (plist-get target :call-id)))
         (seq-find (lambda (entry)
                     (and (eq (dsh-bridge-extras--kind-of entry) 'tool-result)
                          (equal (alist-get 'callId entry) call-id)))
                   (alist-get 'entries alist))))
      ('file-diff
       (let ((path (plist-get target :path)))
         (seq-find (lambda (entry)
                     (and (eq (dsh-bridge-extras--kind-of entry) 'tool-result)
                          (seq-some (lambda (file)
                                      (dsh-bridge-extras--file-matches-p path file))
                                    (alist-get 'files entry))))
                   (alist-get 'entries alist))))
      (_ nil))))

(defun dsh-bridge-extras--key-for-target (target alist)
  "Resolve TARGET against ALIST and turn it into a selectable key."
  (let ((entry (dsh-bridge-extras--resolve-target target alist)))
    (when entry
      (if (eq (dsh-bridge-extras--kind-of entry) 'tool-result)
          (if (and (eq (plist-get target :kind) 'file-diff)
                   (alist-get 'files entry))
              (progn
                (setq dsh-bridge-extras--focus-file (plist-get target :path))
                (dsh-bridge-extras--file-key entry))
            (dsh-bridge-extras--entry-key entry))
        (dsh-bridge-extras--entry-key entry)))))

;;; Markdown, JSON, and diff presentation

(defun dsh-bridge-extras--markdown-available-p ()
  "Whether Markdown mode is installed."
  (and (require 'markdown-mode nil t) t))

(defun dsh-bridge-extras--line-count (text)
  "The number of lines in TEXT."
  (if (string-empty-p text) 0 (1+ (seq-count (lambda (ch) (eq ch ?\n)) text))))

(defun dsh-bridge-extras--whitelisted-properties (text)
  "Copy TEXT keeping only `face' and `font-lock-face' text properties.
Markdown fontification adds keymaps, invisibility, display properties,
and other interactive state; none of that may leak into the inspector."
  (let ((pos 0)
        (length (length text))
        (parts nil))
    (while (< pos length)
      (let* ((next (next-property-change pos text))
             (end (or next length))
             (props (text-properties-at pos text))
             (face (plist-get props 'face))
             (lock-face (plist-get props 'font-lock-face))
             (piece (substring-no-properties text pos end)))
        (push (if (or face lock-face)
                  (propertize piece 'face face 'font-lock-face lock-face)
                piece)
              parts)
        (setq pos end)))
    (apply #'concat (nreverse parts))))

(defun dsh-bridge-extras--fontify-markdown (text)
  "Return TEXT Markdown-fontified when possible, else verbatim.
Only the whitelisted presentation properties are transferred.  Text
over the byte/line bounds is returned unfontified, never truncated."
  (if (or (not (dsh-bridge-extras--markdown-available-p))
          (> (string-bytes text) dsh-bridge-extras-markdown-byte-limit)
          (> (dsh-bridge-extras--line-count text)
             dsh-bridge-extras-markdown-line-limit))
      nil
    (condition-case nil
        (with-temp-buffer
          (insert text)
          (delay-mode-hooks
            (if (fboundp 'gfm-mode) (gfm-mode) (markdown-mode)))
          (font-lock-ensure)
          (dsh-bridge-extras--whitelisted-properties (buffer-string)))
      (error nil))))

(defun dsh-bridge-extras--insert-markdown (text)
  "Insert reasoning TEXT, Markdown-fontified when available."
  (let ((fontified (dsh-bridge-extras--fontify-markdown text)))
    (insert (or fontified
                (propertize text 'face 'dsh-bridge-view-thinking-face)))
    (unless (string-suffix-p "\n" text) (insert "\n"))))

(defun dsh-bridge-extras--pretty-json (text)
  "Return TEXT pretty-printed as JSON, or nil when it is not valid JSON."
  (condition-case nil
      (with-temp-buffer
        (insert text)
        (json-pretty-print-buffer)
        (let ((pretty (buffer-string)))
          (unless (string= (string-trim pretty) (string-trim text)) pretty)))
    (error nil)))

(defun dsh-bridge-extras--show-raw (text)
  "Show exact TEXT in a read-only buffer."
  (let ((buffer (get-buffer-create dsh-bridge-extras--raw-buffer-name)))
    (with-current-buffer buffer
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert text)
      (unless (string-suffix-p "\n" text) (insert "\n"))
      (special-mode)
      (set-buffer-modified-p nil))
    (pop-to-buffer buffer)))

(defun dsh-bridge-extras--insert-raw-button (text)
  "Insert a button that shows the exact TEXT."
  (insert " ")
  (insert-text-button "[raw]"
                      'action (lambda (button)
                                (dsh-bridge-extras--show-raw (button-get button 'raw-text)))
                      'raw-text text
                      'help-echo "Show the exact raw text"
                      'follow-link t))

(defun dsh-bridge-extras--insert-json (text)
  "Insert arguments TEXT, pretty-printed when it is valid JSON."
  (let ((pretty (dsh-bridge-extras--pretty-json text)))
    (if pretty
        (progn
          (insert (propertize (substring-no-properties pretty)
                              'face 'dsh-bridge-extras-code-face))
          (unless (string-suffix-p "\n" pretty) (insert "\n"))
          (dsh-bridge-extras--insert-raw-button text)
          (insert "\n"))
      (insert text)
      (unless (string-suffix-p "\n" text) (insert "\n")))))

(defun dsh-bridge-extras--diff-face (line)
  "The face for one rendered diff LINE, or nil."
  (cond
   ((string-prefix-p "File: " line) 'dsh-bridge-extras-file-face)
   ((string-prefix-p "+" line) (if (facep 'diff-added) 'diff-added 'highlight))
   ((string-prefix-p "-" line) (if (facep 'diff-removed) 'diff-removed 'shadow))
   ((string-prefix-p "  " line) 'dsh-bridge-extras-note-face)
   ((string-prefix-p " " line) (if (facep 'diff-context) 'diff-context 'default))
   (t 'dsh-bridge-extras-note-face)))

(defun dsh-bridge-extras--insert-diff-text (text)
  "Insert rendered diff TEXT with diff faces, never as an appliable patch."
  (require 'diff-mode nil t)
  (dolist (line (split-string text "\n"))
    (unless (string-empty-p line)
      (let ((face (dsh-bridge-extras--diff-face line)))
        (insert (if face (propertize line 'face face) line) "\n")))))

;;; Detail fetching

(defun dsh-bridge-extras--detail (key)
  "The fetched detail plist for KEY, or nil."
  (and (hash-table-p dsh-bridge-extras--details)
       (gethash key dsh-bridge-extras--details)))

(defun dsh-bridge-extras--fetch-detail (key &optional byte-offset)
  "Fetch detail for KEY at BYTE-OFFSET (default zero)."
  (when (and dsh-bridge-extras--session
             (numberp dsh-bridge-extras--turn)
             (numberp dsh-bridge-extras--epoch)
             (numberp dsh-bridge-extras--cursor))
    (let ((buffer (current-buffer))
          (generation dsh-bridge-extras--generation)
          (session dsh-bridge-extras--session)
          (turn dsh-bridge-extras--turn)
          (epoch dsh-bridge-extras--epoch)
          (cursor dsh-bridge-extras--cursor)
          (offset (or byte-offset 0))
          (request (make-symbol "detail-request")))
      (unless (gethash key dsh-bridge-extras--inflight)
        (puthash key request dsh-bridge-extras--inflight)
        (dsh-bridge--request-async
         "GET" (dsh-bridge-extras--entry-path
                session turn epoch cursor key offset)
         nil
         (lambda (result)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (eq (gethash key dsh-bridge-extras--inflight) request)
                 (remhash key dsh-bridge-extras--inflight)
                 (when (and (= generation dsh-bridge-extras--generation)
                            (equal session dsh-bridge-extras--session)
                            (equal turn dsh-bridge-extras--turn)
                            (equal epoch dsh-bridge-extras--epoch)
                            (equal cursor dsh-bridge-extras--cursor))
                   (dsh-bridge-extras--handle-detail key offset result)))))))))))

(defun dsh-bridge-extras--handle-detail (key offset result)
  "Apply a detail RESULT for KEY fetched at byte OFFSET."
  (let ((status (car result))
        (alist (cdr result)))
    (cond
     ((eq status 200)
      (remhash key dsh-bridge-extras--stale-refreshed)
      (let* ((page (alist-get 'page alist))
             (text (or (alist-get 'text alist) ""))
             (previous (dsh-bridge-extras--detail key))
             (accumulated (if (and (> offset 0) previous)
                              (concat (plist-get previous :text) text)
                            text)))
        (puthash key
                 (list :response (if (and (> offset 0) previous)
                                     (plist-get previous :response)
                                   alist)
                       :text accumulated
                       :next (alist-get 'nextByteOffset page)
                       :total (alist-get 'totalBytes page)
                       :hasMore (eq (alist-get 'hasMore page) t)
                       :error nil)
                 dsh-bridge-extras--details)))
     ((and (eq status 409)
           (equal (alist-get 'reason alist) "stale"))
      ;; The index moved under the entry.  Refresh once per key; a second
      ;; stale read stores an error rather than looping.
      (if (and (hash-table-p dsh-bridge-extras--stale-refreshed)
               (gethash key dsh-bridge-extras--stale-refreshed))
          (progn
            (puthash key (list :error "observation moved; press g to refresh")
                     dsh-bridge-extras--details)
            (message "dsh-bridge-extras: observation is still stale"))
        (when (hash-table-p dsh-bridge-extras--stale-refreshed)
          (puthash key t dsh-bridge-extras--stale-refreshed))
        (message "dsh-bridge-extras: observation moved; refreshing")
        (dsh-bridge-extras-refresh t)))
     (t
      (let* ((message (dsh-bridge-extras--error-message status alist))
             (previous (and (> offset 0) (dsh-bridge-extras--detail key))))
        (puthash key
                 (if previous
                     (plist-put (copy-sequence previous) :error
                                (format "Could not load more: %s; press L to retry"
                                        message))
                   (list :error message))
                 dsh-bridge-extras--details)
        (message "dsh-bridge-extras: %s" message))))
    (dsh-bridge-extras--render)))

;;; Rendering

(defun dsh-bridge-extras--insert-entry-header (key label &optional face)
  "Insert a selectable entry header for KEY with LABEL and FACE."
  (let ((selected (equal key dsh-bridge-extras--selected)))
    (insert (propertize (format "%s%s\n"
                                (if selected "> " "  ")
                                label)
                        'dsh-bridge-extras-entry key
                        'dsh-bridge-extras-header key
                        'face (or face
                                  (and selected 'bold)
                                  'dsh-bridge-extras-heading-face)))))

(defun dsh-bridge-extras--insert-section (title)
  "Insert a section heading TITLE."
  (insert "\n")
  (insert (propertize (concat title "\n") 'face 'dsh-bridge-extras-section-face)))

(defun dsh-bridge-extras--insert-detail-body (key)
  "Insert the disclosed body for KEY."
  (let ((detail (dsh-bridge-extras--detail key)))
    (cond
     ((null detail)
      (insert (propertize "  Loading...\n" 'face 'dsh-bridge-extras-note-face)))
     ((and (plist-get detail :error) (not (plist-get detail :response)))
      (insert (propertize (format "  %s\n" (plist-get detail :error))
                          'face 'dsh-bridge-extras-error-face)))
     (t
      (let ((response (plist-get detail :response))
            (text (or (plist-get detail :text) "")))
        (pcase (dsh-bridge-extras--kind-of response)
          ('thinking (dsh-bridge-extras--insert-markdown text))
          ('tool-call
           (insert (propertize "Arguments:\n" 'face 'dsh-bridge-extras-note-face))
           (dsh-bridge-extras--insert-json text))
          ('tool-result
           (insert (propertize "Result:\n" 'face 'dsh-bridge-extras-note-face))
           (insert text)
           (unless (string-suffix-p "\n" text) (insert "\n"))
           (dsh-bridge-extras--insert-result-blocks response)
           (let ((error (alist-get 'error response)))
             (when error
               (insert (propertize
                        (format "Error: %s%s\n"
                                (or (alist-get 'name error) "tool")
                                (if-let* ((code (alist-get 'code error)))
                                    (format " (%s)" code)
                                  ""))
                        'face 'dsh-bridge-extras-error-face))
               (when-let* ((reason (alist-get 'reason error)))
                 (unless (string-empty-p reason)
                   (insert reason "\n"))))))
          ('file-diff
           (dsh-bridge-extras--insert-diff-text text)
           (when (alist-get 'truncated response)
             (insert (propertize "  (display truncated by the bridge)\n"
                                 'face 'dsh-bridge-extras-note-face)))))
        (when-let* ((error (plist-get detail :error)))
          (insert (propertize (format "  %s\n" error)
                              'face 'dsh-bridge-extras-error-face)))
        (when (plist-get detail :hasMore)
          (let* ((next (plist-get detail :next))
                 (total (plist-get detail :total))
                 (remaining (and (numberp next) (numberp total)
                                 (max 0 (- total next)))))
            (insert (propertize
                     (if remaining
                         (format "  ... %d more bytes; press L to load more\n"
                                 remaining)
                       "  ... more content; press L to load more\n")
                     'face 'dsh-bridge-extras-note-face))))
        (unless (string-suffix-p "\n" (buffer-string))
          (insert "\n")))))))

(defun dsh-bridge-extras--insert-result-blocks (response)
  "Insert non-text content block metadata from RESPONSE."
  (let ((content (alist-get 'content response)))
    (dolist (block (alist-get 'blocks content))
      (insert (propertize
               (format "  [%s%s%s]\n"
                       (or (alist-get 'type block) "block")
                       (if-let* ((media (alist-get 'mediaType block)))
                           (format " %s" media) "")
                       (if-let* ((bytes (alist-get 'bytes block)))
                           (format " %s bytes" bytes) ""))
               'face 'dsh-bridge-extras-note-face)))
    (when (and (numberp (alist-get 'omittedBlocks content))
               (> (alist-get 'omittedBlocks content) 0))
      (insert (propertize
               (format "  (%d block(s) not displayed)\n"
                       (alist-get 'omittedBlocks content))
               'face 'dsh-bridge-extras-note-face)))))

(defun dsh-bridge-extras--insert-thinking (entry)
  "Render one thinking index ENTRY."
  (let ((key (dsh-bridge-extras--entry-key entry)))
    (dsh-bridge-extras--insert-entry-header
     key (format "thinking [step %s] %s"
                 (alist-get 'step entry)
                 (or (alist-get 'summary entry) "")))
    (when (gethash key dsh-bridge-extras--expanded)
      (dsh-bridge-extras--insert-detail-body key))))

(defun dsh-bridge-extras--tool-groups ()
  "Group index tool entries for display.
A call and its result stay separate wire entries but share one visual
group; an orphan result is its own group."
  (let ((groups nil))
    (dolist (entry (dsh-bridge-extras--entries))
      (pcase (dsh-bridge-extras--kind-of entry)
        ('tool-call
         (push (list :call entry :results nil) groups))
        ('tool-result
         (let ((group (seq-find (lambda (candidate)
                                  (and (plist-get candidate :call)
                                       (equal (alist-get 'callId (plist-get candidate :call))
                                              (alist-get 'callId entry))))
                                groups)))
           (if group
               (setf (plist-get group :results)
                     (append (plist-get group :results) (list entry)))
             (push (list :call nil :results (list entry)) groups))))))
    (nreverse groups)))

(defun dsh-bridge-extras--insert-tool-entry (entry)
  "Render one tool ENTRY header and body."
  (let* ((key (dsh-bridge-extras--entry-key entry))
         (kind (dsh-bridge-extras--kind-of entry))
         (label
          (pcase kind
            ('tool-call
             (format "call %s - %s [%s]"
                     (or (alist-get 'name entry) "tool")
                     (or (alist-get 'summary entry) "")
                     (or (alist-get 'settlement entry) "pending")))
            ('tool-result
             (format "result %s [%s%s]"
                     (or (alist-get 'name entry) "tool")
                     (if (eq (alist-get 'isError entry) t) "error" "ok")
                     (if (equal (alist-get 'settlement entry) "orphan") ", orphan" ""))))))
    (dsh-bridge-extras--insert-entry-header
     key label
     (cond ((and (eq kind 'tool-result) (eq (alist-get 'isError entry) t))
            'dsh-bridge-extras-error-face)
           ((and (eq kind 'tool-call) (equal (alist-get 'settlement entry) "pending"))
            'dsh-bridge-extras-pending-face)
           (t nil)))
    (when (gethash key dsh-bridge-extras--expanded)
      (dsh-bridge-extras--insert-detail-body key))))

(defun dsh-bridge-extras--insert-file-group (entry)
  "Render ENTRY's file-change group and its file lines."
  (let* ((key (dsh-bridge-extras--file-key entry))
         (files (alist-get 'files entry))
         (name (or (alist-get 'name entry) "tool")))
    (dsh-bridge-extras--insert-entry-header
     key (format "files changed by %s (%d)" name (length files)))
    (dolist (file files)
      (let ((absolute (alist-get 'absolute file))
            (path (alist-get 'path file)))
        (insert "    ")
        (insert (propertize
                 (or path (or absolute "file"))
                 'dsh-bridge-extras-entry key
                 'dsh-bridge-extras-file absolute
                 'face 'dsh-bridge-extras-file-face))
        (insert (propertize
                 (format " [%s%s%s]\n"
                         (or (alist-get 'status file) "unknown")
                         (if-let* ((operation (alist-get 'operation file)))
                             (format ", %s" operation) "")
                         (if (equal (alist-get 'pathSource file) "inferred")
                             ", inferred path" ""))
                 'face 'dsh-bridge-extras-note-face))))
    (when (gethash key dsh-bridge-extras--expanded)
      (dsh-bridge-extras--insert-detail-body key))))

(defun dsh-bridge-extras--insert-header (alist)
  "Insert the inspector title and observation facts for ALIST."
  (let ((session (or (alist-get 'sessionId alist) dsh-bridge-extras--session))
        (turn (alist-get 'turn alist))
        (epoch (alist-get 'epoch alist))
        (cursor (alist-get 'cursor alist)))
    (insert (propertize
             (format "DSH Inspector - session %s - turn %s\n"
                     (or session "?") (or turn "?"))
             'face 'dsh-bridge-extras-heading-face))
    (insert (propertize
             (format "observation: epoch %s, cursor %s%s%s\n"
                     (or epoch "?") (or cursor "?")
                     (if (alist-get 'open alist) ", open" "")
                     (if-let* ((cwd (alist-get 'cwd alist)))
                         (format ", cwd %s" cwd)
                       ""))
             'face 'dsh-bridge-extras-note-face))
    (when (or (alist-get 'truncated alist)
              (> (or (alist-get 'droppedEntries alist) 0) 0))
      (let ((dropped (alist-get 'droppedEntries alist)))
        (insert (propertize
                 (format "notice: index truncated; %s older entr%s not shown\n"
                         (or dropped "some")
                         (if (equal dropped 1) "y" "ies"))
                 'face 'dsh-bridge-extras-note-face))))
    (when (alist-get 'failure alist)
      (let ((failure (alist-get 'failure alist)))
        (insert (propertize
                 (format "failure: %s%s\n"
                         (or (alist-get 'code failure) "error")
                         (if-let* ((message (alist-get 'message failure)))
                             (if (string-empty-p message) "" (format ": %s" message))
                           ""))
                 'face 'dsh-bridge-extras-error-face))))
    (when-let* ((status dsh-bridge-extras--status))
      (insert (propertize (concat status "\n")
                          'face 'dsh-bridge-extras-note-face)))
    (insert "\n")))

(defun dsh-bridge-extras--render ()
  "Render the inspector from the current index and detail caches."
  (let ((inhibit-read-only t)
        (key dsh-bridge-extras--selected)
        (file dsh-bridge-extras--focus-file))
    (erase-buffer)
    (if (null dsh-bridge-extras--index)
        (progn
          (insert (propertize "DSH Inspector\n" 'face 'dsh-bridge-extras-heading-face))
          (when-let* ((status dsh-bridge-extras--status))
            (insert status "\n"))
          (unless dsh-bridge-extras--status
            (insert (propertize "No index loaded.  Press g to fetch.\n"
                                'face 'dsh-bridge-extras-note-face))))
      (dsh-bridge-extras--insert-header dsh-bridge-extras--index)
      (let* ((entries (dsh-bridge-extras--entries))
             (thinking (seq-filter (lambda (entry)
                                     (eq (dsh-bridge-extras--kind-of entry) 'thinking))
                                   entries))
             (file-entries (seq-filter (lambda (entry)
                                         (and (eq (dsh-bridge-extras--kind-of entry) 'tool-result)
                                              (alist-get 'files entry)))
                                       entries)))
        (dsh-bridge-extras--insert-section "Thinking")
        (if (null thinking)
            (insert (propertize "  (none)\n" 'face 'dsh-bridge-extras-note-face))
          (dolist (entry thinking)
            (dsh-bridge-extras--insert-thinking entry)))
        (dsh-bridge-extras--insert-section "Tool calls")
        (let ((groups (dsh-bridge-extras--tool-groups)))
          (if (null groups)
              (insert (propertize "  (none)\n" 'face 'dsh-bridge-extras-note-face))
            (dolist (group groups)
              (when-let* ((call (plist-get group :call)))
                (dsh-bridge-extras--insert-tool-entry call))
              (dolist (result (plist-get group :results))
                (dsh-bridge-extras--insert-tool-entry result)))))
        (dsh-bridge-extras--insert-section "Changed files")
        (if (null file-entries)
            (insert (propertize "  (none)\n" 'face 'dsh-bridge-extras-note-face))
          (dolist (entry file-entries)
            (dsh-bridge-extras--insert-file-group entry)))))
    (setq buffer-read-only t)
    (goto-char (point-min))
    (when key (dsh-bridge-extras--goto-key key))
    (when file (dsh-bridge-extras--goto-file file))
    (setq dsh-bridge-extras--focus-file nil)
    (set-buffer-modified-p nil)))

(defun dsh-bridge-extras--goto-key (key)
  "Move point to the header line of KEY, if present."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (if (and (equal (get-text-property (point) 'dsh-bridge-extras-entry) key)
               (get-text-property (point) 'dsh-bridge-extras-header))
          (setq found t)
        (goto-char (or (next-single-property-change
                        (point) 'dsh-bridge-extras-entry)
                       (point-max)))))
    found))

(defun dsh-bridge-extras--goto-file (path)
  "Move point to the file line for PATH, if present."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (if (equal (get-text-property (point) 'dsh-bridge-extras-file) path)
          (setq found t)
        (goto-char (or (next-single-property-change
                        (point) 'dsh-bridge-extras-file)
                       (point-max)))))
    found))

;;; Commands

(defun dsh-bridge-extras-inspect-turn (&optional _arg session turn)
  "Inspect complete committed detail for one DSH turn.
From a DSH-View buffer, inspect the turn currently shown and select
the activity entry or changed file at point.  From DSH-Sessions or the
dispatcher, inspect the resolved target session's newest visible turn
via the non-resuming `turn=latest' discovery.  With a prefix argument,
choose the session explicitly.

The inspector is read-only and fetches details lazily.  It never
resumes a cold session and never calls the baseline `/turns' route."
  (interactive "P")
  (let* ((origin (or (and (boundp 'transient--prefix) transient--prefix
                          (boundp 'transient--original-buffer)
                          (buffer-live-p transient--original-buffer)
                          transient--original-buffer)
                     (current-buffer)))
         (in-view (with-current-buffer origin
                    (derived-mode-p 'dsh-bridge-view-mode)))
         (resolved (or session
                       (dsh-bridge--session-for-command "Inspect session: ")))
         (view-context
          (and in-view resolved
               (equal resolved
                      (buffer-local-value 'dsh-bridge--view-content-session origin))))
         (view-turn (and view-context
                         (buffer-local-value 'dsh-bridge--view-turn origin)))
         (target-turn (or turn
                          (and (numberp view-turn) view-turn)
                          'latest))
         (target (and view-context
                      (with-current-buffer origin
                        (dsh-bridge-extras--identity-at-point)))))
    (unless resolved
      (user-error "dsh-bridge-extras: no session to inspect"))
    (dsh-bridge-extras--open resolved target-turn target)))

(defun dsh-bridge-extras--open (session turn target)
  "Open the inspector buffer for SESSION, TURN, and at-point TARGET."
  (let ((buffer (get-buffer-create dsh-bridge-extras-buffer-name)))
    (with-current-buffer buffer
      (let ((same (equal session dsh-bridge-extras--session)))
        (unless (derived-mode-p 'dsh-bridge-extras-mode)
          (dsh-bridge-extras-mode))
        (setq dsh-bridge-extras--session session
              dsh-bridge-extras--turn (and (numberp turn) turn)
              dsh-bridge-extras--request-turn turn
              dsh-bridge-extras--epoch nil
              dsh-bridge-extras--cursor nil
              dsh-bridge-extras--cwd nil
              dsh-bridge-extras--index nil
              dsh-bridge-extras--status nil
              dsh-bridge-extras--selected nil
              dsh-bridge-extras--focus-file nil
              dsh-bridge-extras--details (make-hash-table :test #'equal)
              dsh-bridge-extras--inflight (make-hash-table :test #'equal)
              dsh-bridge-extras--stale-refreshed (make-hash-table :test #'equal)
              dsh-bridge-extras--expanded (if same
                                              dsh-bridge-extras--expanded
                                            (make-hash-table :test #'equal)))
        (dsh-bridge-extras--fetch-index buffer session turn target)))
    (pop-to-buffer buffer)
    buffer))

(defun dsh-bridge-extras-toggle ()
  "Disclose or hide the entry at point, fetching its detail on first use."
  (interactive)
  (let ((key (dsh-bridge-extras--key-at-point)))
    (if (null key)
        (message "dsh-bridge-extras: no entry at point")
      (setq dsh-bridge-extras--selected key)
      (if (gethash key dsh-bridge-extras--expanded)
          (remhash key dsh-bridge-extras--expanded)
        (puthash key t dsh-bridge-extras--expanded)
        (let ((detail (dsh-bridge-extras--detail key)))
          (when (or (null detail) (plist-get detail :error))
            (dsh-bridge-extras--fetch-detail key))))
      (dsh-bridge-extras--render))))

(defun dsh-bridge-extras-next-entry ()
  "Move to the next entry header."
  (interactive)
  (dsh-bridge-extras--walk-entry 1))

(defun dsh-bridge-extras-previous-entry ()
  "Move to the previous entry header."
  (interactive)
  (dsh-bridge-extras--walk-entry -1))

(defun dsh-bridge-extras--walk-entry (direction)
  "Move to the next header in DIRECTION (1 or -1)."
  (let ((here (point))
        (found nil))
    (if (> direction 0)
        (progn
          (goto-char (or (next-single-property-change
                          (point) 'dsh-bridge-extras-header)
                         (point-max)))
          (while (and (not found) (not (eobp)))
            (if (get-text-property (point) 'dsh-bridge-extras-header)
                (setq found t)
              (goto-char (or (next-single-property-change
                              (point) 'dsh-bridge-extras-header)
                             (point-max))))))
      (let ((previous (previous-single-property-change
                       (point) 'dsh-bridge-extras-header)))
        (when previous
          (goto-char previous)
          (while (and (not found)
                      (not (bobp))
                      (not (get-text-property (point) 'dsh-bridge-extras-header)))
            (setq previous (previous-single-property-change
                            (point) 'dsh-bridge-extras-header))
            (goto-char (or previous (point-min))))
          (when (get-text-property (point) 'dsh-bridge-extras-header)
            (setq found t)))))
    (if found
        (progn
          (setq dsh-bridge-extras--selected (dsh-bridge-extras--key-at-point))
          (dsh-bridge-extras--render))
      (goto-char here)
      (message "dsh-bridge-extras: no more entries"))))

(defun dsh-bridge-extras-refresh (&optional automatic)
  "Re-fetch the inspector's index, preserving disclosure state.
AUTOMATIC is non-nil for stale-response recovery; an explicit refresh
also resets the guard that prevents repeated automatic recovery."
  (interactive)
  (if (null dsh-bridge-extras--session)
      (message "dsh-bridge-extras: no session to refresh")
    (unless automatic
      (when (hash-table-p dsh-bridge-extras--stale-refreshed)
        (clrhash dsh-bridge-extras--stale-refreshed)))
    (let ((turn (or (and (numberp dsh-bridge-extras--turn)
                         dsh-bridge-extras--turn)
                    dsh-bridge-extras--request-turn
                    'latest)))
      (dsh-bridge-extras--fetch-index (current-buffer)
                                      dsh-bridge-extras--session
                                      turn nil))))

(defun dsh-bridge-extras-load-more ()
  "Fetch the next page of the expanded entry at point."
  (interactive)
  (let* ((key (or (dsh-bridge-extras--key-at-point) dsh-bridge-extras--selected))
         (detail (and key (dsh-bridge-extras--detail key))))
    (cond
     ((null key) (message "dsh-bridge-extras: no entry at point"))
     ((null detail) (message "dsh-bridge-extras: disclose the entry first"))
     ((and (plist-get detail :error) (not (plist-get detail :hasMore)))
      (message "dsh-bridge-extras: %s" (plist-get detail :error)))
     ((not (plist-get detail :hasMore)) (message "dsh-bridge-extras: no more content"))
     (t (dsh-bridge-extras--fetch-detail key (plist-get detail :next))))))

(defun dsh-bridge-extras-visit-file ()
  "Visit the file named at point, or the first changed file of the entry."
  (interactive)
  (let* ((path (dsh-bridge-extras--property-string-at 'dsh-bridge-extras-file))
         (key (or (dsh-bridge-extras--key-at-point) dsh-bridge-extras--selected))
         (detail (and key (dsh-bridge-extras--detail key)))
         (files (and detail (alist-get 'files (plist-get detail :response))))
         (fallback (and files (alist-get 'absolute (car files))))
         (target (or path fallback)))
    (if target
        (find-file target)
      (message "dsh-bridge-extras: no file at point"))))

;;; Load-time entry points

;; The baseline maps exist by the time this library loads (it requires
;; `dsh-bridge'), so the inspector key can be added without an eager load from
;; the core library.  The dispatcher's inert suffix is declared in core and
;; autoloads this command.
(define-key dsh-bridge-view-mode-map (kbd "I")
            #'dsh-bridge-extras-inspect-turn)
(define-key dsh-bridge-sessions-mode-map (kbd "I")
            #'dsh-bridge-extras-inspect-turn)

(provide 'dsh-bridge-extras)

;;; dsh-bridge-extras.el ends here
