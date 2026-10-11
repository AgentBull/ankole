import { Transaction, GardState } from '../state'
import { phrases } from '../phrases'
import { Panel } from './panel'
import { Wordgard } from './editor'

/**
 * Dialogs are {@link Panel panels} opened as a side-effect, and
 * closed by user action. This interface is used to describe them.
 */
export interface Dialog {
  /**
   * A function to render the content of the dialog. The result
   * should contain at least one `<form>` element. Submit handlers
   * and a handler for the Escape key will be added to the form.
   *
   * If this is not given, the `label`, `input`, and `submitLabel`
   * fields will be used to create a simple form for you.
   */
  content?: (wg: Wordgard, close: () => void) => Element
  /**
   * When `content` isn't given, this provides the text shown in the
   * dialog.
   */
  label?: string
  /**
   * The attributes for an input element shown next to the label. If
   * not given, no input element is added.
   */
  input?: { [attr: string]: string }
  /**
   * The label for the button that submits the form. Defaults to
   * `"OK"`.
   */
  submitLabel?: string
  /** Extra classes to add to the panel. */
  class?: string
  /**
   * A query selector to find the field that should be focused when
   * the dialog is opened. When set to true, this picks the first
   * `<input>` or `<button>` element in the form. When set to
   * `false`, focus is not moved into the dialog.
   */
  focus?: string | boolean
  /**
   * By default, dialogs are shown above the editor. Set this to
   * `false` to have it show up at the bottom.
   */
  top?: boolean
}

export namespace Dialog {
  /**
   * Show a dialog to display a message or prompt the user for input.
   * Returns an effect that can be dispatched to close the dialog,
   * and a promise that resolves when the dialog is closed or a form
   * inside of it is submitted.
   *
   * You are encouraged, if your handling of the result of the promise
   * dispatches a transaction, to include the `close` effect in it. If
   * you don't, this function will automatically dispatch a separate
   * transaction right after.
   */
  export function show(
    wg: Wordgard,
    config: Dialog
  ): {
    close: Transaction.Effect<unknown>
    result: Promise<HTMLFormElement | null>
  } {
    let resolve: (form: HTMLFormElement | null) => void
    const promise = new Promise<HTMLFormElement | null>(r => (resolve = r))
    const panelCtor = (wg: Wordgard) => createDialog(wg, config, resolve)
    if (wg.state.field(dialogField, false)) {
      wg.dispatch({ effects: openDialogEffect.of(panelCtor) })
    } else {
      wg.dispatch({ effects: GardState.appendConfig.of(dialogField.init(() => [panelCtor])) })
    }
    const close = closeDialogEffect.of(panelCtor)
    return {
      close,
      result: promise.then(form => {
        const queue = wg.win.queueMicrotask || ((f: () => void) => wg.win.setTimeout(f, 10))
        queue(() => {
          if (wg.state.field(dialogField).indexOf(panelCtor) > -1) wg.dispatch({ effects: close })
        })
        return form
      })
    }
  }

  /**
   * Find the {@link Panel} for an open dialog, using a class name as
   * identifier.
   */
  export function get(wg: Wordgard, className: string) {
    const dialogs = wg.state.field(dialogField, false) || []
    for (const open of dialogs) {
      const panel = Panel.get(wg, open)
      if (panel && panel.dom.classList.contains(className)) return panel
    }
    return null
  }

  /** Close the {@link Panel} for an open dialog, by class name. */
  export function close(wg: Wordgard, className: string) {
    const dialogs = wg.state.field(dialogField, false) || []
    for (const open of dialogs) {
      const panel = Panel.get(wg, open)
      if (panel && panel.dom.classList.contains(className)) {
        wg.dispatch({ effects: closeDialogEffect.of(open) })
        return true
      }
    }
    return false
  }
}

const dialogField = GardState.Field.define<readonly Panel.Constructor[]>({
  create() {
    return []
  },
  update(dialogs, tr) {
    for (const e of tr.effects) {
      if (e.is(openDialogEffect)) dialogs = [e.value].concat(dialogs)
      else if (e.is(closeDialogEffect)) dialogs = dialogs.filter(d => d != e.value)
    }
    return dialogs
  },
  provide: f => Panel.show.computeN(state => state.field(f))
})

const openDialogEffect = Transaction.Effect.define<Panel.Constructor>()
const closeDialogEffect = Transaction.Effect.define<Panel.Constructor>()

function createDialog(wg: Wordgard, config: Dialog, result: (form: HTMLFormElement | null) => void): Panel {
  let content = config.content ? config.content(wg, () => done(null)) : null
  if (!content) {
    content = document.createElement('form')
    content.className = 'wg-form'
    if (config.input) {
      const input = document.createElement('input')
      for (const attr in config.input) {
        if (attr == 'style') input.style.cssText = config.input[attr]!
        else input.setAttribute(attr, config.input[attr]!)
      }
      if (/^(text|password|number|email|tel|url)$/.test(input.type)) input.classList.add('wg-textfield')
      if (!input.name) input.name = 'input'
      const label = content.appendChild(document.createElement('label'))
      if (config.label) label.append(`${config.label}: `)
      label.append(input)
    } else if (config.label) {
      content.append(document.createTextNode(config.label))
    }
    const button = document.createElement('button')
    button.className = 'wg-dialog-button'
    button.type = 'submit'
    content.append(' ', button)
    button.append(config.submitLabel ?? 'OK')
  }
  const forms = content.nodeName == 'FORM' ? [content] : content.querySelectorAll('form')
  for (let i = 0; i < forms.length; i++) {
    const form = forms[i] as HTMLFormElement
    form.addEventListener('keydown', (event: KeyboardEvent) => {
      if (event.keyCode == 27) {
        // Escape
        event.preventDefault()
        done(null)
      } else if (event.keyCode == 13) {
        // Enter
        event.preventDefault()
        done(form)
      }
    })
    form.addEventListener('submit', (event: Event) => {
      event.preventDefault()
      done(form)
    })
  }
  const close = document.createElement('button')
  close.onclick = () => done(null)
  close.setAttribute('aria-label', phrases.get(wg.state, 'dialog_close'))
  close.className = 'wg-dialog-close'
  close.type = 'button'
  close.append('×')
  const panel = document.createElement('wg-dialog')
  panel.append(content, close)
  if (config.class) panel.className = config.class

  function done(form: HTMLFormElement | null) {
    if (panel.contains(panel.ownerDocument.activeElement)) wg.focus()
    result(form)
  }
  let mustFocus = config.focus
  return {
    dom: panel,
    top: config.top !== false,
    connect: () => {
      if (mustFocus) {
        mustFocus = false
        let focus: HTMLInputElement | HTMLButtonElement | undefined | null
        if (typeof config.focus == 'string') focus = content!.querySelector(config.focus) as any
        else focus = content!.querySelector('input') || content!.querySelector('button')
        if (focus && 'select' in focus) focus.select()
        else if (focus && 'focus' in focus) focus.focus()
      }
    }
  }
}
