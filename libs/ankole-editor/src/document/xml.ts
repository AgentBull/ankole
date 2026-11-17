import { SaxesParser } from 'saxes'
import { normalizeTree } from './normalize'
import {
  checkSource,
  DocumentError,
  element,
  limits,
  text,
  TreeError,
  type DocumentErrorCode,
  type Element,
  type Node
} from './tree'

export function parseXml(source: string): Element {
  checkSource(source, 'xml')
  const parser = new SaxesParser({ xmlns: false, defaultXMLVersion: '1.0', forceXMLVersion: true })
  const positions = new WeakMap<Node, [number, number]>()
  const stack: Element[] = []
  let root: Element | undefined
  let count = 0
  const fail = (reason: string, fix: string, code: DocumentErrorCode) => {
    throw new DocumentError('xml', reason, Math.max(0, parser.position - 1), parser.position, fix, source, code)
  }
  const addText = (value: string) => {
    const parent = stack.at(-1)
    if (!parent) return
    const node = text(value)
    positions.set(node, [Math.max(0, parser.position - value.length), parser.position])
    parent.children.push(node)
  }
  parser.on('text', addText)
  parser.on('cdata', addText)
  parser.on('xmldecl', declaration => {
    if (declaration.version !== '1.0') {
      fail(
        'Only XML 1.0 is accepted',
        'Write <?xml version="1.0"?> or remove the declaration.',
        'unsupported_xml_version'
      )
    }
    if (declaration.encoding && !/^utf-8$/i.test(declaration.encoding)) {
      fail('The source encoding must be UTF-8', 'Remove encoding or set it to UTF-8.', 'invalid_encoding')
    }
  })
  parser.on('doctype', () =>
    fail('Pages do not allow a DOCTYPE declaration', 'Remove the DOCTYPE declaration.', 'unsupported_syntax')
  )
  parser.on('comment', () => fail('Pages do not have comment nodes', 'Remove this comment.', 'unsupported_syntax'))
  parser.on('processinginstruction', () =>
    fail('Pages do not allow processing instructions', 'Remove this processing instruction.', 'unsupported_syntax')
  )
  parser.on('opentag', tag => {
    if (++count > limits.nodes || stack.length > limits.depth) {
      fail(
        `The page exceeds ${limits.nodes} nodes or ${limits.depth} levels of nesting`,
        'Split the page into smaller pages.',
        'limit_exceeded'
      )
    }
    const node = element(tag.name, Object.fromEntries(Object.entries(tag.attributes)))
    positions.set(node, [Math.max(0, source.lastIndexOf(`<${tag.name}`, parser.position)), parser.position])
    if (stack.length) stack.at(-1)!.children.push(node)
    else root = node
    stack.push(node)
  })
  parser.on('closetag', () => {
    stack.pop()
  })
  parser.on('error', error =>
    fail(error.message.replace(/^\d+:\d+: /, ''), 'Correct this XML syntax.', 'invalid_tag_syntax')
  )
  parser.write(source).close()
  if (!root) {
    throw new DocumentError(
      'xml',
      'Missing <page> root element',
      0,
      0,
      'Wrap the page content in <page>.',
      source,
      'missing_root'
    )
  }
  try {
    return normalizeTree(root)
  } catch (error) {
    if (!(error instanceof TreeError)) throw error
    const [start, end] = (error.node && positions.get(error.node)) ?? [0, source.length]
    throw new DocumentError('xml', error.message, start, end, error.fix, source, error.code)
  }
}

const escapes: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  '\t': '&#9;',
  '\n': '&#10;',
  '\r': '&#13;'
}

export function xmlEscape(value: string, attribute = false): string {
  return value.replace(attribute ? /[&<>"\t\r\n]/g : /[&<>\r]/g, character => escapes[character]!)
}

export function printXml(tree: Element): string {
  return printNormalizedXml(normalizeTree(tree))
}

/** @internal The caller already validated and normalized this tree. */
export function printNormalizedXml(tree: Element): string {
  function print(node: Node): string {
    if (node.type === 'text') return xmlEscape(node.value)
    const attrs = Object.entries(node.attrs)
      .map(([key, value]) => ` ${key}="${xmlEscape(value, true)}"`)
      .join('')
    return node.children.length
      ? `<${node.name}${attrs}>${node.children.map(print).join('')}</${node.name}>`
      : `<${node.name}${attrs} />`
  }
  return print(tree)
}
