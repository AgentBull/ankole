import { unwrapMathDelimiters } from '../document/math-delimiters'

/*
 * Word desktop copies list items as paragraphs with `mso-list` styles and a typed marker, not as
 * `ul`/`ol`/`li`. This filter turns each run of such paragraphs into nested lists (SPEC §7.5 Paste
 * and copy), so the ordinary HTML parser keeps the list structure.
 */
const listStyle = /mso-list:\s*(l\d+)\s+level(\d+)/i
// `1.`, `a)`, `(i)`, `一、` and `（一）` number a list; bullet glyphs do not.
const orderedMarker = /^\s*[(（]?(?:\d+|[a-z]|[ivxlcdm]+|[一二三四五六七八九十百]+)[.)）、．]/i

/**
 * Convert rendered KaTeX / MathJax / MathML formula markup (`<annotation encoding="application/x-tex">`,
 * `data-equation`) from chat messages, Notion, Feishu, Wikipedia, or web pages into canonical
 * `.math-block` and `.math-inline` nodes so HTML paste preserves LaTeX instead of duplicating glyph runs.
 */
export function mathHTML(html: string): string {
  if (
    typeof DOMParser === 'undefined' ||
    (!html.includes('application/x-tex') && !html.includes('katex') && !html.includes('data-equation'))
  ) {
    return html
  }
  const doc = new DOMParser().parseFromString(html, 'text/html')
  let changed = false
  const extractTex = (el: Element): string | null => {
    const raw =
      el.getAttribute('data-equation') ??
      el.querySelector('annotation[encoding="application/x-tex"], annotation[encoding*="tex" i]')?.textContent
    if (raw == null) return null
    const cleaned = unwrapMathDelimiters(raw).trim()
    return cleaned || null
  }
  const isSoleParagraphContent = (el: Element): HTMLElement | null => {
    const parent = el.parentElement
    if (!parent || parent.localName !== 'p') return null
    for (const child of Array.from(parent.childNodes)) {
      if (child === el) continue
      if (child.nodeType === 3 && !child.textContent?.trim()) continue
      return null
    }
    return parent
  }

  for (const el of Array.from(
    doc.querySelectorAll(
      '.katex-display, mjx-container[display="true"], math[display="block"], [data-equation][data-display="block"]'
    )
  )) {
    if (!el.isConnected || el.closest('[data-math], [data-inline-math]')) continue
    const tex = extractTex(el)
    if (!tex) continue
    const block = doc.createElement('div')
    block.className = 'math-block'
    block.setAttribute('contenteditable', 'false')
    block.setAttribute('data-math', tex)
    ;(isSoleParagraphContent(el) ?? el).replaceWith(block)
    changed = true
  }

  for (const el of Array.from(doc.querySelectorAll('.katex, mjx-container, math, [data-equation]'))) {
    if (!el.isConnected || el.closest('[data-math], [data-inline-math]')) continue
    const tex = extractTex(el)
    if (!tex) continue
    const span = doc.createElement('span')
    span.className = 'math-inline'
    span.setAttribute('contenteditable', 'false')
    span.setAttribute('data-inline-math', tex.replace(/\r\n?|\n/g, ' '))
    el.replaceWith(span)
    changed = true
  }

  return changed ? doc.body.innerHTML : html
}

export function wordListHTML(html: string): string {
  if (!html.includes('mso-list')) return html
  const doc = new DOMParser().parseFromString(html, 'text/html')
  for (const first of Array.from(doc.querySelectorAll<HTMLElement>('p[style*="mso-list"]'))) {
    // A later pass of this loop already moved the paragraph into a list.
    if (!first.isConnected || !listStyle.test(first.getAttribute('style') ?? '')) continue
    const run: HTMLElement[] = []
    for (let node: Element | null = first; node && isListParagraph(node); node = node.nextElementSibling) {
      run.push(node as HTMLElement)
    }
    first.before(...listsFrom(doc, run))
    for (const paragraph of run) paragraph.remove()
  }
  return doc.body.innerHTML
}

function isListParagraph(node: Element): boolean {
  return node.localName === 'p' && listStyle.test(node.getAttribute('style') ?? '')
}

function listsFrom(doc: Document, run: HTMLElement[]): Node[] {
  const root = doc.createElement('div')
  // `lists[n]` is the open list at level n + 1; a new list id starts a separate root list.
  let lists: HTMLElement[] = []
  let id: string | undefined
  for (const paragraph of run) {
    const [, listID, levelText] = listStyle.exec(paragraph.getAttribute('style') ?? '')!
    const marker = takeMarker(paragraph)
    if (listID !== id) {
      lists = []
      id = listID
    }
    const level = Math.max(1, Math.min(Number(levelText), lists.length + 1))
    lists.length = level
    if (!lists[level - 1]) {
      const list = doc.createElement(orderedMarker.test(marker) ? 'ol' : 'ul')
      // A list that a Word selection starts at `4.` or `(4)` keeps that number.
      const first = /^\s*[(（]?(\d{1,9})[.)）、．]/.exec(marker)?.[1]
      if (list.localName === 'ol' && first && Number(first) !== 1) list.setAttribute('start', String(Number(first)))
      const parent = level === 1 ? root : lists[level - 2]!.lastElementChild
      ;(parent ?? root).append(list)
      lists[level - 1] = list
    }
    const item = doc.createElement('li')
    item.append(...Array.from(paragraph.childNodes))
    lists[level - 1]!.append(item)
  }
  return Array.from(root.childNodes)
}

/** Remove the typed list marker and return its text. */
function takeMarker(paragraph: HTMLElement): string {
  let marker = ''
  const walker = paragraph.ownerDocument.createTreeWalker(paragraph, NodeFilter.SHOW_COMMENT)
  const comments: Comment[] = []
  for (let node = walker.nextNode(); node; node = walker.nextNode()) comments.push(node as Comment)
  // `<![if !supportLists]>…<![endif]>` parses as two comments around the marker.
  const start = comments.find(comment => /if\s+!supportLists/i.test(comment.data))
  const end = start && comments.find(comment => comment !== start && /endif/i.test(comment.data))
  if (start && end) {
    const range = paragraph.ownerDocument.createRange()
    range.setStartBefore(start)
    range.setEndAfter(end)
    marker = range.toString()
    range.deleteContents()
  }
  for (const ignored of Array.from(paragraph.querySelectorAll('[style*="mso-list:Ignore" i]'))) {
    marker ||= ignored.textContent ?? ''
    ignored.remove()
  }
  return marker
}
