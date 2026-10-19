import { SaxesParser } from 'saxes'
import { normalizeTree } from './normalize'
import { checkSource, DocumentError, element, limits, text, TreeError, type Element, type Node } from './tree'

export function parseXml(source: string): Element {
  checkSource(source, 'xml')
  const parser = new SaxesParser({ xmlns: false, defaultXMLVersion: '1.0', forceXMLVersion: true })
  const positions = new WeakMap<Node, [number, number]>()
  const stack: Element[] = []
  let root: Element | undefined
  let count = 0
  const fail = (reason: string, fix: string) => {
    throw new DocumentError('xml', reason, Math.max(0, parser.position - 1), parser.position, fix, source)
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
    if (declaration.version !== '1.0') fail('只支持 XML 1.0', '请写 <?xml version="1.0"?> 或删除声明。')
    if (declaration.encoding && !/^utf-8$/i.test(declaration.encoding)) {
      fail('源码编码必须是 UTF-8', '请删除 encoding 或写 UTF-8。')
    }
  })
  parser.on('doctype', () => fail('页面不支持 DOCTYPE', '请删除 DOCTYPE。'))
  parser.on('comment', () => fail('页面没有注释节点', '请删除这段注释。'))
  parser.on('processinginstruction', () => fail('页面不支持处理指令', '请删除这段指令。'))
  parser.on('opentag', tag => {
    if (++count > limits.nodes || stack.length > limits.depth) {
      fail(`页面超过 ${limits.nodes} 个节点或 ${limits.depth} 层嵌套`, '请把页面拆小。')
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
  parser.on('error', error => fail(error.message.replace(/^\d+:\d+: /, ''), '请修正这处 XML 语法。'))
  parser.write(source).close()
  if (!root) throw new DocumentError('xml', '缺少 page 根元素', 0, 0, '请用 <page> 包住整页内容。', source)
  try {
    return normalizeTree(root)
  } catch (error) {
    if (!(error instanceof TreeError)) throw error
    const [start, end] = (error.node && positions.get(error.node)) ?? [0, source.length]
    throw new DocumentError('xml', error.message, start, end, error.fix, source)
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

function xmlEscape(value: string, attribute = false): string {
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
