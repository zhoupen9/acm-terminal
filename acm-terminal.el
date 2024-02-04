;;; acm-terminal.el --- Patch for LSP bridge acm on Terminal -*- lexical-binding: t; -*-

;; Copyright (C) 2022 Gong Qijian <gongqijian@gmail.com>

;; Author: Gong Qijian <gongqijian@gmail.com>
;; Created: 2022/07/07
;; Version: 0.1.0
;; Last-Updated: 2023-12-06 19:41:42 +0800
;;           By: Gong Qijian
;; Package-Requires: ((emacs "26.1"))
;; URL: https://github.com/twlz0ne/acm-terminal
;; Keywords: 

;; This program is free software; you can redistribute it and/or modify
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

;; Patch for LSP bridge acm on Terminal.

;; ## Requirements

;; - [lsp-bridge](https://github.com/manateelazycat/lsp-bridge) ddf03f3(2022-08-22) or newer
;; - [popon](https://codeberg.org/akib/emacs-popon)

;; ## Installation

;; Clone or download this repository (path of the folder is the `<path-to-acm-terminal>` used below).

;; ## Configuration

;; ```emacs-lisp
;; (require 'yasnippet)
;; (yas-global-mode 1)

;; (require 'lsp-bridge)
;; (global-lsp-bridge-mode)

;; (unless (display-graphic-p)
;;   (add-to-list 'load-path "<path-to-acm-terminal>")
;;   (with-eval-after-load 'acm
;;     (require 'acm-terminal)))
;; ```

;;; Code:

(require 'subr-x)
(require 'acm)
(require 'popon)

(defvar acm-terminal-min-width 45
  "The minimum width of the candidate menu in characters.")

(defvar acm-terminal-max-width 100
  "The maximum width of the candidate menu in characters.")

(defvar acm-terminal-doc-continuation-string "\\"
  "The string showing at the end of wrapped lines.")

(defvar acm-terminal-doc-min-width 40
  "The minimum width of the candidate doc in characters.")

(defvar acm-terminal-doc-max-width 80
  "The maximum width of the candidate doc in characters.")

(defvar acm-terminal-annotation-icons
  '(("Function" . " 󰡱 ")
    ("Keyword" . "  ")
    ("Module" . "  ")
    ("Method" . "  ")
    ("Struct" . "  ")
    ("Snippet" . "  ")
    ("Yas-Snippet" . "  ")
    ("Text" . "  ")
    ("Variable" . " 󰫧 ")
    ("Class" . "  ")
    ("Custom" . "  ")
    ("Feature" . " 󰯺 ")
    ("Macro" . " 󰰏 ")
    ("Interface" . "  ")
    ("Constant" . "  ")
    ("Field" . "  ")
    (nil . " T "))
  "Annotation icons.")

(defcustom acm-terminal-enable-annotation-icon nil
  "Enable annotation icon display instead of text, default false."
  :type 'boolean
  :group 'acm-terminal)

(defvar-local acm-terminal-candidate-doc nil
  "Latest docstring.")

(defvar-local acm-terminal-doc-scroll-start 0
  "Start of doc scrolling.")

(defvar-local acm-terminal-current-input nil
  "Curent input.")

(defface acm-terminal-default-face
  '()
  "Default face for Terminal.")

(defface acm-terminal-select-face
  '()
  "Default select face for Terminal.")

(defun acm-terminal-line-number-display-width ()
  "Return width of line number bar."
  (if (bound-and-true-p display-line-numbers-mode)
      (+ (line-number-display-width) 2)
    0))

(defun acm-terminal-nsplit-string (string width &optional cont)
  "Split STRING into substrings of length WIDTH.

If CONT non-nil, append it to each substring except the last, also, keep the
substring lenght, e.g.:

  (fn \"foobarbazq\" 3 \"↩\") => (\"fo↩\" \"ob↩\" \"ar↩\" \"q\")
  (fn \"foobarbazq\" 3)     => (\"foo\" \"bar\" \"q\") "
  (let* ((cont (or cont ""))
         (cont-width (string-width cont))
         last-column
         lines)
    (with-temp-buffer
      (insert string)
      (when acm-markdown-render-timer
        (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) width)))
          (acm-markdown-render-content)))
      (goto-char (point-min))
      (while (not (eobp))
        (setq last-column (current-column))
        (forward-char)
        (when (eq ?\t (char-before (point)))
          (let ((tab-width (- (current-column) last-column)))
            (backward-delete-char 1)
            (insert (make-string tab-width ?\s))))
        (when (and (not (eolp)) (<= width (current-column)))
          (unless ;; Backward if there is not a pagebreak line
              (and acm-markdown-render-timer
                   (let ((props (text-properties-at (1- (point)))))
                     (and (memq 'display props) (memq 'markdown-hr-face props))))
            (backward-char cont-width))
          (insert cont "\n")))
      (mapcar (lambda (line)
                (truncate-string-to-width line width 0 ?\s))
              (split-string (buffer-string) "\n")))))

(defun acm-terminal-default-background ()
  (or (face-background 'acm-terminal-default-face)
      (pcase (face-background 'default)
        ("unspecified-bg" "white")
        (`,color color))))

(defun acm-terminal-init-colors (&optional force)
  (let* ((is-dark-mode (string-equal (acm-frame-get-theme-mode) "dark"))
         (blend-background (if is-dark-mode "#000000" "#AAAAAA"))
         (default-background (acm-terminal-default-background)))
    ;; Make sure menu follow the theme of Emacs.
    (when (or force (equal (face-attribute 'acm-terminal-default-face :background) 'unspecified))
      (set-face-background 'acm-terminal-default-face (acm-frame-color-blend default-background blend-background (if is-dark-mode 0.8 0.9))))
    (when (or force (equal (face-attribute 'acm-terminal-select-face :background) 'unspecified))
      (set-face-background 'acm-terminal-select-face (acm-frame-color-blend default-background blend-background 0.6)))
    (when (or force (equal (face-attribute 'acm-terminal-select-face :foreground) 'unspecified))
      (set-face-foreground 'acm-terminal-select-face (face-attribute 'font-lock-function-name-face :foreground)))))

(defun acm-terminal-get-popup-position (frame)
  "Return postion of menu."
  (if (and frame (eobp))
      ;; The existing overlay will cause `popon-x-y-at-pos' and `posn-x-y' to
      ;; get the wrong position when point at the and of buffer.
      (let ((pos (popon-position frame))
            (direction (plist-get (cdr frame) :direction))
            (size (popon-size frame)))
        (cons (car pos)
              (if (eq 'top direction)
                  (+ (cdr pos) (cdr size))
                (1- (cdr pos)))))
    (let ((pos (popon-x-y-at-pos acm-menu-frame-popup-point)))
      (if (eobp)
          (cons (car pos) (1+ (cdr pos)))
        pos))))

(defun acm-terminal-popon-visible-p (popon)
  (when (popon-live-p popon)
    (plist-get (cdr popon) :visible)))

(defun acm-terminal-make-popon (text pos &optional window buffer priority)
  "Create an invisible popon with TEXT at POS of WINDOW.
See `popon-create' for more information."
  (cl-letf (((symbol-function 'popon-update) #'ignore))
    (popon-create text pos window buffer priority)))

(defun acm-terminal-make-frame (_)
  "Advice override `acm-make-frame' to make an invisible popon."
  (let ((pos (acm-terminal-get-popup-position nil)))
    (acm-terminal-make-popon (cons "" 0) pos)))

(cl-defmacro acm-terminal-create-frame-if-not-exist (frame _frame-buffer _frame-name &optional _internal-border)
  `(unless (popon-live-p ,frame)
     (setq ,frame (acm-terminal-make-frame nil))))

(defun acm-terminal-max-length (return)
  "Advice to adjust the max lenght."
  (min (+ return 2)
       (- (window-width)
          (+ (- (car (window-inside-edges)) (window-left-column))
             (acm-terminal-line-number-display-width)))))

(defun acm-terminal-menu-item-icon-text (annotation)
  "Returns icon text for given annotation."
  (cdr (assoc annotation acm-terminal-annotation-icons)))

(defun acm-terminal-menu-render-items (items menu-index)
  (let* ((item-index 0)
         ;; The max length is calcuated base on the format
         ;; bellow (see `acm-menu-max-length'):
         ;;
         ;;   {label}\s{annotation}
         ;;
         ;; but in Terminal we render the items in a different way, so the
         ;; calculation format should be:
         ;;
         ;;   {label}\s{annotation}\s
         ;;
         ;; without changing the format, then we should add 1 when using
         ;; `acm-menu-max-length-cache'.
         (max-length (1- acm-menu-max-length-cache)))
    (dolist (v items)
      (let* ((candidate (plist-get v :displayLabel))
             (candidate-length (funcall acm-string-width-function candidate))
             (annotation (plist-get v :annotation))
             (annotation-text (if annotation annotation ""))
             (annotation-length (if acm-terminal-enable-annotation-icon 0 (funcall acm-string-width-function annotation-text)))
             (candidate-max-length (- max-length annotation-length 2))
             (padding-length (if acm-terminal-enable-annotation-icon (- max-length candidate-length 8) (- max-length (+ candidate-length annotation-length) 2)))
             (quick-access-key (nth item-index acm-quick-access-keys))
             candidate-line)

        ;; Render deprecated candidate.
        (when (plist-get v :deprecated)
          (add-face-text-property 0 (length candidate) 'acm-deprecated-face 'append candidate))

        ;; Build candidate line.
        (setq candidate-line
              (concat
               (when acm-terminal-enable-annotation-icon
                 (propertize (format "%s" (acm-terminal-menu-item-icon-text annotation))
                             'face
                             (if (equal item-index menu-index) 'acm-terminal-select-face 'font-lock-doc-face)))
               (when acm-enable-quick-access
                 (if quick-access-key (concat quick-access-key ". ") "   "))
               (if (zerop padding-length)
                   candidate
                 (if (> padding-length 0)
                     (concat candidate (make-string padding-length ?\s))
                   (truncate-string-to-width candidate candidate-max-length
                                             0 ?\s)))
              (if acm-terminal-enable-annotation-icon
                  "\n"
                " ")

              (unless acm-terminal-enable-annotation-icon
                (propertize (format "%s \n" (capitalize annotation-text))
                            'face
                            (if (equal item-index menu-index) 'acm-terminal-select-face 'font-lock-doc-face)))))

        ;; Render current candidate.
        (if (equal item-index menu-index)
            (progn
              (add-face-text-property 0 (length candidate-line) 'acm-terminal-select-face 'append candidate-line)

              ;; Hide doc frame if some backend not support fetch candidate documentation.
              (when (and
                     (not (member (plist-get v :backend) '("lsp" "elisp" "yas")))
                     (acm-frame-visible-p acm-doc-frame))
                (acm-doc-hide)))
          (add-face-text-property 0 (length candidate-line) 'acm-terminal-default-face 'append candidate-line))

        ;; Insert candidate line.
        (insert candidate-line)

        ;; Delete the last extra return line.
        (when (equal item-index (1- (length items)))
          (delete-char -1))

        ;; Update item index.
        (setq item-index (1+ item-index))))))

(defun acm-terminal-markdown-render-content (orig-fn)
  (cl-letf* ((orig-face-attribute (symbol-function #'face-attribute))
             ((symbol-function #'face-attribute)
              (lambda (face attribute &optional frame inherit)
                (if (and (popon-live-p frame)
                         (eq face 'markdown-code-face)
                         (eq attribute :background))
                    (acm-terminal-default-background)
                  (funcall orig-face-attribute face attribute nil inherit)))))
    (funcall orig-fn)))

(defun acm-terminal-doc-render (doc &optional width)
  "Render DOC string."
  (when (and (stringp doc) (not (string-empty-p doc)))
    (let ((width (or width (1- acm-terminal-doc-max-width))))
      (mapcar
       (lambda (line)
         (add-face-text-property 0 (length line) 'acm-terminal-default-face 'append line)
         line)
       (acm-terminal-nsplit-string doc width acm-terminal-doc-continuation-string)))))

(defun acm-terminal-menu-render (menu-old-cache)
  (let* ((items acm-menu-candidates)
         (menu-old-max-length (car menu-old-cache))
         (menu-old-number (cdr menu-old-cache))
         (menu-new-max-length (acm-menu-max-length))
         (menu-new-number (length items))
         (menu-index acm-menu-index))
    ;; Record newest cache.
    (setq acm-menu-max-length-cache menu-new-max-length)
    (setq acm-menu-number-cache menu-new-number)

    ;; Insert menu candidates.
    (when acm-menu-frame
      (let ((lines (split-string
                    (with-temp-buffer
                      (acm-terminal-menu-render-items items menu-index)
                      (buffer-string))
                    "\n")))
        ;; Adjust menu frame position.
        (acm-terminal-menu-adjust-pos acm-menu-frame lines))

      (popon-redisplay)
      (plist-put (cdr acm-menu-frame) :visible t))

    ;; ;; Not adjust menu frame size if not necessary,
    ;; ;; such as select candidate just change index,
    ;; ;; or menu width not change when switch to next page.
    ;; (when (or (not (equal menu-old-max-length menu-new-max-length))
    ;;           (not (equal menu-old-number menu-new-number)))
    ;;   ;; Adjust doc frame with menu frame position.
    ;;   (when (acm-terminal-popon-visible-p acm-doc-frame)
    ;;     (acm-terminal-doc-adjust-pos acm-terminal-candidate-doc)))

    ;; Fetch `documentation' and `additionalTextEdits' information.
    (cl-letf (((symbol-function 'acm-frame-visible-p) 'acm-terminal-popon-visible-p))
      (acm-terminal-doc-try-show))))

(defun acm-terminal-menu-adjust-pos (frame &optional lines)
  "Adjust menu frame position."
  (pcase-let* ((`(,edge-left ,edge-top ,edge-right ,edge-bottom) (window-inside-edges))
               (textarea-width (- (window-width)
                                  (+ (- edge-left (window-left-column))
                                     (acm-terminal-line-number-display-width))))
               (textarea-height (- edge-bottom edge-top))
               (`(,cursor-x . ,cursor-y)
                (prog1 (acm-terminal-get-popup-position acm-menu-frame)
                  (when lines
                    (plist-put (cdr acm-menu-frame) :lines lines)
                    (plist-put (cdr acm-menu-frame) :width (length (car lines))))))
               (`(,menu-w . ,menu-h) (popon-size acm-menu-frame))
               (bottom-free-h (- edge-bottom edge-top cursor-y)))
    (let ((x (if (> textarea-width (+ cursor-x menu-w))
                 cursor-x
               (- cursor-x (- (+ cursor-x menu-w) textarea-width) 1))))
      (plist-put (cdr acm-menu-frame) :x x))
    (cond
     ;; top
     ((<= bottom-free-h menu-h)
      (plist-put (cdr acm-menu-frame) :direction 'top)
      (plist-put (cdr acm-menu-frame) :y (- cursor-y menu-h)))
     ;; bottom
     (t
      (plist-put (cdr acm-menu-frame) :direction 'bottom)
      (plist-put (cdr acm-menu-frame) :y (+ cursor-y 1))))))

(defun acm-terminal-code-action-render (menu-old-cache)
  (let* ((items menu-old-cache);;acm-menu-candidates)
         (menu-old-max-length (car menu-old-cache))
         (menu-old-number (cdr menu-old-cache))
         ;;(menu-new-max-length (acm-menu-max-length))
         (menu-new-max-length 100)
         (menu-new-number (length items))
         (menu-index 0))
    ;; Record newest cache.
    (setq acm-menu-max-length-cache menu-new-max-length)
    (setq acm-menu-number-cache menu-new-number)

    ;; Insert menu candidates.
    (when lsp-bridge-call-hierarchy--frame
      (let ((lines (split-string
                    (with-temp-buffer
                      (acm-terminal-menu-render-items items menu-index)
                      (buffer-string))
                    "\n")))
        ;; Adjust menu frame position.
        (acm-terminal-code-action-adjust-pos lines))

      (popon-redisplay)
      (plist-put (cdr lsp-bridge-call-hierarchy--frame) :visible t))))

(defun acm-terminal-code-action-adjust-pos (&optional lines)
  "Adjust menu frame position."
  (pcase-let* ((`(,edge-left ,edge-top ,edge-right ,edge-bottom) (window-inside-edges))
               (textarea-width (- (window-width)
                                  (+ (- edge-left (window-left-column))
                                     (acm-terminal-line-number-display-width))))
               (textarea-height (- edge-bottom edge-top))
               (`(,cursor-x . ,cursor-y)
                (prog1 (acm-terminal-get-popup-position lsp-bridge-call-hierarchy--frame)
                  (when lines
                    (plist-put (cdr lsp-bridge-call-hierarchy--frame) :lines lines)
                    (plist-put (cdr lsp-bridge-call-hierarchy--frame) :width (length (car lines))))))
               (`(,menu-w . ,menu-h) (popon-size lsp-bridge-call-hierarchy--frame))
               (bottom-free-h (- edge-bottom edge-top cursor-y)))
    (let ((x (if (> textarea-width (+ cursor-x menu-w))
                 cursor-x
               (- cursor-x (- (+ cursor-x menu-w) textarea-width) 1))))
      (plist-put (cdr lsp-bridge-call-hierarchy--frame) :x x))
    (cond
     ;; top
     ((<= bottom-free-h menu-h)
      (plist-put (cdr lsp-bridge-call-hierarchy--frame) :direction 'top)
      (plist-put (cdr lsp-bridge-call-hierarchy--frame) :y (- cursor-y menu-h)))
     ;; bottom
     (t
      (plist-put (cdr lsp-bridge-call-hierarchy--frame) :direction 'bottom)
      (plist-put (cdr lsp-bridge-call-hierarchy--frame) :y (+ cursor-y 1))))))

(defun acm-terminal-doc-get-page (lines start height)
  "Get doc page.

LINES   Doc lines
HEIGHT  Doc frame height
START   Start line"
  (let* ((taken-lines (seq-take (nthcdr start lines) height))
         (height-diff (- height (length taken-lines))))
    (if (< 0 height-diff)
        (append taken-lines
                (let ((blank-line (make-string (length (car taken-lines)) ?\s)))
                  (add-face-text-property
                   0 (length blank-line) 'acm-terminal-default-face 'append blank-line)
                  (make-list height-diff blank-line)))
      taken-lines)))

(defun acm-terminal-doc-top-edge-y (cursor-y menu-h doc-h &optional doc-lines)
  "Return the y-coordinate of doc at left/right top edge, set :lines if possible.

CURSOR-Y        y-coordinate of cursor
MENU-H          height of menu frame
DOC-H           height of doc frame
DOC-LINES       text lines of doc"
  (if (> doc-h cursor-y)
      ;; +---------y-------+--+
      ;; |         |       |  |
      ;; |         |       |  |
      ;; |  +------+       |  |
      ;; |  |      |       |  |
      ;; |  +-menu-+~~doc~~+  |
      ;; |  a|     :.......:  |
      ;; +--------------------+
      (prog1 0
        (when doc-lines
          (plist-put (cdr acm-doc-frame) :lines (seq-take doc-lines cursor-y))))
    (if (> doc-h menu-h)
        ;; +--------------------+
        ;; |         y-------+  |
        ;; |         |       |  |
        ;; |  +------+       |  |
        ;; |  |      |       |  |
        ;; |  +-menu-+--doc--+  |
        ;; |  a|                |
        ;; +--------------------+
        (- cursor-y doc-h)
      ;; +--------------------+
      ;; |  +------y-------+  |
      ;; |  |      |       |  |
      ;; |  |      +--doc--+  |
      ;; |  |      |          |
      ;; |  +-menu-+          |
      ;; |  a|                |
      ;; +--------------------+
      (- cursor-y menu-h))))

(defun acm-terminal-doc-adjust-pos (&optional candidate-doc)
  "Adjust doc frame position."
  (pcase-let* ((`(,edge-left ,edge-top ,edge-right ,edge-bottom) (window-inside-edges))
               (textarea-width (- (window-width)
                                  (+ (- edge-left (window-left-column))
                                     (acm-terminal-line-number-display-width))))
               (textarea-height (- edge-bottom edge-top))
               (`(,cursor-x . ,cursor-y) (acm-terminal-get-popup-position acm-doc-frame))
               (`(,menu-x . ,menu-y) (popon-position acm-menu-frame))
               (`(,menu-w . ,menu-h) (popon-size acm-menu-frame))
               (menu-right (+ menu-x menu-w))
               (doc-w nil)
               (doc-h nil)
               (doc-y nil)
               (doc-lines nil))
    (cond
     ;; l:menu + r:document
     ((>= textarea-width (+ menu-right acm-terminal-doc-max-width))
      (setq doc-lines (acm-terminal-doc-render candidate-doc))
      (if (eq 'bottom (plist-get (cdr acm-menu-frame) :direction))
          ;; right bottom
          (progn
            (setq doc-h (- textarea-height cursor-y))
            (setq doc-y (1+ cursor-y)))
        ;; right top
        (setq doc-h cursor-y)
        (setq doc-y (acm-terminal-doc-top-edge-y cursor-y menu-h (length doc-lines) doc-lines)))
      (plist-put (cdr acm-doc-frame) :width acm-terminal-doc-max-width)
      (plist-put (cdr acm-doc-frame) :x menu-right)
      (plist-put (cdr acm-doc-frame) :y doc-y)
      (plist-put (cdr acm-doc-frame) :lines
                                     (if (<= (length doc-lines) doc-h)
                                         ;; doc <= frame
                                         doc-lines
                                       ;; doc > frame
                                       (seq-take doc-lines doc-h))))
     (t
      (let* ((fix-width (min acm-terminal-doc-max-width (- textarea-width 1)))
             (rects
              (list
               (list 'right-bottom (- textarea-width menu-x menu-w) (- textarea-height cursor-y))
               (list 'right-top (- textarea-width menu-x menu-w) cursor-y)
               (list 'bottom fix-width (- edge-bottom edge-top menu-y menu-h))
               (list 'left-bottom menu-x (- textarea-height cursor-y))
               (list 'left-top menu-x cursor-y)
               (list 'top fix-width menu-y))))
        ;; Find the largest free space in left/top/bottom/right
        (pcase-let* ((`(,rect ,rect-width ,rect-height)
                      (car (seq-sort (lambda (r1 r2)
                                       (> (apply #'* (cdr r1)) (apply #'* (cdr r2))))
                                     (if acm-terminal-doc-min-width
                                         (seq-filter
                                          (lambda (r)
                                            (>= (cadr r) acm-terminal-doc-min-width))
                                          rects)
                                       rects))))
                     (rerender-width (- (min fix-width rect-width) 1)))
          (setq doc-lines (acm-terminal-doc-render candidate-doc rerender-width))
          (setq doc-h (length doc-lines)) ;; Update doc height
          (setq doc-w (1+ rerender-width))
          (plist-put (cdr acm-doc-frame) :lines doc-lines)
          (plist-put (cdr acm-doc-frame) :width doc-w)
          (pcase rect
            ('left-bottom
             (plist-put (cdr acm-doc-frame) :x (- menu-x doc-w))
             (plist-put (cdr acm-doc-frame) :y (1+ cursor-y)))
            ('left-top
             (plist-put (cdr acm-doc-frame) :x (- menu-x doc-w))
             (plist-put (cdr acm-doc-frame) :y (acm-terminal-doc-top-edge-y
                                                cursor-y menu-h doc-h doc-lines)))
            ('top
             (plist-put (cdr acm-doc-frame) :x (if (>= (- textarea-width menu-x) doc-w)
                                                   menu-x
                                                 (- textarea-width doc-w)))
             (plist-put (cdr acm-doc-frame)
                        :y (let ((offset 0)
                                 (y (if (< menu-y cursor-y)
                                        ;; menu on top
                                        (- menu-y doc-h)
                                      ;; menu on bottom
                                      (- menu-y doc-h
                                         (if (eq 'bottom (plist-get (cdr acm-menu-frame) :direction))
                                             (setq offset 1)
                                           0)))))
                             (if (< y 0)
                                 (prog1 0
                                   (plist-put (cdr acm-doc-frame)
                                              :lines (seq-take doc-lines (+ doc-h y offset))))
                               y))))
            ('bottom
             (plist-put (cdr acm-doc-frame) :x (if (>= (- textarea-width menu-x) doc-w)
                                                   menu-x
                                                 (- textarea-width doc-w)))
             (plist-put (cdr acm-doc-frame) :y (+ menu-y menu-h
                                                  (if (eq 'top (plist-get (cdr acm-menu-frame) :direction))
                                                      1
                                                    0)))
             (plist-put (cdr acm-doc-frame) :lines (seq-take doc-lines rect-height)))
            ('right-bottom
             (plist-put (cdr acm-doc-frame) :x (+ menu-x menu-w))
             (plist-put (cdr acm-doc-frame) :y (1+ cursor-y)))
            ('right-top
             (plist-put (cdr acm-doc-frame) :x (+ menu-x menu-w))
             (plist-put (cdr acm-doc-frame) :y (acm-terminal-doc-top-edge-y
                                                cursor-y menu-h doc-h doc-lines))))))))
    (popon-redisplay)))

(defun acm-terminal-doc-hide ()
  (when (popon-live-p acm-doc-frame)
    (setq acm-doc-frame (popon-kill acm-doc-frame)))

  (acm-cancel-timer acm-markdown-render-timer)
  (setq acm-markdown-render-doc nil))

(defun acm-terminal-doc-try-show (&optional update-completion-item)
  (when acm-enable-doc
    (let* ((candidate (acm-menu-current-candidate))
           (backend (plist-get candidate :backend))
           (candidate-doc-func (intern-soft (format "acm-backend-%s-candidate-doc" backend)))
           (candidate-doc
            (when (fboundp candidate-doc-func)
              (funcall candidate-doc-func candidate))))
      (setq acm-terminal-candidate-doc candidate-doc)
      (setq acm-terminal-doc-scroll-start 0)
      (if (or (consp candidate-doc) ; If the type fo snippet is set to command,
                                        ; then the "doc" will be a list.
              (and (stringp candidate-doc) (not (string-empty-p candidate-doc))))
          (let ((doc (if (stringp candidate-doc)
                         candidate-doc
                       (format "%S" candidate-doc))))
            ;; Create doc frame if it not exist.
            (acm-terminal-create-frame-if-not-exist acm-doc-frame acm-doc-buffer "acm doc frame")

            ;; Adjust doc frame position and size.
            (if (string-equal backend "lsp")
                (progn
                  ;; NOTE: It is imposible to do it as in the GUI:
                  ;; Insert doc first, then render in timer.
                  (acm-cancel-timer acm-markdown-render-timer)
                  (setq acm-markdown-render-timer
                        (run-with-idle-timer
                         0.2 nil #'acm-terminal-doc-adjust-pos doc)))
              (acm-terminal-doc-adjust-pos doc)))

        (pcase backend
          ;; If backend is LSP, doc frame hide when `update-completion-item' is t.
          ("lsp" (when update-completion-item
                   (acm-doc-hide)))
          ;; Hide doc frame immediately if backend is not LSP.
          (_ (acm-doc-hide)))))))

(defun acm-terminal-doc-scroll-up ()
  "Scroll text of doc upward."
  (interactive)
  (when (popon-live-p acm-doc-frame)
    (pcase-let*
        ((`(,doc-x . ,doc-y) (popon-position acm-doc-frame))
         (`(,doc-w . ,doc-h) (popon-size acm-doc-frame))
         (total-lines
          (acm-terminal-doc-render acm-terminal-candidate-doc (1- doc-w)))
         (scroll-start
          (- (+ acm-terminal-doc-scroll-start doc-h) next-screen-context-lines))
         (taken-lines
          (when (< scroll-start (length total-lines))
            (acm-terminal-doc-get-page total-lines scroll-start doc-h))))
      (when taken-lines
        (plist-put (cdr acm-doc-frame) :lines taken-lines)
        (popon-redisplay)
        (setq acm-terminal-doc-scroll-start scroll-start)))))

(defun acm-terminal-doc-scroll-down ()
  "Scroll text of doc down."
  (interactive)
  (when (popon-live-p acm-doc-frame)
    (pcase-let*
        ((`(,doc-x . ,doc-y) (popon-position acm-doc-frame))
         (`(,doc-w . ,doc-h) (popon-size acm-doc-frame))
         (total-lines
          (acm-terminal-doc-render acm-terminal-candidate-doc (1- doc-w)))
         (scroll-start
          (+ (- acm-terminal-doc-scroll-start doc-h) next-screen-context-lines))
         (taken-lines
          (when (<= 0 scroll-start)
            (acm-terminal-doc-get-page total-lines scroll-start doc-h))))
      (when taken-lines
        (plist-put (cdr acm-doc-frame) :lines taken-lines)
        (popon-redisplay)
        (setq acm-terminal-doc-scroll-start scroll-start)))))

(defun acm-terminal-hide ()
  (interactive)
  (let* ((candidate-info (acm-menu-current-candidate))
         (backend (plist-get candidate-info :backend)))
    ;; Turn off `acm-mode'.
    (acm-mode -1)

    ;; Hide menu frame.
    (when acm-menu-frame
      (setq acm-menu-frame (popon-kill acm-menu-frame)))

    ;; Hide doc frame.
    (acm-doc-hide)

    ;; Clean `acm-menu-max-length-cache'.
    (setq acm-menu-max-length-cache 0)

    ;; Remove hook of `acm--pre-command'.
    (remove-hook 'pre-command-hook #'acm--pre-command 'local)

    ;; Clean backend cache.
    (when-let* ((backend-clean (intern-soft (format "acm-backend-%s-clean" backend)))
                (fp (fboundp backend-clean)))
      (funcall backend-clean))))

(defun acm-terminal-update ()
  ;; Adjust `gc-cons-threshold' to maximize temporary,
  ;; make sure Emacs not do GC when filter/sort candidates.
  (let* ((gc-cons-threshold most-positive-fixnum)
         (keyword (acm-get-input-prefix))
         (previous-select-candidate-index (+ acm-menu-offset acm-menu-index))
         (previous-select-candidate (acm-menu-index-info (acm-menu-current-candidate)))
         (candidates (acm-update-candidates))
         (menu-candidates (cl-subseq candidates 0 (min (length candidates) acm-menu-length)))
         (current-select-candidate-index (cl-position previous-select-candidate (mapcar 'acm-menu-index-info menu-candidates) :test 'equal))
         (direction (when (popon-live-p acm-menu-frame)
                      (plist-get (cdr acm-menu-frame) :direction)))
         (bounds (acm-get-input-prefix-bound)))
    (cond
     ;; Hide completion menu if user type first candidate completely.
     ((and (equal (length candidates) 1)
           (string-equal keyword (plist-get (nth 0 candidates) :label))
           ;; Volar always send back single emmet candidate, we need filter this condition.
           (not (string-equal "Emmet Abbreviation" (plist-get (nth 0 candidates) :annotation))))
      (acm-hide))
     ((> (length candidates) 0)
      (let* ((menu-old-cache (cons acm-menu-max-length-cache acm-menu-number-cache)))
        ;; Enable acm-mode to inject mode keys.
        (acm-mode 1)

        ;; Use `pre-command-hook' to hide completion menu when command match `acm-continue-commands'.
        (add-hook 'pre-command-hook #'acm--pre-command nil 'local)

        ;; Adjust candidates.
        (setq-local acm-menu-offset 0)  ;init offset to 0
        (if (zerop (length acm-menu-candidates))
            ;; Adjust `acm-menu-index' to -1 if no candidates found.
            (setq-local acm-menu-index -1)
          ;; First init `acm-menu-index' to 0.
          (setq-local acm-menu-index 0)

          ;; The following code is specifically to adjust the selection position of candidate when typing fast.
          (when (and current-select-candidate-index
                     (> (length candidates) 1))
            (cond
             ;; Swap the position of the first two candidates
             ;; if previous candidate's position change from 1st to 2nd.
             ((and (= previous-select-candidate-index 0) (= current-select-candidate-index 1))
              (cl-rotatef (nth 0 candidates) (nth 1 candidates))
              (cl-rotatef (nth 0 menu-candidates) (nth 1 menu-candidates)))
             ;; Swap the position of the first two candidates and select 2nd postion
             ;; if previous candidate's position change from 2nd to 1st.
             ((and (= previous-select-candidate-index 1) (= current-select-candidate-index 0))
              (cl-rotatef (nth 0 candidates) (nth 1 candidates))
              (cl-rotatef (nth 0 menu-candidates) (nth 1 menu-candidates))
              (setq-local acm-menu-index 1))
             ;; Select 2nd position if previous candidate's position still is 2nd.
             ((and (= previous-select-candidate-index 1) (= current-select-candidate-index 1))
              (setq-local acm-menu-index 1)))))

        ;; Set candidates and menu candidates.
        (setq-local acm-candidates candidates)
        (setq-local acm-menu-candidates menu-candidates)

        ;; Init colors.
        (acm-frame-init-colors)

        ;; Record menu popup position and buffer.
        (setq acm-menu-frame-popup-point (or (car bounds) (point)))

        ;; `posn-at-point' will failed in CI, add checker make sure CI can pass.
        ;; CI don't need popup completion menu.
        (when (posn-at-point acm-menu-frame-popup-point)
          (setq acm-frame-popup-position (acm-frame-get-popup-position acm-menu-frame-popup-point))

          ;; Create menu frame if it not exists.
          (acm-terminal-create-frame-if-not-exist acm-menu-frame acm-buffer "acm frame")
          (plist-put (cdr acm-menu-frame) :direction direction)

          ;; Render menu.
          (acm-terminal-menu-render menu-old-cache))
        ))
     (t
      (acm-hide)))))

(defun acm-terminal-code-action-popup-select ()
  (interactive)
  (lsp-bridge-code-action-popup-quit)
  (lsp-bridge-code-action--fix-do
   (cdr (nth lsp-bridge-call-hierarchy--index lsp-bridge-call-hierarchy--popup-response))))

(defun acm-terminal-code-action-popup-quit ()
  (interactive)
  (acm-cancel-timer lsp-bridge-code-action-popup-maybe-preview-timer)

  (acm-frame-delete-frame lsp-bridge-call-hierarchy--frame)
  (kill-buffer "*lsp-bridge-code-action-menu*")

  ;; (advice-remove 'lsp-bridge-call-hierarchy-select #'lsp-bridge-code-action-popup-select)
  ;; (advice-remove 'lsp-bridge-call-hierarchy-quit #'lsp-bridge-code-action-popup-quit)
  (when (get-buffer-window lsp-bridge-code-action--current-buffer)
    (select-window (get-buffer-window lsp-bridge-code-action--current-buffer))))

(defun acm-terminal-code-action-popup-menu (actions default-action)
  (let ((recentf-keep '(".*" . nil)) ;; not push temp file in recentf-list
        (recentf-exclude '(".*"))
        (menu-length (length actions))
        (menu-buffer (get-buffer-create "*lsp-bridge-code-action-menu*"))
        (menu-width 0)
        (menu-frame-exist (frame-live-p lsp-bridge-call-hierarchy--frame))
        cursor
        menu-items '())
    ;; Calcuate cursor position when menu frame is not visible.
    (unless menu-frame-exist
      (setq cursor (acm-frame-get-popup-position (point))))

    ;; Prepare for previewing.
    (setq lsp-bridge-code-action--current-buffer (current-buffer))
    (setq lsp-bridge-code-action--oldfile (make-temp-file
                                           (buffer-name) nil nil (buffer-string)))
    (setq lsp-bridge-code-action--preview-alist '())

    ;; Reuse hierarchy popup keymap and mode here.
    (setq lsp-bridge-call-hierarchy--popup-response actions)

    (acm-terminal-create-frame-if-not-exist lsp-bridge-call-hierarchy--frame menu-buffer "code action")

    (with-current-buffer menu-buffer
      ;; Erase menu buffer for multiple code-action response from Python side.
      (read-only-mode -1)
      (erase-buffer)

      ;; (cl-loop for i from 0 to (1- (length actions))
      ;;          do (let* ((title (car (nth i actions)))
      ;;                    (format-line (format "%d. %s\n" (1+ i) title))
      ;;                    (line-width (length format-line)))
      ;;               ;;(insert format-line)
      ;;               ;;(setq menu-width (max line-width menu-width))))
      (dolist (action actions)
        (let* ((action-text (car action))
               (title (plist-get action :title))
               (menu-item (list :key title :displayLabel action-text)))
          (insert action-text)
          ;;(plist-put (car menu-item) :displayLabel "abc")
          (if menu-items
              (setq menu-items (append menu-items (list menu-item)))
            (setq menu-items (list menu-item)))))
                    
      ;;(lsp-bridge-call-hierarchy-mode)
      (acm-mode 1)
      (goto-char (point-min))
      (setq-local cursor-type nil)
      (setq-local truncate-lines t)
      (setq-local mode-line-format nil)

      ;; Don't adjust frame position if code action menu current is visible.
      (unless menu-frame-exist
        ;;(acm-frame-set-frame-position lsp-bridge-call-hierarchy--frame (car cursor) (+ (cdr cursor) (line-pixel-height)))
        ;;(set-frame-position lsp-bridge-call-hierarchy--frame (car cursor) (cdr cursor))
        (popon-put lsp-bridge-call-hierarchy--frame :x 0)
        (popon-put lsp-bridge-call-hierarchy--frame :y 10)
        ;; (acm-frame-set-frame-size lsp-bridge-call-hierarchy--frame omenu-width
        ;;                           (min menu-length (/ (frame-height acm-frame--emacs-frame) 4)))
        (popon-put lsp-bridge-call-hierarchy--frame :widht menu-width)
        (popon-put lsp-bridge-call-hierarchy--frame :height menu-length)
        (acm-terminal-code-action-render menu-items)))
    ;;(popon-redisplay)))
    ;;(t popon-kill lsp-bridge-call-hierarchy--frame)
    ))

(defun acm-terminal-can-display-p ()
  (not (or noninteractive
           emacs-basic-display)))

(defun acm-terminal-doc-preview ()
  "Stub function to supress doc preview.")

(defvar acm-terminal-advices
  '((acm-frame-init-colors :override acm-terminal-init-colors)
    (acm-frame-can-display-p :override acm-terminal-can-display-p)
    (acm-hide :override acm-terminal-hide)
    (acm-update :override acm-terminal-update)
    (acm-doc-try-show :override acm-terminal-doc-try-show)
    (acm-doc-hide :override acm-terminal-doc-hide)
    (acm-doc-scroll-up :override acm-terminal-doc-scroll-up)
    (acm-doc-scroll-down :override acm-terminal-doc-scroll-down)
    (acm-menu-max-length :filter-return acm-terminal-max-length)
    (acm-menu-render :override acm-terminal-menu-render)
    (acm-menu-render-items :override acm-terminal-menu-render-items)
    (acm-markdown-render-content :around acm-terminal-markdown-render-content)
    (lsp-bridge-code-action-popup-select :override acm-terminal-code-action-popup-select)
    (lsp-bridge-code-action-popup-quit :override acm-terminal-code-action-popup-quit)
    (lsp-bridge-code-action-popup-menu :override acm-terminal-code-action-popup-menu))
  "A list of (ORIG-FN HOW ADVICE-FN).")

(defun acm-terminal-active ()
  (mapc (pcase-lambda (`(,orig-fn ,how ,advice-fn))
          (advice-add orig-fn how advice-fn))
        acm-terminal-advices))

(defun acm-terminal-deactive ()
  (mapc (pcase-lambda (`( ,orig-fn ,_ ,advice-fn ))
          (advice-remove orig-fn advice-fn))
        acm-terminal-advices))

(unless window-system
  (acm-terminal-active))

(provide 'acm-terminal)

;;; acm-terminal.el ends here
