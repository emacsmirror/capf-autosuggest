;;; capf-autosuggest.el --- Show first completion-at-point as an overlay -*- lexical-binding: t; -*-

;; Filename: capf-autosuggest.el
;; Description: Show first completion-at-point as an overlay
;; Author: jakanakaevangeli <jakanakaevangeli@chiru.no>
;; Created: 2021-07-13
;; Version: 1.0
;; URL: https://github.com/jakanakaevangeli/emacs-capf-autosuggest

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; capf-autosuggest lets you preview the most recent matching history element,
;; similar to zsh-autosuggestions or fish.  It works in eshell and in modes
;; derived from comint-mode, for example M-x shell or M-x run-python.
;;
;; Installation:
;;
;; Add the following to your Emacs init file:
;;
;;  (add-to-list 'load-path "/path/to/emacs-capf-autosuggest")
;;  (require 'capf-autosuggest)
;;  (add-hook 'comint-mode-hook #'capf-autosuggest-setup-comint)
;;  (add-hook 'eshell-mode-hook #'capf-autosuggest-setup-eshell)
;;
;; Configuration:
;;
;; Use `capf-autosuggest-define-partial-accept-cmd' to make a command that can
;; move point into an auto-suggested layer.
;;
;; Example: to make C-M-f (forward-sexp) movable into suggested text, put the
;; following into you init file:
;;
;;  (with-eval-after-load 'capf-autosuggest
;;    (capf-autosuggest-define-partial-accept-cmd
;;     movable-forward-sexp forward-sexp)
;;    (define-key capf-autosuggest-active-mode-map [remap forward-sexp]
;;      #'movable-forward-sexp))
;;
;; By default, C-n (next-line) will accept the currently displayed suggestion
;; and send input to shell/eshell.  See the customization group
;; capf-autosuggest do disable this behaviour or enable it for other commands,
;; such as C-c C-n or M-n.
;;
;; Details:
;;
;; capf-autosuggest provides a minor mode, capf-autosuggest-mode, that lets you
;; preview the first completion candidate for in-buffer completion as an
;; overlay.  Instead of using the default hook `completion-at-point-functions',
;; it uses its own hook `capf-autosuggest-capf-functions'.  However, by
;; default, this hook contains a function that reads the default hook, but only
;; if point is at end of line, because an auto-suggested overlay can be
;; annoying in the middle of a line.  If you want, you can try enabling this
;; minor mode in an ordinary buffer for previewing tab completion candidates at
;; end of line.
;;
;; completion-at-point functions for comint and eshell history are also
;; provided.  Because they are less useful for tab completion and more useful
;; for auto-suggestion preview, they should be added to
;; `capf-autosuggest-capf-functions', which doesn't interfere with tab
;; completion.  The setup functions mentioned in "Installation" paragraph add
;; them to this hook locally.  By default, if there are no matches for history
;; completion and point is at end of line, we fall back to previewing the
;; default tab completion candidates, as described in the previous paragraph.
;;
;; You can customize this behaviour by customizing
;; `capf-autosuggest-capf-functions'. For example, you could add
;; `capf-autosuggest-orig-capf' to enable auto-suggestions of tab completion
;; candidates in the middle of a line.
;;
;; Alternatives:
;;
;; There is also esh-autosuggest[1] with similar functionality.  Differences:
;; it is simpler and more concise, however it depends on company. It optionally
;; allows having a delay and it is implemented only for eshell.
;;
;; [1]: http://github.com/dieggsy/esh-autosuggest

;;; Code:

(require 'ring)
(eval-when-compile
  (require 'subr-x)
  (require 'cl-lib))

(defvar comint-input-ring)
(defvar comint-accum-marker)
(defvar comint-use-prompt-regexp)
(defvar eshell-history-ring)
(defvar eshell-last-output-end)
(declare-function eshell-bol "esh-mode")
(declare-function comint-previous-matching-input-from-input "comint")
(declare-function eshell-previous-matching-input-from-input "em-hist")
(declare-function eshell-send-input "esh-mode")
(declare-function eshell-next-prompt "em-prompt")
(declare-function eshell-next-input "em-hist")
(declare-function eshell-next-matching-input-from-input "em-hist")

(defgroup capf-autosuggest nil
  "Show completion-at-point as an overlay."
  :group 'completion
  :prefix "capf-autosuggest-"
  :link
  '(url-link "https://github.com/jakanakaevangeli/emacs-capf-autosuggest"))

;;; Auto-suggestion overlay

(defface capf-autosuggest-face '((t :inherit file-name-shadow))
  "Face used for auto suggestions.")

(defvar capf-autosuggest-capf-functions '(capf-autosuggest-orig-if-at-eol-capf)
  "`completion-at-point-functions', used by capf-autosuggest.
It is used instead of the standard
`completion-at-point-functions', but the default value contains
`capf-autosuggest-orig-if-at-eol-capf' which searches the
standard capf functions, if point is at the end of line.")

(defvar capf-autosuggest-all-completions-only-one nil
  "Non-nil if only the first result of `all-completions' is of interest.
capf-autosuggest binds this to t around calls to
`all-completions'.  A dynamic completion table can take this as a
hint to only return a list of one element for optimization.")

(defvar-local capf-autosuggest--overlay nil)
(defvar-local capf-autosuggest--str "")
(defvar-local capf-autosuggest--tick nil)
(defvar-local capf-autosuggest--region '(nil)
  "Region of `completion-at-point'.")

(defun capf-autosuggest-orig-capf (&optional capf-functions)
  "A capf that chooses from hook variable CAPF-FUNCTIONS.
CAPF-FUNCTIONS defaults to `completion-at-point-functions'.
Don't add this function to `completion-at-point-functions', as
this will result in an infinite loop.  Useful for adding to
`capf-autosuggest-capf-functions', making it search the standard
capf functions."
  (cdr (run-hook-wrapped (or capf-functions 'completion-at-point-functions)
                         #'completion--capf-wrapper 'all)))

(defun capf-autosuggest-orig-if-at-eol-capf ()
  "`capf-autosuggest-orig-capf' if at the end of buffer.
Otherwise, return nil."
  (when (eolp)
    (capf-autosuggest-orig-capf)))

(defvar capf-autosuggest-active-mode)

(defun capf-autosuggest--post-h ()
  "Create an auto-suggest overlay."
  (when capf-autosuggest-active-mode
    ;; `identity' is used to generate slightly faster byte-code
    (pcase-let ((`(,beg . ,end) (identity capf-autosuggest--region)))
      (unless (and (< beg (point) end)
                   (eq (buffer-modified-tick) capf-autosuggest--tick))
        (capf-autosuggest-active-mode -1))))

  (unless capf-autosuggest-active-mode
    (pcase (let ((buffer-read-only t))
             (condition-case _
                 (capf-autosuggest-orig-capf 'capf-autosuggest-capf-functions)
               (buffer-read-only t)))
      (`(,beg ,end ,table . ,plist)
       (let* ((pred (plist-get plist :predicate))
              (string (buffer-substring-no-properties beg end))
              ;; See `completion-emacs21-all-completions'
              (base (car (completion-boundaries string table pred ""))))
         (when-let*
             ((completions
               (let ((capf-autosuggest-all-completions-only-one t))
                 ;; Use `all-completions' rather than
                 ;; `completion-all-completions' to bypass completion styles
                 ;; and strictly match only on prefix.  This makes sense here
                 ;; as we only use the string without the prefix for the
                 ;; overlay.
                 (all-completions string table pred)))
              ;; `all-completions' may return strings that don't strictly
              ;; match on our prefix.  Ignore them.
              ((string-prefix-p (substring string base) (car completions)))
              (str (substring (car completions) (- end beg base)))
              ((/= 0 (length str))))
           (setq capf-autosuggest--region (cons beg end)
                 capf-autosuggest--str (copy-sequence str)
                 capf-autosuggest--tick (buffer-modified-tick))
           (move-overlay capf-autosuggest--overlay end end)
           (when (eq ?\n (aref str 0))
             (setq str (concat " " str)))
           (add-text-properties 0 1 (list 'cursor (length str)) str)
           (add-face-text-property 0 (length str) 'capf-autosuggest-face t str)
           (overlay-put capf-autosuggest--overlay 'after-string str)
           (capf-autosuggest-active-mode)))))))

;;;###autoload
(define-minor-mode capf-autosuggest-mode
  "Auto-suggest first completion at point with an overlay."
  :group 'capf-autosuggest
  (if capf-autosuggest-mode
      (progn
        (setq capf-autosuggest--overlay (make-overlay (point) (point) nil t t))
        (add-hook 'post-command-hook #'capf-autosuggest--post-h nil t)
        (add-hook 'change-major-mode-hook
                  #'capf-autosuggest-active-mode-deactivate nil t))
    (remove-hook 'change-major-mode-hook
                 #'capf-autosuggest-active-mode-deactivate t)
    (remove-hook 'post-command-hook #'capf-autosuggest--post-h t)
    (capf-autosuggest-active-mode -1)))

;;; Various commands and menu-items

;;;###autoload
(defmacro capf-autosuggest-define-partial-accept-cmd (name command)
  "Define a command NAME.
It will call COMMAND interactively, allowing it to move point
into an auto-suggested overlay.  COMMAND must not modify buffer.
NAME must not be called if variable
`capf-autosuggest-active-mode' is inactive.  NAME is suitable for
binding in `capf-autosuggest-active-mode-map'."
  `(defun ,name ()
     ,(format "`%s', possibly moving point into an auto-suggested overlay."
              command)
     (interactive)
     (capf-autosuggest-call-partial-accept-cmd #',command)))

(defun capf-autosuggest-call-partial-accept-cmd (command)
  "Call COMMAND interactively, stepping into auto-suggested overlay.
Temporarily convert the overlay to buffer text and call COMMAND
interactively.  Afterwards, the added text is deleted, but only
the portion after point.  Additionally, if point is outside of
the added text, the whole text is deleted."
  (let (beg end text)
    (with-silent-modifications
      (catch 'cancel-atomic-change
        (atomic-change-group
          (save-excursion
            (goto-char (overlay-start capf-autosuggest--overlay))
            (setq beg (point))
            (insert-and-inherit capf-autosuggest--str)
            (setq end (point)))
          (call-interactively command)
          (and (> (point) beg)
               (<= (point) end)
               (setq text (buffer-substring beg (point))))
          (throw 'cancel-atomic-change nil))))
    (when text
      (if (= (point) beg)
          (insert text)
        (save-excursion
          (goto-char beg)
          (insert text))))))

(declare-function evil-forward-char "ext:evil-commands" nil t)
(declare-function evil-end-of-line "ext:evil-commands" nil t)
(declare-function evil-end-of-visual-line "ext:evil-commands" nil t)
(declare-function evil-end-of-line-or-visual-line "ext:evil-commands" nil t)
(declare-function evil-middle-of-visual-line "ext:evil-commands" nil t)
(declare-function evil-last-non-blank "ext:evil-commands" nil t)
(declare-function evil-forward-word-begin "ext:evil-commands" nil t)
(declare-function evil-forward-word-end "ext:evil-commands" nil t)
(declare-function evil-forward-WORD-begin "ext:evil-commands" nil t)
(declare-function evil-forward-WORD-end "ext:evil-commands" nil t)

(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-forward-word forward-word)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-forward-char forward-char)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-forward-sexp forward-sexp)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-end-of-line end-of-line)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-move-end-of-line move-end-of-line)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-end-of-visual-line end-of-visual-line)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-evil-forward-char evil-forward-char)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-evil-end-of-line evil-end-of-line)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-evil-end-of-visual-line evil-end-of-visual-line)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-evil-end-of-line-or-visual-line evil-end-of-line-or-visual-line)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-evil-middle-of-visual-line evil-middle-of-visual-line)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-evil-last-non-blank evil-last-non-blank)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-evil-forward-word-begin evil-forward-word-begin)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-evil-forward-word-end evil-forward-word-end)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-evil-forward-WORD-begin evil-forward-WORD-begin)
(capf-autosuggest-define-partial-accept-cmd capf-autosuggest-evil-forward-WORD-end evil-forward-WORD-end)

(defun capf-autosuggest-accept ()
  "Accept current auto-suggestion.
Do not call this command if variable `capf-autosuggest-active-mode' is
inactive."
  (interactive)
  (capf-autosuggest-call-partial-accept-cmd
   (lambda ()
     (interactive)
     (goto-char (overlay-start capf-autosuggest--overlay)))))

(defun capf-autosuggest-comint-previous-matching-input-from-input (n)
  "Like `comint-previous-matching-input-from-input'.
But increase arument N by 1, if positive, but not on command
repetition."
  (interactive "p")
  (and (not (memq last-command '(comint-previous-matching-input-from-input
                                 comint-next-matching-input-from-input)))
       (> n 0)
       (setq n (1+ n)))
  (comint-previous-matching-input-from-input n)
  (setq this-command #'comint-previous-matching-input-from-input))

(defun capf-autosuggest-eshell-previous-matching-input-from-input (n)
  "Like `eshell-previous-matching-input-from-input'.
But increase arument N by 1, if positive, but not on command
repetition."
  (interactive "p")
  (and (not (memq last-command '(eshell-previous-matching-input-from-input
                                 eshell-next-matching-input-from-input)))
       (> n 0)
       (setq n (1+ n)))
  (eshell-previous-matching-input-from-input n)
  (setq this-command #'eshell-previous-matching-input-from-input))

(defun capf-autosuggest-comint-send-input ()
  "`capf-autosuggest-accept' and `comint-send-input'."
  (interactive)
  (capf-autosuggest-accept)
  (call-interactively (or (command-remapping #'comint-send-input)
                          #'comint-send-input))
  (setq this-command #'comint-send-input))

(defun capf-autosuggest-eshell-send-input ()
  "`capf-autosuggest-accept' and `eshell-send-input'."
  (interactive)
  (capf-autosuggest-accept)
  (call-interactively (or (command-remapping #'eshell-send-input)
                          #'eshell-send-input))
  (setq this-command #'eshell-send-input))

(defun capf-autosuggest-minibuffer-send-input ()
  "`capf-autosuggest-accept' and `exit-minibuffer'."
  (interactive)
  (capf-autosuggest-accept)
  (call-interactively (or (command-remapping #'exit-minibuffer)
                          #'exit-minibuffer))
  (setq this-command #'exit-minibuffer))

(defcustom capf-autosuggest-dwim-next-line t
  "Whether `next-line' can accept and send current suggestion.
If t and point is on last line, `next-line' will accept the
current suggestion and send input."
  :type 'boolean)
(defcustom capf-autosuggest-dwim-next-prompt nil
  "Whether next-prompt commands can send current suggestion.
If t and point is after the last prompt, `comint-next-prompt' and
`eshell-next-prompt' will accept the current suggestion and send
input."
  :type 'boolean)
(defcustom capf-autosuggest-dwim-next-input nil
  "Whether next-input commands can send current suggestion.
If t and previous command wasn't a history command
(next/previous-input or previous/next-matching-input-from-input),
`comint-next-input' and `eshell-next-input' will accept the
current suggestion and send input."
  :type 'boolean)
(defcustom capf-autosuggest-dwim-next-matching-input-from-input nil
  "Whether next-input commands can send current suggestion.
If t and previous command wasn't a history matching command
(previous or next-matching-input-from-input),
`comint-next-matching-input-from-input' and
`eshell-next-matching-input-from-input' will accept the current
suggestion and send input."
  :type 'boolean)

(defvar capf-autosuggest-active-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap forward-word] #'capf-autosuggest-forward-word)
    (define-key map [remap forward-char] #'capf-autosuggest-forward-char)
    (define-key map [remap forward-sexp] #'capf-autosuggest-forward-sexp)
    (define-key map [remap end-of-line] #'capf-autosuggest-end-of-line)
    (define-key map [remap move-end-of-line] #'capf-autosuggest-move-end-of-line)
    (define-key map [remap end-of-visual-line] #'capf-autosuggest-end-of-visual-line)

    (define-key map [remap evil-forward-char] #'capf-autosuggest-evil-forward-char)
    (define-key map [remap evil-end-of-line] #'capf-autosuggest-evil-end-of-line)
    (define-key map [remap evil-end-of-visual-line] #'capf-autosuggest-evil-end-of-visual-line)
    (define-key map [remap evil-end-of-line-or-visual-line] #'capf-autosuggest-evil-end-of-line-or-visual-line)
    (define-key map [remap evil-middle-of-visual-line] #'capf-autosuggest-evil-middle-of-visual-line)
    (define-key map [remap evil-last-non-blank] #'capf-autosuggest-evil-last-non-blank)
    (define-key map [remap evil-forward-word-begin] #'capf-autosuggest-evil-forward-word-begin)
    (define-key map [remap evil-forward-word-end] #'capf-autosuggest-evil-forward-word-end)
    (define-key map [remap evil-forward-WORD-begin] #'capf-autosuggest-evil-forward-WORD-begin)
    (define-key map [remap evil-forward-WORD-end] #'capf-autosuggest-evil-forward-WORD-end)

    (define-key map [remap eshell-previous-matching-input-from-input]
      #'capf-autosuggest-eshell-previous-matching-input-from-input)
    (define-key map [remap comint-previous-matching-input-from-input]
      #'capf-autosuggest-comint-previous-matching-input-from-input)

    (define-key map [remap next-line]
      (list 'menu-item "" #'next-line :filter
            (lambda (cmd)
              (if (and capf-autosuggest-dwim-next-line
                       (looking-at-p "[^\n]*\n?\\'"))
                  (cond
                   ((derived-mode-p 'comint-mode) #'capf-autosuggest-comint-send-input)
                   ((derived-mode-p 'eshell-mode) #'capf-autosuggest-eshell-send-input)
                   ((minibufferp) #'capf-autosuggest-minibuffer-send-input)
                   (t cmd))
                cmd))))
    (define-key map [remap comint-next-prompt]
      (list 'menu-item "" #'comint-next-prompt :filter
            (lambda (cmd)
              (if (and capf-autosuggest-dwim-next-prompt
                       (comint-after-pmark-p))
                  #'capf-autosuggest-comint-send-input
                cmd))))
    (define-key map [remap eshell-next-prompt]
      (list 'menu-item "" #'eshell-next-prompt :filter
            (lambda (cmd)
              (if (and capf-autosuggest-dwim-next-prompt
                       (>= (point) eshell-last-output-end))
                  #'capf-autosuggest-comint-send-input
                cmd))))
    (define-key map [remap comint-next-input]
      (list 'menu-item "" #'comint-next-input :filter
            (lambda (cmd)
              (if (or (not capf-autosuggest-dwim-next-input)
                      (memq last-command
                            '(comint-next-matching-input-from-input
                              comint-previous-matching-input-from-input
                              comint-next-input comint-previous-input)))
                  cmd
                #'capf-autosuggest-comint-send-input))))
    (define-key map [remap eshell-next-input]
      (list 'menu-item "" #'eshell-next-input :filter
            (lambda (cmd)
              (if (or (not capf-autosuggest-dwim-next-input)
                      (memq last-command
                            '(eshell-next-matching-input-from-input
                              eshell-previous-matching-input-from-input
                              eshell-next-input eshell-previous-input)))
                  cmd
                #'capf-autosuggest-eshell-send-input))))
    (define-key map [remap comint-next-matching-input-from-input]
      (list 'menu-item "" #'comint-next-matching-input-from-input :filter
            (lambda (cmd)
              (if (or (not capf-autosuggest-dwim-next-matching-input-from-input)
                      (memq last-command
                            '(comint-next-matching-input-from-input
                              comint-previous-matching-input-from-input)))
                  cmd
                #'capf-autosuggest-comint-send-input))))
    (define-key map [remap eshell-next-matching-input-from-input]
      (list 'menu-item "" #'eshell-next-matching-input-from-input :filter
            (lambda (cmd)
              (if (or (not capf-autosuggest-dwim-next-matching-input-from-input)
                      (memq last-command
                            '(eshell-previous-matching-input-from-input
                              eshell-next-matching-input-from-input)))
                  cmd
                #'capf-autosuggest-eshell-send-input))))
    map)
  "Keymap active when an auto-suggestion is shown.")

(define-minor-mode capf-autosuggest-active-mode
  "Active when auto-suggested overlay is shown."
  :group 'capf-autosuggest
  (unless capf-autosuggest-active-mode
    (delete-overlay capf-autosuggest--overlay)))

(defun capf-autosuggest-active-mode-deactivate ()
  "Deactivate `capf-autosuggest-active-mode'."
  (capf-autosuggest-active-mode -1))

;;;; History completion function

;;;###autoload
(defun capf-autosuggest-comint-capf ()
  "Completion-at-point function for comint input history.
Is only applicable if point is after the last prompt."
  (let ((ring comint-input-ring)
        (beg nil))
    (and ring (ring-p ring) (not (ring-empty-p ring))
         (or (and (setq beg comint-accum-marker)
                  (setq beg (marker-position beg)))
             (and (setq beg (get-buffer-process (current-buffer)))
                  (setq beg (marker-position (process-mark beg)))))
         (>= (point) beg)
         (list beg (if comint-use-prompt-regexp
                       (line-end-position)
                     (field-end))
               (capf-autosuggest--completion-table ring)
               :exclusive 'no))))

(defun capf-autosuggest-eshell-capf ()
  "Completion-at-point function for eshell input history.
Is only applicable if point is after the last prompt."
  (let ((ring eshell-history-ring)
        (beg nil))
    (and ring (ring-p ring) (not (ring-empty-p ring))
         (setq beg eshell-last-output-end)
         (setq beg (marker-position beg))
         (>= (point) beg)
         (list (save-excursion (eshell-bol) (point)) (point-max)
               (capf-autosuggest--completion-table ring)
               :exclusive 'no))))

(defun capf-autosuggest--completion-table (ring)
  "Return a completion table to complete on RING."
  (let (self)
    (setq
     self
     (lambda (input predicate action)
       (cond
        ((eq action t)
         (cl-loop
          with only-one = capf-autosuggest-all-completions-only-one
          with regexps = completion-regexp-list
          for i below (ring-size ring)
          for elem = (ring-ref ring i)
          if (string-prefix-p input elem)
          if (cl-loop for regex in regexps
                      always (string-match-p regex elem))
          if (or (null predicate)
                 (funcall predicate elem))
          if only-one
          return (list elem)
          else collect elem))
        ((eq action nil)
         (complete-with-action
          nil (let ((capf-autosuggest-all-completions-only-one nil))
                (funcall self input predicate t))
          input predicate))
        ((eq action 'lambda)
         (and (ring-member ring input)
              (or (null predicate)
                  (funcall predicate input))
              (cl-loop for regex in completion-regexp-list
                       always (string-match-p regex input))))
        (t (complete-with-action
            action (ring-elements ring) input predicate)))))))

;;;###autoload
(defun capf-autosuggest-setup-comint ()
  "Setup capf-autosuggest for history suggestion in comint."
  (capf-autosuggest-mode)
  (add-hook 'capf-autosuggest-capf-functions #'capf-autosuggest-comint-capf nil t))

;;;###autoload
(defun capf-autosuggest-setup-eshell ()
  "Setup capf-autosuggest for history suggestion in eshell."
  (capf-autosuggest-mode)
  (add-hook 'capf-autosuggest-capf-functions #'capf-autosuggest-eshell-capf nil t))

;;;###autoload
(defun capf-autosuggest-setup-minibuffer ()
  "Setup capf-autosuggest for history suggestion in the minibuffer."
  (let ((hist minibuffer-history-variable)
        (should-prin1 nil))
    (when (and (not (eq t hist))
               (setq hist (symbol-value hist)))
      (when (eq minibuffer-history-sexp-flag (minibuffer-depth))
        (setq should-prin1 t))
      (capf-autosuggest-mode)
      (add-hook 'capf-autosuggest-capf-functions
                (lambda ()
                  (when should-prin1
                    (setq hist (mapcar #'prin1-to-string hist)
                          should-prin1 nil))
                  (list (minibuffer-prompt-end)
                        (point-max)
                        hist
                        :exclusive 'no))
                nil t))))

(provide 'capf-autosuggest)
;;; capf-autosuggest.el ends here
