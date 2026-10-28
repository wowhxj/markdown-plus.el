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
;;     bullets, GitHub alert markers and fenced code block markers are
;;     rendered, and the raw source is revealed only when point enters
;;     the element and re-hidden when point leaves.
;;   * Fenced code blocks (```lang ... ```) get a distinct background;
;;     their content is never touched, and the fence markers render as a
;;     Nerd Font icon (plus the language, when named) like other markup.
;;   * Inline image preview for local and remote images, written either
;;     as ![alt](path) or as <img src="path" width="400">; remote images
;;     are downloaded asynchronously and shown when ready.  A local
;;     <img src="clip.mp4" width="..."> is shown as a clickable ffmpeg
;;     thumbnail instead, since Emacs cannot decode video.
;;   * GitHub alerts (> [!NOTE], > [!WARNING], ...) render as a coloured
;;     label with a Nerd Font icon.
;;   * <source src="clip.mp4"> renders as a clickable file name; Emacs
;;     decodes no video, so RET or a click hands it to the system player.
;;   * [text](#name) jumps to <a id="name"> in the same buffer, which is
;;     what makes an Org- or Pandoc-exported table of contents work.
;;   * Automatic table alignment when leaving a GFM table.
;;   * `markdown-plus-org-mode' extends the reveal to Org
;;     #+begin_src markdown blocks.  Org already renders them, by copying
;;     markdown-mode's text properties out of its native-fontification
;;     scratch buffer; this adds the reveal-on-point half, which cannot
;;     travel that way.  Nothing in it calls Org, so Org is not a
;;     dependency.  Add it to `org-mode-hook'.
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
(require 'url-util)
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

(defcustom markdown-plus-video-extensions '("mp4" "m4v" "mov" "webm" "mkv")
  "File extensions previewed as a video thumbnail instead of an image.
Applies to a local file referenced by `<img src=\"...\">'; Emacs cannot
decode video, so `ffmpeg' grabs a frame instead."
  :type '(repeat string)
  :group 'markdown-plus)

(defcustom markdown-plus-video-thumbnail-at "00:00:01"
  "Seek position passed to ffmpeg's -ss option when grabbing a video frame.
Clips shorter than this fall back to the first frame."
  :type 'string
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

(defconst markdown-plus--fence-re
  "^[ \t]*\\(```+\\|~~~+\\)[ \t]*\\([[:alnum:]_+-]*\\)[ \t]*$"
  "Regexp matching a fenced code block's opening or closing marker line.
Group 1 is the fence delimiter, group 2 the language (empty when closing).")

;;;; Faces / colors -----------------------------------------------------------

(defface markdown-plus-underline-face '((t (:underline t)))
  "Face for the text inside `<u>...</u>'."
  :group 'markdown-plus)

(defface markdown-plus-video-face '((t (:inherit link)))
  "Face for a rendered video link."
  :group 'markdown-plus)

(defface markdown-plus-heading-level-face '((t (:inherit shadow)))
  "Face for the `H1'/`H2'/... label substituted for a heading's `#' markup."
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

(defconst markdown-plus--fence-icon (string #xF121) ; nf-oct-code
  "Icon substituted for a fence marker line while it is not revealed.")

(defun markdown-plus--fence-display (lang)
  "Return the display substitution for a fence line naming LANG (or \"\")."
  (markdown-plus--icon-label
   (if (zerop (length lang))
       markdown-plus--fence-icon
     (concat markdown-plus--fence-icon " " lang))))

(defun markdown-plus--alert-properties ()
  "Return font-lock properties for the alert marker just matched, or nil.
Nil for an unknown type, which leaves the marker untouched."
  (let ((spec (assoc (upcase (match-string-no-properties 2))
                     markdown-plus-alert-types)))
    (when spec
      `(face (:foreground ,(nth 2 spec) :weight bold)
             ,@(when markdown-hide-markup
                 `(display ,(markdown-plus--icon-label (nth 1 spec))))))))

(defun markdown-plus--heading-level-properties ()
  "Return font-lock properties labelling the ATX heading markup just matched.
Assumes match data from `markdown-match-propertized-text' on the
`markdown-heading' property, whose group 4 is the heading's `#' markup
run (see `markdown-regex-header').  Nil when markup is not hidden, or
for a setext heading, which has no group-4 markup to replace."
  (when (and markdown-hide-markup (match-beginning 4))
    `(face nil display ,(propertize
                          (format "H%d " (cl-count ?# (match-string-no-properties 4)))
                          'face 'markdown-plus-heading-level-face))))

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

(defvar markdown-plus-video-thumbnail-map
  (let ((map (make-sparse-keymap)))
    ;; Same rationale as `markdown-plus-video-map': point on the tag means
    ;; it is revealed as raw text, so RET must stay a newline for editing.
    (define-key map (kbd "C-c C-o") #'markdown-plus-play-video-thumbnail-at-point)
    (define-key map [mouse-2] #'markdown-plus-play-video-thumbnail-at-point)
    (define-key map [follow-link] 'mouse-face)
    map)
  "Keymap active on a video thumbnail rendered from an `<img>' tag.")

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

;; Defined by the `define-minor-mode' form further down, but read here.
(defvar markdown-plus--region)

(defun markdown-plus--fence-matcher (last)
  "Match a fenced code block marker line before LAST.
Group 0 is the marker text and group 2 its language, as in
`markdown-plus--fence-re'.  Group 3 is added for the line's own newline:
`markdown-fontify-code-blocks-generic' hides that newline along with the
marker, and that is what merges a block into the surrounding text.  The
two need separate groups because the icon may only replace the marker --
covering the newline with a `display' string would eat the line break."
  (when (re-search-forward markdown-plus--fence-re last t)
    (let* ((md (match-data))
           (text-end (nth 1 md)))
      (set-match-data
       (append md (when (< text-end (point-max))
                    (list text-end (1+ text-end)))))
      t)))

(defun markdown-plus--fence-properties ()
  "Return font-lock properties for the fence marker line just matched.
Substitutes the icon unless the active appear region covers the line --
read from `markdown-plus--region', never (point), which is not the real
cursor position during jit-lock redisplay."
  (let* ((lang (match-string-no-properties 2))
         (lbeg (match-beginning 0))
         (lend (min (point-max) (1+ (match-end 0))))
         (revealed (and markdown-plus--region
                        (< (car markdown-plus--region) lend)
                        (> (cdr markdown-plus--region) lbeg))))
    `(face nil invisible nil
           display ,(unless revealed (markdown-plus--fence-display lang)))))

(defvar markdown-plus--font-lock-keywords
  `((,markdown-plus--alert-re
     (1 (markdown-plus--alert-properties) prepend t))
    (,markdown-plus--video-re
     (0 (markdown-plus--video-properties) prepend))
    (markdown-plus--fence-matcher
     (0 (markdown-plus--fence-properties) prepend)
     ;; the marker's own newline: un-hide it, but never put the icon on it
     (3 '(face nil invisible nil) prepend t))
    (,markdown-plus--underline-re
     (2 (markdown-plus--markup-properties) prepend)
     (3 'markdown-plus-underline-face prepend)
     (4 (markdown-plus--markup-properties) prepend))
    ((lambda (last) (markdown-match-propertized-text 'markdown-heading last))
     (4 (markdown-plus--heading-level-properties) prepend t)))
  "Font-lock keywords added on top of markdown-mode's own.
Appended so they run last; `prepend' then puts their faces on top.
`display' and `invisible' are in markdown-mode's
`font-lock-extra-managed-props', so font-lock cleans them up itself.

Fences are handled here rather than in `markdown-plus--jit-fixup' so that
they also work inside an Org `#+begin_src markdown' block:
`org-src-font-lock-fontify-block' copies every property in the language
mode's `font-lock-extra-managed-props' back into the Org buffer, but it
fontifies its scratch buffer with font-lock only -- `jit-lock-functions'
never run there, so anything applied in the jit-lock fixup is invisible
to Org.")

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
            (replace-regexp-in-string "\\\\ " " " path)
            (file-name-directory
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
  "Create an image object for FILE, optionally requesting pixel WIDTH.
The configured maximum width applies when WIDTH is nil; the configured
maximum height applies in either case."
  (apply #'create-image file nil nil
         :max-width (max (car markdown-plus-max-image-size) (or width 0))
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

(defun markdown-plus--video-file-p (file)
  "Return non-nil if FILE's extension is one of `markdown-plus-video-extensions'."
  (member (downcase (or (file-name-extension file) ""))
          markdown-plus-video-extensions))

(defun markdown-plus--video-thumbnail (file)
  "Return a thumbnail image for video FILE, or nil if `ffmpeg' fails.
The thumbnail is cached as the sibling file FILE.thumb.jpg and is
regenerated whenever FILE is newer than it."
  (let* ((thumb (concat file ".thumb.jpg"))
         (grab (lambda (seek)
                 (eq 0 (call-process "ffmpeg" nil nil nil "-loglevel" "error"
                                     "-y" "-ss" seek "-i" file
                                     "-frames:v" "1" thumb)))))
    (unless (file-newer-than-file-p thumb file)
      ;; A clip shorter than `markdown-plus-video-thumbnail-at' seeks past
      ;; its end and produces no frame; retry from the start.
      (or (funcall grab markdown-plus-video-thumbnail-at)
          (funcall grab "0")))
    (and (file-exists-p thumb) thumb)))

(defun markdown-plus--put-video-thumbnail-overlay (beg end file &optional width)
  "Overlay BEG..END with a thumbnail of video FILE, at WIDTH pixels.
Clicking or `C-c C-o' on the overlay hands FILE to the system player,
via `markdown-plus-video-thumbnail-map'; Emacs decodes no video, so a
still frame from `ffmpeg' stands in for the image."
  (unless (cl-some (lambda (o) (overlay-get o 'markdown-plus-image))
                   (overlays-at beg))
    (let* ((thumb (markdown-plus--video-thumbnail file))
           (img (and thumb (ignore-errors (markdown-plus--make-image thumb width)))))
      (when img
        (let ((ov (make-overlay beg end)))
          (overlay-put ov 'markdown-plus-image t)
          (overlay-put ov 'display img)
          (overlay-put ov 'keymap markdown-plus-video-thumbnail-map)
          (overlay-put ov 'mouse-face 'highlight)
          (overlay-put ov 'help-echo (concat "mouse-1, C-c C-o: play " file))
          (overlay-put ov 'markdown-plus-video-src file)
          (overlay-put ov 'evaporate t))))))

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
images not yet cached are downloaded asynchronously.  A local file
naming a `markdown-plus-video-extensions' format renders as a clickable
`ffmpeg' thumbnail instead of an image (remote videos are not, since
that would mean downloading the whole clip just to grab a frame).  The
image under point is left as source so it can be edited."
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
                    (if (markdown-plus--video-file-p f)
                        (markdown-plus--put-video-thumbnail-overlay mbeg mend f width)
                      (markdown-plus--put-image-overlay mbeg mend f width))))))))))))

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
Order: HTML image, video, fence line, Markdown image, link, underline,
ATX heading line, inline markup, then the whole-line markers (alert,
list bullet).  The HTML/structural forms come first: their file names
routinely contain `_', which the inline matcher would otherwise read as
emphasis.  The markers come last so inline markup on the same line
still wins.  Only fence *lines* participate this way; the code inside a
block never does, so it is never treated as revealable."
  (let ((pos (point)))
    (cond
     ((markdown-plus--bounds-at pos markdown-plus--html-image-re))
     ((markdown-plus--bounds-at pos markdown-plus--video-re))
     ((markdown-plus--bounds-at pos markdown-plus--fence-re))
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

1. Remove the scaling `display' wrongly applied by sub/superscript
   fontification to strikethrough ~~text~~.
2. Re-reveal the active appear region so editing within it does not
   flicker between revealed and hidden.

Fence lines are not handled here; see `markdown-plus--font-lock-keywords'
for why they have to be a font-lock keyword instead.

All steps check before modifying so unchanged lines are left alone."
  (when markdown-hide-markup
    (save-excursion
      ;; (1) strip subscript display wrongly added inside ~~strikethrough~~
      (goto-char beg)
      (let ((lim (min end (point-max))))
        (while (re-search-forward "~~\\(?:[^~\n]\\)+?~~" lim t)
          (let ((mb (match-beginning 0)) (me (match-end 0)))
            (when (text-property-not-all mb me 'display nil)
              (with-silent-modifications
                (remove-text-properties mb me '(display nil)))))))
      ;; (2) keep the active appear region revealed.  Use the tracked
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

;;;; Org `#+begin_src markdown' blocks -----------------------------------------

;; Rendering inside an Org src block comes for free: Org's native src
;; fontification runs the language mode over a scratch buffer and copies back
;; every property in its `font-lock-extra-managed-props', which for
;; markdown-mode covers `display' and `invisible'.  So markdown-plus's
;; font-lock keywords (alerts, videos, fences, <u>) already show up in Org.
;;
;; Reveal-on-point does not, because that is driven from `post-command-hook'
;; in the buffer being edited, and the scratch buffer is long gone by then.
;; `markdown-plus-org-mode' supplies just that missing half.  Nothing here
;; calls into Org, so no dependency on it is introduced.

(defconst markdown-plus-org--src-langs '("markdown" "md" "gfm")
  "Src block languages treated as Markdown.")

(defvar-local markdown-plus-org--region nil
  "The currently revealed region as a cons (BEG . END), or nil.")

(defun markdown-plus-org--block-bounds ()
  "Return (BEG . END) of the Markdown src block body point is inside, or nil.
BEG is the first character after the `#+begin_src' line, END the beginning
of the `#+end_src' line."
  (save-excursion
    (let ((case-fold-search t)
          (pos (point))
          head-end)
      (forward-line 0)
      (when (and (re-search-backward
                  "^[ \t]*#\\+begin_src[ \t]+\\([^ \t\n]+\\)" nil t)
                 (member (downcase (match-string 1))
                         markdown-plus-org--src-langs))
        (setq head-end (line-end-position))
        (when (re-search-forward "^[ \t]*#\\+end_src\\>" nil t)
          (let ((tail-beg (line-beginning-position)))
            (when (and (> pos head-end) (< pos tail-beg))
              (cons (min (1+ head-end) tail-beg) tail-beg))))))))

(defun markdown-plus-org--reveal (beg end)
  "Reveal raw Markdown markup in BEG..END.
`org-src-invisible' is Org's alias for the `invisible' it copied over, so
both have to go."
  (with-silent-modifications
    (remove-text-properties
     beg end
     '(org-src-invisible nil invisible nil display nil composition nil))))

(defun markdown-plus-org--restore (beg end)
  "Re-hide BEG..END by refontifying it, extended to whole lines.
Refontifying is enough to restore everything: it re-runs Org's src block
fontification, which copies the properties back."
  (let ((b (save-excursion (goto-char beg) (line-beginning-position)))
        (e (save-excursion (goto-char end) (line-end-position))))
    (with-silent-modifications
      (font-lock-flush b e)
      (font-lock-ensure b e))))

(defun markdown-plus-org--after-change (beg end _len)
  "Strip hiding properties that text just typed into BEG..END inherited.
`self-insert-command' inserts with inheritance, so a character typed right
after hidden markup -- the closing backtick of `code', say -- picks up its
`invisible' property and vanishes.  A Markdown buffer recovers by itself:
`invisible' is in markdown-mode's `font-lock-extra-managed-props', so the
next font-lock pass unfontifies it away.  Org copies the same property under
the `org-src-invisible' alias, which its own font-lock does not manage and
`org-src-font-lock-fontify-block' does not clear -- it removes only `face' --
so there the text stays hidden for good.

Org's folding uses `invisible' as well, hence the check that the change is
inside a Markdown src block."
  (when (and (> end beg)
             (or (text-property-not-all beg end 'invisible nil)
                 (text-property-not-all beg end 'org-src-invisible nil)))
    (save-excursion
      (goto-char beg)
      (when (markdown-plus-org--block-bounds)
        (with-silent-modifications
          (remove-text-properties
           beg end '(invisible nil org-src-invisible nil)))))))

(defun markdown-plus-org--post-command ()
  "Reveal the Markdown element at point and re-hide the previous one.
Reuses `markdown-plus--element-bounds', so an Org src block reveals at the
same granularity a Markdown buffer does; the result is clamped to the block
so a match can never leak into the surrounding Org text."
  (condition-case nil
      (let* ((body (markdown-plus-org--block-bounds))
             (bounds (and body (markdown-plus--element-bounds)))
             (new (when bounds
                    (cons (max (car body) (car bounds))
                          (min (cdr body) (cdr bounds))))))
        ;; Clear the region before restoring, for the same reason
        ;; `markdown-plus--post-command' does.
        (when (and markdown-plus-org--region
                   (not (equal markdown-plus-org--region new)))
          (let ((old markdown-plus-org--region))
            (setq markdown-plus-org--region nil)
            (markdown-plus-org--restore (car old) (cdr old))))
        (when (and new (not (equal new markdown-plus-org--region)))
          (markdown-plus-org--reveal (car new) (cdr new))
          (setq markdown-plus-org--region new)))
    (error nil)))

;;;###autoload
(define-minor-mode markdown-plus-org-mode
  "Reveal raw Markdown markup at point inside Org `#+begin_src markdown' blocks.

Org already renders the markup, by copying markdown-mode's text properties
out of its native-fontification scratch buffer.  This mode adds the missing
half: the element at point shows its raw source, and re-hides on leaving.

Add it to `org-mode-hook'."
  :lighter " M+org"
  :group 'markdown-plus
  (if markdown-plus-org-mode
      (progn
        (add-hook 'post-command-hook #'markdown-plus-org--post-command nil t)
        (add-hook 'after-change-functions #'markdown-plus-org--after-change nil t))
    (remove-hook 'post-command-hook #'markdown-plus-org--post-command t)
    (remove-hook 'after-change-functions #'markdown-plus-org--after-change t)
    (when markdown-plus-org--region
      (let ((old markdown-plus-org--region))
        (setq markdown-plus-org--region nil)
        (markdown-plus-org--restore (car old) (cdr old))))))

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

(defun markdown-plus--resolve-and-play (src)
  "Play SRC: browse it directly if a URL, else resolve and open the file.
Emacs decodes no video format at all, so the file is handed to
`browse-url', which on each platform reaches the system's default
application for it."
  (cond
   ((string-match-p "\\`https?://" src) (browse-url src))
   (t (let ((file (markdown-plus--local-file src)))
        (unless file (user-error "No such file: %s" src))
        (browse-url (browse-url-file-url (expand-file-name file)))))))

(defun markdown-plus-play-video-at-point (&optional event)
  "Play the video of the `<source>' tag at point, or at EVENT.
Bound to \\`C-c C-o' and mouse-1 on a rendered video link."
  (interactive (list last-nonmenu-event))
  (when (consp event)
    (posn-set-point (event-start event)))
  (let ((bounds (markdown-plus--bounds-at (point) markdown-plus--video-re)))
    (unless bounds
      (user-error "Point is not on a video link"))
    (let ((src (markdown-plus--html-attr
                (buffer-substring-no-properties (car bounds) (cdr bounds))
                "src")))
      (unless src (user-error "This <source> tag has no `src'"))
      (markdown-plus--resolve-and-play src))))

(defun markdown-plus-play-video-thumbnail-at-point (&optional event)
  "Play the video behind the thumbnail at point, or at EVENT.
Bound to \\`C-c C-o' and mouse-1 on a video thumbnail rendered from an
`<img src=\"....mp4\">' tag."
  (interactive (list last-nonmenu-event))
  (when (consp event)
    (posn-set-point (event-start event)))
  (let* ((ov (cl-find-if (lambda (o) (overlay-get o 'markdown-plus-video-src))
                        (overlays-at (point))))
         (src (and ov (overlay-get ov 'markdown-plus-video-src))))
    (unless src (user-error "Point is not on a video thumbnail"))
    (markdown-plus--resolve-and-play src)))

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

;;;; Heading insertion / jump, Org-style ---------------------------------------

(defun markdown-plus--enclosing-heading-level ()
  "Return the level of the heading enclosing point, or nil if none.
Moves point to that heading's start; callers that only want the level
wrap this in `save-excursion'."
  (condition-case nil
      (progn (markdown-back-to-heading) (markdown-outline-level))
    (error nil)))

;;;###autoload
(defun markdown-plus-insert-heading ()
  "Insert a heading at point, at the same level as the enclosing one.
Splits the line at point the way `markdown-insert-header' always does:
text after point moves onto the new heading.  Mirrors Org's `M-RET'
\(`org-meta-return'), except on a list item, where it defers to
`markdown-insert-list-item' instead of starting a heading -- Org's
M-RET is itself list-aware in exactly this way."
  (interactive "*")
  (if (markdown-list-item-at-point-p)
      (call-interactively #'markdown-insert-list-item)
    (let ((level (save-excursion (or (markdown-plus--enclosing-heading-level) 1))))
      (markdown-insert-header level "" nil))))

;;;###autoload
(defun markdown-plus-insert-heading-after-subtree ()
  "Insert a heading after the current subtree, at the same level.
Mirrors Org's `C-RET' (`org-insert-heading-respect-content'): always a
heading, regardless of what point is inside."
  (interactive "*")
  (let* ((found (save-excursion (markdown-plus--enclosing-heading-level)))
         (level (or found 1)))
    (if found (markdown-end-of-subtree) (goto-char (point-max)))
    (markdown-insert-header level "" nil)))

;;;###autoload
(defun markdown-plus-consult-heading ()
  "Jump to a heading in this buffer, searched and filtered via `consult'.
Mirrors Org's `C-c C-j' (`org-goto').  Requires the `consult' package."
  (interactive)
  ;; `consult-imenu' lives in its own file, not the umbrella `consult'
  ;; feature; `fboundp' alone would already be true from an unloaded
  ;; package.el autoload, so try that before forcing a `require'.
  (unless (or (fboundp 'consult-imenu) (require 'consult-imenu nil t))
    (user-error "markdown-plus-consult-heading requires the `consult' package"))
  ;; Scope the index to headings only; footnotes are irrelevant to a
  ;; heading jump and would just be noise in the candidate list.
  (let ((markdown-add-footnotes-to-imenu nil))
    (consult-imenu)))

;;;; Clipboard paste ----------------------------------------------------------

(defun markdown-plus--clipboard-selection (target)
  "Read TARGET from the clipboard, or return nil when unavailable."
  (when (fboundp 'gui-get-selection)
    (ignore-errors (gui-get-selection 'CLIPBOARD target))))

(defun markdown-plus--clipboard-files ()
  "Return local file paths advertised by the clipboard, or nil."
  (let* ((selection (or (markdown-plus--clipboard-selection 'text/uri-list)
                        (markdown-plus--clipboard-selection 'public.file-url)
                        (markdown-plus--clipboard-selection 'NSFilenamesPboardType)))
         (items (cond ((stringp selection) (split-string selection "[\r\n]+" t))
                      ((listp selection) selection)))
         files)
    (dolist (item items)
      (when (stringp item)
        (let ((path (cond
                     ((string-match "\\`file://\\(?:localhost\\)?\\(/.*\\)\\'" item)
                      (url-unhex-string (match-string 1 item)))
                     ((file-name-absolute-p item) item))))
          (when (and path (file-exists-p path))
            (push path files)))))
    (nreverse files)))

(defun markdown-plus--markdown-path (path)
  "Escape whitespace in PATH for use as a Markdown link destination."
  (replace-regexp-in-string "[ \t]" (lambda (s) (concat "\\\\" s)) path t t))

(defun markdown-plus--clipboard-image (file)
  "Save a PNG image from the clipboard to FILE; return non-nil on success."
  (cond
   ((eq system-type 'darwin)
    (and (executable-find "pngpaste")
         (eq 0 (call-process "pngpaste" nil nil nil file))))
   ((eq system-type 'gnu/linux)
    (let ((coding-system-for-read 'binary))
      (with-temp-buffer
        (let ((status
               (cond
                ((executable-find "wl-paste")
                 (call-process "wl-paste" nil t nil "--no-newline" "--type" "image/png"))
                ((executable-find "xclip")
                 (call-process "xclip" nil t nil "-selection" "clipboard" "-t" "image/png" "-o")))))
          (when (and (eq status 0) (> (buffer-size) 0))
            (write-region (point-min) (point-max) file nil 'silent)
            t)))))))

(defun markdown-plus--paste-clipboard-image ()
  "Save a clipboard image beside this document and insert its Markdown link."
  (let ((temporary (make-temp-file "markdown-plus-clipboard-" nil ".png")))
    (unwind-protect
        (when (markdown-plus--clipboard-image temporary)
          (let* ((base (file-name-base (or (buffer-file-name) (buffer-name))))
                 (directory (expand-file-name
                             (concat base ".assets")
                             (file-name-directory (or (buffer-file-name) default-directory))))
                 (name (concat "img_" (format-time-string "%Y%m%d_%H%M%S") ".png"))
                 (destination (expand-file-name name directory))
                 (n 1))
            (make-directory directory t)
            (while (file-exists-p destination)
              (setq destination
                    (expand-file-name
                     (format "img_%s_%d.png" (format-time-string "%Y%m%d_%H%M%S") n)
                     directory)
                    n (1+ n)))
            (let ((width (max 50 (truncate (read-number "Image width in pixels: " 800))))
                  (relative (file-relative-name
                             destination
                             (file-name-directory (or (buffer-file-name) default-directory)))))
              (rename-file temporary destination)
              (insert (format "\n<img src=\"%s\" width=\"%d\">\n" relative width))
              (save-excursion
                (forward-line -1)
                (goto-char (1+ (line-end-position)))
                (markdown-plus--display-images-in-region
                 (line-beginning-position) (line-end-position)))
              t)))
      (when (file-exists-p temporary)
        (delete-file temporary)))))

(defun markdown-plus--insert-clipboard-files (files)
  "Insert Markdown links to clipboard FILES and return non-nil."
  (when files
    (dolist (file files)
      (let* ((relative (markdown-plus--markdown-path
                        (file-relative-name
                         file (file-name-directory (or (buffer-file-name) default-directory)))))
             (name (file-name-nondirectory file)))
        (insert (if (image-type-from-file-name file)
                    (format "![%s](%s)" name relative)
                  (format "[%s](%s)" name relative)))
        (insert "\n")))
    (save-excursion
      (goto-char (min (1+ (point)) (point-max)))
      (markdown-plus--display-images-in-region (point-min) (point-max)))
    t))

(defun markdown-plus--resize-image-at-point (delta)
  "Change the HTML image width at point by DELTA pixels."
  (let ((bounds (markdown-plus--bounds-at (point) markdown-plus--html-image-re)))
    (unless bounds
      (user-error "Point is not on an HTML image"))
    (let* ((beg (car bounds))
           (end (cdr bounds))
           (tag (buffer-substring-no-properties beg end))
           (old-width (markdown-plus--html-attr tag "width"))
           (width (if (and old-width (string-match-p "\\`[0-9]+\\'" old-width))
                      (string-to-number old-width)
                    (car markdown-plus-max-image-size)))
           (new-width (max 50 (+ width delta)))
           (new-tag (if (string-match "[ \t]+width=\"[0-9]+\"" tag)
                        (replace-match (format " width=\"%d\"" new-width) t t tag)
                      (replace-regexp-in-string ">$" (format " width=\"%d\">" new-width)
                                               tag t t))))
      (delete-region beg end)
      (goto-char beg)
      (insert new-tag)
      (let ((new-end (point)))
        (markdown-plus--remove-image-overlays beg new-end)
        (save-excursion
          (goto-char (min (1+ new-end) (point-max)))
          (markdown-plus--display-images-in-region beg new-end)))
      new-width)))

;;;###autoload
(defun markdown-plus-enlarge-image-at-point ()
  "Increase the width of the HTML image at point by 100 pixels."
  (interactive)
  (markdown-plus--resize-image-at-point 100))

;;;###autoload
(defun markdown-plus-shrink-image-at-point ()
  "Decrease the width of the HTML image at point by 100 pixels."
  (interactive)
  (markdown-plus--resize-image-at-point -100))

;;;###autoload
(defun markdown-plus-paste ()
  "Paste clipboard content into Markdown, handling images and files specially.
Plain text uses the normal Emacs `yank' command."
  (interactive)
  (unless (or (markdown-plus--paste-clipboard-image)
              (markdown-plus--insert-clipboard-files
               (markdown-plus--clipboard-files)))
    (yank)))

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
    ;; Match the local Org clipboard-paste shortcut; both cases accommodate
    ;; Emacs configs that distinguish Command-V from Command-Shift-V.
    (define-key map (kbd "s-v") #'markdown-plus-paste)
    (define-key map (kbd "s-V") #'markdown-plus-paste)
    (define-key map (kbd "C-+") #'markdown-plus-enlarge-image-at-point)
    (define-key map (kbd "C--") #'markdown-plus-shrink-image-at-point)
    ;; Org-style heading commands.  These shadow markdown-mode's own
    ;; `M-RET'/`C-c C-j' (both bound to `markdown-insert-list-item' there);
    ;; `markdown-plus-insert-heading' still reaches that command on a list
    ;; item, so list continuation keeps working.
    (define-key map (kbd "M-RET") #'markdown-plus-insert-heading)
    (define-key map (kbd "<C-return>") #'markdown-plus-insert-heading-after-subtree)
    (define-key map (kbd "C-c C-j") #'markdown-plus-consult-heading)
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
