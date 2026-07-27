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
;;     *italic*), inline code (`code`), strikethrough (~~del~~),
;;     subscript/superscript (~x~ / ^x^), ATX headings (#), links
;;     ([text](url)), images (![](url)), underline (<u>x</u>), list
;;     bullets and GitHub alert markers are rendered, and the raw source
;;     is revealed only when point enters the element and re-hidden when
;;     point leaves.
;;   * Fenced code blocks (```lang ... ```) are always shown verbatim
;;     (fence lines stay visible) and get a distinct background.
;;   * Inline image preview for local and remote images, written either
;;     as ![alt](path) or as <img src="path" width="400">; remote images
;;     are downloaded asynchronously and shown when ready.
;;   * GitHub alerts (> [!NOTE], > [!WARNING], ...) render as a coloured
;;     label with a Nerd Font icon.
;;   * <source src="clip.mp4"> renders as a clickable file name; Emacs
;;     decodes no video, so RET or a click hands it to the system player.
;;   * [text](#name) jumps to <a id="name"> in the same buffer, which is
;;     what makes an Org- or Pandoc-exported table of contents work.
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
(require 'browse-url)                   ; `browse-url-file-url'
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

(defcustom markdown-plus-alert-types
  ;; The leading characters are Nerd Font icons; a display that cannot show
  ;; one falls back to the bare word.  Emoji are avoided on purpose: the
  ;; variation selector in ℹ️ and friends renders as a stray box in Emacs.
  '(("NOTE"      " Note"      "#1f6feb")   ; nf-fa-info_circle
    ("TIP"       " Tip"       "#1a7f37")   ; nf-fa-lightbulb_o
    ("IMPORTANT" " Important" "#8250df")   ; nf-fa-exclamation_circle
    ("WARNING"   " Warning"   "#9a6700")   ; nf-fa-exclamation_triangle
    ("CAUTION"   " Caution"   "#cf222e"))  ; nf-fa-ban
  "GitHub alert types rendered in blockquotes.
Each entry is (TYPE LABEL COLOR): TYPE is the uppercase keyword in a
`> [!TYPE]' line, LABEL is shown in its place, COLOR is the foreground.
A first character of LABEL that the display cannot show is dropped, so
an icon-prefixed label degrades to plain text without a font."
  :type '(alist :key-type (string :tag "Type")
                :value-type (group (string :tag "Label") (color :tag "Color")))
  :group 'markdown-plus)

;;;; Regexps ------------------------------------------------------------------

(defconst markdown-plus--md-image-re "!\\[[^]]*\\](\\([^)]+\\))"
  "Regexp matching a Markdown image link.  Group 1 is the path/URL.")

;; Spelled out per character so the match does not depend on `case-fold-search'.
(defconst markdown-plus--html-image-re "<[iI][mM][gG][ \t][^>]*>"
  "Regexp matching an HTML <img …> tag.")

(defconst markdown-plus--image-re
  (concat markdown-plus--md-image-re "\\|" markdown-plus--html-image-re)
  "Regexp matching either image form.
Group 1 holds the path for the Markdown form; for the HTML form the
path comes from the tag's `src' attribute.")

(defconst markdown-plus--link-re "\\[[^]]*\\]([^)]+)"
  "Regexp matching a link.  Images are rejected by the caller's predicate.")

(defconst markdown-plus--inline-re
  ;; **bold** *italic* __x__ _x_ ~~del~~ ~sub~ ^sup^ `code`
  ;; (~~ precedes ~ so strikethrough wins over subscript)
  "\\(\\*\\*\\|\\*\\|__\\|_\\|~~\\|~\\|\\^\\|`+\\)\\(?:.\\|\n\\)+?\\1"
  "Regexp matching inline emphasis/code.  Group 1 is the delimiter.")

(defconst markdown-plus--underline-re
  "\\(?1:\\(?2:<u>\\)\\(?3:.*?\\)\\(?4:</u>\\)\\)"
  "Regexp matching `<u>text</u>'.
Group 1 is the whole element, 2 and 4 the delimiters, 3 the text.")

(defconst markdown-plus--alert-re
  "^[ \t]*>[ \t]*\\(\\[!\\([A-Za-z]+\\)\\]\\)[ \t]*$"
  "Regexp matching a GitHub alert marker line.
Group 1 is the `[!TYPE]' marker, group 2 the bare type.")

;; Spelled out per character so the match does not depend on `case-fold-search'.
(defconst markdown-plus--video-re
  "<[sS][oO][uU][rR][cC][eE][ \t][^>]*>"
  "Regexp matching an HTML <source …> tag.")

;;;; Faces / colors -----------------------------------------------------------

(defface markdown-plus-underline-face '((t (:underline t)))
  "Face for the text inside `<u>...</u>'."
  :group 'markdown-plus)

(defface markdown-plus-video-face '((t (:inherit link)))
  "Face for a rendered video link."
  :group 'markdown-plus)

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

;;;; Extra font-lock: alerts, videos and <u> ----------------------------------

(defun markdown-plus--markup-properties ()
  "Return the properties to apply to markup, honouring `markdown-hide-markup'."
  (if markdown-hide-markup markdown-markup-properties 'markdown-markup-face))

(defun markdown-plus--icon-label (label)
  "Return LABEL, dropping a leading icon this display cannot show.
Lets an icon-prefixed label degrade to plain text without a Nerd Font."
  (if (or (zerop (length label))
          (char-displayable-p (aref label 0)))
      label
    (string-trim-left (substring label 1))))

(defun markdown-plus--alert-properties ()
  "Return font-lock properties for the alert marker just matched, or nil.
Nil for an unknown type, which leaves the marker untouched."
  (let ((spec (assoc (upcase (match-string-no-properties 2))
                     markdown-plus-alert-types)))
    (when spec
      `(face (:foreground ,(nth 2 spec) :weight bold)
             ,@(when markdown-hide-markup
                 `(display ,(markdown-plus--icon-label (nth 1 spec))))))))

(defvar markdown-plus-video-map
  (let ((map (make-sparse-keymap)))
    ;; `C-c C-o' rather than `RET': point on the tag means the tag is
    ;; revealed, so RET has to stay a newline for editing.  This is also the
    ;; key markdown-mode uses to follow its own links, and it needs binding
    ;; here because `markdown-follow-thing-at-point' does not recognise an
    ;; HTML tag as anything followable.
    (define-key map (kbd "C-c C-o") #'markdown-plus-play-video-at-point)
    (define-key map [mouse-2] #'markdown-plus-play-video-at-point)
    ;; With the `mouse-face' property set, this is what lets mouse-1 follow
    ;; the link too; the same arrangement markdown-mode uses for its links.
    (define-key map [follow-link] 'mouse-face)
    map)
  "Keymap active on a rendered video link.")

(defun markdown-plus--video-properties ()
  "Return font-lock properties turning the matched <source> tag into a link."
  (let ((src (markdown-plus--html-attr (match-string-no-properties 0) "src")))
    (when src
      `(face markdown-plus-video-face
             keymap ,markdown-plus-video-map
             mouse-face highlight
             help-echo ,(concat "mouse-1, C-c C-o: play " src)
             ,@(when markdown-hide-markup
                 `(display ,(markdown-plus--icon-label
                             (concat (string #xF04B) ; nf-fa-play
                                     " " (file-name-nondirectory src)))))))))

(defvar markdown-plus--font-lock-keywords
  `((,markdown-plus--alert-re
     (1 (markdown-plus--alert-properties) prepend t))
    (,markdown-plus--video-re
     (0 (markdown-plus--video-properties) prepend))
    (,markdown-plus--underline-re
     (2 (markdown-plus--markup-properties) prepend)
     (3 'markdown-plus-underline-face prepend)
     (4 (markdown-plus--markup-properties) prepend)))
  "Font-lock keywords added on top of markdown-mode's own.
Appended so they run last; `prepend' then puts their faces on top.
`display' and `invisible' are in markdown-mode's
`font-lock-extra-managed-props', so font-lock cleans them up itself.")

;;;; Image preview ------------------------------------------------------------

(defun markdown-plus--html-attr (tag attr)
  "Return the value of ATTR in the HTML TAG string, or nil."
  (let ((case-fold-search t))
    (when (string-match (concat "\\<" attr "[ \t]*=[ \t]*\"\\([^\"]*\\)\"") tag)
      (match-string 1 tag))))

(defun markdown-plus--remote-image-path (url)
  "Return a stable cache file name for the remote image URL."
  (let* ((ext (or (and (string-match "\\.\\([a-zA-Z]+\\)\\(?:\\?.*\\)?\\'" url)
                       (match-string 1 url))
                  "png"))
         (name (concat (md5 url) "." ext)))
    (expand-file-name name markdown-plus-image-cache-dir)))

(defun markdown-plus--local-file (path)
  "Resolve PATH, relative to the buffer's file, to an existing file or nil."
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

(defun markdown-plus--make-image (file &optional width)
  "Create an image object for FILE bounded by `markdown-plus-max-image-size'.
WIDTH, when non-nil, requests that pixel width; the maximum size still
caps the result, preserving the aspect ratio."
  (apply #'create-image file nil nil
         :max-width (car markdown-plus-max-image-size)
         :max-height (cdr markdown-plus-max-image-size)
         (when width (list :width width))))

(defun markdown-plus--put-image-overlay (beg end file &optional width)
  "Overlay BEG..END to render the link as the image in FILE, at WIDTH pixels."
  (when (and (file-exists-p file)
             (not (cl-some (lambda (o) (overlay-get o 'markdown-plus-image))
                           (overlays-at beg))))
    (let ((img (ignore-errors (markdown-plus--make-image file width))))
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

(defun markdown-plus--image-at-match ()
  "Return (PATH . WIDTH) for the image just matched by `markdown-plus--image-re'.
PATH is nil when an HTML tag carries no usable `src'.  WIDTH is the
tag's pixel `width' attribute, or nil."
  (let* ((tag (unless (match-beginning 1) (match-string-no-properties 0)))
         (raw (if tag
                  (markdown-plus--html-attr tag "src")
                (match-string-no-properties 1)))
         (w (and tag (markdown-plus--html-attr tag "width"))))
    (cons (and raw (string-trim raw))
          (and w (string-match-p "\\`[0-9]+\\'" w) (string-to-number w)))))

(defun markdown-plus--display-images-in-region (beg end)
  "Render image previews within BEG..END.
Both `![alt](path)' and `<img src=\"path\">' are recognised.  Remote
images not yet cached are downloaded asynchronously.  The image under
point is left as source so it can be edited."
  (when (display-graphic-p)
    (let ((cur (point)))
      (save-excursion
        (goto-char beg)
        (while (re-search-forward markdown-plus--image-re end t)
          (let* ((mbeg (match-beginning 0))
                 (mend (match-end 0))
                 (spec (markdown-plus--image-at-match))
                 (path (car spec))
                 (width (cdr spec)))
            (unless (or (null path) (and (<= mbeg cur) (<= cur mend)))
              (if (string-match-p "\\`https?://" path)
                  (let ((cache (markdown-plus--remote-image-path path)))
                    (if (file-exists-p cache)
                        (markdown-plus--put-image-overlay mbeg mend cache width)
                      (markdown-plus--download-image path cache (current-buffer))))
                (let ((f (markdown-plus--local-file path)))
                  (when f
                    (markdown-plus--put-image-overlay mbeg mend f width)))))))))))

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

(defun markdown-plus--bounds-at (pos regexp &optional predicate)
  "Return (BEG . END) of the REGEXP match on POS's line spanning POS, or nil.
PREDICATE, when given, is called with the match data set and must return
non-nil for a match to count."
  (save-excursion
    (goto-char pos)
    (let ((line-end (line-end-position))
          found)
      (goto-char (line-beginning-position))
      (while (and (not found) (re-search-forward regexp line-end t))
        (when (and (<= (match-beginning 0) pos)
                   (>= (match-end 0) pos)
                   (or (null predicate) (funcall predicate)))
          (setq found (cons (match-beginning 0) (match-end 0)))))
      found)))

(defun markdown-plus--line-marker-bounds (regexp group &optional marker-re)
  "Return (BEG . END) of GROUP if the current line matches REGEXP, else nil.
When MARKER-RE is given, the marker text must match it as well.
Unlike `markdown-plus--bounds-at' the whole line triggers, but only the
marker is revealed, so other markup on the line keeps its own reveal."
  (save-excursion
    (beginning-of-line)
    (when (and (looking-at regexp) (match-beginning group))
      (let ((beg (match-beginning group))
            (end (match-end group)))
        (when (or (null marker-re)
                  (string-match-p
                   marker-re (buffer-substring-no-properties beg end)))
          (cons beg end))))))

(defun markdown-plus--element-bounds ()
  "Return (BEG . END) of the revealable element at point, or nil.
Order: HTML image, video, Markdown image, link, underline, ATX heading
line, inline markup, then the whole-line markers (alert, list bullet).
The HTML forms come first: their file names routinely contain `_', which
the inline matcher would otherwise read as emphasis.
The markers come last so inline markup on the same line still wins.
Code blocks do not participate; their fence lines are always shown by
`markdown-plus--jit-fixup'."
  (let ((pos (point)))
    (cond
     ((markdown-plus--bounds-at pos markdown-plus--html-image-re))
     ((markdown-plus--bounds-at pos markdown-plus--video-re))
     ((markdown-plus--bounds-at pos markdown-plus--md-image-re))
     ((markdown-plus--bounds-at
       pos markdown-plus--link-re
       (lambda () (not (eq (char-before (match-beginning 0)) ?!)))))
     ((markdown-plus--bounds-at pos markdown-plus--underline-re))
     ((save-excursion
        (beginning-of-line)
        (looking-at "[ \t]*#+[ \t]"))
      (cons (line-beginning-position) (line-end-position)))
     ((markdown-plus--bounds-at pos markdown-plus--inline-re))
     ((markdown-plus--line-marker-bounds markdown-plus--alert-re 1))
     ;; Only unordered markers: markdown-mode does not hide `1.', so there
     ;; would be nothing to reveal.
     ((markdown-plus--line-marker-bounds markdown-regex-list 2 "\\`[-*+:]\\'")))))

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

;;;; Video links --------------------------------------------------------------

(defun markdown-plus-play-video-at-point (&optional event)
  "Play the video of the `<source>' tag at point, or at EVENT.
Bound to \\`C-c C-o' and mouse-1 on a rendered video link.  Emacs decodes
no video format at all, so the file is handed to `browse-url', which on
each platform reaches the system's default application for it."
  (interactive (list last-nonmenu-event))
  (when (consp event)
    (posn-set-point (event-start event)))
  (let ((bounds (markdown-plus--bounds-at (point) markdown-plus--video-re)))
    (unless bounds
      (user-error "Point is not on a video link"))
    (let* ((src (markdown-plus--html-attr
                 (buffer-substring-no-properties (car bounds) (cdr bounds))
                 "src"))
           (file (and src (markdown-plus--local-file src))))
      (cond
       ((null src) (user-error "This <source> tag has no `src'"))
       ((string-match-p "\\`https?://" src) (browse-url src))
       ((null file) (user-error "No such file: %s" src))
       (t (browse-url (browse-url-file-url (expand-file-name file))))))))

;;;; Anchor links -------------------------------------------------------------

(defun markdown-plus--follow-anchor (url)
  "Jump to the in-buffer anchor named by URL, a `#name' fragment.
Targets are HTML anchors, `<a id=\"name\">' and `<a name=\"name\">', which
is what Org and Pandoc emit for cross-references.  `markdown--browse-url'
drops such links on the floor: a bare fragment has an empty file part, so
nothing happens and nothing is reported.

Installed on `markdown-follow-link-functions', so both \\[markdown-follow-thing-at-point]
and a mouse click reach it.  Returns non-nil once it has jumped."
  (when (string-prefix-p "#" url)
    (let* ((target (substring url 1))
           (case-fold-search t)
           (dest (save-excursion
                   (goto-char (point-min))
                   (when (re-search-forward
                          (format "\\_<\\(?:id\\|name\\)[ \t]*=[ \t]*\"%s\""
                                  (regexp-quote target))
                          nil t)
                     (line-beginning-position)))))
      (unless dest
        (user-error "No anchor `%s' in this buffer" target))
      ;; Leave the mark behind so \\[exchange-point-and-mark] returns; no
      ;; "Mark set" message, the jump is its own feedback.
      (push-mark nil t)
      (goto-char dest)
      t)))

;;;; Emphasis editing ---------------------------------------------------------

;;;###autoload
(defun markdown-plus-insert-underline ()
  "Insert or remove `<u>...</u>' around the region, the word at point, or point.
Markdown has no underline of its own, so the HTML tag is used; it is
hidden and revealed like the native markup."
  (interactive)
  (markdown--insert-common "<u>" "</u>" markdown-plus--underline-re 1 3
                           'markdown-plus-underline-face t))

;;;; Minor mode ---------------------------------------------------------------

(defvar markdown-plus-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-x C-v") #'markdown-plus-show-images)
    (define-key map (kbd "C-c C-x C-r") #'markdown-plus-hide-images)
    ;; macOS-style emphasis toggles; the markdown-mode commands remove the
    ;; markup again when point is already inside it.
    (define-key map (kbd "s-b") #'markdown-insert-bold)
    (define-key map (kbd "s-i") #'markdown-insert-italic)
    (define-key map (kbd "s-`") #'markdown-insert-code)
    (define-key map (kbd "s-_") #'markdown-plus-insert-underline)
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
  (add-hook 'markdown-follow-link-functions #'markdown-plus--follow-anchor nil t)
  (font-lock-add-keywords nil markdown-plus--font-lock-keywords t)
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
  (remove-hook 'markdown-follow-link-functions #'markdown-plus--follow-anchor t)
  (font-lock-remove-keywords nil markdown-plus--font-lock-keywords)
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
