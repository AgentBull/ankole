import {
  checkAttributeName,
  checkCharacters,
  checkElementName,
  compareNames,
  element,
  limits,
  text,
  TreeError,
  type Element,
  type Node
} from './tree'
import { marks, ruleOf, type ElementRule, type Mark } from './vocabulary'

/*
 * The normal form keeps everything a reader can see and removes differences
 * that do not change the rendered page: attribute order, defaults, source line
 * breaks inside prose, white space at the edges of bold and italic text, empty
 * formats, and the nesting order of formats. Two trees with the same normal
 * form show the same page.
 */

const layout = /^[ \t\r\n]*$/
// A source line break disappears between these characters and becomes a space elsewhere.
const closeScript =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\u3000-\u303f\u30fc\ufe30-\ufe4f\uff00-\uffef]/u
const valueHints: Record<string, string> = {
  align: 'left、center、right 或 justify',
  indent: '1 到 999 的整数',
  start: '0 或不超过 9 位的正整数',
  task: 'todo 或 done',
  colspan: '1 到 9999 的整数',
  rowspan: '1 到 9999 的整数',
  tone: 'info 或 warning'
}
// Empty values of these attributes show nothing and equal a missing attribute.
const optionalText = new Set(['alt', 'lang', 'meta', 'style', 'title'])

type Count = { nodes: number }
type Atom = { value?: string; node?: Element; marks: Mark[]; style: string; link: Element | null }

export function normalizeTree(root: Element): Element {
  if (root?.type !== 'element' || root.name !== 'page') {
    throw new TreeError('根元素必须是 page', root, '请用 <page> 包住整页内容。')
  }
  return normalizeElement(root, undefined, 0, { nodes: 0 })
}

export const sameTree = (a: Element, b: Element) =>
  JSON.stringify(normalizeTree(a)) === JSON.stringify(normalizeTree(b))

function count(node: Node, depth: number, state: Count) {
  if (++state.nodes > limits.nodes || depth > limits.depth) {
    throw new TreeError(`页面超过 ${limits.nodes} 个节点或 ${limits.depth} 层嵌套`, node, '请把页面拆小。')
  }
}

function normalizeElement(node: Element, parent: Element | undefined, depth: number, state: Count): Element {
  count(node, depth, state)
  if (parent) {
    checkElementName(node.name, node)
    if (node.name === 'page') throw new TreeError('page 只能作为根元素', node, '请删除嵌套的 <page>。')
  }
  const rule = ruleOf(node.name)
  if (rule?.parents && !rule.parents.includes(parent?.name ?? '')) {
    throw new TreeError(
      `<${node.name}> 只能放在 ${rule.parents.map(name => `<${name}>`).join(' 或 ')} 里`,
      node,
      `请把 <${node.name}> 移到 ${rule.parents.map(name => `<${name}>`).join(' 或 ')} 中。`
    )
  }
  const attrs = normalizeAttributes(node, rule)
  const children = !rule
    ? unknownChildren(node, depth, state)
    : rule.content === 'text'
      ? textChildren(node, depth, state)
      : rule.content === 'empty'
        ? emptyChildren(node)
        : rule.content === 'inline'
          ? normalizeInline(node.children, node, depth, state)
          : blockChildren(node, rule.content, depth, state)
  return element(node.name, attrs, children)
}

function normalizeAttributes(node: Element, rule: ElementRule | undefined): Record<string, string> {
  const entries = Object.entries(node.attrs).sort(([a], [b]) => compareNames(a, b))
  if (node.name === 'page' && entries.length) throw new TreeError('page 没有属性', node, '页面标题等信息不写在正文里。')
  const kept: [string, string][] = []
  for (const [key, value] of entries) {
    checkAttributeName(key, node)
    checkCharacters(value, node)
    const known = rule && Object.hasOwn(rule.attributes, key)
    const pattern = known ? rule.attributes[key] : null
    if (pattern && !pattern.test(value)) {
      throw new TreeError(
        `<${node.name}> 的 ${key}="${value}" 不合法`,
        node,
        `${key} 的值应为 ${valueHints[key] ?? pattern.source}。`
      )
    }
    if (
      known &&
      ((optionalText.has(key) && value === '') ||
        (node.name === 'ol' && key === 'start' && value === '1') ||
        ((key === 'colspan' || key === 'rowspan') && value === '1'))
    ) {
      continue
    }
    kept.push([key, value])
  }
  for (const key of rule?.required ?? []) {
    if (!kept.some(([name]) => name === key)) {
      throw new TreeError(`<${node.name}> 缺少 ${key} 属性`, node, `请为 <${node.name}> 写上 ${key}。`)
    }
  }
  // Object.fromEntries keeps names such as __proto__ as ordinary attributes.
  return Object.fromEntries(kept)
}

function textChildren(node: Element, depth: number, state: Count): Node[] {
  let value = ''
  for (const child of node.children) {
    count(child, depth + 1, state)
    if (child.type === 'element') {
      throw new TreeError(`<${node.name}> 只能包含文字`, child, '请删除其中的元素，或改用代码文字。')
    }
    checkCharacters(child.value, child)
    value += child.value
  }
  return value ? [text(value)] : []
}

function emptyChildren(node: Element): Node[] {
  for (const child of node.children) {
    if (child.type === 'element' || child.value) {
      throw new TreeError(`<${node.name}> 是空元素`, child, `请把 <${node.name}> 写成 <${node.name} />。`)
    }
  }
  return []
}

function blockChildren(node: Element, content: 'blocks' | readonly string[], depth: number, state: Count): Node[] {
  const result: Element[] = []
  for (const child of node.children) {
    if (child.type === 'text') {
      checkCharacters(child.value, child)
      if (layout.test(child.value)) continue
      throw new TreeError(
        `<${node.name}> 中的文字必须放在块元素里`,
        child,
        Array.isArray(content) ? `请用 <${content[0]}> 包住这段文字。` : '请用 <p> 包住这段文字。'
      )
    }
    if (Array.isArray(content) && !content.includes(child.name)) {
      // A wrapper such as <tbody> holds allowed children. The repair removes the wrapper.
      const wrapper = child.children.some(
        grandchild => grandchild.type === 'element' && content.includes(grandchild.name)
      )
      throw new TreeError(
        `<${node.name}> 只能包含 ${content.map(name => `<${name}>`).join('、')}`,
        child,
        wrapper
          ? `请去掉 <${child.name}> 标签，把其中的元素直接放在 <${node.name}> 里。`
          : `请把 <${child.name}> 移出 <${node.name}>。`
      )
    }
    if (content === 'blocks' && ruleOf(child.name)?.kind === 'inline') {
      throw new TreeError(`<${child.name}> 是行内元素，不能直接放在 <${node.name}> 里`, child, `请把它放进 <p>。`)
    }
    const normalized = normalizeElement(child, node, depth + 1, state)
    // A list without items shows nothing.
    if ((normalized.name === 'ul' || normalized.name === 'ol') && !normalized.children.length) continue
    result.push(normalized)
  }
  return mergeLists(result)
}

// Adjacent lists of the same kind form one list, as in a block editor. The list keeps
// the attributes of both lists and the start of the first.
function mergeLists(blocks: Element[]): Element[] {
  const merged: Element[] = []
  for (const block of blocks) {
    const previous = merged.at(-1)
    if (!previous || (block.name !== 'ul' && block.name !== 'ol') || previous.name !== block.name) {
      merged.push(block)
      continue
    }
    const { start: _, ...attrs } = block.attrs
    for (const [key, value] of Object.entries(attrs)) {
      if (Object.hasOwn(previous.attrs, key) && previous.attrs[key] !== value) {
        throw new TreeError(
          `相邻的两个 <${block.name}> 的属性 ${key} 不同`,
          block,
          `请把两个列表的 ${key} 改成相同的值，或在两个列表之间加一个段落。`
        )
      }
    }
    previous.attrs = Object.fromEntries(
      Object.entries({ ...attrs, ...previous.attrs }).sort(([a], [b]) => compareNames(a, b))
    )
    previous.children.push(...block.children)
  }
  return merged
}

function unknownChildren(node: Element, depth: number, state: Count): Node[] {
  const children = node.children.filter(child => child.type === 'element' || child.value !== '')
  const inline = children.some(child =>
    child.type === 'text' ? !layout.test(child.value) : ruleOf(child.name)?.kind === 'inline'
  )
  const block = children.some(child => child.type === 'element' && ruleOf(child.name)?.kind === 'block')
  if (inline && block) {
    throw new TreeError(`<${node.name}> 不能同时包含块元素和行内内容`, node, '请把行内内容放进 <p>，或把块元素移出。')
  }
  if (block) return blockChildren(node, 'blocks', depth, state)
  // Line breaks between child elements only lay out the source.
  if (
    !inline &&
    children.some(child => child.type === 'element') &&
    children.every(child => child.type === 'element' || /[\r\n]/.test(child.value))
  ) {
    return children.flatMap(child =>
      child.type === 'element' ? [normalizeElement(child, node, depth + 1, state)] : []
    )
  }
  return normalizeInline(children, node, depth, state)
}

function normalizeInline(nodes: Node[], container: Element, depth: number, state: Count): Node[] {
  const atoms: Atom[] = []
  flatten(nodes, { marks: [], style: '', link: null }, atoms, container, depth + 1, state)
  convertLineBreaks(atoms)
  return rebuild(merge(splitEmphasisSpace(atoms)))
}

function flatten(
  nodes: Node[],
  context: Omit<Atom, 'value' | 'node'>,
  atoms: Atom[],
  container: Element,
  depth: number,
  state: Count
) {
  for (const child of nodes) {
    if (child.type === 'text') {
      count(child, depth, state)
      checkCharacters(child.value, child)
      if (child.value) atoms.push({ ...context, value: child.value })
      continue
    }
    checkElementName(child.name, child)
    const rule = ruleOf(child.name)
    if (rule?.kind === 'block') {
      throw new TreeError(
        `<${child.name}> 是块元素，不能放在行内内容里`,
        child,
        '请把它移到段落之外；在 Markdown 中让它单独成行，并用空行与文字隔开。'
      )
    }
    const plain = Object.keys(child.attrs).length === 0
    if (rule && plain && (marks as readonly string[]).includes(child.name)) {
      count(child, depth, state)
      const name = child.name as Mark
      const merged = context.marks.includes(name)
        ? context.marks
        : marks.filter(mark => mark === name || context.marks.includes(mark))
      flatten(child.children, { ...context, marks: merged }, atoms, container, depth + 1, state)
    } else if (child.name === 'span' && Object.keys(child.attrs).every(key => key === 'style')) {
      count(child, depth, state)
      const style = child.attrs.style ?? ''
      checkCharacters(style, child)
      flatten(
        child.children,
        { ...context, style: joinStyle(context.style, style) },
        atoms,
        container,
        depth + 1,
        state
      )
    } else if (child.name === 'a') {
      count(child, depth, state)
      if (context.link) throw new TreeError('链接不能嵌套', child, '请删除内层链接。')
      const link = element('a', normalizeAttributes(child, rule))
      const inner: Atom[] = []
      flatten(child.children, { ...context, link }, inner, container, depth + 1, state)
      if (inner.length) atoms.push(...inner)
      else atoms.push({ ...context, node: link })
    } else if (child.name === 'br' || child.name === 'img') {
      atoms.push({ marks: [], style: '', link: context.link, node: normalizeElement(child, container, depth, state) })
    } else {
      atoms.push({ ...context, node: normalizeElement(child, container, depth, state) })
    }
  }
}

function joinStyle(outer: string, inner: string): string {
  if (!outer.trim()) return inner
  if (!inner.trim()) return outer
  return `${outer}${/;\s*$/.test(outer) ? '' : ';'} ${inner}`
}

// A line break in the source of prose is a soft break. It becomes a space,
// except between Chinese or Japanese characters, after a hard break and at
// the edges of the text. Code keeps one space for each break.
function convertLineBreaks(atoms: Atom[]) {
  atoms.forEach((atom, index) => {
    if (atom.value === undefined || !/[\r\n]/.test(atom.value)) return
    if (atom.marks.includes('code')) {
      atom.value = atom.value.replace(/\r\n|\r|\n/g, ' ')
      return
    }
    atom.value = atom.value.replace(/[ \t]*(?:\r\n|\r|\n)[ \t\r\n]*/g, (match, offset: number, whole: string) => {
      const before = neighbour(atoms, index, whole.slice(0, offset), -1)
      const after = neighbour(atoms, index, whole.slice(offset + match.length), 1)
      return before === null || after === null || (closeScript.test(before) && closeScript.test(after)) ? '' : ' '
    })
  })
}

// White space is visible in code, underlined, struck and highlighted text.
const decorated = (atom: Atom) =>
  atom.marks.some(mark => mark === 'code' || mark === 'u' || mark === 's' || mark === 'mark')

function neighbour(atoms: Atom[], index: number, own: string, direction: 1 | -1): string | null {
  const edge = (value: string, spaceVisible: boolean) => {
    const characters = [...(spaceVisible ? value : value.replace(/[ \t\r\n]/g, ''))]
    return direction < 0 ? characters.at(-1) : characters[0]
  }
  const found = edge(own, false)
  if (found) return found
  for (let i = index + direction; i >= 0 && i < atoms.length; i += direction) {
    const atom = atoms[i]!
    if (atom.node) return atom.node.name === 'br' ? null : 'x'
    const character = edge(atom.value ?? '', decorated(atom))
    if (character) return character
  }
  return null
}

// White space looks the same in bold or italic. Keep it outside the emphasis.
function splitEmphasisSpace(atoms: Atom[]): Atom[] {
  return atoms.flatMap(atom => {
    if (
      atom.value === undefined ||
      atom.marks.includes('code') ||
      !(atom.marks.includes('strong') || atom.marks.includes('em'))
    ) {
      return [atom]
    }
    const plain = atom.marks.filter(mark => mark !== 'strong' && mark !== 'em')
    const [, lead = '', body = '', trail = ''] = /^(\s*)([\s\S]*?)(\s*)$/u.exec(atom.value)!
    return [
      ...(lead ? [{ ...atom, value: lead, marks: plain }] : []),
      ...(body ? [{ ...atom, value: body }] : []),
      ...(trail ? [{ ...atom, value: trail, marks: plain }] : [])
    ]
  })
}

const sameLink = (a: Element | null, b: Element | null) =>
  a === b || (!!a && !!b && JSON.stringify(a.attrs) === JSON.stringify(b.attrs))

function merge(atoms: Atom[]): Atom[] {
  const merged: Atom[] = []
  for (const atom of atoms) {
    if (atom.value === '') continue
    const previous = merged.at(-1)
    if (
      previous?.value !== undefined &&
      atom.value !== undefined &&
      previous.style === atom.style &&
      sameLink(previous.link, atom.link) &&
      previous.marks.join() === atom.marks.join()
    ) {
      previous.value += atom.value
    } else merged.push({ ...atom })
  }
  return merged
}

type Unit = { atoms: Atom[]; link: Element | null }

// Styles are outermost. A format then wraps the longest run of units, across
// links and across white space inside bold or italic text. Code is innermost.
function rebuild(atoms: Atom[]): Node[] {
  const result: Node[] = []
  for (let i = 0; i < atoms.length;) {
    const style = atoms[i]!.style
    let end = i + 1
    while (end < atoms.length && atoms[end]!.style === style) end++
    const content = formatted(units(atoms.slice(i, end)), [])
    if (style) result.push(element('span', { style }, content))
    else result.push(...content)
    i = end
  }
  return result
}

// A unit is one atom, or all atoms of one link.
function units(atoms: Atom[]): Unit[] {
  const result: Unit[] = []
  for (const atom of atoms) {
    const previous = result.at(-1)
    if (atom.link && previous?.link && sameLink(previous.link, atom.link)) previous.atoms.push(atom)
    else result.push({ atoms: [atom], link: atom.link })
  }
  return result
}

const spaceNeutral = (mark: Mark) => mark === 'strong' || mark === 'em'
const blank = (atom: Atom) => atom.value !== undefined && /^\s+$/u.test(atom.value)
const has = (unit: Unit, mark: Mark) =>
  unit.atoms.some(atom => atom.marks.includes(mark)) &&
  unit.atoms.every(atom => atom.marks.includes(mark) || (spaceNeutral(mark) && blank(atom)))

function runEnd(list: Unit[], start: number, mark: Mark): number {
  let last = start + 1
  for (let end = start + 1; end < list.length; end++) {
    if (has(list[end]!, mark)) last = end + 1
    else if (!(spaceNeutral(mark) && list[end]!.atoms.every(blank))) break
  }
  return last
}

function formatted(list: Unit[], applied: Mark[]): Node[] {
  const result: Node[] = []
  for (let i = 0; i < list.length;) {
    let best: Mark | undefined
    let bestEnd = i
    for (const mark of marks) {
      if (mark === 'code' || applied.includes(mark) || !has(list[i]!, mark)) continue
      const end = runEnd(list, i, mark)
      if (end > bestEnd) {
        best = mark
        bestEnd = end
      }
    }
    const node = best
      ? element(best, {}, formatted(list.slice(i, bestEnd), [...applied, best]))
      : leaf(list[i]!, applied)
    const previous = result.at(-1)
    if (node.type === 'text' && previous?.type === 'text') previous.value += node.value
    else result.push(node)
    i = best ? bestEnd : i + 1
  }
  return result
}

function leaf(unit: Unit, applied: Mark[]): Node {
  if (unit.link) {
    return element(
      'a',
      unit.link.attrs,
      formatted(
        unit.atoms.map(atom => ({ atoms: [atom], link: null })),
        applied
      )
    )
  }
  const atom = unit.atoms[0]!
  const base = atom.node ?? text(atom.value!)
  return atom.marks.includes('code') ? element('code', {}, [base]) : base
}
