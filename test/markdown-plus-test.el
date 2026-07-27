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
                     "mouse-1, RET: play a/VID_01.mp4")))))

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

(provide 'markdown-plus-test)
;;; markdown-plus-test.el ends here
