import { Elt, Leaf, Mark, Node, Plot, Schema } from '../../core/doc'
import { Decoration, Wordgard } from '../../core/editor'
import type { Widget } from '../../core/editor/decoration'
import { history } from '../../core/history'
import { GardSelection } from '../../core/state'
import * as T from '../../core/types'
import { element } from '../../document/tree'
import {
  Attrs,
  attributeValue,
  codeNodes,
  extraAttrs,
  extraOf,
  markChange,
  markSet,
  markValue
} from '../../editor/attributes'
import type { BlockDefinition } from '../../editor/block'
import { insertBlock } from '../../editor/block-insert'
import { editorPhrases } from '../../editor/phrases'
import {
  closeMermaidMenu,
  createDiagramToolbarWidget,
  diagramGutterWidget,
  diagramLineNumbers,
  diagramPreviewWidget,
  type MermaidLabels,
  type MermaidTemplate,
  type MermaidThemeMode,
  type MermaidViewMode
} from '../mermaid'
import { InfographicPreview } from './preview'

/**
 * `infographic`: an editable AntV Infographic DSL source block with a live SVG preview. The plot
 * holds the source as text and line-break nodes, matching code and Mermaid blocks.
 */
export const InfographicBlock = Plot.define('Infographic', {
  inlineContent: [Leaf.Text, T.LineBreak],
  group: Node.Group.Content,
  role: Node.Role.Code,
  shape: { structure: Elt.mk('div', [Elt.mk('pre', [0])]) }
})

/** Which panes an Infographic block shows. Absent means `both`. */
export const InfographicView = Mark.Type.define<MermaidViewMode>('InfographicView', {
  target: InfographicBlock,
  keepOnSplit: true,
  validate: attributeValue('infographic', 'view'),
  shape: { attributes: {} }
})

/** The infographic palette. Absent means `auto`, following the host theme. */
export const InfographicTheme = Mark.Type.define<MermaidThemeMode>('InfographicTheme', {
  target: InfographicBlock,
  keepOnSplit: true,
  validate: attributeValue('infographic', 'theme'),
  shape: { attributes: {} }
})

/** Curated starter templates using built-in offline-safe Infographic layouts. */
export const infographicTemplates: readonly MermaidTemplate[] = [
  {
    id: 'process',
    title: editorPhrases.ref('infographic_template_process'),
    source: [
      'infographic list-row-horizontal-icon-arrow',
      'data',
      '  title Launch Process',
      '  lists',
      '    - label Plan',
      '      desc Define scope and goals',
      '      icon rocket',
      '    - label Build',
      '      desc Implement core workflow',
      '      icon code',
      '    - label Ship',
      '      desc Verify and release',
      '      icon check'
    ].join('\n')
  },
  {
    id: 'timeline',
    title: editorPhrases.ref('infographic_template_timeline'),
    source: [
      'infographic sequence-timeline-simple',
      'data',
      '  title Product Roadmap',
      '  sequences',
      '    - label Q1',
      '      desc Foundation and architecture',
      '    - label Q2',
      '      desc Beta launch and feedback',
      '    - label Q3',
      '      desc General availability'
    ].join('\n')
  },
  {
    id: 'funnel',
    title: editorPhrases.ref('infographic_template_funnel'),
    source: [
      'infographic sequence-funnel-simple',
      'data',
      '  title Conversion Funnel',
      '  sequences',
      '    - label Visitors',
      '      value 10000',
      '    - label Signups',
      '      value 2400',
      '    - label Customers',
      '      value 480'
    ].join('\n')
  },
  {
    id: 'swot',
    title: editorPhrases.ref('infographic_template_swot'),
    source: [
      'infographic compare-swot',
      'data',
      '  title Strategic Analysis',
      '  compares',
      '    - label Strengths',
      '      children',
      '        - label Fast core product',
      '        - label Unified data model',
      '    - label Weaknesses',
      '      children',
      '        - label Fewer integrations',
      '    - label Opportunities',
      '      children',
      '        - label Enterprise adoption',
      '    - label Threats',
      '      children',
      '        - label Market competition'
    ].join('\n')
  },
  {
    id: 'kpi',
    title: editorPhrases.ref('infographic_template_kpi'),
    source: [
      'infographic list-grid-badge-card',
      'data',
      '  title Key Metrics',
      '  lists',
      '    - label Revenue',
      '      value $1.2M',
      '      desc +18% QoQ',
      '      icon chart',
      '    - label Active Teams',
      '      value 340',
      '      desc +12% QoQ',
      '      icon user',
      '    - label Uptime',
      '      value 99.95%',
      '      desc Last 90 days',
      '      icon check'
    ].join('\n')
  },
  {
    id: 'hierarchy',
    title: editorPhrases.ref('infographic_template_hierarchy'),
    source: [
      'infographic compare-hierarchy-left-right-circle-node-pill-badge',
      'data',
      '  title Platform Architecture',
      '  compares',
      '    - label Control Plane',
      '      children',
      '        - label Identity and AuthZ',
      '        - label Durable State',
      '    - label Execution Plane',
      '      children',
      '        - label Native Kernel',
      '        - label Agent Runtime'
    ].join('\n')
  }
]

function setInfographicMark<V>(editor: Wordgard, pos: number, type: Mark.Type<V>, value: V | null) {
  if (editor.state.readOnly) return
  editor.dispatch({
    changes: markChange(editor.state.doc.nodeAt(pos), pos, type, value),
    effects: closeMermaidMenu.of(null),
    annotations: history.isolate.of(true),
    userEvent: 'infographic.configure'
  })
}

export function setInfographicView(editor: Wordgard, pos: number, view: MermaidViewMode) {
  setInfographicMark(editor, pos, InfographicView, view === 'both' ? null : view)
}

export function setInfographicTheme(editor: Wordgard, pos: number, theme: MermaidThemeMode) {
  setInfographicMark(editor, pos, InfographicTheme, theme === 'auto' ? null : theme)
}

export function applyInfographicTemplate(editor: Wordgard, pos: number, source: string) {
  const node = editor.state.doc.nodeAt(pos)
  if (!node?.isPlot || node.type !== InfographicBlock.type || editor.state.readOnly) return
  const unchanged = node.textContent() === source
  editor.dispatch({
    changes: unchanged ? undefined : { from: pos + 1, to: pos + node.length - 1, insert: codeNodes(source) },
    effects: closeMermaidMenu.of(null),
    annotations: history.isolate.of(true),
    userEvent: 'infographic.template'
  })
  editor.focus()
}

const infographicToolbarWidget = createDiagramToolbarWidget(InfographicBlock.type, 'https://infographic.antv.vision/')

type InfographicBlockView = {
  host: HTMLElement
  lines: number
  preview: InfographicPreview
  scroll?: { source: HTMLElement; remove: () => void }
}

const infographicViewsPlugin = Wordgard.Plugin.define(
  () => {
    const views = new Map<HTMLElement, InfographicBlockView>()

    const clear = () => {
      for (const entry of views.values()) {
        entry.preview.destroy()
        entry.scroll?.remove()
      }
      views.clear()
    }

    const sync = (editor: Wordgard) => {
      if (!editor.connected) return
      const placeholder = editorPhrases.get(editor.state, 'infographic_placeholder')
      const seen = new Set<HTMLElement>()
      editor.state.doc.iterate((node, pos) => {
        if (node.type !== InfographicBlock.type || !node.isPlot) return
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
          entry = { host, lines: 0, preview: new InfographicPreview(host) }
          views.set(block, entry)
        }
        const source = node.textContent()
        const view = node.mark(InfographicView) ?? 'both'
        const theme = node.mark(InfographicTheme) ?? 'auto'
        const gutter = block.querySelector<HTMLElement>('.mermaid-gutter')
        const sourceElement = block.querySelector<HTMLElement>('.mermaid-pre')
        if (gutter) {
          const lines = source ? source.split('\n').length : 1
          if (entry.lines !== lines || !gutter.textContent) {
            entry.lines = lines
            gutter.textContent = diagramLineNumbers(lines)
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
        if (view === 'code') entry.preview.setSource('', '', theme)
        else entry.preview.setSource(source, placeholder, theme)
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

export const infographic: BlockDefinition = {
  name: 'infographic',
  type: InfographicBlock.type,
  schema: [
    InfographicBlock,
    InfographicView,
    InfographicTheme,
    Schema.Override.markTarget(Attrs, target => [target, InfographicBlock])
  ],
  extension: [
    infographicViewsPlugin,
    Decoration.Tag.shape.derived(InfographicBlock.type, state => {
      const labels: MermaidLabels = {
        template: editorPhrases.get(state, 'mermaid_template'),
        view: editorPhrases.get(state, 'mermaid_view'),
        expand: editorPhrases.get(state, 'mermaid_expand'),
        theme: editorPhrases.get(state, 'mermaid_theme'),
        help: editorPhrases.get(state, 'mermaid_help')
      }
      const readOnly = state.readOnly
      return tag => {
        const view = tag.mark(InfographicView) ?? 'both'
        const theme = tag.mark(InfographicTheme) ?? 'auto'
        return Elt.mk<Widget | string>(
          'div',
          { class: 'mermaid-block infographic-block', 'data-view': view, 'data-theme': theme },
          [
            infographicToolbarWidget.of({ view, theme, readOnly, knowledge: false, labels }),
            diagramGutterWidget,
            diagramPreviewWidget,
            Elt.mk<Widget | string>('pre', { class: 'mermaid-pre' }, [0])
          ]
        )
      }
    })
  ],
  import: (node, context) => {
    const view = node.attrs.view as MermaidViewMode | undefined
    const theme = node.attrs.theme as MermaidThemeMode | undefined
    const marks = markSet([
      view !== undefined && view !== 'both' && InfographicView.of(view),
      theme !== undefined && theme !== 'auto' && InfographicTheme.of(theme),
      extraAttrs(node.attrs, ['view', 'theme'])
    ])
    return InfographicBlock.withMarks(marks).create(context.code(node.children))
  },
  read: (node, context) => {
    const view = markValue(node, InfographicView)
    const theme = markValue(node, InfographicTheme)
    return element(
      'infographic',
      {
        ...extraOf(node),
        ...(view ? { view } : {}),
        ...(theme ? { theme } : {})
      },
      node.isPlot ? context.code(node) : []
    )
  },
  insert: {
    title: editorPhrases.ref('infographic_title'),
    detail: editorPhrases.ref('infographic_detail'),
    keywords: 'infographic diagram visual timeline swot funnel cards 信息图 图解 视觉图 时间线 漏斗 对比图',
    turnInto: true,
    insert: wg => {
      insertBlock(wg, InfographicBlock.create([]), at => ({ selection: GardSelection.cursor(at + 1) }))
    }
  }
}
