import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { Wordgard } from '../src/core/editor'
import { readClipboard } from '../src/core/editor/clipboard'
import * as T from '../src/core/types'
import { MermaidBlock } from '../src/blocks/mermaid'
import { InfographicBlock } from '../src/blocks/infographic'
import { printMarkdown, printXml } from '../src/document'
import { looksLikeMarkdown, parsePastedMarkdown } from '../src/document/markdown-paste'
import { pasteTextAtDocumentStart, splitPastedDocumentTitle } from '../src/editor/clipboard'
import { knowledgeExtension } from '../src/editor/knowledge'
import { expectReopens, exportMarkdown, open, readTree, select } from './helpers'

function fakeTransfer(entries: Record<string, string | undefined>): DataTransfer {
  const normalized = new Map<string, string>(
    Object.entries(entries)
      .filter((entry): entry is [string, string] => entry[1] !== undefined)
      .map(([k, v]) => [k.toLowerCase(), v])
  )
  return {
    types: [...normalized.keys()],
    files: [] as unknown as FileList,
    items: [] as unknown as DataTransferItemList,
    dropEffect: 'none',
    effectAllowed: 'all',
    getData(format: string) {
      return normalized.get(format.toLowerCase()) ?? ''
    },
    setData(format: string, data: string) {
      normalized.set(format.toLowerCase(), data)
    },
    clearData() {
      normalized.clear()
    },
    setDragImage() {}
  } as unknown as DataTransfer
}

function pasteInto(editor: Wordgard, entries: Record<string, string | undefined>, plain = false) {
  const { from, to } = editor.state.selection.replacementRange
  const slice = readClipboard(editor.state, fakeTransfer(entries), editor.state.doc.resolve(from), plain)
  expect(slice).not.toBeNull()
  editor.dispatch({
    changes: { correct: { from, to, insert: slice!, fit: true }, local: true },
    userEvent: 'input.paste'
  })
}

function monacoHtmlFromText(source: string): string {
  const body = source
    .split(/\r?\n/)
    .map(line =>
      line
        ? `<div><span style="color: #d4d4d4;">${line.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')}</span></div>`
        : '<br>'
    )
    .join('')
  return `<div style="color: #cccccc; background-color: #1f1f1f; font-family: Menlo, Monaco, monospace; white-space: pre;">${body}</div>`
}

const lifecycleDocPath = resolve(import.meta.dir, '../../../docs/design-docs/overview.md')
const lifecycleMarkdown = readFileSync(lifecycleDocPath, 'utf8')

describe('Notion-aligned smart Markdown and IDE clipboard paste', () => {
  test('parses design-docs/overview.md across plain text, VS Code, JetBrains <pre>, and chat <div> wrappers', () => {
    for (const payload of [
      { 'text/plain': lifecycleMarkdown },
      {
        'text/plain': lifecycleMarkdown,
        'text/html': monacoHtmlFromText(lifecycleMarkdown),
        'vscode-editor-data': JSON.stringify({ version: 1, isFromEmptySelection: false, mode: 'markdown' })
      },
      {
        'text/plain': lifecycleMarkdown,
        'text/html': `<pre style="font-family: 'JetBrains Mono', monospace;">${lifecycleMarkdown
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')}</pre>`
      },
      {
        'text/plain': lifecycleMarkdown,
        'text/html': monacoHtmlFromText(lifecycleMarkdown)
      }
    ]) {
      const editor = open('')
      pasteInto(editor, payload)
      const tree = readTree(editor)
      const first = tree.children[0]
      expect(first).toMatchObject({ type: 'element', name: 'h1' })
      expect(printXml(tree)).toContain('<h1>Ankole Lifecycle Overview</h1>')
      expect(printXml(tree)).toContain('<h2>A Chat Turn</h2>')
      expect(printXml(tree)).toContain('<h2>Site Startup</h2>')

      let mermaidCount = 0
      editor.state.doc.iterate(node => {
        if (node.type === MermaidBlock.type) mermaidCount++
      })
      expect(mermaidCount).toBe(10)
      expectReopens(editor)
    }
  })

  test('splits design-docs/overview.md when pasted into an empty Document Page title field', () => {
    const split = splitPastedDocumentTitle(lifecycleMarkdown, { replaceAllTitle: true })
    expect(split).not.toBeNull()
    expect(split!.title).toBe('Ankole Lifecycle Overview')
    expect(split!.body.startsWith('The ten state machines')).toBe(true)

    const editor = open('')
    expect(pasteTextAtDocumentStart(editor, split!.body)).toBe(true)
    const xml = printXml(readTree(editor))
    expect(xml).toContain('<h2>A Chat Turn</h2>')
    expect(xml).toContain('<mermaid>')
    expectReopens(editor)

    // Pasting into a non-empty document prepends cleanly without merging into the existing heading.
    const existing = open('## Existing Section\n\nExisting body')
    expect(pasteTextAtDocumentStart(existing, '**Prepended intro**\n\n- item')).toBe(true)
    expect(exportMarkdown(existing)).toBe('**Prepended intro**\n\n- item\n\n## Existing Section\n\nExisting body')
  })

  test('routes structural blocks pasted into the title field straight to the document body', () => {
    const split = splitPastedDocumentTitle('```mermaid\nstateDiagram-v2\n  [*] --> Ready\n```', {
      replaceAllTitle: true
    })
    expect(split).toEqual({
      title: '',
      body: '```mermaid\nstateDiagram-v2\n  [*] --> Ready\n```'
    })
    expect(splitPastedDocumentTitle('Plain single line', { replaceAllTitle: true })).toBeNull()
    expect(splitPastedDocumentTitle('# Clean Heading', { replaceAllTitle: true })).toEqual({
      title: 'Clean Heading',
      body: ''
    })
    expect(splitPastedDocumentTitle('# Heading\n\nBody paragraph', { replaceAllTitle: false })).toBeNull()
    expect(splitPastedDocumentTitle('Line one\nLine two')).toBeNull()
  })

  test('creates language-tagged code or diagram blocks for multi-line VS Code copies while Shift+Paste stays plain', () => {
    const tsxEditor = open('')
    pasteInto(tsxEditor, {
      'text/plain': 'export function Greeting() {\n  return <div>Hello</div>\n}\n',
      'text/html': monacoHtmlFromText('export function Greeting() {\n  return <div>Hello</div>\n}\n'),
      'vscode-editor-data': JSON.stringify({ version: 1, mode: 'typescriptreact' })
    })
    expect(tsxEditor.state.doc.content[0]!.type).toBe(T.CodeBlock.type)
    expect(tsxEditor.state.doc.content[0]!.mark(T.CodeBlockLanguage)).toBe('tsx')
    expect(exportMarkdown(tsxEditor)).toBe('```tsx\nexport function Greeting() {\n  return <div>Hello</div>\n}\n```')

    const shellEditor = open('')
    pasteInto(shellEditor, {
      'text/plain': '#!/usr/bin/env bash\necho "ok"',
      'text/html': monacoHtmlFromText('#!/usr/bin/env bash\necho "ok"'),
      'vscode-editor-data': JSON.stringify({ version: 1, mode: 'shellscript' })
    })
    expect(shellEditor.state.doc.content[0]!.mark(T.CodeBlockLanguage)).toBe('shell')

    const diagramEditor = open('')
    pasteInto(diagramEditor, {
      'text/plain': 'infographic compare-swot\n  data',
      'text/html': monacoHtmlFromText('infographic compare-swot\n  data'),
      'vscode-editor-data': JSON.stringify({ version: 1, mode: 'infographic' })
    })
    expect(diagramEditor.state.doc.content[0]!.type).toBe(InfographicBlock.type)

    // Knowledge mode downgrades InfographicBlock to <pre lang="infographic">.
    const knowledgeEditor = open('', knowledgeExtension)
    pasteInto(knowledgeEditor, {
      'text/plain': 'infographic compare-swot\n  data',
      'text/html': monacoHtmlFromText('infographic compare-swot\n  data'),
      'vscode-editor-data': JSON.stringify({ version: 1, mode: 'infographic' })
    })
    expect(knowledgeEditor.state.doc.content[0]!.type).toBe(T.CodeBlock.type)
    expect(knowledgeEditor.state.doc.content[0]!.mark(T.CodeBlockLanguage)).toBe('infographic')

    // Single-line VS Code copy inserts inline text without creating a code block.
    const inlineEditor = open('Call  now')
    select(inlineEditor, 6)
    pasteInto(inlineEditor, {
      'text/plain': 'computeTotal()',
      'text/html': monacoHtmlFromText('computeTotal()'),
      'vscode-editor-data': JSON.stringify({ version: 1, mode: 'typescript' })
    })
    expect(exportMarkdown(inlineEditor)).toBe('Call computeTotal() now')

    // Shift+Paste (plain = true) always inserts literal plain text without parsing Markdown.
    const plainEditor = open('')
    pasteInto(
      plainEditor,
      {
        'text/plain': '# Raw Heading\n\n**not bold**',
        'text/html': monacoHtmlFromText('# Raw Heading\n\n**not bold**'),
        'vscode-editor-data': JSON.stringify({ version: 1, mode: 'markdown' })
      },
      true
    )
    expect(plainEditor.state.doc.content[0]!.type).toBe(T.Paragraph.type)
    expect(printXml(readTree(plainEditor))).toBe('<page><p># Raw Heading</p><p>**not bold**</p></page>')

    // Pasting inside an existing code block keeps literal text even when clipboard carries Markdown.
    const inCodeEditor = open('```ts\nconst a = 1\n```')
    select(inCodeEditor)
    pasteInto(inCodeEditor, {
      'text/plain': '\n# Not a heading',
      'text/html': monacoHtmlFromText('\n# Not a heading'),
      'vscode-editor-data': JSON.stringify({ version: 1, mode: 'markdown' })
    })
    expect(exportMarkdown(inCodeEditor)).toBe('```ts\nconst a = 1\n# Not a heading\n```')
  })

  test('keeps fenced code, Mermaid, and math blocks closed at paste boundaries', () => {
    const editor = open('Before **after**')
    select(editor, 8) // right after "Before "
    pasteInto(editor, {
      'text/plain': '# Heading\n\n```mermaid\nstateDiagram-v2\n  [*] --> Active\n```'
    })
    expect(exportMarkdown(editor)).toBe(
      'Before Heading\n\n```mermaid\nstateDiagram-v2\n  [*] --> Active\n```\n\n**after**'
    )
  })

  test('converts standalone iframe embed snippets into preview <embed> blocks in doc mode', () => {
    const editor = open('')
    pasteInto(editor, {
      'text/plain':
        '<iframe width="560" height="315" src="https://www.youtube.com/embed/dQw4w9WgXcQ" title="Demo video" frameborder="0"></iframe>'
    })
    expect(printXml(readTree(editor))).toBe(
      '<page><embed height="315" href="https://www.youtube.com/embed/dQw4w9WgXcQ" title="Demo video" /></page>'
    )
  })

  test('leniently normalizes frontmatter, comments, autolinks, tasks, single-line math, HTML aliases, and placeholders', () => {
    const raw = [
      '---',
      'title: Architecture Notes',
      'tags:',
      '  - design',
      '---',
      '',
      '<!-- Leading comment stripped -->',
      '# Overview',
      '',
      'Contact <alice@example.com> or visit <https://en.wikipedia.org/wiki/Markdown_(markup)>.',
      '',
      'Placeholders like <id>, <botId>, and <路径> stay literal, while <b>bold</b>, <i>italic</i>, <del>old</del>, and <kbd>⌘K</kbd> map cleanly.',
      '',
      '[ ] Pending item',
      '[x] Completed item',
      '',
      '$$E = mc^2$$',
      '',
      'Inline $$x^2 + y^2$$ stays literal prose.',
      '',
      '<img src="https://example.com/diagram.png" width="480" alt="Diagram" />',
      '',
      '<details>',
      '<summary>More details</summary>',
      '',
      '### Nested Heading',
      '',
      'Body text\u0000.',
      '</details>'
    ].join('\n')

    const page = parsePastedMarkdown(raw, 'doc')
    expect(page).not.toBeNull()
    const xml = printXml(page!)
    const md = printMarkdown(page!)
    expect(md).toContain('# Overview')
    expect(md).not.toContain('Architecture Notes')
    expect(md).not.toContain('Leading comment')
    expect(xml).toContain('<a href="mailto:alice@example.com">alice@example.com</a>')
    expect(xml).toContain('<a href="https://en.wikipedia.org/wiki/Markdown_(markup)">')
    expect(md).toContain('\\<id>, \\<botId>, and \\<路径>')
    expect(md).toContain('**bold**, *italic*, ~~old~~, and `⌘K`')
    expect(md).toContain('- [ ] Pending item\n- [x] Completed item')
    expect(md).toContain('$$\nE = mc^2\n$$')
    expect(md).toContain('Inline \\$\\$x^2 + y^2\\$\\$ stays literal prose.')
    expect(md).toContain('![Diagram](https://example.com/diagram.png)')
    expect(md).toContain('### Nested Heading')

    // Also succeeds cleanly in Knowledge mode (downgrading <math> to <pre lang="math">).
    const knowledgePage = parsePastedMarkdown(raw, 'knowledge')
    expect(knowledgePage).not.toBeNull()
    expect(printXml(knowledgePage!)).toContain('<pre lang="math">E = mc^2</pre>')

    // Preserves horizontal rules when `---` is not YAML frontmatter.
    const withRule = parsePastedMarkdown('---\n\nParagraph text\n\n---', 'doc')
    expect(printMarkdown(withRule!)).toBe('---\n\nParagraph text\n\n---')

    // Recovers via tag-escaping fallback when a known tag is unclosed in wild prose.
    const unclosedKnownTag = parsePastedMarkdown('# Section\n\nIn HTML an unclosed <span> tag is literal.', 'doc')
    expect(printMarkdown(unclosedKnownTag!)).toBe('# Section\n\nIn HTML an unclosed \\<span> tag is literal.')
  })

  test('preserves literal code inside blockquote fences, nested list fences, and multi-line inline code spans', () => {
    const raw = [
      '> ```sh',
      '> echo $$',
      '> kill -0 $$',
      '> ```',
      '',
      '- Outer step',
      '  - Inner step',
      '    ```sh',
      '    echo $$',
      '    [x] not a task',
      '    $$not math$$',
      '    <div>literal html</div>',
      '    ```',
      '',
      '> $$',
      '> x + 1 = 2',
      '> $$',
      '',
      'Inline `first line\necho $$\n[x] literal` stays code.'
    ].join('\n')

    const page = parsePastedMarkdown(raw, 'doc')
    expect(page).not.toBeNull()
    const xml = printXml(page!)
    expect(xml).toContain('<blockquote><pre lang="sh">echo $$\nkill -0 $$</pre></blockquote>')
    expect(xml).toContain(
      '<pre lang="sh">echo $$\n[x] not a task\n$$not math$$\n&lt;div&gt;literal html&lt;/div&gt;</pre>'
    )
    expect(xml).toContain('<blockquote><math>x + 1 = 2</math></blockquote>')
    expect(xml).toContain('<code>first line echo $$ [x] literal</code>')
    expect(xml).not.toContain('\\$\\$')

    const editor = open('')
    pasteInto(editor, { 'text/plain': raw })
    expect(exportMarkdown(editor)).toContain('> ```sh\n> echo $$\n> kill -0 $$\n> ```')
    expectReopens(editor)
  })

  test('looksLikeMarkdown avoids false positives on currency, hashtags, unclosed fences, and shell scripts', () => {
    expect(looksLikeMarkdown('')).toBe(false)
    expect(looksLikeMarkdown('plain sentence without formatting')).toBe(false)
    expect(looksLikeMarkdown('-$187.55\t-$91.93\n-$2,222.97\t-$4,109.98')).toBe(false)
    expect(looksLikeMarkdown('It costs $10 or $20 today')).toBe(false)
    expect(looksLikeMarkdown('Issue #42 and #hashtag')).toBe(false)
    expect(looksLikeMarkdown('```\nunclosed code fence')).toBe(false)

    const shellScript = [
      '#!/usr/bin/env bash',
      'set -euo pipefail',
      '# Install packages',
      'apt-get update',
      ...Array.from({ length: 20 }, (_, idx) => `echo "step ${idx}"`)
    ].join('\n')
    expect(looksLikeMarkdown(shellScript, { fromPreWrapper: true })).toBe(false)
    expect(looksLikeMarkdown('# Heading 1')).toBe(true)
    expect(looksLikeMarkdown('- item 1\n- item 2')).toBe(true)
    expect(looksLikeMarkdown(lifecycleMarkdown, { fromPreWrapper: true })).toBe(true)
  })

  test('strips unsafe URL schemes and legacy HTML attributes before schema normalization on paste', () => {
    const pasted = parsePastedMarkdown(
      [
        '<table border="1" cellpadding="4"><tr><th>Col</th></tr><tr><td><a href="javascript:alert(1)">Unsafe</a></td></tr></table>',
        '',
        '<embed href="javascript:alert(1)" />',
        '',
        '<media src="data:text/html,<script>alert(1)</script>" />'
      ].join('\n'),
      'doc'
    )
    expect(pasted).not.toBeNull()
    const xml = printXml(pasted!)
    expect(xml).not.toContain('javascript:')
    expect(xml).not.toContain('data:text/html')
    expect(xml).toContain('<td><p>Unsafe</p></td>')
  })
})
