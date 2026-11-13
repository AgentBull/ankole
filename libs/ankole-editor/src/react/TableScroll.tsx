import { useLayoutEffect } from 'react'
import { TableMap } from '../core/table/tablemap'
import { Table, TableWidths } from '../editor/schema'
import { tableResizePreview } from '../editor/table-presentation'
import { useEditor, useEditorLabel, useEditorState } from './context'

interface TableFrame {
  frame: HTMLElement
  scroll: HTMLElement
}

/** Scrolling is available in editable and read-only documents, including nested and wide tables. */
export function TableScroll() {
  const editor = useEditor()
  const label = useEditorLabel()
  const state = useEditorState()
  useLayoutEffect(() => {
    // `nodeDOM` draws a pending transaction and answers for its positions, not for `state`.
    // The editor renders this component again after it draws that transaction.
    if (state !== editor.state) return
    const preview = state.field(tableResizePreview)
    const tables: TableFrame[] = []
    state.doc.iterate((node, pos) => {
      if (node.type !== Table.type || !node.isPlot) return
      const frame = editor.nodeDOM(pos) as HTMLElement | null
      if (!frame) return
      const scroll = frame.querySelector<HTMLElement>(':scope > .table-scroll')!
      const group = scroll.querySelector('colgroup')!
      const widths = preview?.pos === pos ? preview.widths : node.mark(TableWidths)?.split(',').map(Number)
      const count = TableMap.get(node, pos + 1).width
      editor.observer.ignore(() => {
        if (group.children.length !== count) {
          group.replaceChildren(...Array.from({ length: count }, () => group.ownerDocument.createElement('col')))
        }
        group.querySelectorAll('col').forEach((col, i) => {
          const width = widths?.length === count ? `${widths[i]}px` : ''
          if (col.style.width !== width) col.style.width = width
        })
      })
      tables.push({ frame, scroll })
    })
    if (tables.length === 0) return
    const title = label('table_title')
    const anchor = editor.contentDOM.closest<HTMLElement>('.editor-anchor')
    const documentScroll = editor.contentDOM.closest('.document-scroll')
    // A pass measures every table before it writes to any of them and writes only values that changed. A write
    // between two measurements would make the browser recompute the whole document's styles for the next read,
    // once for every table on every keystroke.
    const update = (targets: readonly TableFrame[]) =>
      editor.observer.ignore(() => {
        const edges = targets.map(({ scroll }) => ({
          left: scroll.scrollLeft > 1,
          right: scroll.scrollLeft + scroll.clientWidth < scroll.scrollWidth - 1
        }))
        const bleeds = targets.some(({ frame }) => frame.parentElement === editor.contentDOM)
        let bleed = 0
        if (bleeds && documentScroll) {
          const content = editor.contentDOM.getBoundingClientRect()
          const host = documentScroll.getBoundingClientRect()
          bleed = Math.max(0, Math.min(content.left - host.left, host.right - content.right))
        }
        targets.forEach(({ scroll }, index) => {
          if (scroll.getAttribute('aria-label') !== title) scroll.setAttribute('aria-label', title)
          scroll.toggleAttribute('data-scroll-left', edges[index]!.left)
          scroll.toggleAttribute('data-scroll-right', edges[index]!.right)
        })
        const value = `${bleed}px`
        if (bleeds && anchor && anchor.style.getPropertyValue('--table-bleed') !== value) {
          anchor.style.setProperty('--table-bleed', value)
        }
      })
    const updateAll = () => update(tables)
    const cleanups = tables.map(table => {
      const { scroll } = table
      const key = (event: KeyboardEvent) => {
        // The focused region owns scrolling; cell editing keeps the editor's bindings.
        if (event.target !== scroll || event.altKey || event.metaKey || event.ctrlKey) return
        const distance = scroll.clientHeight * 0.9
        const offsets: Record<string, [number, number]> = {
          ArrowLeft: [-40, 0],
          ArrowRight: [40, 0],
          ArrowUp: [0, -40],
          ArrowDown: [0, 40],
          PageUp: [0, -distance],
          PageDown: [0, distance],
          Home: [-scroll.scrollLeft, -scroll.scrollTop],
          End: [scroll.scrollWidth, scroll.scrollHeight],
          ' ': [0, event.shiftKey ? -distance : distance]
        }
        const offset = offsets[event.key]
        if (!offset) return
        event.preventDefault()
        event.stopPropagation()
        scroll.scrollBy(...offset)
      }
      const scrolled = () => update([table])
      scroll.addEventListener('keydown', key)
      scroll.addEventListener('scroll', scrolled, { passive: true })
      return () => {
        scroll.removeEventListener('keydown', key)
        scroll.removeEventListener('scroll', scrolled)
      }
    })
    updateAll()
    window.addEventListener('resize', updateAll)
    const observer = new ResizeObserver(updateAll)
    for (const { frame, scroll } of tables) {
      observer.observe(frame)
      observer.observe(scroll)
      const table = scroll.querySelector('table')
      if (table) observer.observe(table)
    }
    if (documentScroll) observer.observe(documentScroll)
    return () => {
      cleanups.forEach(clean => clean())
      window.removeEventListener('resize', updateAll)
      observer.disconnect()
    }
  }, [editor, state])
  return null
}
