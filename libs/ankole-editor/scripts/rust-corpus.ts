/** Golden XML and local edit batches for the Rust document port. */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import fc from 'fast-check'
import { ChangeSet, Leaf, type Node } from '../src/core/doc'
import { Transaction, type GardState } from '../src/core/state'
import { Strong } from '../src/core/types'
import { parseMarkdown } from '../src/document/markdown'
import { DocumentError, limits } from '../src/document/tree'
import { parseXml, printXml } from '../src/document/xml'
import { pageDocument, readTree } from '../src/editor/convert'
import { headlessState } from '../src/editor/extension'
import { preparePageUpdate } from '../src/editor/page-update'
import { schema } from '../src/editor/schema'
import { page as generatedPage } from '../test/arbitrary'

export type EditSample = {
  name: string
  initialXml: string
  initialDocument: Node.JSON
  batches: { clientSeq: number; changes: ChangeSet.JSON }[]
  steps: { xml: string; document: Node.JSON }[]
}

type XmlSample = { name: string; xml: string; canonicalXml: string; document: Node.JSON }
export type Boundary = {
  name: string
  parts: { text: string; count: number }[]
  error: string | null
}
export type Corpus = {
  format: 2
  seed: number
  limits: typeof limits
  xml: XmlSample[]
  invalid: { name: string; xml: string; error: string }[]
  boundaries: Boundary[]
  edits: EditSample[]
}

const directory = fileURLToPath(new URL('../corpus/rust/', import.meta.url))
const corpusFile = fileURLToPath(new URL('../corpus/rust/index.json', import.meta.url))
const defaultSeed = 20261005

export function boundarySource(boundary: Boundary): string {
  return boundary.parts.map(part => part.text.repeat(part.count)).join('')
}

export function parseError(xml: string): string | null {
  try {
    parseXml(xml)
    return null
  } catch (error) {
    if (!(error instanceof DocumentError)) throw error
    return error.message
  }
}

function sample(name: string, xml: string): XmlSample {
  const doc = pageDocument(parseXml(xml))
  return { name, xml, canonicalXml: printXml(readTree(doc)), document: doc.toJSON() }
}

export type Operation = {
  kind: 'insert' | 'replace' | 'delete' | 'mark' | 'unmark' | 'paragraph' | 'remove-block'
  target: number
  offset: number
  width: number
  text: string
}

export const editBatches = fc.array(
  fc.array(
    fc.record({
      kind: fc.constantFrom<Operation['kind']>(
        'insert',
        'replace',
        'delete',
        'mark',
        'unmark',
        'paragraph',
        'remove-block'
      ),
      target: fc.nat(100),
      offset: fc.nat(100),
      width: fc.integer({ min: 1, max: 6 }),
      text: fc.constantFrom('x', '中文', '🙂', 'é', '👩‍💻', 'ع', '&<>', ' ', '\n', '\r\n', '\ud83d', '\u0001')
    }),
    { minLength: 1, maxLength: 4 }
  ),
  { minLength: 2, maxLength: 12 }
)

/** Each batch can contain several local operations; normalize only its final transaction. */
export function editChain(name: string, initialXml: string, batches: readonly (readonly Operation[])[]): EditSample {
  let state = headlessState(parseXml(initialXml))
  const initial = printXml(readTree(state.doc))
  const result: EditSample = {
    name,
    initialXml: initial,
    initialDocument: state.doc.toJSON(),
    batches: [],
    steps: []
  }
  for (const [index, operations] of batches.entries()) {
    let changes = ChangeSet.empty(state.doc.length)
    for (const [operationIndex, operation] of operations.entries()) {
      const transactions = operationUpdates(state, operation)
      for (const [transactionIndex, transaction] of transactions.entries()) {
        const last = operationIndex === operations.length - 1 && transactionIndex === transactions.length - 1
        const prepared = last ? preparePageUpdate(transaction) : transaction
        changes = changes.compose(prepared.changes)
        state = prepared.state
      }
    }
    result.batches.push({ clientSeq: index + 1, changes: changes.toJSON() })
    result.steps.push({ xml: printXml(readTree(state.doc)), document: state.doc.toJSON() })
  }
  return result
}

function operationUpdates(state: GardState, operation: Operation): readonly Transaction[] {
  const texts: { pos: number; text: string }[] = []
  state.doc.iterate((node, pos) => {
    if (node.isText) texts.push({ pos, text: node.param as string })
    else if (node.isPlot && node.isTextblock && !node.content.length) texts.push({ pos: pos + 1, text: '' })
  })
  const text = texts[operation.target % texts.length]
  let change: ChangeSet.Change
  if (operation.kind === 'remove-block' && state.doc.content.length > 1) {
    const at = operation.target % state.doc.content.length
    const from = state.doc.content.slice(0, at).reduce((pos, node) => pos + node.length, 0)
    change = { from, to: from + state.doc.content[at]!.length }
  } else if (operation.kind === 'paragraph' || !text) {
    change = { from: state.doc.length, insert: pageDocument(parseXml('<page><p>added</p></page>')).content }
  } else {
    // Positions are UTF-16 offsets. Keep each generated operation on a code point boundary.
    const offsets = [0]
    for (const character of text.text) offsets.push(offsets.at(-1)! + character.length)
    const start = operation.offset % offsets.length
    const end = Math.min(start + operation.width, offsets.length - 1)
    const from = text.pos + offsets[start]!
    const to = text.pos + offsets[end]!
    switch (operation.kind) {
      case 'mark':
        change = { from, to, add: Strong }
        break
      case 'unmark':
        change = { from, to, remove: Strong }
        break
      case 'delete':
        change = { from, to }
        break
      default:
        change = {
          from,
          to: operation.kind === 'replace' ? to : from,
          insert: [Leaf.text(operation.text)]
        }
    }
  }
  return Transaction.append(state.update({ changes: change }))
}

/** Replay every batch both in memory and through persisted XML, and compare at every step. */
export function verifyChain(sample: EditSample): void {
  let doc = pageDocument(parseXml(sample.initialXml))
  let xml = sample.initialXml
  if (JSON.stringify(doc.toJSON()) !== JSON.stringify(sample.initialDocument)) {
    throw new Error(`${sample.name}: initial document differs`)
  }
  for (const [index, batch] of sample.batches.entries()) {
    const changes = ChangeSet.fromJSON(schema, batch.changes)
    doc = changes.apply(doc)
    const stored = changes.apply(pageDocument(parseXml(xml)))
    xml = printXml(readTree(stored))
    const expected = sample.steps[index]!
    if (
      !doc.eq(stored) ||
      !doc.eq(pageDocument(parseXml(xml))) ||
      xml !== expected.xml ||
      JSON.stringify(doc.toJSON()) !== JSON.stringify(expected.document)
    ) {
      throw new Error(`${sample.name}: replay differs at batch ${index + 1}`)
    }
  }
}

function boundaries(): Boundary[] {
  const part = (text: string, count = 1) => ({ text, count })
  const result: Boundary[] = []
  for (const extra of [0, 1]) {
    const sourceCount = limits.source - '<page><pre></pre></page>'.length + extra
    for (const [name, parts] of [
      ['source', [part('<page><pre>'), part('a', sourceCount), part('</pre></page>')]],
      [
        'source-unicode',
        [
          part('<page><pre>'),
          part('🙂', Math.floor(sourceCount / 2)),
          part('a', sourceCount % 2),
          part('</pre></page>')
        ]
      ],
      ['nodes', [part('<page>'), part('<p />', limits.nodes - 1 + extra), part('</page>')]],
      [
        'depth',
        [
          part('<page>'),
          part('<blockquote>', limits.depth - 2 + extra),
          part('<p>a</p>'),
          part('</blockquote>', limits.depth - 2 + extra),
          part('</page>')
        ]
      ]
    ] as const) {
      const boundary: Boundary = { name: name + (extra ? '-over' : '-at'), parts: [...parts], error: null }
      boundary.error = parseError(boundarySource(boundary))
      if (Boolean(boundary.error) !== Boolean(extra)) throw new Error(`${boundary.name}: wrong limit outcome`)
      result.push(boundary)
    }
  }
  return result
}

export function buildCorpus(seed = defaultSeed): Corpus {
  const xml = [
    sample('prose-and-formats', printXml(parseMarkdown('# 标题\n\n收入 **17%**，有 *强调* 和 ~~删除~~。'))),
    sample(
      'page-and-asset-addresses',
      printXml(
        parseMarkdown(
          '[目标](ankole:page/019a2b00-0000-7000-8000-000000000001)\n\n![图](ankole:asset/3f786850e387550fdab836ed7e6dc881de23001b/chart.png)'
        )
      )
    ),
    sample('table-and-task-list', printXml(parseMarkdown('| a | b |\n| :- | -: |\n| 1 | 2 |\n\n- [ ] 核对\n- 补充'))),
    sample(
      'unknown-and-embed',
      '<page><future layout="calendar" source="import"><p>kept</p></future><p align="center" source="manual">居中</p><embed ref="db_q3" table="tbl_sales" view="viw_march" /></page>'
    ),
    sample(
      'code-unicode-and-breaks',
      '<page><pre lang="ts" meta="title=x">const x = 1\nconst y = 2</pre><p>🙂é👩‍💻中<br />ع</p></page>'
    ),
    sample(
      'comment-anchors',
      '<page><p><comment ids="019a2b00-0000-7000-8000-000000000002 019a2b00-0000-7000-8000-000000000001"><strong>First</strong> 🙂<br /><img src="asset" /></comment> tail</p></page>'
    ),
    sample(
      'code-comment-anchors',
      '<page><pre lang="ts">a<comment ids="019a2b00-0000-7000-8000-000000000001">b\n  c</comment>d</pre></page>'
    ),
    sample(
      'rich-resources',
      '<page><h6>Section</h6><media kind="video" src="ankole:asset/movie.mp4" mime="video/mp4" title="Movie" /><bookmark src="https://example.com/" view="card" title="Example" description="Description" /><embed href="https://www.figma.com/design/example" /><callout tone="success" icon="✅"><p>Ready</p></callout></page>'
    ),
    sample('callout', '<page><callout tone="warning"><p>本期包含新增产品。</p></callout></page>'),
    sample(
      'nested-blocks',
      '<page><block><h2>Parent</h2><block><p>Child</p><p>Grandchild</p></block><ul><li><p>Item</p></li></ul></block><block><p>Leaf parent</p></block></page>'
    ),
    sample(
      'columns',
      '<page><columns><column width="1200"><p>Left</p></column><column width="800"><block><p>Parent</p><p>Child</p></block></column></columns><columns><column/><column width="1000"><p>Full width</p></column></columns></page>'
    ),
    sample(
      'raw-inline-normalization',
      '<page><p>中\n文 <strong> a <em>b</em> </strong><span style="color:red"><span style="font-size:12px">x</span></span><br />\nnext</p></page>'
    ),
    sample(
      'raw-list-and-attributes',
      '<page><ol start="1"><li><p z="2" a="1">a</p></li></ol><ol start="5"><li><p>b</p></li></ol><p><img src="image" alt="" /></p></page>'
    ),
    sample(
      'xml-entities-and-cdata',
      '<?xml version="1.0" encoding="UTF-8"?><page><p a="x&#9;y">&amp;&lt;<![CDATA[汉字]]>&#x1F642;</p></page>'
    ),
    sample('formula', '<page><math source="manual">E = mc^2</math></page>'),
    sample('empty-formula', '<page><math></math></page>'),
    sample('mermaid', '<page><mermaid>flowchart TD\n  A[开始] --&gt; B[结束]</mermaid></page>'),
    sample('mermaid-view-theme', '<page><mermaid view="code" theme="dark">flowchart LR\n  X --&gt; Y</mermaid></page>'),
    sample('empty-mermaid', '<page><mermaid></mermaid></page>'),
    sample(
      'code-wrap-and-formula',
      '<page><pre lang="js" wrap="true">const x = 1</pre><math>\\frac{a}{b}</math></page>'
    ),
    sample(
      'mentions-and-marks',
      '<page><p>详见 <mention page="019a2b00-0000-7000-8000-000000000001" />，由 <strong><mention principal="019a2b00-0000-7000-8000-000000000099" source="import" /> 跟进</strong>。</p><p><a href="https://example.com">前缀 <mention page="019a2b00-0000-7000-8000-000000000002" /> 后缀</a></p><p><comment ids="019a2b00-0000-7000-8000-000000000003"><mention principal="019a2b00-0000-7000-8000-000000000088" /></comment></p></page>'
    )
  ]
  const invalid = [
    ['wrong-root', '<doc><p>a</p></doc>'],
    ['unclosed-element', '<page><p>a</page>'],
    ['stray-close', '<page><p>a</p></p></page>'],
    ['missing-attribute-value', '<page><p align>a</p></page>'],
    ['duplicate-attribute', '<page><p align="left" align="right">a</p></page>'],
    ['invalid-child', '<page><p><td>a</td></p></page>'],
    ['invalid-tone', '<page><callout tone="invalid"><p>a</p></callout></page>'],
    ['missing-href', '<page><p><a>a</a></p></page>'],
    ['missing-src', '<page><p><img alt="a" /></p></page>'],
    ['embed-content', '<page><embed>a</embed></page>'],
    ['root-text', '<page>text</page>'],
    ['doctype', '<!DOCTYPE page><page><p>a</p></page>'],
    ['comment', '<!-- note --><page><p>a</p></page>'],
    ['xml-version', '<?xml version="1.1"?><page />'],
    ['xml-encoding', '<?xml version="1.0" encoding="UTF-16"?><page />'],
    ['late-declaration', ' <?xml version="1.0"?><page />'],
    ['processing-instruction', '<?task x?><page />'],
    ['unknown-entity', '<page><p>&unknown;</p></page>'],
    ['invalid-character-reference', '<page><p>&#0;</p></page>'],
    ['multiple-roots', '<page /><page />'],
    ['xml-invalid-element-name', '<page><p² /></page>'],
    ['xml-invalid-attribute-name', '<page><future a²="1" /></page>'],
    ['namespaced-name', '<page><x:y /></page>'],
    ['unescaped-attribute-less-than', '<page><p data="<" /></page>'],
    ['cdata-terminator-in-text', '<page><p>]]></p></page>'],
    ['math-element', '<page><math><strong>E</strong></math></page>'],
    ['invalid-wrap', '<page><pre wrap="wrap">a</pre></page>'],
    ['mermaid-element', '<page><mermaid><strong>a</strong></mermaid></page>'],
    ['invalid-mermaid-view', '<page><mermaid view="split">a</mermaid></page>'],
    ['mention-missing-target', '<page><p><mention /></p></page>'],
    ['mention-both-targets', '<page><p><mention page="p1" principal="u1" /></p></page>'],
    ['mention-empty-page', '<page><p><mention page="" /></p></page>'],
    ['mention-content', '<page><p><mention page="p1">text</mention></p></page>'],
    ['mention-block-level', '<page><mention page="p1" /></page>']
  ].map(([name, xml]) => {
    const error = parseError(xml!)
    if (!error) throw new Error(`${name}: source must fail`)
    return { name: name!, xml: xml!, error }
  })

  const fixedOperations: Operation[] = [
    { kind: 'insert', target: 0, offset: 1, width: 1, text: '中' },
    { kind: 'mark', target: 0, offset: 0, width: 2, text: '' },
    { kind: 'replace', target: 0, offset: 1, width: 1, text: '🙂' },
    { kind: 'unmark', target: 0, offset: 0, width: 1, text: '' },
    { kind: 'delete', target: 1, offset: 0, width: 1, text: '' },
    { kind: 'paragraph', target: 0, offset: 0, width: 1, text: '' },
    { kind: 'insert', target: 2, offset: 1, width: 1, text: 'ع' },
    { kind: 'remove-block', target: 1, offset: 0, width: 1, text: '' }
  ]
  const fixedBatches = [
    fixedOperations.slice(0, 2),
    fixedOperations.slice(2, 4),
    fixedOperations.slice(4, 6),
    fixedOperations.slice(6)
  ]
  const edits = [
    editChain(
      'comment-anchors',
      '<page><p><comment ids="019a2b00-0000-7000-8000-000000000001">First paragraph</comment></p><pre><comment ids="019a2b00-0000-7000-8000-000000000002">code\n  next</comment></pre></page>',
      fixedBatches
    ),
    editChain('text-and-marks', '<page><p>plain text</p><p>other</p></page>', fixedBatches),
    editChain(
      'table-cells',
      '<page><table><tr><th><p>header</p></th></tr><tr><td><p>123</p></td></tr></table></page>',
      fixedBatches
    ),
    editChain(
      'columns',
      '<page><columns><column width="1200"><p>Left</p><p>Second</p></column><column width="800"><p>Right</p></column></columns><p>After</p></page>',
      fixedBatches
    ),
    editChain('unicode', '<page><p>🙂é👩‍💻中</p><p>ع</p></page>', fixedBatches),
    editChain(
      'nested-blocks',
      '<page><block><p>Parent</p><block><p>Child</p><p>Grandchild</p></block></block><p>After</p></page>',
      fixedBatches
    ),
    editChain(
      'unknown-and-embed',
      '<page><future x="1">kept</future><p>before</p><embed ref="r" table="t" view="v" /><p>after</p></page>',
      fixedBatches
    )
  ]
  for (const [index, [tree, editsForPage]] of fc
    .sample(fc.tuple(generatedPage, editBatches), { seed, numRuns: 8 })
    .entries()) {
    const source = printXml(tree)
    xml.push(sample(`generated-${index}`, source))
    edits.push(editChain(`generated-${index}-seed-${seed}`, source, editsForPage))
  }
  return { format: 2, seed, limits, xml, invalid, boundaries: boundaries(), edits }
}

export function readCorpus(): Corpus {
  return JSON.parse(readFileSync(corpusFile, 'utf8')) as Corpus
}

if (import.meta.main) {
  if (process.argv.at(-1) !== '--write') throw new Error('Use generate:corpus to update the golden file')
  const corpus = buildCorpus(process.env.FC_SEED ? Number(process.env.FC_SEED) : defaultSeed)
  mkdirSync(directory, { recursive: true })
  writeFileSync(corpusFile, `${JSON.stringify(corpus, null, 2)}\n`)
  console.warn(`Corpus: ${corpus.xml.length} pages, ${corpus.edits.length} local edit chains`)
}
