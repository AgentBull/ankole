// This module defines an editor component for use in the browser, on
// top of the editing model defined in the other modules. It _can_ be
// loaded outside the browser, but won't do anything useful there.

// ### Editor Component

// The {@link Wordgard} class is responsible for displaying an editor
// interface and the document inside of it. It captures basic user
// events, such as typing and pointer clicks, and converts them into
// editing actions.

export { Wordgard } from './editor'

// ### Key Bindings

// Functionality used for binding keys to editing commands.

export { KeyBinding } from './keymap'

// ### Decoration

// Decorations provide a way to influence the way the document is
// displayed without changing the document itself, via editor
// extensions. They are useful for showing out-of-band information or
// editing controls directly in the editable content.

export { Decoration } from './decoration'
