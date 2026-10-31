/*
 * Word desktop copies list items as paragraphs with `mso-list` styles and a typed marker, not as
 * `ul`/`ol`/`li`. This filter turns each run of such paragraphs into nested lists (SPEC §7.5 Paste
 * and copy), so the ordinary HTML parser keeps the list structure.
 */
const listStyle = /mso-list:\s*(l\d+)\s+level(\d+)/i
// `1.`, `a)`, `(i)`, `一、` and `（一）` number a list; bullet glyphs do not.
const orderedMarker = /^\s*[(（]?(?:\d+|[a-z]|[ivxlcdm]+|[一二三四五六七八九十百]+)[.)）、．]/i

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
