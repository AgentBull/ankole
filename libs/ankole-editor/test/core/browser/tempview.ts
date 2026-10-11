// Helper library for browser test scripts

import { Wordgard } from '../../../src/core/editor'
import { GardState } from '../../../src/core/state'
import { Plot } from '../../../src/core/doc'
import { maybeTag } from '../schema'

const workspace: HTMLElement = document.querySelector('#workspace')! as HTMLElement

let currentTempEditor: Wordgard | null = null
let hide: any = null

/**
 * Create a hidden editor with the given document and extensions that
 * lives until the next call to `tempEditor`.
 */
export function tempEditor(doc: string | Plot.Doc, config: GardState.Extension = []): Wordgard {
  if (currentTempEditor) {
    currentTempEditor.dom.remove()
    currentTempEditor = null
  }

  let t0, t1
  if (typeof doc != 'string') {
    t0 = maybeTag(doc, 0)
    t1 = maybeTag(doc, 1)
  }
  currentTempEditor = Wordgard.create({ doc, selection: t0 != null ? { anchor: t0, head: t1 } : undefined, config })
  workspace.appendChild(currentTempEditor.dom)
  workspace.style.pointerEvents = ''
  if (hide == null) {
    hide = setTimeout(() => {
      hide = null
      workspace.style.pointerEvents = 'none'
    }, 100)
  }
  return currentTempEditor
}

/** Focus the given editor or raise an error when the window doesn't have focus. */
export function requireFocus(wg: Wordgard): Wordgard {
  if (!document.hasFocus()) throw new Error("The document doesn't have focus, which is needed for this test")
  wg.focus()
  return wg
}
