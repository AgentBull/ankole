import { GardState } from '../state'
import { Command, Menu, toggleMark } from '../command'
import { Strong, Emphasis, Code, Underline, Strikethrough, Superscript, Subscript } from '../types'
import { phrases } from '../phrases'
import { KeyBinding } from '../editor'

/**
 * Extension that enables strong emphasis support. Includes the
 * {@link Strong schema element}, {@link strong.keyBinding key
 * binding}, and {@link strong.button menu button}.
 */
export function strong(): GardState.Extension {
  return [GardState.schemaElement.of(Strong), strong.button, strong.keyBinding]
}

export namespace strong {
  /** Binds `Mod-b` to toggle strong emphasis. */
  export const keyBinding = KeyBinding.of({
    key: 'Mod-b',
    run: Command.bind(toggleMark, Strong)
  })

  /** A menu button that toggles strong emphasis. */
  export const button = Menu.Button.toggleMark({
    mark: Strong,
    parent: Menu.Group.inline,
    rank: 10,
    description: phrases.ref('toggle_strong'),
    label: {
      icon: 'M51 81c13 0 21-7 21-18 0-8-6-14-14-15v0a14 14 0 0 0 12-13c0-9-7-15-19-15H24V81zM37 29h11c6 0 10 3 10 8 0 5-4 8-11 8H37V29zm0 42V54h11c8 0 12 3 12 9 0 6-4 9-11 9H37z'
    }
  })
}

/**
 * Returns extensions for the emphasis mark—the {@link Emphasis
 * schema element}, a {@link emphasis.keyBinding key binding}, and
 * a {@link emphasis.button menu button}.
 */
export function emphasis(): GardState.Extension {
  return [GardState.schemaElement.of(Emphasis), emphasis.button, emphasis.keyBinding]
}

export namespace emphasis {
  /** Binds `Mod-i` to toggle emphasis. */
  export const keyBinding = KeyBinding.of({
    key: 'Mod-i',
    run: Command.bind(toggleMark, Emphasis)
  })

  /** Menu button that toggles emphasis. */
  export const button = Menu.Button.toggleMark({
    mark: Emphasis,
    parent: Menu.Group.inline,
    rank: 15,
    description: phrases.ref('toggle_em'),
    label: {
      icon: 'M50 73 60 28c1-4 2-4 8-5l1-3H45l-1 3c7 1 7 1 6 5L41 73c-1 4-2 4-8 5l-1 3h24l1-3c-7-1-7-1-7-5z'
    }
  })
}

/**
 * Returns extensions that enable the code font mark. Includes the
 * {@link Code schema element}, a {@link code.keyBinding key
 * binding}, and a {@link code.button menu button}.
 */
export function code(): GardState.Extension {
  return [GardState.schemaElement.of(Code), code.button, code.keyBinding]
}

export namespace code {
  /** Binds `` Mod-` `` to toggle the code font mark. */
  export const keyBinding = KeyBinding.of({
    key: 'Mod-`',
    run: Command.bind(toggleMark, Code)
  })

  /** Menu button for toggling code font. */
  export const button = Menu.Button.toggleMark({
    mark: Code,
    parent: Menu.Group.inline,
    rank: 30,
    description: phrases.ref('toggle_code'),
    label: {
      icon: 'M37 30a2 2 0 1 0-4-4l-22 22a3 3 0 0 0 0 4l22 22a2 2 0 0 0 4-4L17 50zm27 0a2 2 0 0 1 4-4l22 22a3 3 0 0 1 0 4l-22 22a2 2 0 0 1-4-4L83 50z'
    }
  })
}

/**
 * Returns an extension bundle for the underline mark, including the
 * {@link Underline schema element}, a {@link underline.keyBinding
 * key bindding}, and a {@link underline.button menu button}.
 */
export function underline(): GardState.Extension {
  return [GardState.schemaElement.of(Underline), underline.button, underline.keyBinding]
}

export namespace underline {
  /** Binds `Mod-u` to toggle the underline mark. */
  export const keyBinding = KeyBinding.of({
    key: 'Mod-u',
    run: Command.bind(toggleMark, Underline)
  })

  /** Menu button for toggling underline. */
  export const button = Menu.Button.toggleMark({
    mark: Underline,
    parent: Menu.Group.inline,
    rank: 60,
    description: phrases.ref('toggle_underline'),
    label: {
      icon: 'M33 20h-8V60c0 13 9 23 24 23s24-9 24-23V20h-8v40c0 9-6 16-17 16s-15-7-15-16M78 94h-56v-6h56z'
    }
  })
}

/**
 * Extensions to support a strikethrough mark—the {@link
 * Strikethrough schema element}, a {@link strikethrough.keyBinding
 * key binding}, and a {@link strikethrough.button menu button}.
 */
export function strikethrough(): GardState.Extension {
  return [GardState.schemaElement.of(Strikethrough), strikethrough.button, strikethrough.keyBinding]
}

export namespace strikethrough {
  /** Binds `Mod-/` to toggle strikethrough. */
  export const keyBinding = KeyBinding.of({
    key: 'Mod-/',
    run: Command.bind(toggleMark, Strikethrough)
  })

  /** Menu button that toggles the strikethrough mark. */
  export const button = Menu.Button.toggleMark({
    mark: Strikethrough,
    parent: Menu.Group.inline,
    rank: 65,
    description: phrases.ref('toggle_strikethrough'),
    label: {
      icon: 'M38 37c0 2 0 3 2 5H31a17 17 0 0 1-1-5c0-10 9-16 21-16 12 0 20 7 20 17h-7c-1-6-6-10-13-10-7 0-13 4-13 10zm13 44c-13 0-21-7-22-17h7c1 6 7 10 15 10c8 0 14-4 14-10c0-5-3-8-11-10L48 53h20c3 3 4 6 4 10 0 11-9 18-22 18M11 50v-6h75v6H11'
    }
  })
}

/**
 * Add support for a superscript mark. Includes the {@link
 * Superscript schema element}, a {@link superscript.keyBinding
 * key binding}, and a {@link superscript.button menu button}.
 */
export function superscript(): GardState.Extension {
  return [GardState.schemaElement.of(Superscript), superscript.button, superscript.keyBinding]
}

export namespace superscript {
  /** Binds `Mod-.` to toggle superscript. */
  export const keyBinding = KeyBinding.of({
    key: 'Mod-.',
    run: Command.bind(toggleMark, Superscript)
  })

  /** Menu button for toggling superscript. */
  export const button = Menu.Button.toggleMark({
    mark: Superscript,
    parent: Menu.Group.inline,
    rank: 70,
    description: phrases.ref('toggle_super'),
    label: {
      icon: 'm27 78 6-18H55l6 18H69L48 19H40L19 78zm17-50 9 26h-18l9-26zm32-11v0c4 -10 12 0 5 6l-11 11V38h22v-6h-12v0l6-6c3-3 5-5 5-10 0-5-4-9-11-9C72 6 69 11 69 16v0z'
    }
  })
}

/**
 * Support for a subscript mark. Includes the {@link Subscript
 * schema element}, a {@link subscript.keyBinding key binding}, and
 * a {@link subscript.button menu button}.
 */
export function subscript(): GardState.Extension {
  return [GardState.schemaElement.of(Subscript), subscript.button, subscript.keyBinding]
}

export namespace subscript {
  /** Binds `Mod-,` to toggle the subscript mark. */
  export const keyBinding = KeyBinding.of({
    key: 'Mod-,',
    run: Command.bind(toggleMark, Subscript)
  })

  /** Menu button for toggling subscript. */
  export const button = Menu.Button.toggleMark({
    mark: Subscript,
    parent: Menu.Group.inline,
    rank: 75,
    description: phrases.ref('toggle_sub'),
    label: {
      icon: 'm21 78 6-18H49l6 18H63L41 19H34L13 78zm17-50 9 26h-18l9-26zm38 45v0c4 -10 12 0 5 6l-11 11V94h22v-6h-12v0l6-6c3-3 5-5 5-10 0-5-4-9-11-9-8 0-11 5-11 10v0z'
    }
  })
}
