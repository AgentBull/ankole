import { useLayoutEffect } from 'react'
import { TableMap } from '../core/table/tablemap'
import { Table, TableWidths } from '../editor/schema'
import { tableResizePreview } from '../editor/table-presentation'
import { useEditor, useEditorLabel, useEditorState } from './context'

/** Scrolling is available in editable and read-only documents, including nested and wide tables. */
export function TableScroll() {
  const editor = useEditor()
  const label = useEditorLabel()
  const state = useEditorState()
  useLayoutEffect(() => {
    const preview = state.field(tableResizePreview)
    const cleanups: (() => void)[] = []
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
      const update = () =>
        editor.observer.ignore(() => {
          scroll.setAttribute('aria-label', label('table_title'))
          scroll.toggleAttribute('data-scroll-left', scroll.scrollLeft > 1)
          scroll.toggleAttribute('data-scroll-right', scroll.scrollLeft + scroll.clientWidth < scroll.scrollWidth - 1)
          const content = editor.contentDOM.getBoundingClientRect()
          const host = editor.contentDOM.closest('.document-scroll')?.getBoundingClientRect()
          const bleed =
            frame.parentElement === editor.contentDOM && host
              ? Math.max(0, Math.min(content.left - host.left, host.right - content.right))
              : 0
          if (frame.parentElement === editor.contentDOM) {
            editor.contentDOM.closest<HTMLElement>('.editor-anchor')?.style.setProperty('--table-bleed', `${bleed}px`)
          }
        })
      update()
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
      scroll.addEventListener('keydown', key)
      scroll.addEventListener('scroll', update, { passive: true })
      window.addEventListener('resize', update)
      const observer = new ResizeObserver(update)
      observer.observe(frame)
      observer.observe(scroll)
      const documentScroll = editor.contentDOM.closest('.document-scroll')
      if (documentScroll) observer.observe(documentScroll)
      const table = scroll.querySelector('table')
      if (table) observer.observe(table)
      cleanups.push(() => {
        scroll.removeEventListener('keydown', key)
        scroll.removeEventListener('scroll', update)
        window.removeEventListener('resize', update)
        observer.disconnect()
      })
    })
    return () => cleanups.forEach(clean => clean())
  }, [editor, state])
  return null
}
