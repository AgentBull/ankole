import { attributeValue } from '../../editor/attributes'
import { Elt, Leaf, Mark, Node, Plot, Schema } from '../../core/doc'
import { Decoration, Wordgard } from '../../core/editor'
import { Widget } from '../../core/editor/decoration'
import { history } from '../../core/history'
import { GardSelection, GardState, Transaction } from '../../core/state'
import { element } from '../../document/tree'
import { Attrs, codeNodes, extraAttrs, extraOf, markChange, markSet, markValue } from '../../editor/attributes'
import type { BlockDefinition } from '../../editor/block'
import { insertBlock } from '../../editor/block-insert'
import { editorPhrases } from '../../editor/phrases'
import { connectedWidget, widgetBlock } from '../../editor/widget'
import type { PhraseSet } from '../../core/phrases'
import * as T from '../../core/types'
import { MermaidPreview } from './preview'

const viewModes = ['both', 'code', 'diagram'] as const
const themes = ['auto', 'light', 'dark'] as const
export type MermaidViewMode = (typeof viewModes)[number]
export type MermaidTheme = (typeof themes)[number]

/**
 * `mermaid`: an editable Mermaid source block with a rendered preview. The plot holds the source as
 * text and line-break nodes, so typing, undo, collaboration, and clipboard work like a code block.
 */
export const MermaidBlock = Plot.define('Mermaid', {
  inlineContent: [Leaf.Text, T.LineBreak],
  group: Node.Group.Content,
  role: Node.Role.Code,
  shape: { structure: Elt.mk('div', [Elt.mk('pre', [0])]) }
})

/** Which panes a Mermaid block shows. Absent means `both`. */
export const MermaidView = Mark.Type.define<MermaidViewMode>('MermaidView', {
  target: MermaidBlock,
  keepOnSplit: true,
  validate: attributeValue('mermaid', 'view'),
  shape: { attributes: {} }
})

/** The diagram palette. Absent means `auto`, following the host theme. */
export const MermaidTheme = Mark.Type.define<MermaidTheme>('MermaidTheme', {
  target: MermaidBlock,
  keepOnSplit: true,
  validate: attributeValue('mermaid', 'theme'),
  shape: { attributes: {} }
})

export type MermaidMenuKind = 'view' | 'theme' | 'template'
export type MermaidMenuState = { pos: number; kind: MermaidMenuKind }

/** Open a Mermaid toolbar menu for the block at `pos`. */
export const openMermaidMenu = Transaction.Effect.define<MermaidMenuState>()
/** Close the open Mermaid toolbar menu. */
export const closeMermaidMenu = Transaction.Effect.define<null>()

/** The Mermaid toolbar menu, or null. */
export const mermaidMenuField = GardState.Field.define<MermaidMenuState | null>({
  create: () => null,
  update(value, tr) {
    let next = value !== null && tr.docChanged ? { ...value, pos: tr.changes.mapPos(value.pos, -1) } : value
    for (const effect of tr.effects) {
      if (effect.is(openMermaidMenu)) next = effect.value
      else if (effect.is(closeMermaidMenu)) next = null
    }
    return next !== null && tr.state.doc.nodeAt(next.pos)?.type === MermaidBlock.type ? next : null
  }
})

/** The Mermaid block shown in the expanded dialog, or null. */
export const expandedMermaidField = GardState.Field.define<number | null>({
  create: () => null,
  update(value, tr) {
    let pos = value !== null && tr.docChanged ? tr.changes.mapPos(value, -1) : value
    for (const effect of tr.effects) {
      if (effect.is(openExpandedMermaid)) pos = effect.value
      else if (effect.is(closeExpandedMermaid)) pos = null
    }
    return pos !== null && tr.state.doc.nodeAt(pos)?.type === MermaidBlock.type ? pos : null
  }
})

export const openExpandedMermaid = Transaction.Effect.define<number>()
export const closeExpandedMermaid = Transaction.Effect.define<null>()

export type MermaidTemplate = { id: string; title: PhraseSet.Ref; source: string }

/** Starter diagrams in the template menu. */
export const mermaidTemplates: readonly MermaidTemplate[] = [
  {
    id: 'basic',
    title: editorPhrases.ref('mermaid_template_basic'),
    source: 'flowchart TD\n  A[开始] --> B[结束]'
  },
  {
    id: 'decision',
    title: editorPhrases.ref('mermaid_template_decision'),
    source: 'flowchart TD\n  A[开始] --> B{是否继续?}\n  B -->|是| C[处理]\n  B -->|否| D[结束]'
  },
  {
    id: 'horizontal',
    title: editorPhrases.ref('mermaid_template_horizontal'),
    source: 'flowchart LR\n  A[输入] --> B[处理] --> C[输出]'
  }
]

function setMermaidMark<V>(editor: Wordgard, pos: number, type: Mark.Type<V>, value: V | null) {
  if (editor.state.readOnly) return
  editor.dispatch({
    changes: markChange(editor.state.doc.nodeAt(pos), pos, type, value),
    effects: closeMermaidMenu.of(null),
    annotations: history.isolate.of(true),
    userEvent: 'mermaid.configure'
  })
}

export function setMermaidView(editor: Wordgard, pos: number, view: MermaidViewMode) {
  setMermaidMark(editor, pos, MermaidView, view === 'both' ? null : view)
}

export function setMermaidTheme(editor: Wordgard, pos: number, theme: MermaidTheme) {
  setMermaidMark(editor, pos, MermaidTheme, theme === 'auto' ? null : theme)
}

export function applyMermaidTemplate(editor: Wordgard, pos: number, source: string) {
  const node = editor.state.doc.nodeAt(pos)
  if (!node?.isPlot || node.type !== MermaidBlock.type || editor.state.readOnly) return
  const unchanged = node.textContent() === source
  editor.dispatch({
    changes: unchanged ? undefined : { from: pos + 1, to: pos + node.length - 1, insert: codeNodes(source) },
    effects: closeMermaidMenu.of(null),
    annotations: history.isolate.of(true),
    userEvent: 'mermaid.template'
  })
  editor.focus()
}

type MermaidLabels = {
  template: string
  view: string
  expand: string
  theme: string
  help: string
}

type MermaidToolbarValue = {
  view: MermaidViewMode
  theme: MermaidTheme
  readOnly: boolean
  labels: MermaidLabels
}

function toolbarButton(text: string, title: string, action: string): HTMLButtonElement {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = `mermaid-toolbar-${action}`
  button.dataset.mermaidAction = action
  button.textContent = text
  button.title = title
  button.setAttribute('aria-label', title)
  button.tabIndex = 0
  return button
}

function mermaidToolbar(value: MermaidToolbarValue): HTMLDivElement {
  const bar = document.createElement('div')
  bar.className = 'mermaid-toolbar'
  bar.contentEditable = 'false'

  const spacer = document.createElement('span')
  spacer.className = 'mermaid-spacer'
  bar.append(spacer)

  if (!value.readOnly) {
    bar.append(toolbarButton(value.labels.template, value.labels.template, 'template'))
    bar.append(toolbarButton(value.labels.view, value.labels.view, 'view'))
  }
  bar.append(toolbarButton(value.labels.expand, value.labels.expand, 'expand'))
  if (!value.readOnly) bar.append(toolbarButton(value.labels.theme, value.labels.theme, 'theme'))
  bar.append(toolbarButton(value.labels.help, value.labels.help, 'help'))
  return bar
}

const mermaidToolbarWidget = connectedWidget<MermaidToolbarValue, HTMLDivElement>({
  render: value => mermaidToolbar(value),
  connect: (_value, bar, editor) => {
    const find = () => {
      const found = widgetBlock(editor, bar)
      return found?.node.type === MermaidBlock.type ? found.pos : null
    }
    const mouseDown = (event: MouseEvent) => {
      if ((event.target as Element | null)?.closest('[data-mermaid-action]')) event.preventDefault()
    }
    const click = (event: MouseEvent) => {
      const target = (event.target as Element | null)?.closest<HTMLElement>('[data-mermaid-action]')
      if (!target) return
      event.preventDefault()
      const action = target.dataset.mermaidAction
      const pos = find()
      if (pos === null) return
      if (action === 'help') {
        window.open('https://mermaid.js.org/syntax/flowchart.html', '_blank', 'noopener,noreferrer')
        return
      }
      if (action === 'expand') {
        const open = editor.state.field(expandedMermaidField, false) === pos
        editor.dispatch({ effects: open ? closeExpandedMermaid.of(null) : openExpandedMermaid.of(pos) })
        return
      }
      if (action === 'template' || action === 'view' || action === 'theme') {
        const kind = action as MermaidMenuKind
        const current = editor.state.field(mermaidMenuField, false)
        editor.dispatch({
          effects:
            current?.pos === pos && current.kind === kind
              ? closeMermaidMenu.of(null)
              : openMermaidMenu.of({ pos, kind })
        })
      }
    }
    bar.addEventListener('mousedown', mouseDown)
    bar.addEventListener('click', click)
    return () => {
      bar.removeEventListener('mousedown', mouseDown)
      bar.removeEventListener('click', click)
    }
  },
  propagateEvent: false
})

const mermaidGutterWidget = Widget.create({
  render: () => {
    const gutter = document.createElement('div')
    gutter.className = 'mermaid-gutter'
    gutter.setAttribute('aria-hidden', 'true')
    return gutter
  }
})

const mermaidPreviewWidget = Widget.create({
  render: () => {
    const preview = document.createElement('div')
    preview.className = 'mermaid-preview'
    return preview
  }
})

type BlockView = {
  host: HTMLElement
  lines: number
  preview: MermaidPreview
  scroll?: { source: HTMLElement; remove: () => void }
}

function lineNumbers(count: number): string {
  return Array.from({ length: Math.max(1, count) }, (_, index) => String(index + 1)).join('\n')
}

const mermaidViewsPlugin = Wordgard.Plugin.define(
  () => {
    const views = new Map<HTMLElement, BlockView>()

    const clear = () => {
      for (const entry of views.values()) {
        entry.preview.destroy()
        entry.scroll?.remove()
      }
      views.clear()
    }

    const sync = (editor: Wordgard) => {
      if (!editor.connected) return
      const placeholder = editorPhrases.get(editor.state, 'mermaid_placeholder')
      const seen = new Set<HTMLElement>()
      editor.state.doc.iterate((node, pos) => {
        if (node.type !== MermaidBlock.type || !node.isPlot) return
        const block = editor.nodeDOM(pos) as HTMLElement | null
        const host = block?.querySelector<HTMLElement>('.mermaid-preview')
        if (!block || !host) return false
        seen.add(block)
        let entry = views.get(block)
        if (entry && entry.host !== host) {
          entry.preview.destroy()
          entry.scroll?.remove()
          entry = undefined
        }
        if (!entry) {
          entry = { host, lines: 0, preview: new MermaidPreview(host) }
          views.set(block, entry)
        }
        const source = node.textContent()
        const view = node.mark(MermaidView) ?? 'both'
        const gutter = block.querySelector<HTMLElement>('.mermaid-gutter')
        const sourceElement = block.querySelector<HTMLElement>('.mermaid-pre')
        if (gutter) {
          const lines = source ? source.split('\n').length : 1
          if (entry.lines !== lines || !gutter.textContent) {
            entry.lines = lines
            gutter.textContent = lineNumbers(lines)
            gutter.style.setProperty('--mermaid-gutter-width', String(String(lines).length))
          }
          gutter.scrollTop = sourceElement?.scrollTop ?? 0
        }
        if (sourceElement && entry.scroll?.source !== sourceElement) {
          entry.scroll?.remove()
          const onScroll = () => {
            const currentGutter = block.querySelector<HTMLElement>('.mermaid-gutter')
            if (currentGutter) currentGutter.scrollTop = sourceElement.scrollTop
          }
          sourceElement.addEventListener('scroll', onScroll)
          entry.scroll = { source: sourceElement, remove: () => sourceElement.removeEventListener('scroll', onScroll) }
        }
        if (view === 'code') entry.preview.setSource('', '')
        else entry.preview.setSource(source, placeholder)
        return false
      })
      for (const [block, entry] of views) {
        if (seen.has(block)) continue
        entry.preview.destroy()
        entry.scroll?.remove()
        views.delete(block)
      }
    }

    return {
      connect(editor) {
        sync(editor)
      },
      disconnect() {
        clear()
      },
      sync
    }
  },
  plugin =>
    Wordgard.updateListener.of(update => {
      update.editor.plugin(plugin)?.sync(update.editor)
    })
)

export const mermaid: BlockDefinition = {
  name: 'mermaid',
  type: MermaidBlock.type,
  schema: [
    MermaidBlock,
    MermaidView,
    MermaidTheme,
    Schema.Override.markTarget(Attrs, target => [target, MermaidBlock])
  ],
  extension: [
    mermaidMenuField,
    expandedMermaidField,
    mermaidViewsPlugin,
    Decoration.Tag.shape.derived(MermaidBlock.type, state => {
      const labels: MermaidLabels = {
        template: editorPhrases.get(state, 'mermaid_template'),
        view: editorPhrases.get(state, 'mermaid_view'),
        expand: editorPhrases.get(state, 'mermaid_expand'),
        theme: editorPhrases.get(state, 'mermaid_theme'),
        help: editorPhrases.get(state, 'mermaid_help')
      }
      const readOnly = state.readOnly
      return tag => {
        const view = tag.mark(MermaidView) ?? 'both'
        const theme = tag.mark(MermaidTheme) ?? 'auto'
        return Elt.mk<Widget | string>('div', { class: 'mermaid-block', 'data-view': view, 'data-theme': theme }, [
          mermaidToolbarWidget.of({ view, theme, readOnly, labels }),
          mermaidGutterWidget,
          mermaidPreviewWidget,
          // Keep the content hole in the last child, as code blocks do, so tile updates
          // cannot mistake a wrapper for the node's content.
          Elt.mk<Widget | string>('pre', { class: 'mermaid-pre' }, [0])
        ])
      }
    })
  ],
  import: (node, context) => {
    const view = node.attrs.view as MermaidViewMode | undefined
    const theme = node.attrs.theme as MermaidTheme | undefined
    const marks = markSet([
      view !== undefined && view !== 'both' && MermaidView.of(view),
      theme !== undefined && theme !== 'auto' && MermaidTheme.of(theme),
      extraAttrs(node.attrs, ['view', 'theme'])
    ])
    return MermaidBlock.withMarks(marks).create(context.code(node.children))
  },
  read: (node, context) => {
    const view = markValue(node, MermaidView)
    const theme = markValue(node, MermaidTheme)
    return element(
      'mermaid',
      {
        ...extraOf(node),
        ...(view ? { view } : {}),
        ...(theme ? { theme } : {})
      },
      node.isPlot ? context.code(node) : []
    )
  },
  insert: {
    title: editorPhrases.ref('mermaid_title'),
    detail: editorPhrases.ref('mermaid_detail'),
    keywords: 'mermaid flowchart diagram 流程图',
    turnInto: false,
    insert: wg => {
      insertBlock(wg, MermaidBlock.create([]), at => ({ selection: GardSelection.cursor(at + 1) }))
    }
  }
}
