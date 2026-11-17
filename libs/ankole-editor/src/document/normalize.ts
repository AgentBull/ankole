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
import { commentIDs } from './comments'
import { parseEmbedProps } from './embed-props'

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
  align: 'left, center, right, or justify',
  indent: 'an integer from 1 to 999',
  start: '0 or a positive integer of at most 9 digits',
  task: 'todo or done',
  colspan: 'an integer from 1 to 9999',
  rowspan: 'an integer from 1 to 9999',
  width: 'an integer from 1 to 9999',
  height: 'an integer from 160 to 1600',
  tone: 'info, warning, success, danger, or neutral',
  wrap: 'true',
  view: 'both, code, or diagram',
  theme: 'auto, light, or dark',
  page: 'a non-empty page ID',
  principal: 'a non-empty principal UID'
}
// Empty values of these attributes show nothing and equal a missing attribute.
const optionalText = new Set(['alt', 'lang', 'meta', 'style', 'title'])

// A style keeps only declarations that change the look of text in place. Others, such as
// `position: fixed`, could cover the page for every reader.
const keptStyles = new Set(['color', 'background-color', 'text-transform'])

export function keptStyle(style: string): string {
  // A CSS comment, closed or open to the end, is not part of a declaration name. An open comment
  // would hide a style joined after it, so a style with one is rewritten.
  let open = false
  const declarations = style
    .replace(/\/\*[\s\S]*?(\*\/|$)/g, (_, close: string) => ((open ||= !close), ''))
    .split(';')
    .filter(declaration => declaration.trim())
  const kept = declarations.filter(declaration =>
    keptStyles.has(/^\s*([a-z-]+)\s*:/i.exec(declaration)?.[1]!.toLowerCase() ?? '')
  )
  return kept.length === declarations.length && !open ? style : kept.map(declaration => declaration.trim()).join('; ')
}

type Count = { nodes: number }
type Atom = { value?: string; node?: Element; marks: Mark[]; style: string; link: Element | null; comments: string[] }

export function normalizeTree(root: Element): Element {
  if (root?.type !== 'element' || root.name !== 'page') {
    throw new TreeError('The root element must be <page>', root, 'Wrap the page content in <page>.', 'invalid_root')
  }
  return normalizeElement(root, undefined, 0, { nodes: 0 })
}

function count(node: Node, depth: number, state: Count) {
  if (++state.nodes > limits.nodes || depth > limits.depth) {
    throw new TreeError(
      `The page exceeds ${limits.nodes} nodes or ${limits.depth} levels of nesting`,
      node,
      'Split the page into smaller pages.',
      'limit_exceeded'
    )
  }
}

function normalizeElement(node: Element, parent: Element | undefined, depth: number, state: Count): Element {
  count(node, depth, state)
  if (parent) {
    checkElementName(node.name, node)
    if (node.name === 'page') {
      throw new TreeError('<page> can only be the root element', node, 'Remove the nested <page>.', 'invalid_parent')
    }
  }
  const rule = ruleOf(node.name)
  if (rule?.parents && !rule.parents.includes(parent?.name ?? '')) {
    throw new TreeError(
      `<${node.name}> can only be placed inside ${rule.parents.map(name => `<${name}>`).join(' or ')}`,
      node,
      `Move <${node.name}> inside ${rule.parents.map(name => `<${name}>`).join(' or ')}.`,
      'invalid_parent'
    )
  }
  const attrs = normalizeAttributes(node, rule)
  const children = normalizeElementChildren(node, rule, depth, state)
  if (node.name === 'block' && !Object.keys(attrs).length && children.length < 2) {
    return (children[0] as Element | undefined) ?? element('p')
  }
  return element(node.name, attrs, children)
}

function normalizeElementChildren(node: Element, rule: ElementRule | undefined, depth: number, state: Count) {
  if (!rule) return unknownChildren(node, depth, state)
  switch (rule.content) {
    case 'text':
      return textChildren(node, depth, state)
    case 'empty':
      return emptyChildren(node)
    case 'inline':
      return normalizeInline(node.children, node, depth, state)
    default:
      return blockChildren(node, rule.content, depth, state)
  }
}

function normalizeAttributes(node: Element, rule: ElementRule | undefined): Record<string, string> {
  const entries = Object.entries(node.attrs).sort(([a], [b]) => compareNames(a, b))
  if (node.name === 'comment') {
    if (entries.length !== 1 || entries[0]![0] !== 'ids') {
      throw new TreeError(
        '<comment> only accepts the ids attribute',
        node,
        'Provide ids and remove other attributes.',
        'invalid_attribute'
      )
    }
    try {
      return { ids: commentIDs(node.attrs.ids!).join(' ') }
    } catch {
      throw new TreeError(
        'ids on <comment> must be space-separated UUIDv7 values',
        node,
        'Use valid comment thread IDs.',
        'invalid_attribute'
      )
    }
  }
  if (node.name === 'page' && entries.length) {
    throw new TreeError(
      '<page> does not accept attributes',
      node,
      'Page metadata such as the title belongs outside the body.',
      'invalid_attribute'
    )
  }
  const kept: [string, string][] = []
  for (const [key, raw] of entries) {
    checkAttributeName(key, node)
    checkCharacters(raw, node)
    const known = rule && Object.hasOwn(rule.attributes, key)
    const value = known && key === 'style' ? keptStyle(raw) : raw
    if (node.name === 'embed' && key === 'props') {
      try {
        parseEmbedProps(value)
      } catch {
        throw new TreeError('Invalid embed props', node, 'Use a JSON object of at most 16 KiB.', 'invalid_attribute')
      }
    }
    const pattern = known ? rule.attributes[key] : null
    if (pattern && !pattern.test(value)) {
      throw new TreeError(
        `${key}="${value}" on <${node.name}> is not valid`,
        node,
        `The value of ${key} must be ${key === 'view' && node.name !== 'mermaid' && node.name !== 'infographic' ? 'link, title, card, or preview' : (valueHints[key] ?? pattern.source)}.`,
        'invalid_attribute'
      )
    }
    if (
      known &&
      ((optionalText.has(key) && value === '') ||
        (node.name === 'ol' && key === 'start' && value === '1') ||
        (node.name === 'column' && key === 'width' && value === '1000') ||
        ((key === 'colspan' || key === 'rowspan') && value === '1') ||
        ((node.name === 'mermaid' || node.name === 'infographic') &&
          ((key === 'view' && value === 'both') || (key === 'theme' && value === 'auto'))))
    ) {
      continue
    }
    kept.push([key, value])
  }
  for (const key of rule?.required ?? []) {
    if (!kept.some(([name]) => name === key)) {
      throw new TreeError(
        `<${node.name}> is missing the ${key} attribute`,
        node,
        `Add ${key} to <${node.name}>.`,
        'missing_attribute'
      )
    }
  }
  if (node.name === 'mention') {
    const hasPage = kept.some(([name]) => name === 'page')
    const hasPrincipal = kept.some(([name]) => name === 'principal')
    if (hasPage === hasPrincipal) {
      throw new TreeError(
        hasPage
          ? '<mention> cannot specify both page and principal attributes'
          : '<mention> requires a page or principal attribute',
        node,
        hasPage ? 'Keep only page or principal.' : 'Add page="..." or principal="..." to <mention>.',
        hasPage ? 'invalid_attribute' : 'missing_attribute'
      )
    }
  }
  // Object.fromEntries keeps names such as __proto__ as ordinary attributes.
  return Object.fromEntries(kept)
}

function textChildren(node: Element, depth: number, state: Count): Node[] {
  const atoms: Atom[] = []
  flatten(node.children, { marks: [], style: '', link: null, comments: [] }, atoms, node, depth + 1, state)
  if (node.name === 'inline-math') {
    for (const atom of atoms) {
      if (atom.value !== undefined && (atom.value.includes('\n') || atom.value.includes('\r'))) {
        atom.value = replaceCodeLineBreaks(atom.value)
      }
    }
  }
  return rebuild(merge(atoms))
}

function emptyChildren(node: Element): Node[] {
  for (const child of node.children) {
    if (child.type === 'element' || child.value) {
      throw new TreeError(
        `<${node.name}> is an empty element`,
        child,
        `Write <${node.name}> as <${node.name} />.`,
        'invalid_content'
      )
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
        `Text inside <${node.name}> must be wrapped in a block element`,
        child,
        Array.isArray(content) ? `Wrap this text in <${content[0]}>.` : 'Wrap this text in <p>.',
        'invalid_content'
      )
    }
    if (Array.isArray(content) && !content.includes(child.name)) {
      // A wrapper such as <tbody> holds allowed children. The repair removes the wrapper.
      const wrapper = child.children.some(
        grandchild => grandchild.type === 'element' && content.includes(grandchild.name)
      )
      throw new TreeError(
        `<${node.name}> can contain only ${content.map(name => `<${name}>`).join(', ')}`,
        child,
        wrapper
          ? `Remove the <${child.name}> wrapper tags and place their children directly inside <${node.name}>.`
          : `Move <${child.name}> outside <${node.name}>.`,
        'invalid_content'
      )
    }
    if (content === 'blocks' && ruleOf(child.name)?.kind === 'inline') {
      throw new TreeError(
        `<${child.name}> is an inline element and cannot be placed directly inside <${node.name}>`,
        child,
        'Wrap it in <p>.',
        'invalid_content'
      )
    }
    const normalized = normalizeElement(child, node, depth + 1, state)
    // A list without items shows nothing.
    if ((normalized.name === 'ul' || normalized.name === 'ol') && !normalized.children.length) continue
    if (normalized.name === 'columns' && !Object.keys(normalized.attrs).length) {
      const columns = (normalized.children as Element[]).filter(
        column => column.children.length || Object.keys(column.attrs).some(key => key !== 'width')
      )
      if (columns.length < 2 && columns.every(column => Object.keys(column.attrs).every(key => key === 'width'))) {
        result.push(...columns.flatMap(column => column.children as Element[]))
        continue
      }
      normalized.children = columns
    }
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
          `Adjacent <${block.name}> lists have different ${key} attributes`,
          block,
          `Set ${key} to the same value on both lists, or add a paragraph between them.`,
          'conflicting_list_attribute'
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
    throw new TreeError(
      `<${node.name}> cannot mix block elements and inline content`,
      node,
      'Wrap inline content in <p> or move block elements outside.',
      'invalid_content'
    )
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
  flatten(nodes, { marks: [], style: '', link: null, comments: [] }, atoms, container, depth + 1, state)
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
    if (container.name === 'pre' && child.name !== 'comment') {
      throw new TreeError(
        '<pre> can contain only text',
        child,
        'Remove child elements or convert them to plain code text.',
        'invalid_content'
      )
    }
    if (container.name === 'math' || container.name === 'inline-math') {
      throw new TreeError(
        `<${container.name}> can contain only text`,
        child,
        'Write the formula as plain LaTeX text.',
        'invalid_content'
      )
    }
    if (container.name === 'mermaid' && child.name !== 'comment') {
      throw new TreeError(
        '<mermaid> can contain only text',
        child,
        'Write the Mermaid source as plain text.',
        'invalid_content'
      )
    }
    if (container.name === 'infographic' && child.name !== 'comment') {
      throw new TreeError(
        '<infographic> can contain only text',
        child,
        'Write the Infographic source as plain text.',
        'invalid_content'
      )
    }
    checkElementName(child.name, child)
    const rule = ruleOf(child.name)
    if (rule?.kind === 'block') {
      throw new TreeError(
        `<${child.name}> is a block element and cannot be placed inside inline content`,
        child,
        'Move it outside the paragraph; in Markdown, place it on its own line separated by blank lines.',
        'invalid_content'
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
    } else if (child.name === 'comment') {
      count(child, depth, state)
      const attrs = normalizeAttributes(child, rule)
      flatten(
        child.children,
        { ...context, comments: [...new Set([...context.comments, ...commentIDs(attrs.ids!)])].sort() },
        atoms,
        container,
        depth + 1,
        state
      )
    } else if (child.name === 'span' && Object.keys(child.attrs).every(key => key === 'style')) {
      count(child, depth, state)
      checkCharacters(child.attrs.style ?? '', child)
      const style = keptStyle(child.attrs.style ?? '')
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
      if (context.link) throw new TreeError('Links cannot be nested', child, 'Remove the inner link.', 'nested_link')
      const link = element('a', normalizeAttributes(child, rule))
      const inner: Atom[] = []
      flatten(child.children, { ...context, link }, inner, container, depth + 1, state)
      if (inner.length) atoms.push(...inner)
      else atoms.push({ ...context, node: link })
    } else if (child.name === 'br' || child.name === 'img') {
      atoms.push({
        marks: [],
        style: '',
        link: context.link,
        comments: context.comments,
        node: normalizeElement(child, container, depth, state)
      })
    } else if (child.name === 'mention') {
      atoms.push({
        ...context,
        link: null,
        node: normalizeElement(child, container, depth, state)
      })
    } else {
      atoms.push({ ...context, node: normalizeElement(child, container, depth, state) })
    }
  }
}

function joinStyle(outer: string, inner: string): string {
  if (!outer.trim()) return inner
  if (!inner.trim()) return outer
  return `${outer}${outer.trimEnd().endsWith(';') ? '' : ';'} ${inner}`
}

const isLayoutSpaceCode = (code: number) => code === 0x20 || code === 0x09 || code === 0x0d || code === 0x0a

// White space is visible in code, underlined, struck and highlighted text.
const decorated = (atom: Atom) =>
  atom.marks.some(mark => mark === 'code' || mark === 'u' || mark === 's' || mark === 'mark')

function codePointStartingAt(value: string, index: number): string {
  return String.fromCodePoint(value.codePointAt(index)!)
}

function codePointEndingAt(value: string, endIndex: number): string {
  const i = endIndex - 1
  const pair = i > 0 ? value.codePointAt(i - 1)! : 0
  return String.fromCodePoint(pair > 0xffff ? pair : value.codePointAt(i)!)
}

function edgeChar(value: string, spaceVisible: boolean, fromEnd: boolean): string | undefined {
  if (fromEnd) {
    for (let i = value.length - 1; i >= 0; i--) {
      if (!spaceVisible && isLayoutSpaceCode(value.charCodeAt(i))) continue
      const pair = i > 0 ? value.codePointAt(i - 1)! : 0
      return String.fromCodePoint(pair > 0xffff ? pair : value.codePointAt(i)!)
    }
    return undefined
  }
  for (let i = 0; i < value.length; i++) {
    if (!spaceVisible && isLayoutSpaceCode(value.charCodeAt(i))) continue
    return String.fromCodePoint(value.codePointAt(i)!)
  }
  return undefined
}

function replaceCodeLineBreaks(value: string): string {
  let out = ''
  let copiedUntil = 0
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i)
    if (code !== 0x0d && code !== 0x0a) continue
    out += `${value.slice(copiedUntil, i)} `
    if (code === 0x0d && value.charCodeAt(i + 1) === 0x0a) i++
    copiedUntil = i + 1
  }
  return copiedUntil === 0 ? value : out + value.slice(copiedUntil)
}

function convertProseLineBreaks(value: string, leftBefore: string | null, rightAfter: string | null): string {
  let out = ''
  let copiedUntil = 0
  let i = 0
  while (i < value.length) {
    if (!isLayoutSpaceCode(value.charCodeAt(i))) {
      i++
      continue
    }
    const runStart = i
    let sawBreak = false
    while (i < value.length) {
      const code = value.charCodeAt(i)
      if (!isLayoutSpaceCode(code)) break
      if (code === 0x0d || code === 0x0a) sawBreak = true
      i++
    }
    if (!sawBreak) continue
    const runEnd = i
    const before = runStart > 0 ? codePointEndingAt(value, runStart) : leftBefore
    const after = runEnd < value.length ? codePointStartingAt(value, runEnd) : rightAfter
    const replacement =
      before === null || after === null || (closeScript.test(before) && closeScript.test(after)) ? '' : ' '
    out += value.slice(copiedUntil, runStart) + replacement
    copiedUntil = runEnd
  }
  return copiedUntil === 0 ? value : out + value.slice(copiedUntil)
}

// A line break in the source of prose is a soft break. It becomes a space,
// except between Chinese or Japanese characters, after a hard break and at
// the edges of the text. Code keeps one space for each break.
function convertLineBreaks(atoms: Atom[]) {
  if (atoms.length === 0) return

  const rightAfter = Array.from<string | null>({ length: atoms.length })
  let nextRight: string | null = null
  for (let i = atoms.length - 1; i >= 0; i--) {
    rightAfter[i] = nextRight
    const atom = atoms[i]!
    if (atom.node) {
      nextRight = atom.node.name === 'br' ? null : 'x'
    } else {
      const ch = edgeChar(atom.value ?? '', decorated(atom), false)
      if (ch !== undefined) nextRight = ch
    }
  }

  let leftBefore: string | null = null
  for (let i = 0; i < atoms.length; i++) {
    const atom = atoms[i]!
    const value = atom.value
    if (value !== undefined && (value.includes('\n') || value.includes('\r'))) {
      atom.value = atom.marks.includes('code')
        ? replaceCodeLineBreaks(value)
        : convertProseLineBreaks(value, leftBefore, rightAfter[i]!)
    }
    if (atom.node) {
      leftBefore = atom.node.name === 'br' ? null : 'x'
    } else {
      const ch = edgeChar(atom.value ?? '', decorated(atom), true)
      if (ch !== undefined) leftBefore = ch
    }
  }
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
    if (!atom.value) return []
    const trimmedStart = atom.value.trimStart()
    if (!trimmedStart) {
      return [{ ...atom, marks: atom.marks.filter(mark => mark !== 'strong' && mark !== 'em') }]
    }
    const leadEnd = atom.value.length - trimmedStart.length
    const body = trimmedStart.trimEnd()
    if (leadEnd === 0 && body.length === atom.value.length) {
      return [atom]
    }
    const plain = atom.marks.filter(mark => mark !== 'strong' && mark !== 'em')
    const bodyEnd = leadEnd + body.length
    return [
      ...(leadEnd > 0 ? [{ ...atom, value: atom.value.slice(0, leadEnd), marks: plain }] : []),
      { ...atom, value: body },
      ...(bodyEnd < atom.value.length ? [{ ...atom, value: atom.value.slice(bodyEnd), marks: plain }] : [])
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
      previous.comments.join() === atom.comments.join() &&
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
    const comments = atoms[i]!.comments
    let end = i + 1
    while (end < atoms.length && atoms[end]!.style === style && atoms[end]!.comments.join() === comments.join()) end++
    let content = formatted(units(atoms.slice(i, end)), [])
    if (comments.length) content = [element('comment', { ids: comments.join(' ') }, content)]
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
