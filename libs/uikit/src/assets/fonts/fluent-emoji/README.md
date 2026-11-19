# Fluent Emoji Color

The `FluentEmojiColor*.woff2` files and `FluentEmojiColor.css` come from
[tetunori/fluent-emoji-webfont](https://github.com/tetunori/fluent-emoji-webfont)
version 0.8.5 (commit `b7fc5ad4ceb3c7d665087040073d4b64490af96f`), which builds
Microsoft's MIT-licensed [Fluent Emoji](https://github.com/microsoft/fluentui-emoji)
into a Unicode-range-split webfont. The stylesheet URL was rewritten to load the
local font files.

UI Kit applies the family through `.ankole-fluent-emoji`. Applications that render
emoji import `@ankole/uikit/emoji.css`; the shared UI Kit stylesheet does not load
the font. Pod imports it for Page icons and the emoji picker.
