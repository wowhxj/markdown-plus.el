;;; markdown-plus-test.el --- Tests for markdown-plus -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;
;;   emacs -Q --batch -L . -L test -l test/markdown-plus-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'markdown-plus)

(defmacro markdown-plus-test--with (text &rest body)
  "Run BODY in a `markdown-mode' buffer holding TEXT, point where `|' was."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (delay-mode-hooks (markdown-mode))
     (insert ,text)
     (goto-char (point-min))
     (when (search-forward "|" nil t)
       (delete-char -1))
     ,@body))

(defun markdown-plus-test--revealed ()
  "Return the text `markdown-plus--element-bounds' would reveal, or nil."
  (let ((b (markdown-plus--element-bounds)))
    (when b (buffer-substring-no-properties (car b) (cdr b)))))

;;;; HTML image tags

(ert-deftest markdown-plus-test-html-attr ()
  "Attributes are read regardless of case."
  (let ((tag "<IMG SRC=\"a/b.PNG\" ALT=\"x\" WIDTH=\"400\">"))
    (should (equal (markdown-plus--html-attr tag "src") "a/b.PNG"))
    (should (equal (markdown-plus--html-attr tag "width") "400"))
    (should-not (markdown-plus--html-attr tag "height"))))

(ert-deftest markdown-plus-test-image-re-both-forms ()
  "`markdown-plus--image-re' matches Markdown and HTML images alike."
  (with-temp-buffer
    (insert "![alt](pic.png)\n<IMG SRC=\"other.PNG\" WIDTH=\"400\">\n")
    (goto-char (point-min))
    (should (re-search-forward markdown-plus--image-re nil t))
    (should (equal (markdown-plus--image-at-match) '("pic.png" . nil)))
    (should (re-search-forward markdown-plus--image-re nil t))
    (should (equal (markdown-plus--image-at-match) '("other.PNG" . 400)))))

(ert-deftest markdown-plus-test-image-re-ignores-other-tags ()
  "A `<source>' tag is not mistaken for an image."
  (with-temp-buffer
    (insert "<source src=\"v.mp4\" type=\"video/mp4\">")
    (goto-char (point-min))
    (should-not (re-search-forward markdown-plus--image-re nil t))))

(ert-deftest markdown-plus-test-image-width-only-if-numeric ()
  "A non-pixel width such as `100%' is ignored rather than mis-parsed."
  (with-temp-buffer
    (insert "<img src=\"a.png\" width=\"100%\">")
    (goto-char (point-min))
    (should (re-search-forward markdown-plus--image-re nil t))
    (should (equal (markdown-plus--image-at-match) '("a.png" . nil)))))

;;;; Reveal targets

(ert-deftest markdown-plus-test-bounds-html-image ()
  "Point inside an HTML image reveals the whole tag, not the underscores."
  (markdown-plus-test--with "<IMG SRC=\"IMG_2025_01.PNG\" WI|DTH=\"400\">"
    (should (equal (markdown-plus-test--revealed)
                   "<IMG SRC=\"IMG_2025_01.PNG\" WIDTH=\"400\">"))))

(ert-deftest markdown-plus-test-bounds-list-bullet ()
  "Point anywhere on a bullet line reveals just the list marker."
  (markdown-plus-test--with "-   厨房隐|患\n"
    (should (equal (markdown-plus-test--revealed) "-"))))

(ert-deftest markdown-plus-test-bounds-ordered-marker-ignored ()
  "An ordered list marker is not revealed; markdown-mode never hides it."
  (markdown-plus-test--with "2.  plain te|xt\n"
    (should-not (markdown-plus-test--revealed))))

(ert-deftest markdown-plus-test-bounds-inline-beats-bullet ()
  "Inline markup on a bullet line wins over the bullet itself."
  (markdown-plus-test--with "- some **bo|ld** text\n"
    (should (equal (markdown-plus-test--revealed) "**bold**"))))

(ert-deftest markdown-plus-test-bounds-alert ()
  "Point anywhere on an alert line reveals just the `[!TYPE]' marker."
  (markdown-plus-test--with "> [!NOTE]|\n"
    (should (equal (markdown-plus-test--revealed) "[!NOTE]")))
  (markdown-plus-test--with ">| [!WARNING]\n"
    (should (equal (markdown-plus-test--revealed) "[!WARNING]"))))

(ert-deftest markdown-plus-test-bounds-plain-blockquote ()
  "An ordinary blockquote is not treated as an alert."
  (markdown-plus-test--with "> just a quo|te\n"
    (should-not (markdown-plus-test--revealed))))

(ert-deftest markdown-plus-test-bounds-underline ()
  "Point inside `<u>...</u>' reveals the whole element."
  (markdown-plus-test--with "a <u>und|er</u> b\n"
    (should (equal (markdown-plus-test--revealed) "<u>under</u>"))))

;;;; Fenced code blocks

(ert-deftest markdown-plus-test-bounds-fence-open ()
  "Point on the opening fence line reveals the whole marker line."
  (markdown-plus-test--with "```py|thon\ncode\n```\n"
    (should (equal (markdown-plus-test--revealed) "```python"))))

(ert-deftest markdown-plus-test-bounds-fence-close ()
  "Point on the closing fence line reveals it, language absent."
  (markdown-plus-test--with "```python\ncode\n``|`\n"
    (should (equal (markdown-plus-test--revealed) "```"))))

(ert-deftest markdown-plus-test-bounds-fence-content-not-revealable ()
  "Point inside the code content is not itself a revealable element."
  (markdown-plus-test--with "```python\nco|de\n```\n"
    (should-not (markdown-plus-test--revealed))))

(ert-deftest markdown-plus-test-bounds-inline-code-not-a-fence ()
  "A single-backtick inline code span is not mistaken for a fence."
  (markdown-plus-test--with "see `co|de` here\n"
    (should (equal (markdown-plus-test--revealed) "`code`"))))

(ert-deftest markdown-plus-test-fence-iconified-by-default ()
  "With no active region, jit-fixup shows the icon, never invisible."
  (markdown-plus-test--with "```python\ncode\n```\n"
    (markdown-plus-mode 1)
    (font-lock-ensure)
    (setq markdown-plus--region nil)
    (markdown-plus--jit-fixup (point-min) (point-max))
    (goto-char (point-min))
    (should (equal (get-text-property (point) 'display)
                   (markdown-plus--fence-display "python")))
    (should-not (get-text-property (point) 'invisible))))

(ert-deftest markdown-plus-test-fence-raw-when-region-covers-it ()
  "When the tracked region covers the fence line, the raw text shows.
Mirrors --post-command: only markdown-plus--region decides this, never
raw (point) -- jit-lock redisplay can move point without it being the
real cursor position."
  (markdown-plus-test--with "```python\ncode\n```\n"
    (markdown-plus-mode 1)
    (font-lock-ensure)
    (setq markdown-plus--region (cons (point-min) (line-end-position)))
    (markdown-plus--jit-fixup (point-min) (point-max))
    (goto-char (point-min))
    (should-not (get-text-property (point) 'display))
    (should-not (get-text-property (point) 'invisible))))

(ert-deftest markdown-plus-test-fence-never-invisible ()
  "The fence line and its trailing newline never carry `invisible' after
jit-fixup, regardless of region state.  This is the failure mode ported
from the org-buffer bug: markdown-fontify-code-blocks-generic hides a
fence line's own newline along with its text, which otherwise merges
the block into whatever surrounds it once point is elsewhere."
  (markdown-plus-test--with "text\n\n```python\ncode\n```\n"
    (markdown-plus-mode 1)
    (font-lock-ensure)
    (markdown-plus--jit-fixup (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "```python")
    (should-not (get-text-property (line-beginning-position) 'invisible))
    (should-not (get-text-property (line-end-position) 'invisible))))

(ert-deftest markdown-plus-test-fence-closing-icon-no-language ()
  "The closing fence, with no language, shows the bare icon."
  (markdown-plus-test--with "```python\ncode\n```\n"
    (markdown-plus-mode 1)
    (font-lock-ensure)
    (setq markdown-plus--region nil)
    (markdown-plus--jit-fixup (point-min) (point-max))
    (goto-char (point-min))
    (search-forward "code\n")
    (should (equal (get-text-property (point) 'display)
                   (markdown-plus--fence-display "")))))

(ert-deftest markdown-plus-test-fence-reveal-restore-roundtrip ()
  "Reveal (point on the fence) shows raw text; leaving restores the icon,
exercising the same reveal/restore + jit-fixup backstop path
--post-command drives."
  (markdown-plus-test--with "```python\ncode\n```\n"
    (markdown-plus-mode 1)
    (font-lock-ensure)
    (goto-char (point-min))
    (let ((bounds (markdown-plus--element-bounds)))
      (should bounds)
      (setq markdown-plus--region bounds)
      (markdown-plus--reveal (car bounds) (cdr bounds)))
    (goto-char (point-min))
    (should-not (get-text-property (point) 'display))
    (let ((old markdown-plus--region))
      (setq markdown-plus--region nil)
      (markdown-plus--restore (car old) (cdr old)))
    (markdown-plus--jit-fixup (point-min) (point-max))
    (goto-char (point-min))
    (should (equal (get-text-property (point) 'display)
                   (markdown-plus--fence-display "python")))))

;;;; Font-lock

(ert-deftest markdown-plus-test-alert-fontification ()
  "A known alert type gets a `display' label; an unknown one is left alone."
  (markdown-plus-test--with "> [!NOTE]\n> body\n\n> [!BOGUS]\n"
    (markdown-plus-mode 1)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "[!NOTE]")
    (should (equal (get-text-property (match-beginning 0) 'display)
                   (markdown-plus--icon-label
                    (nth 1 (assoc "NOTE" markdown-plus-alert-types)))))
    (search-forward "[!BOGUS]")
    (should-not (get-text-property (match-beginning 0) 'display))))

(ert-deftest markdown-plus-test-icon-label-fallback ()
  "An icon the display cannot show is dropped; a plain label is untouched."
  (should (equal (markdown-plus--icon-label "Note") "Note"))
  (cl-letf (((symbol-function 'char-displayable-p) (lambda (_) nil)))
    (should (equal (markdown-plus--icon-label " Note") "Note")))
  (cl-letf (((symbol-function 'char-displayable-p) (lambda (_) t)))
    (should (equal (markdown-plus--icon-label " Note") " Note"))))

;;;; Video links

(ert-deftest markdown-plus-test-video-fontification ()
  "A <source> tag renders as a clickable file name carrying a keymap."
  (markdown-plus-test--with
      "> [!NOTE]\n> <source src=\"a/VID_01.mp4\" type=\"video/mp4\">\n"
    (markdown-plus-mode 1)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "<source")
    (let ((p (match-beginning 0)))
      (should (equal (get-text-property p 'display)
                     (markdown-plus--icon-label
                      (concat (string #xF04B) " VID_01.mp4"))))
      (should (string-suffix-p "VID_01.mp4" (get-text-property p 'display)))
      (should (eq (get-text-property p 'keymap) markdown-plus-video-map))
      (should (equal (get-text-property p 'help-echo)
                     "mouse-1, C-c C-o: play a/VID_01.mp4")))))

(ert-deftest markdown-plus-test-video-keys ()
  "C-c C-o plays; RET and the other C-c bindings are left alone."
  (markdown-plus-test--with
      "> <source src=\"a/VID_01.mp4\" ty|pe=\"video/mp4\">\n"
    (markdown-plus-mode 1)
    (font-lock-ensure)
    (should (eq (key-binding (kbd "C-c C-o"))
                'markdown-plus-play-video-at-point))
    ;; A prefix binding in a text-property keymap must not hide the rest.
    (should (eq (key-binding (kbd "C-c C-x C-v")) 'markdown-plus-show-images))
    (should (eq (key-binding (kbd "C-c C-x C-r")) 'markdown-plus-hide-images))
    ;; RET stays a newline: point on the tag means the tag is revealed.
    (should-not (eq (key-binding (kbd "RET"))
                    'markdown-plus-play-video-at-point))))

(ert-deftest markdown-plus-test-video-keys-off-link ()
  "Away from a video link, C-c C-o is markdown-mode's own command again."
  (markdown-plus-test--with "plain te|xt\n"
    (markdown-plus-mode 1)
    (font-lock-ensure)
    (should (eq (key-binding (kbd "C-c C-o")) 'markdown-follow-thing-at-point))))

(ert-deftest markdown-plus-test-video-bounds-beats-inline ()
  "The underscores in a video file name are not read as emphasis."
  (markdown-plus-test--with
      "> <source src=\"a/VID_20250321_120125.mp4\" type=\"vi|deo/mp4\">\n"
    (should (equal (markdown-plus-test--revealed)
                   "<source src=\"a/VID_20250321_120125.mp4\" type=\"video/mp4\">"))))

(ert-deftest markdown-plus-test-play-video-resolves-file ()
  "Playing hands the existing file to `browse-url' as a file URL."
  (let* ((dir (make-temp-file "markdown-plus-test" t))
         (vid (expand-file-name "clip.mp4" dir))
         (called nil))
    (unwind-protect
        (progn
          (write-region "" nil vid nil 'silent)
          (with-temp-buffer
            (delay-mode-hooks (markdown-mode))
            (setq buffer-file-name (expand-file-name "doc.md" dir))
            (insert "> <source src=\"clip.mp4\" type=\"video/mp4\">\n")
            (goto-char (point-min))
            (search-forward "clip.mp4")
            (cl-letf (((symbol-function 'browse-url)
                       (lambda (url &rest _) (setq called url))))
              (markdown-plus-play-video-at-point))
            (setq buffer-file-name nil))
          (should (equal called (browse-url-file-url vid))))
      (delete-directory dir t))))

(ert-deftest markdown-plus-test-play-video-missing-file ()
  "A `src' pointing nowhere is reported instead of silently opening nothing."
  (markdown-plus-test--with "> <source src=\"nope.mp4\" type=\"video/mp4\">\n"
    (goto-char (point-min))
    (search-forward "nope")
    (should-error (markdown-plus-play-video-at-point) :type 'user-error)))

(ert-deftest markdown-plus-test-play-video-not-on-link ()
  "Invoking the command away from a video link says so."
  (markdown-plus-test--with "plain te|xt\n"
    (should-error (markdown-plus-play-video-at-point) :type 'user-error)))

;;;; Video thumbnails

(ert-deftest markdown-plus-test-video-file-p ()
  "Video detection is by extension, case-insensitively."
  (should (markdown-plus--video-file-p "a/b.mp4"))
  (should (markdown-plus--video-file-p "a/B.MP4"))
  (should (markdown-plus--video-file-p "clip.mov"))
  (should-not (markdown-plus--video-file-p "a.png"))
  (should-not (markdown-plus--video-file-p "no-extension")))

(ert-deftest markdown-plus-test-image-re-matches-video-img-tag ()
  "An `<img>' tag pointing at a video is still an image match; the
video/still-image branch is decided later, from the resolved file."
  (with-temp-buffer
    (insert "<img src=\"clip.mp4\" width=\"400\">\n")
    (goto-char (point-min))
    (should (re-search-forward markdown-plus--image-re nil t))
    (should (equal (markdown-plus--image-at-match) '("clip.mp4" . 400)))))

(defun markdown-plus-test--make-clip (path)
  "Write a short real video to PATH with ffmpeg, for thumbnail tests."
  (call-process "ffmpeg" nil nil nil "-loglevel" "error" "-y"
                "-f" "lavfi" "-i" "testsrc=duration=1:size=64x64:rate=5"
                "-pix_fmt" "yuv420p" path))

(ert-deftest markdown-plus-test-video-thumbnail-generates-and-caches ()
  "A thumbnail is generated once, cached, and regenerated when stale."
  (let* ((dir (make-temp-file "markdown-plus-test" t))
         (clip (expand-file-name "clip.mp4" dir))
         (thumb (concat clip ".thumb.jpg")))
    (unwind-protect
        (progn
          (markdown-plus-test--make-clip clip)
          (should (file-exists-p clip))
          (let ((got (markdown-plus--video-thumbnail clip)))
            (should (equal got thumb))
            (should (file-exists-p thumb))
            (should (> (file-attribute-size (file-attributes thumb)) 0)))
          ;; Up to date: left alone.
          (let ((before (file-attribute-modification-time
                         (file-attributes thumb))))
            (markdown-plus--video-thumbnail clip)
            (should (equal before (file-attribute-modification-time
                                   (file-attributes thumb)))))
          ;; Stale (older than the clip): regenerated.
          (set-file-times thumb '(0 0))
          (markdown-plus--video-thumbnail clip)
          (should (file-newer-than-file-p thumb clip)))
      (delete-directory dir t))))

(ert-deftest markdown-plus-test-video-thumbnail-overlay ()
  "An `<img>' tag naming a video gets a clickable thumbnail overlay,
carrying the video keymap rather than the generic `image-map'."
  (let* ((dir (make-temp-file "markdown-plus-test" t))
         (clip (expand-file-name "clip.mp4" dir)))
    (unwind-protect
        (progn
          (markdown-plus-test--make-clip clip)
          (with-temp-buffer
            (delay-mode-hooks (markdown-mode))
            (setq buffer-file-name (expand-file-name "doc.md" dir))
            (insert "<img src=\"clip.mp4\" width=\"400\">\n")
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
              (markdown-plus--display-images-in-region (point-min) (point-max)))
            (setq buffer-file-name nil)
            (let* ((ovs (seq-filter (lambda (o) (overlay-get o 'markdown-plus-image))
                                   (overlays-in (point-min) (point-max))))
                   (ov (car ovs)))
              (should (= 1 (length ovs)))
              (should (equal clip (overlay-get ov 'markdown-plus-video-src)))
              (should (eq (overlay-get ov 'keymap) markdown-plus-video-thumbnail-map))
              (should (equal 400 (plist-get (cdr (overlay-get ov 'display)) :width))))))
      (delete-directory dir t))))

(ert-deftest markdown-plus-test-image-overlay-still-uses-image-map ()
  "A plain (non-video) `<img>' tag is unaffected: still `image-map'."
  (let* ((dir (make-temp-file "markdown-plus-test" t))
         (pic (expand-file-name "pic.png" dir)))
    (unwind-protect
        (progn
          (write-region "" nil pic nil 'silent)
          (with-temp-buffer
            (delay-mode-hooks (markdown-mode))
            (setq buffer-file-name (expand-file-name "doc.md" dir))
            (insert "<img src=\"pic.png\">\n")
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                      ((symbol-function 'create-image) (lambda (&rest _) (list 'image))))
              (markdown-plus--display-images-in-region (point-min) (point-max)))
            (setq buffer-file-name nil)
            (let ((ov (car (seq-filter (lambda (o) (overlay-get o 'markdown-plus-image))
                                       (overlays-in (point-min) (point-max))))))
              (should (eq (overlay-get ov 'keymap) image-map))
              (should-not (overlay-get ov 'markdown-plus-video-src)))))
      (delete-directory dir t))))

(ert-deftest markdown-plus-test-play-video-thumbnail-resolves-file ()
  "Playing a thumbnail hands the video file to `browse-url'."
  (let* ((dir (make-temp-file "markdown-plus-test" t))
         (clip (expand-file-name "clip.mp4" dir))
         (called nil))
    (unwind-protect
        (progn
          (markdown-plus-test--make-clip clip)
          (with-temp-buffer
            (delay-mode-hooks (markdown-mode))
            (setq buffer-file-name (expand-file-name "doc.md" dir))
            (insert "<img src=\"clip.mp4\" width=\"400\">\n")
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
              (markdown-plus--display-images-in-region (point-min) (point-max)))
            (goto-char (point-min))
            (cl-letf (((symbol-function 'browse-url)
                       (lambda (url &rest _) (setq called url))))
              (markdown-plus-play-video-thumbnail-at-point))
            (setq buffer-file-name nil)
            (should (equal called (browse-url-file-url clip)))))
      (delete-directory dir t))))

(ert-deftest markdown-plus-test-play-video-thumbnail-not-on-overlay ()
  "Invoking the command away from a thumbnail says so."
  (markdown-plus-test--with "plain te|xt\n"
    (should-error (markdown-plus-play-video-thumbnail-at-point) :type 'user-error)))

;;;; Anchor links

(ert-deftest markdown-plus-test-follow-anchor ()
  "Following `#name' jumps to the matching HTML anchor and marks the origin."
  (markdown-plus-test--with
      "- [Sec](#org1234)\n\nfiller\n\n<a id=\"org1234\"></a>\n\n# Sec\n"
    (markdown-plus-mode 1)
    (goto-char (point-min))
    (search-forward "#org1234")
    (goto-char (1- (point)))
    (let ((origin (point)))
      (markdown-follow-thing-at-point nil)
      (should (looking-at-p "<a id=\"org1234\">"))
      (should (= (mark t) origin)))))

(ert-deftest markdown-plus-test-follow-anchor-missing ()
  "A fragment with no matching anchor reports it instead of doing nothing."
  (markdown-plus-test--with "[Sec](#nope)\n"
    (markdown-plus-mode 1)
    (goto-char (point-min))
    (search-forward "#nope")
    (goto-char (1- (point)))
    (should-error (markdown-follow-thing-at-point nil) :type 'user-error)))

(ert-deftest markdown-plus-test-follow-anchor-ignores-plain-links ()
  "A non-fragment URL is left to markdown-mode's own handling."
  (with-temp-buffer
    (should-not (markdown-plus--follow-anchor "https://example.com"))
    (should-not (markdown-plus--follow-anchor "other.md"))))

(ert-deftest markdown-plus-test-underline-fontification ()
  "`<u>' delimiters are hidden and the text carries the underline face."
  (markdown-plus-test--with "a <u>under</u> b\n"
    (markdown-plus-mode 1)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "<u>")
    (should (eq (get-text-property (match-beginning 0) 'invisible)
                'markdown-markup))
    (should (memq 'markdown-plus-underline-face
                  (ensure-list (get-text-property (point) 'face))))))

;;;; Emphasis editing

(ert-deftest markdown-plus-test-insert-underline-toggles ()
  "`markdown-plus-insert-underline' wraps a word and unwraps it again."
  (markdown-plus-test--with "hel|lo\n"
    (markdown-plus-mode 1)
    (markdown-plus-insert-underline)
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "<u>hello</u>\n"))
    (font-lock-ensure)
    (markdown-plus-insert-underline)
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "hello\n"))))

;;;; Org src blocks

(require 'org)

(defmacro markdown-plus-test--with-org (text &rest body)
  "Run BODY in an `org-mode' buffer holding TEXT, point where `|' was.
`markdown-mode-hook' carries `markdown-plus-mode' the way a real
configuration does, which is what makes Org's native src fontification
run markdown-plus inside its scratch buffer."
  (declare (indent 1) (debug t))
  `(let ((markdown-mode-hook '(markdown-plus-mode)))
     (with-temp-buffer
       (delay-mode-hooks (org-mode))
       (insert ,text)
       (goto-char (point-min))
       (when (search-forward "|" nil t)
         (delete-char -1))
       (markdown-plus-org-mode 1)
       (font-lock-ensure)
       ,@body)))

(defconst markdown-plus-test--org-block "\
* S

#+begin_src markdown
```python
print(1)
```

- **bold** x
#+end_src

plain org text
")

(ert-deftest markdown-plus-test-org-block-bounds ()
  "The block body is recognised; the fence lines and Org text are outside it."
  (markdown-plus-test--with-org markdown-plus-test--org-block
    (goto-char (point-min))
    (search-forward "print(1)")
    (should (markdown-plus-org--block-bounds))
    (goto-char (point-min))
    (search-forward "plain org")
    (should-not (markdown-plus-org--block-bounds))
    (goto-char (point-min))
    (search-forward "#+begin_src")
    (should-not (markdown-plus-org--block-bounds))))

(ert-deftest markdown-plus-test-org-block-other-language-ignored ()
  "A src block in another language is left alone."
  (markdown-plus-test--with-org
      "#+begin_src python\nprint(1)\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "print(1)")
    (should-not (markdown-plus-org--block-bounds))))

(ert-deftest markdown-plus-test-org-fence-rendered-without-this-mode ()
  "Fence icons reach Org through font-lock alone, with no reveal involved.
This is the property that lets the package cover Org without org-side code."
  (markdown-plus-test--with-org markdown-plus-test--org-block
    (goto-char (point-min))
    (search-forward "```python")
    (should (equal (get-text-property (match-beginning 0) 'display)
                   (markdown-plus--fence-display "python")))
    (should-not (invisible-p (match-beginning 0)))))

(ert-deftest markdown-plus-test-org-reveal-on-point ()
  "Point on the fence reveals it; leaving restores the icon."
  (markdown-plus-test--with-org markdown-plus-test--org-block
    (goto-char (point-min))
    (search-forward "```python")
    (goto-char (match-beginning 0))
    (markdown-plus-org--post-command)
    (should-not (get-text-property (point) 'display))
    ;; leave the block entirely
    (goto-char (point-max))
    (markdown-plus-org--post-command)
    (goto-char (point-min))
    (search-forward "```python")
    (should (equal (get-text-property (match-beginning 0) 'display)
                   (markdown-plus--fence-display "python")))))

(ert-deftest markdown-plus-test-org-reveal-is-element-granular ()
  "Reveal uses the same element bounds a Markdown buffer would."
  (markdown-plus-test--with-org markdown-plus-test--org-block
    (goto-char (point-min))
    (search-forward "**bold**")
    (goto-char (1- (point)))
    (markdown-plus-org--post-command)
    (should (equal markdown-plus-org--region
                   (save-excursion
                     (let ((b (markdown-plus--element-bounds)))
                       (cons (car b) (cdr b))))))
    (should-not (invisible-p (car markdown-plus-org--region)))))

(ert-deftest markdown-plus-test-org-no-reveal-outside-block ()
  "Org text outside a Markdown block never reveals, whatever it looks like."
  (markdown-plus-test--with-org
      "* S\n\nsome *org* emphasis here\n"
    (goto-char (point-min))
    (search-forward "*org*")
    (goto-char (1- (point)))
    (markdown-plus-org--post-command)
    (should-not markdown-plus-org--region)))

(ert-deftest markdown-plus-test-org-mode-off-restores ()
  "Turning the mode off puts back whatever was revealed."
  (markdown-plus-test--with-org markdown-plus-test--org-block
    (goto-char (point-min))
    (search-forward "```python")
    (goto-char (match-beginning 0))
    (markdown-plus-org--post-command)
    (should markdown-plus-org--region)
    (markdown-plus-org-mode -1)
    (should-not markdown-plus-org--region)
    (goto-char (point-min))
    (search-forward "```python")
    (should (equal (get-text-property (match-beginning 0) 'display)
                   (markdown-plus--fence-display "python")))))

(defun markdown-plus-test--type (string)
  "Type STRING into the current buffer the way a user would.
`self-insert-command' is what matters here: it inserts with inheritance, so
a character typed against hidden markup picks up its `invisible' property."
  (dolist (char (string-to-list string))
    (let ((last-command-event char))
      (self-insert-command 1))
    (markdown-plus-org--post-command)
    (font-lock-flush (line-beginning-position) (line-end-position))
    (font-lock-ensure (line-beginning-position) (line-end-position))))

(defun markdown-plus-test--visible (beg end)
  "Return the text of BEG..END that is actually on screen."
  (let ((out "") (pos beg))
    (while (< pos end)
      (unless (invisible-p pos)
        (setq out (concat out (char-to-string (char-after pos)))))
      (setq pos (1+ pos)))
    out))

(ert-deftest markdown-plus-test-org-typing-after-hidden-markup ()
  "Text typed right after hidden markup stays visible.
Only the markup itself -- the two backticks -- may disappear.  Without the
`after-change-functions' fix the inherited `invisible' hides everything
typed from there on, and Org never clears it."
  (markdown-plus-test--with-org
      "* S\n\n#+begin_src markdown\n2. path `~/wiki`\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "`~/wiki`")
    (markdown-plus-test--type " and more")
    (let ((beg (line-beginning-position))
          (end (line-end-position)))
      (should (equal (markdown-plus-test--visible beg end)
                     "2. path ~/wiki and more")))))

(ert-deftest markdown-plus-test-org-typed-newlines-survive ()
  "Newlines typed after hidden markup do not swallow the blank lines."
  (markdown-plus-test--with-org
      "* S\n\n#+begin_src markdown\n2. path `~/wiki`\n#+end_src\n"
    (goto-char (point-min))
    (search-forward "`~/wiki`")
    (markdown-plus-test--type "\n\n\nhello")
    (let* ((beg (progn (goto-char (point-min))
                       (search-forward "#+begin_src markdown\n")
                       (point)))
           (end (progn (search-forward "#+end_src") (line-beginning-position)))
           (raw (buffer-substring-no-properties beg end)))
      (should (equal (markdown-plus-test--visible beg end)
                     (replace-regexp-in-string "`" "" raw))))))

(ert-deftest markdown-plus-test-org-after-change-stays-in-block ()
  "The `invisible' strip is confined to Markdown src blocks.
Org hides its own folded text with `invisible', so clearing the property
outside a block would unfold the buffer."
  (markdown-plus-test--with-org
      "* S\n\nplain org text\n\n#+begin_src markdown\nin block\n#+end_src\n"
    ;; Outside the block: left alone.
    (goto-char (point-min))
    (search-forward "plain")
    (let ((beg (match-beginning 0)) (end (match-end 0)))
      (put-text-property beg end 'invisible 'org-fold-outline)
      (markdown-plus-org--after-change beg end 0)
      (should (eq (get-text-property beg 'invisible) 'org-fold-outline)))
    ;; Inside it: stripped.
    (goto-char (point-min))
    (search-forward "in block")
    (let ((beg (match-beginning 0)) (end (match-end 0)))
      (put-text-property beg end 'invisible 'markdown-markup)
      (markdown-plus-org--after-change beg end 0)
      (should-not (get-text-property beg 'invisible)))))

(provide 'markdown-plus-test)
;;; markdown-plus-test.el ends here
