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
    (should (equal (get-text-property (match-beginning 0) 'display) "ℹ️ Note"))
    (search-forward "[!BOGUS]")
    (should-not (get-text-property (match-beginning 0) 'display))))

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
