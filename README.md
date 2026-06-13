# markdown-plus

Org-mode-like WYSIWYG editing for Markdown, layered on top of
[markdown-mode](https://github.com/jrblevin/markdown-mode).

## Features

- **org-appear-style reveal** — markup is hidden and rendered; the raw
  source of the element at point is revealed and re-hidden as point
  moves. Covers emphasis (`**bold**`, `*italic*`, `_underline_`),
  inline code (`` `code` ``), strikethrough (`~~del~~`),
  subscript/superscript (`~x~` / `^x^`), ATX headings (`#`), links
  (`[text](url)`) and images (`![](url)`).
- **Code blocks always verbatim** — fenced blocks (```` ```lang ````)
  keep their fence lines visible and get a distinct background.
- **Inline image preview** — local and remote images; remote images are
  downloaded asynchronously and shown when ready.
- **Table auto-alignment** — GFM tables are aligned when you leave them.

## Requirements

- Emacs 27.1+
- `markdown-mode` 2.6+

## Installation

Put `markdown-plus.el` on your `load-path`, then:

```elisp
(require 'markdown-plus)
(add-hook 'markdown-mode-hook #'markdown-plus-mode)
```

Or enable it on demand with `M-x markdown-plus-mode` in a Markdown buffer.

## Keybindings

| Key         | Command                     |
|-------------|-----------------------------|
| `C-c C-x C-v` | `markdown-plus-show-images` |
| `C-c C-x C-r` | `markdown-plus-hide-images` |

## Customization

`M-x customize-group RET markdown-plus RET`:

- `markdown-plus-prettify-faces` — enlarge heading faces and shade code
  blocks (default `t`).
- `markdown-plus-auto-preview-images` — render image previews on enable
  (default `t`).
- `markdown-plus-max-image-size` — `(MAX-WIDTH . MAX-HEIGHT)` in pixels.
- `markdown-plus-image-cache-dir` — where remote images are cached.

## License

GPL-3.0-or-later.
