;;; dsh-bridge-extras.el --- Optional DSH item inspector  -*- lexical-binding: t; -*-

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

;; Optional companion to `dsh-bridge'.  DSH-View supplies the turn overview;
;; this library shows only the activity item at point: one reasoning block,
;; one logical tool invocation, or one orphan result.  Detail is fetched on
;; demand through the read-only `/details/item' route.  Nothing is inserted
;; into DSH-View or its incremental rendering state.

;;; Code:

(require 'dsh-bridge)
(require 'json)
(require 'url-util)
(require 'button)
(require 'subr-x)

(declare-function markdown-mode "markdown-mode")
(declare-function gfm-mode "markdown-mode")
(declare-function font-lock-ensure "font-lock" (&optional beg end))

(defgroup dsh-bridge-extras nil
  "Optional single-item inspector for the DSH Emacs bridge."
  :group 'dsh-bridge)

(defcustom dsh-bridge-extras-buffer-name "*DSH Inspector*"
  "Name of the read-only DSH item inspector buffer."
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
  "Face for an item subsection heading."
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

(defvar-keymap dsh-bridge-extras-mode-map
  :doc "Keymap for `dsh-bridge-extras-mode'."
  :parent special-mode-map
  "g" #'dsh-bridge-extras-refresh
  "RET" #'dsh-bridge-extras-enter
  "f" #'dsh-bridge-extras-show-in-view
  "D" #'dsh-bridge-extras-describe-session
  "r" #'dsh-bridge-extras-open-prompt
  "l" #'dsh-bridge-list-sessions
  "q" #'quit-window)

(define-derived-mode dsh-bridge-extras-mode special-mode "DSH-Inspector"
  "Major mode for inspecting one DSH activity item.
The buffer is read-only and shows one reasoning block, logical tool
invocation, or orphan result.  Long lines are wrapped by
`visual-line-mode'.  \\[dsh-bridge-extras-refresh] refreshes that item;
RET activates a file-name button.
\\{dsh-bridge-extras-mode-map}"
  (setq buffer-read-only t)
  (visual-line-mode 1))

(defvar-local dsh-bridge-extras--session nil
  "The session id containing the inspected item.")

(defvar-local dsh-bridge-extras--turn nil
  "The concrete turn containing the inspected item.")

(defvar-local dsh-bridge-extras--selector nil
  "The current item's thinking, tool, or orphan-result selector.")

(defvar-local dsh-bridge-extras--item nil
  "The last successful item response, or nil.")

(defvar-local dsh-bridge-extras--epoch nil
  "The observation's surface replacement-generation count.")

(defvar-local dsh-bridge-extras--cursor nil
  "The observation's terminal log cursor.")

(defvar-local dsh-bridge-extras--cwd nil
  "The effective working directory reported with the item.")

(defvar-local dsh-bridge-extras--parts nil
  "Hash table mapping a content-part key to its complete text state.")

(defvar-local dsh-bridge-extras--full-loaded nil
  "Whether the current item was fetched in full, above the probe threshold.")

(defvar-local dsh-bridge-extras--status nil
  "A status or error notice to show in the inspector, or nil.")

(defvar-local dsh-bridge-extras--generation 0
  "Monotonic request generation for this inspector buffer.")

(defvar-local dsh-bridge-extras--inflight nil
  "A token identifying the current request, or nil.")

;;; Session accessor

(defun dsh-bridge-extras-session ()
  "Return the session id of the item in the current DSH-Inspector buffer.
Return nil outside `dsh-bridge-extras-mode'."
  (and (derived-mode-p 'dsh-bridge-extras-mode)
       dsh-bridge-extras--session))

;;; Selectors and query paths

(defun dsh-bridge-extras--property-at-line (property)
  "Return text PROPERTY at point or at the start of the current line."
  (or (get-text-property (point) property)
      (save-excursion
        (beginning-of-line)
        (get-text-property (point) property))))

(defun dsh-bridge-extras--identity-at-point ()
  "Return the activity selector at point in a DSH-View, or nil."
  (when (derived-mode-p 'dsh-bridge-view-mode)
    (let ((activity (dsh-bridge-extras--property-at-line 'dsh-bridge-activity)))
      (cond
       ((and (consp activity) (eq (car activity) 'tool-result))
        (list :kind 'tool-result :call-id (cdr activity)))
       ((consp activity)
        (list :kind 'thinking :seq (car activity) :ord (cdr activity)))
       ((stringp activity)
        (list :kind 'tool :call-id activity))))))

(defun dsh-bridge-extras--query (pairs)
  "Encode PAIRS, a list of (NAME . VALUE), as a query string."
  (mapconcat (lambda (pair)
               (concat (url-hexify-string (car pair)) "="
                       (url-hexify-string (cdr pair))))
             pairs "&"))

(defun dsh-bridge-extras--selector-params (selector)
  "Return query parameters for item SELECTOR."
  (let ((kind (plist-get selector :kind)))
    (cons (cons "kind" (symbol-name kind))
          (pcase kind
            ('thinking
             (list (cons "seq" (number-to-string (plist-get selector :seq)))
                   (cons "ord" (number-to-string (plist-get selector :ord)))))
            ((or 'tool 'tool-result)
             (list (cons "callId" (plist-get selector :call-id))))
            (_ (error "Unknown DSH item selector: %S" selector))))))

(defun dsh-bridge-extras--activity-key (selector)
  "Return the DSH-View activity identity for item SELECTOR, or nil."
  (pcase (plist-get selector :kind)
    ('thinking (cons (plist-get selector :seq) (plist-get selector :ord)))
    ('tool (plist-get selector :call-id))
    ('tool-result (cons 'tool-result (plist-get selector :call-id)))
    (_ nil)))

(defun dsh-bridge-extras--item-path (session turn selector &optional full)
  "Return the item route for SESSION, TURN, and SELECTOR.
FULL requests the complete item without the confirmation threshold."
  (concat "/details/item?"
          (dsh-bridge-extras--query
           (append
            (list (cons "sessionId" session)
                  (cons "turn" (number-to-string turn)))
            (dsh-bridge-extras--selector-params selector)
            (when full (list (cons "full" "1")))))))

;;; Content-part state

(defun dsh-bridge-extras--part (key)
  "Return the accumulated state for content-part KEY."
  (and (hash-table-p dsh-bridge-extras--parts)
       (gethash key dsh-bridge-extras--parts)))

(defun dsh-bridge-extras--store-part (key part)
  "Store the complete PART under KEY."
  (puthash key
           (list :text (or (alist-get 'text part) "")
                 :total (alist-get 'totalBytes part))
           dsh-bridge-extras--parts))

(defun dsh-bridge-extras--store-initial-parts (response)
  "Initialize the buffer's content parts from item RESPONSE."
  (let ((parts (alist-get 'parts response)))
    (dolist (name '(reasoning arguments result))
      (when-let* ((part (alist-get name parts)))
        (dsh-bridge-extras--store-part name part)))
    (let ((index 0))
      (dolist (file (append (alist-get 'files response) nil))
        (dsh-bridge-extras--store-part (list 'diff index) (alist-get 'diff file))
        (setq index (1+ index))))))

;;; Requests

(defun dsh-bridge-extras--error-message (status alist)
  "Return a user-facing message for failed request STATUS and ALIST."
  (cond
   ((null status) "host unreachable")
   ((numberp status)
    (format "HTTP %s: %s" status
            (or (alist-get 'error alist)
                (alist-get 'reason alist)
                "request failed")))
   (t "request failed")))

(defun dsh-bridge-extras--handle-deferred (response)
  "Ask whether to load the large item RESPONSE in full."
  (let* ((total (alist-get 'totalBytes response))
         (size (if (numberp total)
                   (file-size-human-readable total)
                 "large"))
         (load (y-or-n-p
                (format "This item contains %s of content; load it all?" size))))
    (if load
        (progn
          (setq dsh-bridge-extras--status "Loading full item..."
                dsh-bridge-extras--generation
                (1+ dsh-bridge-extras--generation))
          (dsh-bridge-extras--render)
          (dsh-bridge-extras--request t))
      (setq dsh-bridge-extras--status
            (format "Large item (%s) not loaded; press g to load." size))
      (dsh-bridge-extras--render)
      (message "dsh-bridge-extras: large item not loaded"))))

(defun dsh-bridge-extras--request (&optional full)
  "Fetch the current item, asking for the complete item when FULL is non-nil."
  (when (and dsh-bridge-extras--session
             (numberp dsh-bridge-extras--turn)
             dsh-bridge-extras--selector
             (not dsh-bridge-extras--inflight))
    (let* ((buffer (current-buffer))
           (generation dsh-bridge-extras--generation)
           (session dsh-bridge-extras--session)
           (turn dsh-bridge-extras--turn)
           (selector dsh-bridge-extras--selector)
           (request (make-symbol "item-request")))
      (setq dsh-bridge-extras--inflight request)
      (dsh-bridge--request-async
       "GET" (dsh-bridge-extras--item-path session turn selector full)
       nil
       (lambda (result)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (and (eq dsh-bridge-extras--inflight request)
                        (= generation dsh-bridge-extras--generation)
                        (equal session dsh-bridge-extras--session)
                        (equal turn dsh-bridge-extras--turn)
                        (equal selector dsh-bridge-extras--selector))
               (setq dsh-bridge-extras--inflight nil)
               (dsh-bridge-extras--handle-item result)))))))))

(defun dsh-bridge-extras--handle-item (result)
  "Apply an item RESULT, prompting when the host withheld a large payload."
  (let ((status (car result))
        (response (cdr result)))
    (if (not (eq status 200))
        (progn
          (setq dsh-bridge-extras--status
                (dsh-bridge-extras--error-message status response))
          (unless dsh-bridge-extras--item
            (setq dsh-bridge-extras--status
                  (format "Could not load this item: %s"
                          dsh-bridge-extras--status)))
          (message "dsh-bridge-extras: %s" dsh-bridge-extras--status)
          (dsh-bridge-extras--render))
      (setq dsh-bridge-extras--item response
            dsh-bridge-extras--epoch (alist-get 'epoch response)
            dsh-bridge-extras--cursor (alist-get 'cursor response)
            dsh-bridge-extras--cwd (alist-get 'cwd response)
            dsh-bridge-extras--full-loaded
            (not (eq (alist-get 'deferred response) t))
            dsh-bridge-extras--parts (make-hash-table :test #'equal)
            dsh-bridge-extras--status nil)
      (dsh-bridge-extras--store-initial-parts response)
      (when dsh-bridge-extras--cwd
        (dsh-bridge--apply-session-directory
         dsh-bridge-extras--session dsh-bridge-extras--cwd))
      (dsh-bridge-extras--render)
      (when (eq (alist-get 'deferred response) t)
        (dsh-bridge-extras--handle-deferred response)))))

;;; Markdown, JSON, and diff presentation

(defun dsh-bridge-extras--markdown-available-p ()
  "Return non-nil when Markdown mode is installed."
  (and (require 'markdown-mode nil t) t))

(defun dsh-bridge-extras--line-count (text)
  "Return the number of lines in TEXT."
  (if (string-empty-p text) 0 (1+ (seq-count (lambda (ch) (eq ch ?\n)) text))))

(defun dsh-bridge-extras--whitelisted-properties (text)
  "Copy TEXT keeping only face and font-lock-face text properties."
  (let ((pos 0)
        (length (length text))
        (pieces nil))
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
              pieces)
        (setq pos end)))
    (apply #'concat (nreverse pieces))))

(defun dsh-bridge-extras--fontify-markdown (text)
  "Return TEXT Markdown-fontified when possible, else verbatim.
Text over the byte/line bounds is returned unfontified, never truncated."
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
  (insert (or (dsh-bridge-extras--fontify-markdown text)
              (propertize text 'face 'dsh-bridge-view-thinking-face)))
  (unless (string-suffix-p "\n" text) (insert "\n")))

(defun dsh-bridge-extras--pretty-json (text)
  "Return TEXT pretty-printed as JSON, or nil when it is not valid JSON."
  (condition-case nil
      (with-temp-buffer
        (insert text)
        (json-pretty-print-buffer)
        (let ((pretty (buffer-string)))
          (unless (string= (string-trim pretty) (string-trim text)) pretty)))
    (error nil)))

(defun dsh-bridge-extras--insert-json (text)
  "Insert arguments TEXT, pretty-printed when valid JSON."
  (let ((pretty (dsh-bridge-extras--pretty-json text)))
    (if pretty
        (progn
          (insert (propertize (substring-no-properties pretty)
                              'face 'dsh-bridge-extras-code-face))
          (unless (string-suffix-p "\n" pretty) (insert "\n")))
      (insert text)
      (unless (string-suffix-p "\n" text) (insert "\n")))))

(defun dsh-bridge-extras--diff-face (line)
  "Return the face for one rendered diff LINE, or nil."
  (cond
   ((string-prefix-p "File: " line) 'dsh-bridge-extras-file-face)
   ((string-prefix-p "+" line) (if (facep 'diff-added) 'diff-added 'highlight))
   ((string-prefix-p "-" line) (if (facep 'diff-removed) 'diff-removed 'shadow))
   ((string-prefix-p "  " line) 'dsh-bridge-extras-note-face)
   ((string-prefix-p " " line) (if (facep 'diff-context) 'diff-context 'default))
   (t 'dsh-bridge-extras-note-face)))

(defun dsh-bridge-extras--insert-diff-text (text absolute)
  "Insert rendered diff TEXT with diff faces, never as an appliable patch.
ABSOLUTE is the file's host path; the `File: ' line names it as a button."
  (require 'diff-mode nil t)
  (dolist (line (split-string text "\n"))
    (unless (string-empty-p line)
      (if (and absolute (string-prefix-p "File: " line))
          (progn
            (insert (propertize "File: " 'face 'dsh-bridge-extras-note-face))
            (insert-text-button (substring line 6)
                                'path absolute
                                'action #'dsh-bridge--button-visit
                                'follow-link t
                                'help-echo "mouse-1/RET: visit this file")
            (insert "\n"))
        (let ((face (dsh-bridge-extras--diff-face line)))
          (insert (if face (propertize line 'face face) line) "\n"))))))

;;; Rendering

(defun dsh-bridge-extras--item-files ()
  "Return file metadata for the current tool or orphan-result item."
  (append (or (alist-get 'files dsh-bridge-extras--item)
              (alist-get 'files (alist-get 'result dsh-bridge-extras--item)))
          nil))

(defun dsh-bridge-extras--insert-title ()
  "Insert the current item's title and metadata."
  (let* ((item dsh-bridge-extras--item)
         (kind (and item (intern (or (alist-get 'kind item) ""))))
         (session (dsh-bridge-extras-session))
         (label (and session
                     (or (dsh-bridge--session-label session nil t) session)))
         (title (pcase kind
                  ('thinking (format "Thinking — step %s"
                                     (or (alist-get 'step item) "?")))
                  ('tool (format "%s%s"
                                 (or (alist-get 'name item) "Tool")
                                 (if (equal (alist-get 'settlement item) "pending")
                                     " (pending)" "")))
                  ('tool-result (format "%s result (orphan)"
                                        (or (alist-get 'name item) "Tool")))
                  (_ "DSH Inspector"))))
    (insert (propertize (concat title "\n") 'face 'dsh-bridge-extras-heading-face))
    (insert (propertize "Session      " 'face 'dsh-bridge-extras-note-face))
    (if session
        (insert-text-button label
                            'action (lambda (button)
                                      (dsh-bridge-describe-session
                                       (button-get button 'dsh-bridge-session-id)))
                            'dsh-bridge-session-id session
                            'follow-link t
                            'help-echo "mouse-1: describe this session")
      (insert "?"))
    (insert (propertize (format "   Turn %s\n" (or dsh-bridge-extras--turn "?"))
                        'face 'dsh-bridge-extras-note-face))
    (when (and session label (not (equal label session)))
      (insert (propertize (format "Id           %s\n" session)
                          'face 'dsh-bridge-extras-note-face)))
    (when dsh-bridge-extras--cwd
      (insert (propertize (format "Directory    %s\n" dsh-bridge-extras--cwd)
                          'face 'dsh-bridge-extras-note-face)))
    (when (and item dsh-bridge-extras--epoch dsh-bridge-extras--cursor)
      (insert (propertize (format "Observation  epoch %s, cursor %s\n"
                                  dsh-bridge-extras--epoch
                                  dsh-bridge-extras--cursor)
                          'face 'dsh-bridge-extras-note-face)))
    (when-let* ((status dsh-bridge-extras--status))
      (insert (propertize (concat status "\n") 'face 'dsh-bridge-extras-error-face)))
    (insert "\n")))

(defun dsh-bridge-extras--insert-section (title)
  "Insert an item subsection TITLE."
  (unless (bobp) (insert "\n"))
  (insert (propertize (concat title "\n") 'face 'dsh-bridge-extras-section-face)))

(defun dsh-bridge-extras--insert-text-part (key renderer)
  "Insert content-part KEY through RENDERER."
  (when-let* ((state (dsh-bridge-extras--part key)))
    (funcall renderer (plist-get state :text))))

(defun dsh-bridge-extras--insert-result-metadata ()
  "Insert non-text result blocks and structured errors for the item."
  (let* ((result (or (alist-get 'result dsh-bridge-extras--item)
                     dsh-bridge-extras--item))
         (content (alist-get 'content result)))
    (when (eq (alist-get 'isError result) t)
      (insert (propertize "Tool reported an error.\n"
                          'face 'dsh-bridge-extras-error-face)))
    (dolist (block (append (alist-get 'blocks content) nil))
      (insert (propertize
               (format "[%s%s%s]\n"
                       (or (alist-get 'type block) "block")
                       (if-let* ((media (alist-get 'mediaType block)))
                           (format " %s" media) "")
                       (if-let* ((bytes (alist-get 'bytes block)))
                           (format " %s bytes" bytes) ""))
               'face 'dsh-bridge-extras-note-face)))
    (when (> (or (alist-get 'omittedBlocks content) 0) 0)
      (insert (propertize
               (format "(%d block(s) not displayed)\n"
                       (alist-get 'omittedBlocks content))
               'face 'dsh-bridge-extras-note-face)))
    (when-let* ((error (alist-get 'error result)))
      (insert (propertize
               (format "Error: %s%s\n"
                       (or (alist-get 'name error) "tool")
                       (if-let* ((code (alist-get 'code error)))
                           (format " (%s)" code) ""))
               'face 'dsh-bridge-extras-error-face))
      (when-let* ((reason (alist-get 'reason error)))
        (unless (string-empty-p reason) (insert reason "\n"))))))

(defun dsh-bridge-extras--insert-tool-body ()
  "Render the current logical tool or orphan-result item."
  (when (equal (alist-get 'kind dsh-bridge-extras--item) "tool-result")
    (insert (propertize "No call arguments (orphan tool result).\n"
                        'face 'dsh-bridge-extras-note-face)))
  (when (dsh-bridge-extras--part 'arguments)
    (dsh-bridge-extras--insert-section "Arguments")
    (dsh-bridge-extras--insert-text-part
     'arguments
     (lambda (text)
       (dsh-bridge-extras--insert-json text))))
  (when (dsh-bridge-extras--part 'result)
    (dsh-bridge-extras--insert-section "Result")
    (dsh-bridge-extras--insert-text-part
     'result (lambda (text)
               (insert text)
               (unless (string-suffix-p "\n" text) (insert "\n"))))
    (dsh-bridge-extras--insert-result-metadata))
  (let ((files (dsh-bridge-extras--item-files))
        (index 0))
    (while (dsh-bridge-extras--part (list 'diff index))
      (when (= index 0) (dsh-bridge-extras--insert-section "Changed files"))
      (let* ((key (list 'diff index))
             (file (nth index files))
             (absolute (alist-get 'absolute file)))
        (dsh-bridge-extras--insert-diff-text
         (plist-get (dsh-bridge-extras--part key) :text) absolute))
      (setq index (1+ index)))
    (when (> (or (alist-get 'droppedFiles dsh-bridge-extras--item) 0) 0)
      (insert (propertize
               (format "(%d durable file change(s) omitted by the bridge)\n"
                       (alist-get 'droppedFiles dsh-bridge-extras--item))
               'face 'dsh-bridge-extras-note-face)))))

(defun dsh-bridge-extras--render ()
  "Render the current item from its response and complete content parts."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (dsh-bridge-extras--insert-title)
    (when (and dsh-bridge-extras--item
               (or dsh-bridge-extras--full-loaded
                   (not (eq (alist-get 'deferred dsh-bridge-extras--item) t))))
      (if (equal (alist-get 'kind dsh-bridge-extras--item) "thinking")
          (dsh-bridge-extras--insert-text-part
           'reasoning (lambda (text)
                        (dsh-bridge-extras--insert-markdown text)))
        (dsh-bridge-extras--insert-tool-body)))
    (setq buffer-read-only t)
    (goto-char (point-min))
    (forward-line (max 0 (1- line)))
    (set-buffer-modified-p nil)))

;;; Commands

(defun dsh-bridge-extras--goto-view-item (key)
  "Move point to the DSH-View activity line for KEY.
Return non-nil when the line was found."
  (widen)
  (goto-char (point-min))
  (when-let* ((match (text-property-search-forward
                      'dsh-bridge-activity key #'equal)))
    (goto-char (prop-match-beginning match))
    t))

(defun dsh-bridge-extras-enter ()
  "Activate the file button at point."
  (interactive)
  (if (button-at (point))
      (push-button (point))
    (user-error "No action at point")))

(defun dsh-bridge-extras-describe-session ()
  "Show the DSH-Describe report for the inspected item's session."
  (interactive)
  (let ((session (dsh-bridge-extras-session)))
    (if session
        (dsh-bridge-describe-session session)
      (message "No DSH session for this buffer."))))

(defun dsh-bridge-extras-open-prompt ()
  "Open a DSH-Prompt buffer for the inspected item's session."
  (interactive)
  (let ((session (dsh-bridge-extras-session)))
    (if session
        (pop-to-buffer (dsh-bridge--prompt-buffer session)
                       dsh-bridge-prompt-display-action)
      (message "No DSH session for this buffer."))))

(defun dsh-bridge-extras-show-in-view ()
  "Show the inspected item at its line in a DSH-View buffer.
Reuse a view already showing the session.  When that view shows another
turn, select the item's turn from its cached history.  If no view exists,
report rather than opening or resuming one."
  (interactive)
  (let* ((session dsh-bridge-extras--session)
         (turn dsh-bridge-extras--turn)
         (key (and dsh-bridge-extras--selector
                   (dsh-bridge-extras--activity-key
                    dsh-bridge-extras--selector)))
         (views (and session (dsh-bridge--session-views session)))
         (turns (and session (dsh-bridge--turns-cache-turns session))))
    (cond
     ((or (null session) (not (numberp turn)) (null key))
      (message "dsh-bridge-extras: no activity item to show"))
     ((null views)
      (message "dsh-bridge-extras: no DSH-View buffer for this session"))
     (t
      (let* ((buffer
              (or (seq-find (lambda (view)
                              (with-current-buffer view
                                (equal dsh-bridge--view-turn turn)))
                            views)
                  (car views)))
             (index (seq-position
                     turns turn
                     (lambda (record wanted)
                       (equal (alist-get 'turn record) wanted)))))
        (with-current-buffer buffer
          (let ((activity-was-off (null dsh-bridge--view-activity))
                (turn-changed (not (equal dsh-bridge--view-turn turn))))
            (when activity-was-off
              (setq-local dsh-bridge--view-activity t))
            (if (and (or activity-was-off turn-changed)
                     (not (numberp index)))
                (message "dsh-bridge-extras: turn %s is not in this view's cached history"
                         turn)
              (when (or activity-was-off turn-changed)
                (dsh-bridge--view-show-turn index turns))
              (if (and (equal dsh-bridge--view-turn turn)
                       (dsh-bridge-extras--goto-view-item key))
                  (progn
                    (pop-to-buffer
                     buffer
                     '((display-buffer-reuse-window display-buffer-same-window)))
                    (when (get-buffer-window buffer)
                      (recenter)))
                (message "dsh-bridge-extras: item is not visible in the DSH-View"))))))))))

(defun dsh-bridge-extras-inspect-item ()
  "Inspect only the DSH activity item at point.
A thinking line selects one reasoning block, a tool line selects its
logical invocation and result, and an orphan-result line selects that
result.  Refuse when the current DSH-View line names no activity item."
  (interactive)
  (unless (derived-mode-p 'dsh-bridge-view-mode)
    (user-error "No DSH activity item at point"))
  (let ((selector (dsh-bridge-extras--identity-at-point))
        (session dsh-bridge--view-content-session)
        (turn dsh-bridge--view-turn))
    (unless (and selector session (numberp turn))
      (user-error "No DSH activity item at point"))
    (let ((buffer (get-buffer-create dsh-bridge-extras-buffer-name)))
      (with-current-buffer buffer
        (unless (derived-mode-p 'dsh-bridge-extras-mode)
          (dsh-bridge-extras-mode))
        (setq dsh-bridge-extras--generation (1+ dsh-bridge-extras--generation)
              dsh-bridge-extras--session session
              dsh-bridge-extras--turn turn
              dsh-bridge-extras--selector selector
              dsh-bridge-extras--item nil
              dsh-bridge-extras--epoch nil
              dsh-bridge-extras--cursor nil
              dsh-bridge-extras--cwd nil
              dsh-bridge-extras--parts (make-hash-table :test #'equal)
              dsh-bridge-extras--full-loaded nil
              dsh-bridge-extras--status "Loading item..."
              dsh-bridge-extras--inflight nil)
        (dsh-bridge-extras--render)
        (dsh-bridge-extras--request))
      (pop-to-buffer buffer)
      buffer)))

(defun dsh-bridge-extras-refresh ()
  "Re-fetch the current item, preserving it if the refresh fails."
  (interactive)
  (cond
   ((null dsh-bridge-extras--selector)
    (message "dsh-bridge-extras: no item to refresh"))
   (dsh-bridge-extras--inflight
    (message "dsh-bridge-extras: a request is already in flight"))
   (t
    (setq dsh-bridge-extras--generation (1+ dsh-bridge-extras--generation)
          dsh-bridge-extras--status "Refreshing item...")
    (dsh-bridge-extras--render)
    (dsh-bridge-extras--request dsh-bridge-extras--full-loaded))))

(easy-menu-define dsh-bridge-extras-menu dsh-bridge-extras-mode-map
  "Menu bar menu for DSH-Inspector buffers."
  '("DSH Bridge"
    ["Show in DSH-View" dsh-bridge-extras-show-in-view
     :keys "f"
     :help "Move to this item's line in its DSH-View buffer"]
    ["Describe Session" dsh-bridge-extras-describe-session
     :keys "D"
     :help "Show this item's session report"]
    ["Open Prompt Buffer" dsh-bridge-extras-open-prompt
     :keys "r"
     :help "Open a DSH-Prompt buffer for this item's session"]
    "---"
    ["Refresh" dsh-bridge-extras-refresh
     :keys "g"
     :help "Re-fetch this item"]
    "---"
    ["List Sessions" dsh-bridge-list-sessions
     :keys "l"
     :help "Browse DSH sessions"]
    "---"
    ["Quit Window" quit-window
     :keys "q"
     :help "Dismiss this buffer"]))

(provide 'dsh-bridge-extras)

;;; dsh-bridge-extras.el ends here
