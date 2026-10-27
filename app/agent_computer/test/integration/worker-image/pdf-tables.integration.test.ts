import { expect, test } from 'bun:test'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

type TableStyle = 'right-body' | 'left-compact' | 'right-header' | 'helvetica'

function tablePDF(style: TableStyle): string {
  const font = style === 'helvetica' ? 'Helvetica' : 'Courier'
  const width = (text: string) =>
    font === 'Courier' ? text.length * 6 : [...text].reduce((sum, c) => sum + (c === '.' ? 2.78 : 5.56), 0)
  const commands: string[] = []
  const text = (x: number, y: number, value: string) =>
    commands.push(`BT /F1 10 Tf 1 0 0 1 ${x} ${y} Tm (${value}) Tj ET`)
  text(50, 730, 'Item')
  text(style === 'left-compact' ? 150 : 130, 730, 'Description')
  text(style === 'left-compact' ? 250 : style === 'right-header' ? 420 - width('Quantity') : 340, 730, 'Quantity')
  text(style === 'left-compact' ? 350 : style === 'right-header' ? 550 - width('Amount') : 440, 730, 'Amount')
  for (let i = 1; i <= 15; i++) {
    const y = 730 - i * 20,
      quantity = String(i),
      amount = (i * 17.5).toFixed(2)
    text(50, y, String(i))
    text(style === 'left-compact' ? 150 : 130, y, `Widget ${i}`)
    text(style === 'left-compact' ? 250 : 420 - width(quantity), y, quantity)
    text(style === 'left-compact' ? 350 : 550 - width(amount), y, amount)
  }
  for (let i = 0; i <= 16; i++) commands.push(`45 ${744 - i * 20} m 560 ${744 - i * 20} l 0.5 w S`)
  const content = commands.join('\n')
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    `<< /Type /Font /Subtype /Type1 /BaseFont /${font} >>`,
    `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`
  ]
  let pdf = '%PDF-1.4\n'
  const offsets: number[] = []
  for (const [i, object] of objects.entries()) {
    offsets.push(Buffer.byteLength(pdf))
    pdf += `${i + 1} 0 obj\n${object}\nendobj\n`
  }
  const xref = Buffer.byteLength(pdf)
  const entries = offsets.map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('')
  return `${pdf}xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${entries}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`
}

for (const style of ['right-body', 'left-compact', 'right-header', 'helvetica'] as const) {
  test(`PDF table retains all four columns and every data row with ${style}`, () => {
    const root = mkdtempSync('/tmp/ankole-pdf-table-')
    const path = join(root, 'table.pdf')
    try {
      writeFileSync(path, tablePDF(style))
      const result = spawnSync('pdf2md', [path, '--json'], { encoding: 'utf8', timeout: 20_000 })
      expect(result.status, result.stderr).toBe(0)
      const { markdown } = JSON.parse(result.stdout)
      expect(markdown).not.toContain('```')
      const rows = (markdown as string)
        .split('\n')
        .filter(line => line.startsWith('|'))
        .map(line =>
          line
            .split('|')
            .slice(1, -1)
            .map(cell => cell.trim())
        )
        .filter(row => !row.every(cell => /^[-:]+$/.test(cell)))
      expect(rows).toEqual([
        ['Item', 'Description', 'Quantity', 'Amount'],
        ...Array.from({ length: 15 }, (_, index) => {
          const i = index + 1
          return [String(i), `Widget ${i}`, String(i), (i * 17.5).toFixed(2)]
        })
      ])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }, 30_000)
}
