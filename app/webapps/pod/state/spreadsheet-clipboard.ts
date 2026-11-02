/**
 * The system clipboard format of the spreadsheet editor.
 *
 * A copy writes tab-separated text and an HTML table. Other applications paste the table or the
 * text; an Ankole spreadsheet also finds the copied block, with formulas and formats, in the
 * table's `data-ankole-spreadsheet` attribute. Pasting HTML from elsewhere reads the text of each
 * table cell.
 */
import { encodeTSV, type ClipboardBlock } from './spreadsheet-grid'

const ATTRIBUTE = 'data-ankole-spreadsheet'

/** What a copy carries besides its cells: where it came from, and the cut it belongs to. */
export type ClipboardSource = { pageID: string; sheetID: number; range: string; cut?: string }
export type ClipboardPayload = { version: 1; source: ClipboardSource; block: ClipboardBlock }

function escapeHTML(text: string): string {
  return text.replace(/[&<>"']/g, char => `&#${char.charCodeAt(0)};`)
}

function decodeEntities(text: string): string {
  const named: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' }
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (entity, body: string) => {
    if (body[0] === '#') {
      const code = body[1]?.toLowerCase() === 'x' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10)
      return Number.isFinite(code) ? String.fromCodePoint(code) : entity
    }
    return named[body.toLowerCase()] ?? entity
  })
}

/** The text and HTML a copy of `block` writes. */
export function encodeClipboard(block: ClipboardBlock, source: ClipboardSource): { text: string; html: string } {
  const payload: ClipboardPayload = { version: 1, source, block }
  const rows = block.rows
    .map(row => `<tr>${row.map(cell => `<td>${escapeHTML(cell.text).replaceAll('\n', '<br>')}</td>`).join('')}</tr>`)
    .join('')
  return {
    text: encodeTSV(block.rows.map(row => row.map(cell => cell.text))),
    html: `<table ${ATTRIBUTE}="${escapeHTML(JSON.stringify(payload))}"><tbody>${rows}</tbody></table>`
  }
}

/** The copied block of an Ankole spreadsheet, or else the text of the first HTML table's cells. */
export function decodeClipboard(html: string): { payload?: ClipboardPayload; rows?: string[][] } {
  const attribute = new RegExp(`${ATTRIBUTE}="([^"]*)"`).exec(html)
  if (attribute) {
    try {
      const payload = JSON.parse(decodeEntities(attribute[1]!)) as ClipboardPayload
      if (payload.version === 1 && Array.isArray(payload.block?.rows)) return { payload }
    } catch {
      // A damaged attribute falls back to the table text below.
    }
  }
  const table = /<table[\s\S]*?<\/table>/i.exec(html)?.[0]
  if (!table) return {}
  const rows = [...table.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/gi)].map(([, row]) =>
    [...row!.matchAll(/<t[dh][^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(([, cell]) =>
      decodeEntities(
        cell!
          .replace(/<br\s*\/?>/gi, '\n')
          .replace(/<[^>]+>/g, '')
          .replace(/\s*\n\s*/g, '\n')
          .trim()
      )
    )
  )
  return rows.length ? { rows } : {}
}
