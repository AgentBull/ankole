import {
  Command,
  enter,
  deleteUnit,
  deleteWord,
  deleteToLineEnd,
  killToLineEnd,
  yankKilled,
  insertLineBreak,
  transposeChars,
  moveByUnit,
  moveToLineSide,
  moveToTextblockSide,
  moveToDocSide,
  moveByWord,
  moveByLine,
  moveByPage,
  selectAll,
  undo,
  redo
} from '../command'
import { GardState } from '../state'
import { PhraseSet, phrases } from '../phrases'
import { type Wordgard } from './editor'
import browser from './browser'

/**
 * Key bindings associate keys with functions that should be run when
 * a matching keyboard event happens.
 *
 * A key binding can either specify a specific {@link
 * KeyBinding.Spec.char character} to match on, which will be
 * compared against the actual character produced by a key event, or
 * describe a {@link KeyBinding.Spec.key key combination}.
 *
 * Bindings for a given key event are evaluated in order of
 * precedence, with each getting a chance to handle the event,
 * stopping when the first handler returns true.
 *
 * Key combinations are described by strings like
 * `"Shift-Ctrl-Enter"`—a key identifier prefixed with zero or more
 * modifiers. Key identifiers are based on the strings that can
 * appear in
 * [`KeyEvent.key`](https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/key).
 * Use lowercase letters to refer to letter keys. You can use
 * `"Space"` as an alias for the `" "` name.
 *
 * Modifiers can be given in any order. `Shift-`, `Alt-`, `Ctrl-` and
 * `Cmd-` (or `Meta-`) are recognized.
 *
 * You can use `Mod-` as a shorthand for `Cmd-` on Mac and `Ctrl-` on
 * other platforms. So `Mod-b` is `Ctrl-b` on Linux but `Cmd-b` on
 * macOS.
 *
 * Unlike character bindings, key combination bindings should refer
 * to the unmodified base key that is being pressed, not the
 * character produced by combining that key with Shift or AltGraph.
 * Keyboard mappings that rearrange the positions of Latin characters
 * _are_ taken into account for this (the mapped position is used),
 * but the library tries to 'see through' keyboard mappings that
 * assign non-Latin characters to keys (so that both the Latin and
 * the non-Latin name can be used).
 */
export class KeyBinding {
  /**
   * Bindings count as extensions and can be included in an editor
   * configuration.
   */
  extension: GardState.Extension

  private constructor(
    /** The configuration object used to define this binding. */
    readonly spec: KeyBinding.Spec
  ) {
    this.extension = KeyBinding.source.of(this)
  }

  /** Define a binding. */
  static of(spec: KeyBinding.Spec) {
    return new KeyBinding(spec)
  }
}

export namespace KeyBinding {
  /** A description of a key binding. */
  export interface Spec {
    /** A textual character that this binding should trigger for. */
    char?: string
    /**
     * A key combination to use for this binding. If the
     * platform-specific property (`mac`, `win`, or `linux`) for the
     * current platform is used as well in the binding, that one takes
     * precedence. If `key` isn't defined and the platform-specific
     * binding isn't either, a binding is ignored.
     */
    key?: string
    /** Key to use specifically on macOS. */
    mac?: string
    /** Key to use specifically on Windows. */
    win?: string
    /** Key to use specifically on Linux. */
    linux?: string
    /** The command to execute when this binding is triggered. */
    run: Command.Bound | Command
    /**
     * When given, this defines a second binding, using the (possibly
     * platform-specific) key name, prefixed with `Shift-`, to activate
     * this command.
     */
    shift?: Command.Bound | Command
    /**
     * When this property is present, the function is called for every
     * key, and may return true to indicate the key was handled.
     */
    any?: (wg: Wordgard, event: KeyboardEvent) => boolean
    /**
     * By default, all keys events for which a handler exists have
     * their `preventDefault` called, even if no handler returns
     * true. You can set this to true to disable that behavior.
     */
    allowDefault?: boolean
    /**
     * A textual description of what this key does. Will be used by a
     * key-binding list.
     */
    description?: PhraseSet.Ref | string
    /**
     * A textual description of what the shifted variant of this key
     * does.
     */
    shiftDescription?: PhraseSet.Ref | string
    /**
     * The group under which the description of this key should be
     * organized in the list of bindings.
     */
    group?: Group
  }

  /** @internal */
  export function handle(wg: Wordgard, event: KeyboardEvent) {
    const map = getKeymap(wg.state)
    return runHandlers(map, event, wg)
  }

  /**
   * Facet used for registering key bindings. Extension precedence
   * determines the order in which bindings that match the same key
   * are called. When a handler has returned `true` for a given key,
   * no further handlers are called.
   */
  export const source = GardState.Facet.define<KeyBinding>()

  /**
   * By default, the {@link KeyBinding.defaultKeymap default keymap}
   * is automatically active. You can configure this to false if you
   * want to completely replace it.
   */
  export const useDefaultKeymap = GardState.Facet.define<boolean, boolean>({
    combine: input => (input.length ? input[0]! : true)
  })

  /**
   * Key binding groups are used to {@link KeyBinding.Spec.group
   * organize} key bindings in a user-presented list of bindings.
   */
  export class Group {
    private constructor(
      /** The description given for this group. */
      readonly description: PhraseSet.Ref | string,
      /** A sorting rank. */
      readonly rank: number
    ) {}

    /** Define a key binding group. */
    static define(spec: { description: PhraseSet.Ref | string; rank?: number }) {
      return new Group(spec.description, spec.rank || 1000)
    }

    static Inline = new Group(phrases.ref('group_inline'), 20)
    static Block = new Group(phrases.ref('group_block'), 30)
    static History = new Group(phrases.ref('group_history'), 70)
  }

  /**
   * Look for a key associated with the given description in the
   * state's key bindings, and if found, return its key name as a
   * string.
   */
  export function lookupByDescription(state: GardState, desc: string | PhraseSet.Ref) {
    return getDescMap(state).get(desc) || null
  }

  /**
   * The editor's set of default key bindings. Binds the following
   * keys. Most cursor motion bindings include a `Shift-` variant
   * that passes the `extend` flag to the command. Enabled by default
   * unless {@link KeyBinding.useDefaultKeymap} is disabled.
   *
   *  - `Enter` to {@link command.enter}
   *  - `Shift-Enter` to {@link command.insertLineBreak}
   *  - `Backspace` to {@link command.deleteUnit} (`"backward"`)
   *  - `Delete` to {@link command.deleteUnit} (`"forward"`)
   *  - `Ctrl-Backspace` (`Alt-Backspace` on MacOS) to {@link command.deleteWord} (`"backward"`)
   *  - `Ctrl-Delete` (`Alt-Delete` on MacOS) to {@link command.deleteWord} (`"forward"`)
   *  - `Cmd-Backspace` (MacOS) to {@link command.deleteToLineEnd} (`"backward"`)
   *  - `Cmd-Delete` (MacOS) to {@link command.deleteToLineEnd} (`"forward"`)
   *  - `ArrowLeft` to {@link command.moveByUnit} (`{dir: "left"}`)
   *  - `ArrowRight` to {@link command.moveByUnit} (`{dir: "right"}`)
   *  - `ArrowUp` to {@link command.moveByLine} (`{dir: "up"}`)
   *  - `ArrowDown` to {@link command.moveByLine} (`{dir: "down"}`)
   *  - `Ctrl-AllowLeft` (`Cmd-ArrowLeft` on MacOS) to {@link command.moveByWord} (`{dir: "left"}`)
   *  - `Ctrl-AllowRight` (`Cmd-ArrowRight` on MacOS) to {@link command.moveByWord} (`{dir: "right"}`)
   *  - `Cmd-ArrowUp` (MacOS) to {@link command.moveToDocSide} (`{side: "start"}`)
   *  - `Cmd-ArrowDown` (MacOS) to {@link command.moveToDocSide} (`{side: "end"}`)
   *  - `Ctrl-ArrowUp` (MacOS) to {@link command.moveByPage} (`{dir: "up"}`)
   *  - `Ctrl-ArrowDown` (MacOS) to {@link command.moveByPage} (`{dir: "down"}`)
   *  - `PageUp` to {@link command.moveByPage} (`{dir: "up"}`)
   *  - `PageDown` to {@link command.moveByPage} (`{dir: "down"}`)
   *  - `Home` to {@link command.moveToLineSide} (`{dir: "backward"}`)
   *  - `End` to {@link command.moveToLineSide} (`{dir: "forward"}`)
   *  - `Ctrl-Home` (`Cmd-Home` on MacOS) to {@link command.moveToDocSide} (`{side: "start"}`)
   *  - `Ctrl-End` (`Cmd-End` on MacOS) to {@link command.moveToDocSide} (`{side: "end"}`)
   *  - `Ctrl-a` (`Cmd-a` on MacOS) to {@link command.selectAll}
   *  - `Ctrl-z` (`Cmd-z` on MacOS) to {@link command.undo}
   *  - `Ctrl-y` (`Shift-Cmd-z` on MacOS) to {@link command.redo}
   *
   * On MacOS, the following Emacs-style bindings are available:
   *
   *  - `Ctrl-b` to {@link command.moveByUnit} (`{dir: "backward"}`)
   *  - `Ctrl-f` to {@link command.moveByUnit} (`{dir: "forward"}`)
   *  - `Ctrl-p` to {@link command.moveByLine} (`{dir: "up"}`)
   *  - `Ctrl-n` to {@link command.moveByLine} (`{dir: "down"}`)
   *  - `Ctrl-a` to {@link command.moveToTextblockSide} (`{dir: "backward"}`)
   *  - `Ctrl-e` to {@link command.moveToTextblockSide} (`{dir: "forward"}`)
   *  - `Ctrl-d` to {@link command.deleteUnit} (`"forward"`)
   *  - `Ctrl-h` to {@link command.deleteUnit} (`"backward"`)
   *  - `Ctrl-k` to {@link command.killToLineEnd}
   *  - `Ctrl-Alt-h` to {@link command.deleteWord} (`"backward"`)
   *  - `Ctrl-o` to {@link command.insertLineBreak}
   *  - `Ctrl-t` to {@link command.transposeChars}
   *  - `Ctrl-v` to {@link command.moveByPage} (`{dir: "down"}`)
   *  - `Ctrl-y` to {@link command.yankKilled}
   */
  export const defaultKeymap: readonly KeyBinding[] = (
    [
      { key: 'Enter', run: enter },
      { key: 'Shift-Enter', run: insertLineBreak, description: phrases.ref('insert_break'), group: Group.Inline },
      { key: 'Backspace', run: Command.bind(deleteUnit, 'backward') },
      { key: 'Delete', run: Command.bind(deleteUnit, 'forward') },
      { key: 'Ctrl-Backspace', mac: 'Alt-Backspace', run: Command.bind(deleteWord, 'backward') },
      { key: 'Ctrl-Delete', mac: 'Alt-Delete', run: Command.bind(deleteWord, 'forward') },
      { mac: 'Cmd-Backspace', run: Command.bind(deleteToLineEnd, 'backward') },
      { mac: 'Cmd-Delete', run: Command.bind(deleteToLineEnd, 'forward') },
      {
        key: 'ArrowLeft',
        run: Command.bind(moveByUnit, { dir: 'left' }),
        shift: Command.bind(moveByUnit, { dir: 'left', extend: true })
      },
      {
        key: 'ArrowRight',
        run: Command.bind(moveByUnit, { dir: 'right' }),
        shift: Command.bind(moveByUnit, { dir: 'right', extend: true })
      },
      {
        key: 'ArrowDown',
        run: Command.bind(moveByLine, { dir: 'down' }),
        shift: Command.bind(moveByLine, { dir: 'down', extend: true })
      },
      {
        key: 'ArrowUp',
        run: Command.bind(moveByLine, { dir: 'up' }),
        shift: Command.bind(moveByLine, { dir: 'up', extend: true })
      },
      {
        key: 'Mod-ArrowLeft',
        run: Command.bind(moveByWord, { dir: 'left' }),
        shift: Command.bind(moveByWord, { dir: 'left', extend: true })
      },
      {
        key: 'Mod-ArrowRight',
        run: Command.bind(moveByWord, { dir: 'right' }),
        shift: Command.bind(moveByWord, { dir: 'right', extend: true })
      },
      {
        mac: 'Cmd-ArrowLeft',
        run: Command.bind(moveToLineSide, { dir: 'left' }),
        shift: Command.bind(moveToLineSide, { dir: 'left', extend: true })
      },
      {
        mac: 'Cmd-ArrowRight',
        run: Command.bind(moveToLineSide, { dir: 'right' }),
        shift: Command.bind(moveToLineSide, { dir: 'right', extend: true })
      },
      {
        mac: 'Cmd-ArrowUp',
        run: Command.bind(moveToDocSide, { side: 'start' }),
        shift: Command.bind(moveToDocSide, { side: 'start', extend: true })
      },
      {
        mac: 'Cmd-ArrowDown',
        run: Command.bind(moveToDocSide, { side: 'end' }),
        shift: Command.bind(moveToDocSide, { side: 'end', extend: true })
      },
      {
        mac: 'Ctrl-ArrowUp',
        run: Command.bind(moveByPage, { dir: 'up' }),
        shift: Command.bind(moveByPage, { dir: 'up', extend: true })
      },
      {
        mac: 'Ctrl-ArrowDown',
        run: Command.bind(moveByPage, { dir: 'down' }),
        shift: Command.bind(moveByPage, { dir: 'down', extend: true })
      },
      {
        key: 'PageUp',
        run: Command.bind(moveByPage, { dir: 'up' }),
        shift: Command.bind(moveByPage, { dir: 'up', extend: true })
      },
      {
        key: 'PageDown',
        run: Command.bind(moveByPage, { dir: 'down' }),
        shift: Command.bind(moveByPage, { dir: 'down', extend: true })
      },
      {
        key: 'Home',
        run: Command.bind(moveToLineSide, { dir: 'backward' }),
        shift: Command.bind(moveToLineSide, { dir: 'backward', extend: true })
      },
      {
        key: 'End',
        run: Command.bind(moveToLineSide, { dir: 'forward' }),
        shift: Command.bind(moveToLineSide, { dir: 'forward', extend: true })
      },
      {
        key: 'Mod-Home',
        run: Command.bind(moveToDocSide, { side: 'start' }),
        shift: Command.bind(moveToDocSide, { side: 'start', extend: true })
      },
      {
        key: 'Mod-End',
        run: Command.bind(moveToDocSide, { side: 'end' }),
        shift: Command.bind(moveToDocSide, { side: 'end', extend: true })
      },
      { key: 'Mod-a', run: selectAll },
      { key: 'Mod-z', run: undo, description: phrases.ref('undo'), group: Group.History },
      { key: 'Mod-y', mac: 'Mod-Shift-z', run: redo, description: phrases.ref('redo'), group: Group.History },
      { linux: 'Ctrl-Shift-z', run: redo, description: phrases.ref('redo'), group: Group.History },
      // MacOS Emacs-ish bindings
      {
        mac: 'Ctrl-b',
        run: Command.bind(moveByUnit, { dir: 'backward' }),
        shift: Command.bind(moveByUnit, { dir: 'backward', extend: true })
      },
      {
        mac: 'Ctrl-f',
        run: Command.bind(moveByUnit, { dir: 'forward' }),
        shift: Command.bind(moveByUnit, { dir: 'forward', extend: true })
      },
      {
        mac: 'Ctrl-p',
        run: Command.bind(moveByLine, { dir: 'up' }),
        shift: Command.bind(moveByLine, { dir: 'up', extend: true })
      },
      {
        mac: 'Ctrl-n',
        run: Command.bind(moveByLine, { dir: 'down' }),
        shift: Command.bind(moveByLine, { dir: 'down', extend: true })
      },
      {
        mac: 'Ctrl-a',
        run: Command.bind(moveToTextblockSide, { dir: 'backward' }),
        shift: Command.bind(moveToTextblockSide, { dir: 'backward', extend: true })
      },
      {
        mac: 'Ctrl-e',
        run: Command.bind(moveToTextblockSide, { dir: 'forward' }),
        shift: Command.bind(moveToTextblockSide, { dir: 'forward', extend: true })
      },
      { mac: 'Ctrl-d', run: Command.bind(deleteUnit, 'forward') },
      { mac: 'Ctrl-h', run: Command.bind(deleteUnit, 'backward') },
      { mac: 'Ctrl-k', run: killToLineEnd },
      { mac: 'Ctrl-y', run: yankKilled },
      { mac: 'Ctrl-Alt-h', run: Command.bind(deleteWord, 'backward') },
      { mac: 'Ctrl-o', run: insertLineBreak },
      { mac: 'Ctrl-t', run: transposeChars },
      { mac: 'Ctrl-v', run: Command.bind(moveByPage, { dir: 'down' }) }
    ] as KeyBinding.Spec[]
  ).map(KeyBinding.of)
}

type PlatformName = 'mac' | 'win' | 'linux' | 'key'

const currentPlatform: PlatformName = browser.mac ? 'mac' : browser.windows ? 'win' : browser.linux ? 'linux' : 'key'

function normalizeKeyName(name: string, platform: PlatformName): string {
  const parts = name.split(/-(?!$)/)
  let result = parts[parts.length - 1]!
  if (result == 'Space') result = ' '
  else if (/^[A-Z]$/.test(result)) result = result.toLowerCase()
  let alt, ctrl, shift, meta
  for (let i = 0; i < parts.length - 1; ++i) {
    const mod = parts[i]!
    if (mod == 'Cmd' || mod == 'Meta') meta = true
    else if (mod == 'Alt') alt = true
    else if (mod == 'Ctrl') ctrl = true
    else if (mod == 'Shift') shift = true
    else if (mod == 'Mod') {
      if (platform == 'mac') meta = true
      else ctrl = true
    } else throw new Error(`Unrecognized modifier name: ${mod}`)
  }
  if (alt) result = `Alt-${result}`
  if (ctrl) result = `Ctrl-${result}`
  if (meta) result = `${platform == 'mac' ? 'Meta' : 'Cmd'}-${result}`
  if (shift) result = `Shift-${result}`
  return result
}

function modifiers(name: string, event: KeyboardEvent, platform: PlatformName) {
  if (event.altKey) name = `Alt-${name}`
  if (event.ctrlKey) name = `Ctrl-${name}`
  if (event.metaKey) name = `${platform == 'mac' ? 'Meta' : 'Cmd'}-${name}`
  if (event.shiftKey) name = `Shift-${name}`
  return name
}

enum BindingFlag {
  Char = 1,
  Key = 2,
  Any = 4,
  AllowDefault = 8
}

class NormalizedBinding {
  constructor(
    readonly flags: BindingFlag,
    readonly name: string,
    readonly command: (wg: Wordgard, event: KeyboardEvent) => boolean
  ) {}
}

type Keymap = NormalizedBinding[]

const keymapCache = new WeakMap<readonly KeyBinding[], { map: Keymap; deflt: boolean }>()

function getKeymap(state: GardState) {
  const bindings = state.facet(KeyBinding.source)
  const addDefault = state.facet(KeyBinding.useDefaultKeymap)
  let found = keymapCache.get(bindings)
  if (!found || found.deflt != addDefault) {
    found = {
      map: buildKeymap(addDefault ? bindings.concat(KeyBinding.defaultKeymap) : bindings, currentPlatform),
      deflt: addDefault
    }
    keymapCache.set(bindings, found)
  }
  return found.map
}

const lookupCache = new WeakMap<readonly KeyBinding[], Map<string | PhraseSet.Ref, string>>()

function getDescMap(state: GardState) {
  const bindings = state.facet(KeyBinding.source)
  let map = lookupCache.get(bindings)
  if (!map) {
    lookupCache.set(bindings, (map = new Map()))
    for (const binding of bindings.concat(state.facet(KeyBinding.useDefaultKeymap) ? KeyBinding.defaultKeymap : [])) {
      const { description, shiftDescription } = binding.spec
      if (description || shiftDescription) {
        const name = binding.spec[currentPlatform] || binding.spec.key
        if (name && description) map.set(description, normalizeKeyName(name, currentPlatform))
        if (name && shiftDescription) map.set(shiftDescription, `Shift-${normalizeKeyName(name, currentPlatform)}`)
      }
    }
  }
  return map
}

function bind(run: Command.Bound | Command): (wg: Wordgard) => boolean {
  return (wg: Wordgard) => Command.dispatch(wg, run)
}

function buildKeymap(bindings: readonly KeyBinding[], platform: PlatformName): Keymap {
  const map: Keymap = []

  for (const { spec: b } of bindings) {
    const baseFlags = b.allowDefault ? BindingFlag.AllowDefault : 0
    const key = b[platform] || b.key
    if (b.char) {
      if (key) throw new Error('A key binding may not provide both a char and a key field')
      if (b.shift) throw new Error('Shift-modified bindings are not supported for char bindings')
      map.push(new NormalizedBinding(baseFlags | BindingFlag.Char, b.char, bind(b.run)))
    }
    if (key) {
      map.push(new NormalizedBinding(baseFlags | BindingFlag.Key, normalizeKeyName(key, platform), bind(b.run)))
    }
    if (key && b.shift) {
      map.push(
        new NormalizedBinding(baseFlags | BindingFlag.Key, normalizeKeyName(`Shift-${key}`, platform), bind(b.shift))
      )
    }
    if (b.any) map.push(new NormalizedBinding(BindingFlag.Any, '', b.any))
  }
  return map
}

function runHandlers(map: Keymap, event: KeyboardEvent, wg: Wordgard): boolean {
  const key = event.key,
    charCode = key.codePointAt(0)!
  const altGr = event.getModifierState('AltGraph'),
    fromCode = charKeyCodes[event.keyCode]
  const isChar = codePointSize(charCode) == key.length
  const char = isChar ? String.fromCodePoint(charCode) : null
  const base = modifiers(key, event, currentPlatform)
  // If the key used (not the physical key, but the remapped base key)
  // doesn't match the character put in event.key (due to remapping in
  // an international keyboard, or shift status), match against that
  // as well.
  const fallback = isChar && !altGr && fromCode && fromCode != base ? modifiers(fromCode, event, currentPlatform) : null

  let handled = false,
    didMatch = false,
    allowDefault = false
  for (const binding of map) {
    const matched =
      (binding.flags & BindingFlag.Char && (altGr || (!event.ctrlKey && !event.metaKey)) && binding.name == char) ||
      (binding.flags & BindingFlag.Key && (binding.name == base || binding.name == fallback)) ||
      binding.flags & BindingFlag.Any
    if (matched) {
      didMatch = true
      if (!handled && binding.command(wg, event)) {
        handled = true
      } else if (binding.flags & BindingFlag.AllowDefault) {
        allowDefault = true
      }
    }
  }
  if (didMatch && !allowDefault) event.preventDefault()
  return handled
}

function codePointSize(code: number): 1 | 2 {
  return code < 0x10000 ? 1 : 2
}

function buildCharKeyCodes() {
  const result: Record<number, string> = {
    32: ' ',
    59: ';',
    61: '=',
    106: '*',
    107: '+',
    108: ',',
    109: '-',
    110: '.',
    111: '/',
    173: '-',
    186: ';',
    187: '=',
    188: ',',
    189: '-',
    190: '.',
    191: '/',
    192: '`',
    219: '[',
    220: '\\',
    221: ']',
    222: "'"
  }
  for (let i = 0; i < 10; i++) result[48 + i] = String(i) // Digits
  for (let i = 1; i <= 24; i++) result[i + 111] = `F${i}` // Function keys
  for (let i = 65; i <= 90; i++) result[i] = String.fromCharCode(i + 32) // Letters
  return result
}

const charKeyCodes = buildCharKeyCodes()
