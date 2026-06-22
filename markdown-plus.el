;;; markdown-plus.el --- Org-mode-like WYSIWYG editing for Markdown -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Randolph

;; Author: Randolph <xiaojianghuang@yahoo.com>
;; Maintainer: Randolph <xiaojianghuang@yahoo.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (markdown-mode "2.6"))
;; Keywords: wp, markdown, convenience, outlines
;; URL: https://github.com/wowhxj/markdown-plus.el

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
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

;; markdown-plus turns `markdown-mode' buffers into an org-mode-like
;; WYSIWYG editing experience, layered on top of markdown-mode:
;;
;;   * Markup hiding with org-appear-style reveal: emphasis (**bold**,
;;     *italic*, _underline_), inline code (`code`), strikethrough
;;     (~~del~~), subscript/superscript (~x~ / ^x^), ATX headings (#),
;;     links ([text](url)) and images (![](url)) are rendered, and the
;;     raw source is revealed only when point enters the element and
;;     re-hidden when point leaves.
;;   * Fenced code blocks (```lang ... ```) are always shown verbatim
;;     (fence lines stay visible) and get a distinct background.
;;   * Inline image preview for both local and remote images; remote
;;     images are downloaded asynchronously and shown when ready.
;;   * Automatic table alignment when leaving a GFM table.
;;
;; Usage:
;;
;;   (require 'markdown-plus)
;;   (add-hook 'markdown-mode-hook #'markdown-plus-mode)
;;
;; Or enable it interactively with `M-x markdown-plus-mode' in a
;; Markdown buffer.

;;; Code:

(require 'cl-lib)
(require 'markdown-mode)

;;;; Customization ------------------------------------------------------------

(defgroup markdown-plus nil
  "Org-mode-like WYSIWYG editing for Markdown."
  :group 'markdown
  :prefix "markdown-plus-")

(defcustom markdown-plus-prettify-faces t
  "When non-nil, enlarge heading faces and shade code-block faces on enable.
This changes the faces globally (they are shared across buffers)."
  :type 'boolean
  :group 'markdown-plus)

(defcustom markdown-plus-auto-preview-images t
  "When non-nil, render inline image previews when the mode is enabled."
  :type 'boolean
  :group 'markdown-plus)

(defcustom markdown-plus-max-image-size '(800 . 600)
  "Maximum image size as a cons cell (MAX-WIDTH . MAX-HEIGHT) in pixels."
  :type '(cons integer integer)
  :group 'markdown-plus)

(defcustom markdown-plus-image-cache-dir
  (expand-file-name "markdown-plus-images/" temporary-file-directory)
  "Directory used to cache downloaded remote images."
  :type 'directory
  :group 'markdown-plus)

(defconst markdown-plus--image-link-re "!\\[[^]]*\\](\\([^)]+\\))"
  "Regexp matching a Markdown image link.  Group 1 is the path/URL.")

;;;; Faces / colors -----------------------------------------------------------

(defun markdown-plus--color-dark-p (color)
  "Return non-nil when COLOR is perceptually dark."
  (let* ((rgb (color-values color))
         (lum (when rgb
                (/ (+ (* 0.299 (nth 0 rgb))
                      (* 0.587 (nth 1 rgb))
                      (* 0.114 (nth 2 rgb)))
                   65535.0))))
    (and lum (< lum 0.5))))

(defun markdown-plus--color-blend (c1 c2 alpha)
  "Blend C1 with C2 by ALPHA (the share of C2); return a #RRGGBB string."
  (let ((v1 (color-values c1))
        (v2 (color-values c2)))
    (if (and v1 v2)
        (apply #'format "#%02x%02x%02x"
               (cl-mapcar (lambda (a b)
                            (round (/ (+ (* (- 1 alpha) a) (* alpha b)) 256)))
                          v1 v2))
      c1)))

(defun markdown-plus--set-code-block-background ()
  "Give code-block faces a background distinct from the theme background."
  (let* ((bg (face-attribute 'default :background nil t))
         (block-bg (cond
                    ((not (stringp bg)) nil)
                    ((markdown-plus--color-dark-p bg)
                     (markdown-plus--color-blend bg "#ffffff" 0.07))
                    (t (markdown-plus--color-blend bg "#000000" 0.05)))))
    (when block-bg
      (dolist (face '(markdown-code-face markdown-pre-face))
        (when (facep face)
          (set-face-attribute face nil :background block-bg :extend t))))))

(defvar markdown-plus--faces-prettified nil
  "Non-nil once heading/code faces have been prettified.")

(defun markdown-plus--prettify-faces ()
  "Enlarge heading faces and shade code-block faces (once per session)."
  (unless markdown-plus--faces-prettified
    (custom-set-faces
     '(markdown-header-face-1 ((t (:height 1.6 :weight bold :inherit markdown-header-face))))
     '(markdown-header-face-2 ((t (:height 1.4 :weight bold :inherit markdown-header-face))))
     '(markdown-header-face-3 ((t (:height 1.2 :weight bold :inherit markdown-header-face))))
     '(markdown-header-face-4 ((t (:height 1.1 :weight bold :inherit markdown-header-face)))))
    (when (facep 'markdown-inline-code-face)
      (set-face-attribute 'markdown-inline-code-face nil :inherit 'fixed-pitch))
    (markdown-plus--set-code-block-background)
    (setq markdown-plus--faces-prettified t)))

;;;; Image preview ------------------------------------------------------------

(defun markdown-plus--remote-image-path (url)
  "Return a stable cache file name for the remote image URL."
  (let* ((ext (or (and (string-match "\\.\\([a-zA-Z]+\\)\\(?:\\?.*\\)?\\'" url)
                       (match-string 1 url))
                  "png"))
         (name (concat (md5 url) "." ext)))
    (expand-file-name name markdown-plus-image-cache-dir)))

(defun markdown-plus--local-image-file (path)
  "Resolve the local image PATH to an existing absolute file, or nil."
  (let ((f (expand-file-name
            path (file-name-directory
                  (or (buffer-file-name) default-directory)))))
    (and (file-exists-p f) f)))

(defun markdown-plus--write-downloaded-image (dest-file)
  "Write the image body in the `url-retrieve' buffer to DEST-FILE.
Return non-nil on success."
  (goto-char (point-min))
  (when (re-search-forward "\r?\n\r?\n" nil t)
    (let ((coding-system-for-write 'binary))
      (write-region (point) (point-max) dest-file nil 'silent))
    t))

(defun markdown-plus--make-image (file)
  "Create an image object for FILE bounded by `markdown-plus-max-image-size'."
  (create-image file nil nil
                :max-width (car markdown-plus-max-image-size)
                :max-height (cdr markdown-plus-max-image-size)))

(defun markdown-plus--put-image-overlay (beg end file)
  "Overlay BEG..END to render the link as the image in FILE."
  (when (and (file-exists-p file)
             (not (cl-some (lambda (o) (overlay-get o 'markdown-plus-image))
                           (overlays-at beg))))
    (let ((img (ignore-errors (markdown-plus--make-image file))))
      (when img
        (let ((ov (make-overlay beg end)))
          (overlay-put ov 'markdown-plus-image t)
          (overlay-put ov 'display img)
          (overlay-put ov 'keymap image-map)
          (overlay-put ov 'evaporate t))))))

(defun markdown-plus--remove-image-overlays (beg end)
  "Delete image-preview overlays within BEG..END."
  (dolist (ov (overlays-in beg end))
    (when (overlay-get ov 'markdown-plus-image)
      (delete-overlay ov))))

(defun markdown-plus--download-image (url dest target-buffer)
  "Download URL to DEST asynchronously, then refresh previews in TARGET-BUFFER."
  (unless (file-directory-p markdown-plus-image-cache-dir)
    (make-directory markdown-plus-image-cache-dir t))
  (url-retrieve
   url
   (lambda (status the-url dest-file buf)
     (if (plist-get status :error)
         (message "markdown-plus: image download failed %s" the-url)
       (when (and (markdown-plus--write-downloaded-image dest-file)
                  (buffer-live-p buf))
         (with-current-buffer buf
           (markdown-plus--display-images-in-region (point-min) (point-max))))))
   (list url dest target-buffer)
   t t))

(defun markdown-plus--display-images-in-region (beg end)
  "Render image previews within BEG..END.
Remote images not yet cached are downloaded asynchronously.  The link
under point is left as source so it can be edited."
  (when (display-graphic-p)
    (let ((cur (point)))
      (save-excursion
        (goto-char beg)
        (while (re-search-forward markdown-plus--image-link-re end t)
          (let* ((mbeg (match-beginning 0))
                 (mend (match-end 0))
                 (path (string-trim (match-string-no-properties 1))))
            (unless (and (<= mbeg cur) (<= cur mend))
              (if (string-match-p "\\`https?://" path)
                  (let ((cache (markdown-plus--remote-image-path path)))
                    (if (file-exists-p cache)
                        (markdown-plus--put-image-overlay mbeg mend cache)
                      (markdown-plus--download-image path cache (current-buffer))))
                (let ((f (markdown-plus--local-image-file path)))
                  (when f (markdown-plus--put-image-overlay mbeg mend f)))))))))))

;;;###autoload
(defun markdown-plus-show-images ()
  "Render all image previews in the current buffer."
  (interactive)
  (markdown-plus--display-images-in-region (point-min) (point-max)))

;;;###autoload
(defun markdown-plus-hide-images ()
  "Remove all image-preview overlays in the current buffer."
  (interactive)
  (markdown-plus--remove-image-overlays (point-min) (point-max)))

;;;; Appear: element detection ------------------------------------------------

;; Forward declaration; the variable is defined by the `define-minor-mode'
;; form near the end of this file but is referenced earlier.
(defvar markdown-plus-mode)

(defvar-local markdown-plus--region nil
  "The currently revealed markup region as a cons (BEG . END), or nil.")

(defvar-local markdown-plus--timer nil
  "Idle timer used to re-assert reveal after redisplay.")

(defun markdown-plus--inline-bounds (pos)
  "Return (BEG . END) of the inline emphasis/code element at POS, or nil."
  (save-excursion
    (goto-char pos)
    (let ((line-beg (line-beginning-position))
          (line-end (line-end-position))
          found)
      (goto-char line-beg)
      (while (and (not found)
                  (re-search-forward
                   ;; **bold** *italic* __x__ _x_ ~~del~~ ~sub~ ^sup^ `code`
                   ;; (~~ precedes ~ so strikethrough wins over subscript)
                   "\\(\\*\\*\\|\\*\\|__\\|_\\|~~\\|~\\|\\^\\|`+\\)\\(?:.\\|\n\\)+?\\1"
                   line-end t))
        (when (and (<= (match-beginning 0) pos)
                   (>= (match-end 0) pos))
          (setq found (cons (match-beginning 0) (match-end 0)))))
      found)))

(defun markdown-plus--image-bounds (pos)
  "Return (BEG . END) of the image link ![alt](path) at POS, or nil."
  (save-excursion
    (goto-char pos)
    (let ((line-beg (line-beginning-position))
          (line-end (line-end-position))
          found)
      (goto-char line-beg)
      (while (and (not found)
                  (re-search-forward "!\\[[^]]*\\]([^)]+)" line-end t))
        (when (and (<= (match-beginning 0) pos)
                   (>= (match-end 0) pos))
          (setq found (cons (match-beginning 0) (match-end 0)))))
      found)))

(defun markdown-plus--link-bounds (pos)
  "Return (BEG . END) of the plain link [text](url) at POS, or nil.
Images (preceded by `!') are excluded."
  (save-excursion
    (goto-char pos)
    (let ((line-beg (line-beginning-position))
          (line-end (line-end-position))
          found)
      (goto-char line-beg)
      (while (and (not found)
                  (re-search-forward "\\[[^]]*\\]([^)]+)" line-end t))
        (when (and (<= (match-beginning 0) pos)
                   (>= (match-end 0) pos)
                   (not (eq (char-before (match-beginning 0)) ?!)))
          (setq found (cons (match-beginning 0) (match-end 0)))))
      found)))

(defun markdown-plus--element-bounds ()
  "Return (BEG . END) of the revealable element at point, or nil.
Order: image, link, ATX heading line, inline markup.  Code blocks do
not participate; their fence lines are always shown by
`markdown-plus--jit-fixup'."
  (let ((pos (point)))
    (cond
     ((markdown-plus--image-bounds pos))
     ((markdown-plus--link-bounds pos))
     ((save-excursion
        (beginning-of-line)
        (looking-at "[ \t]*#+[ \t]"))
      (cons (line-beginning-position) (line-end-position)))
     (t (markdown-plus--inline-bounds pos)))))

;;;; Appear: reveal / restore -------------------------------------------------

(defun markdown-plus--reveal (beg end)
  "Reveal raw markup in BEG..END and drop any image preview there."
  (markdown-plus--remove-image-overlays beg end)
  (with-silent-modifications
    (remove-text-properties beg end '(display nil invisible nil composition nil))))

(defun markdown-plus--restore (beg end)
  "Re-hide markup in BEG..END by refontifying, and re-render image previews.
The refontified region is extended to whole lines: markdown-mode's link
matchers need full-line context, otherwise a revealed link may fail to
re-hide under jit-lock."
  (let ((b (save-excursion (goto-char beg) (line-beginning-position)))
        (e (save-excursion (goto-char end) (line-end-position))))
    (with-silent-modifications
      (font-lock-flush b e)
      (font-lock-ensure b e))
    (markdown-plus--display-images-in-region b e)))

;;;; Appear: jit-lock fixup ---------------------------------------------------

(defun markdown-plus--jit-fixup (beg end)
  "Run after font-lock during jit-lock fontification of BEG..END.

1. Keep fence lines (```lang/```/~~~) visible (drop hiding props).
2. Remove the scaling `display' wrongly applied by sub/superscript
   fontification to strikethrough ~~text~~.
3. Re-reveal the active appear region so editing within it does not
   flicker between revealed and hidden.

All steps check before modifying so unchanged lines are left alone."
  (when markdown-hide-markup
    (save-excursion
      ;; (1) unhide fence lines
      (goto-char beg)
      (forward-line 0)
      (while (< (point) end)
        (when (and (looking-at "[ \t]*\\(```\\|~~~\\)")
                   (or (get-text-property (line-beginning-position) 'invisible)
                       (get-text-property (point) 'invisible)))
          (with-silent-modifications
            (remove-text-properties
             (line-beginning-position)
             (min (point-max) (1+ (line-end-position)))
             '(invisible nil display nil composition nil))))
        (forward-line 1))
      ;; (2) strip subscript display wrongly added inside ~~strikethrough~~
      (goto-char beg)
      (let ((lim (min end (point-max))))
        (while (re-search-forward "~~\\(?:[^~\n]\\)+?~~" lim t)
          (let ((mb (match-beginning 0)) (me (match-end 0)))
            (when (text-property-not-all mb me 'display nil)
              (with-silent-modifications
                (remove-text-properties mb me '(display nil)))))))
      ;; (3) keep the active appear region revealed.  Use the tracked
      ;; region, never (point): during jit-lock redisplay point is moved
      ;; into the fontified region and is not the real cursor position.
      (when (and markdown-plus--region
                 (< (car markdown-plus--region) end)
                 (> (cdr markdown-plus--region) beg))
        (markdown-plus--reveal (max beg (car markdown-plus--region))
                               (min end (cdr markdown-plus--region)))))))

;;;; Appear: command / timer driving ------------------------------------------

(defun markdown-plus--post-command ()
  "Reveal the element at point and re-hide the previously revealed one.
Wrapped in `condition-case': a signal raised in `post-command-hook'
would make Emacs drop this function, disabling the mode."
  (condition-case nil
      (if (not markdown-hide-markup)
          (setq markdown-plus--region nil)
        (let ((bounds (markdown-plus--element-bounds)))
          ;; Clear the region BEFORE restoring: restore's font-lock-ensure
          ;; triggers a jit-lock pass that runs `markdown-plus--jit-fixup',
          ;; which would otherwise re-reveal the very element being hidden
          ;; (during redisplay point sits inside the fontified region, not
          ;; at the real cursor).
          (when (and markdown-plus--region
                     (not (equal markdown-plus--region bounds)))
            (let ((old markdown-plus--region))
              (setq markdown-plus--region nil)
              (markdown-plus--restore (car old) (cdr old))))
          (when (and bounds (not (equal bounds markdown-plus--region)))
            (markdown-plus--reveal (car bounds) (cdr bounds))
            (setq markdown-plus--region bounds))
          ;; Backstop: re-assert fence/strikethrough across the visible
          ;; window (jit-lock occasionally misses scrolled-in regions).
          (markdown-plus--jit-fixup (window-start) (window-end nil t))
          ;; Editing makes jit-lock re-hide during the redisplay that
          ;; follows this hook; re-assert shortly after, post-redisplay.
          (when (timerp markdown-plus--timer)
            (cancel-timer markdown-plus--timer))
          (setq markdown-plus--timer
                (run-with-idle-timer 0.05 nil #'markdown-plus--reassert
                                     (current-buffer)))))
    (error nil)))

(defun markdown-plus--reassert (buffer)
  "Re-reveal the active region and fix fences/strikethrough in BUFFER.
Counters jit-lock re-hiding after edits or scrolling."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (ignore-errors
        (when (and markdown-plus-mode markdown-hide-markup)
          (let ((r markdown-plus--region))
            (when (and r (<= (car r) (point)) (<= (point) (cdr r)))
              (markdown-plus--reveal (car r) (cdr r))))
          (let ((win (get-buffer-window buffer)))
            (when win
              (markdown-plus--jit-fixup (window-start win)
                                        (window-end win t)))))))))

;;;; Table auto-alignment -----------------------------------------------------

(defvar-local markdown-plus--table-last nil
  "Bounds (BEG . END) of the table point was in at the last command, or nil.")

(defun markdown-plus--table-align-on-leave ()
  "Align the table that point just left, if any."
  (when (and (derived-mode-p 'markdown-mode)
             (fboundp 'markdown-table-at-point-p)
             (fboundp 'markdown-table-align))
    (let ((in-table (markdown-table-at-point-p)))
      (cond
       (in-table
        (setq markdown-plus--table-last
              (ignore-errors
                (cons (markdown-table-begin) (markdown-table-end)))))
       ((and (not in-table) markdown-plus--table-last)
        (let ((beg (car markdown-plus--table-last)))
          (save-excursion
            (when (and (integer-or-marker-p beg) (<= beg (point-max)))
              (goto-char beg)
              (when (markdown-table-at-point-p)
                (ignore-errors (markdown-table-align))))))
        (setq markdown-plus--table-last nil))))))

;;;; Minor mode ---------------------------------------------------------------

(defvar markdown-plus-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-x C-v") #'markdown-plus-show-images)
    (define-key map (kbd "C-c C-x C-r") #'markdown-plus-hide-images)
    map)
  "Keymap for `markdown-plus-mode'.")

(defvar-local markdown-plus--saved nil
  "Alist of markdown variables saved on enable, restored on disable.")

(defun markdown-plus--enable ()
  "Set up markdown-plus in the current buffer."
  (unless (derived-mode-p 'markdown-mode)
    (user-error "markdown-plus-mode requires a markdown-mode buffer"))
  ;; Save and apply the WYSIWYG base settings buffer-locally.
  (setq markdown-plus--saved
        (list (cons 'hide-markup markdown-hide-markup)
              (cons 'hide-urls markdown-hide-urls)
              (cons 'natively markdown-fontify-code-blocks-natively)
              (cons 'image-size markdown-max-image-size)))
  (setq-local markdown-hide-markup t)
  (setq-local markdown-hide-urls nil)        ;; keep URLs revealable in-buffer
  (setq-local markdown-fontify-code-blocks-natively t)
  (setq-local markdown-max-image-size markdown-plus-max-image-size)
  (add-to-invisibility-spec 'markdown-markup)
  (when markdown-plus-prettify-faces
    (markdown-plus--prettify-faces))
  ;; Hooks.
  (add-hook 'post-command-hook #'markdown-plus--post-command nil t)
  (add-hook 'post-command-hook #'markdown-plus--table-align-on-leave nil t)
  ;; Append so it runs after font-lock during each jit-lock pass.
  (add-hook 'jit-lock-functions #'markdown-plus--jit-fixup t t)
  ;; Apply hiding now and initialise visible regions.
  (when (fboundp 'markdown-reload-extensions)
    (markdown-reload-extensions))
  (ignore-errors (font-lock-flush) (font-lock-ensure))
  (ignore-errors (markdown-plus--jit-fixup (point-min) (point-max)))
  (when markdown-plus-auto-preview-images
    (markdown-plus-show-images)))

(defun markdown-plus--disable ()
  "Tear down markdown-plus in the current buffer."
  (remove-hook 'post-command-hook #'markdown-plus--post-command t)
  (remove-hook 'post-command-hook #'markdown-plus--table-align-on-leave t)
  (remove-hook 'jit-lock-functions #'markdown-plus--jit-fixup t)
  (when (timerp markdown-plus--timer)
    (cancel-timer markdown-plus--timer)
    (setq markdown-plus--timer nil))
  (when markdown-plus--region
    (setq markdown-plus--region nil))
  (markdown-plus-hide-images)
  ;; Restore the saved markdown settings.
  (let ((s markdown-plus--saved))
    (when s
      (setq-local markdown-hide-markup (alist-get 'hide-markup s))
      (setq-local markdown-hide-urls (alist-get 'hide-urls s))
      (setq-local markdown-fontify-code-blocks-natively (alist-get 'natively s))
      (setq-local markdown-max-image-size (alist-get 'image-size s))
      (unless markdown-hide-markup
        (remove-from-invisibility-spec 'markdown-markup))))
  (when (fboundp 'markdown-reload-extensions)
    (markdown-reload-extensions))
  (ignore-errors (font-lock-flush) (font-lock-ensure)))

;;;###autoload
(define-minor-mode markdown-plus-mode
  "Org-mode-like WYSIWYG editing for Markdown buffers.

When enabled, Markdown markup is hidden and rendered; the raw source of
the element at point is revealed and re-hidden as point moves.  Fenced
code blocks stay fully visible, inline images are previewed, and GFM
tables are aligned automatically when left.

\\{markdown-plus-mode-map}"
  :lighter " M+"
  :keymap markdown-plus-mode-map
  :group 'markdown-plus
  (if markdown-plus-mode
      (markdown-plus--enable)
    (markdown-plus--disable)))

(provide 'markdown-plus)
;;; markdown-plus.el ends here
