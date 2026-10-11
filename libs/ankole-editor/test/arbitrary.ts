import fc from 'fast-check'
import { element as e, text as t, type Element, type Node } from '../src/document/tree'

/** Text with characters that have a meaning in Markdown, tags, links or line breaking. */
export const prose = fc
  .array(
    fc.constantFrom(
      'a',
      'Z',
      '中',
      '文',
      'é',
      '🙂',
      ' ',
      '  ',
      '\n',
      '*',
      '_',
      '~',
      '`',
      '#',
      '-',
      '+',
      '1.',
      '>',
      '<',
      '<b',
      '</',
      '/>',
      '{',
      '}',
      '[',
      ']',
      '(',
      ')',
      '!',
      '&',
      '&amp;',
      ';',
      ':',
      '10:30',
      '|',
      '\\',
      '"',
      "'",
      '=',
      'www.example.com',
      'https://example.com/a',
      'me@example.com',
      '[ ] ',
      '\t'
    ),
    { maxLength: 12 }
  )
  .map(parts => parts.join(''))

const word = fc.constantFrom('alpha', '中文', 'x y', 'a*b', 'https://example.com', 'q&a', '"quoted"', '<tag>')
const attributeValue = fc.oneof(word, prose, fc.constant(''))
const unknownName = fc.constantFrom('widget', 'chip', '自定义', 'my-block', 'Foo')
const attributes = fc
  .array(fc.tuple(fc.constantFrom('data-x', 'source', '__proto__', 'constructor', 'note', '字段'), attributeValue), {
    maxLength: 2
  })
  .map(pairs => Object.fromEntries(pairs) as Record<string, string>)

const formats = ['strong', 'em', 's', 'u', 'mark', 'sub', 'sup', 'code'] as const

function inline(depth: number, linked = false): fc.Arbitrary<Node> {
  const leaf: fc.Arbitrary<Node>[] = [
    prose.map(value => t(value)),
    fc.constant(e('br')),
    fc
      .record({ src: word, alt: fc.option(word, { nil: undefined }), title: fc.option(word, { nil: undefined }) })
      .map(({ src, alt, title }) =>
        e('img', { src, ...(alt === undefined ? {} : { alt }), ...(title === undefined ? {} : { title }) })
      )
  ]
  if (depth <= 0) return fc.oneof(...leaf)
  const children = fc.array(inline(depth - 1, linked), { minLength: 1, maxLength: 3 })
  const branches: fc.Arbitrary<Node>[] = [
    fc.tuple(fc.constantFrom(...formats), children).map(([name, nodes]) => e(name, {}, nodes)),
    fc
      .tuple(fc.constantFrom('color: red;', 'font-weight: 600'), children)
      .map(([style, nodes]) => e('span', { style }, nodes)),
    fc
      .tuple(unknownName, attributes, fc.array(inline(depth - 1, linked), { maxLength: 2 }))
      .map(([name, attrs, nodes]) => e(name, attrs, nodes)),
    fc
      .tuple(fc.constantFrom(...formats), attributes, children)
      .map(([name, attrs, nodes]) => e(name, { ...attrs, 'data-x': '1' }, nodes))
  ]
  if (!linked) {
    branches.push(
      fc
        .tuple(
          word,
          fc.option(word, { nil: undefined }),
          attributes,
          fc.array(inline(depth - 1, true), { maxLength: 3 })
        )
        .map(([href, title, attrs, nodes]) =>
          e('a', { ...attrs, href, ...(title === undefined ? {} : { title }) }, nodes)
        )
    )
  }
  return fc.oneof(...leaf, ...branches)
}

const inlineContent = (depth: number) => fc.array(inline(depth), { maxLength: 4 })
const textAttributes = fc.oneof(
  fc.constant({}),
  fc.constant({ align: 'center' }),
  fc.constant({ indent: '2' }),
  attributes,
  fc.constant({ style: 'color: blue;' })
)

export function block(depth: number): fc.Arbitrary<Element> {
  const paragraph = fc.tuple(textAttributes, inlineContent(2)).map(([attrs, nodes]) => e('p', attrs, nodes))
  const leaf: fc.Arbitrary<Element>[] = [
    paragraph,
    fc
      .tuple(fc.constantFrom('h1', 'h2', 'h3', 'h4', 'h5', 'h6'), textAttributes, inlineContent(1))
      .map(([name, attrs, nodes]) => e(name, attrs, nodes)),
    fc
      .tuple(
        fc.option(fc.constantFrom('ts', 'json', 'a b'), { nil: undefined }),
        fc.option(fc.constantFrom('title=x', ' x'), { nil: undefined }),
        prose,
        attributes
      )
      .map(([lang, meta, code, attrs]) =>
        e('pre', { ...attrs, ...(lang === undefined ? {} : { lang }), ...(meta === undefined ? {} : { meta }) }, [
          t(code)
        ])
      ),
    fc.oneof(fc.constant({}), attributes).map(attrs => e('hr', attrs)),
    fc.option(word, { nil: undefined }).map(ref => e('database', ref === undefined ? {} : { ref })),
    fc
      .tuple(
        fc.integer({ min: 1, max: 3 }),
        fc.integer({ min: 1, max: 3 }),
        fc.boolean(),
        fc.constantFrom(undefined, 'left', 'right', 'center')
      )
      .chain(([rows, columns, header, align]) =>
        fc
          .array(fc.array(inlineContent(1), { minLength: columns, maxLength: columns }), {
            minLength: rows,
            maxLength: rows
          })
          .map(cells =>
            e(
              'table',
              {},
              cells.map((row, index) =>
                e(
                  'tr',
                  {},
                  row.map(content =>
                    e(header && index === 0 ? 'th' : 'td', align ? { align } : {}, [e('p', {}, content)])
                  )
                )
              )
            )
          )
      ),
    fc.tuple(unknownName, attributes, inlineContent(1)).map(([name, attrs, nodes]) => e(name, attrs, nodes))
  ]
  if (depth <= 0) return fc.oneof(...leaf)
  const blocks = fc.array(block(depth - 1), { maxLength: 3 })
  const item = fc
    .tuple(fc.constantFrom(undefined, 'todo', 'done'), fc.array(block(depth - 1), { maxLength: 2 }), fc.boolean())
    .map(([task, nodes, extra]) =>
      e('li', { ...(task ? { task } : {}), ...(extra ? { 'data-owner': 'a' } : {}) }, nodes)
    )
  return fc.oneof(
    ...leaf,
    blocks.map(nodes => e('blockquote', {}, nodes)),
    fc
      .tuple(fc.constantFrom<Record<string, string>>({}, { tone: 'warning' }, { tone: 'info', note: 'x' }), blocks)
      .map(([attrs, nodes]) => e('callout', attrs, nodes)),
    fc
      .tuple(
        fc.constantFrom('ul', 'ol'),
        fc.constantFrom(undefined, '0', '3'),
        fc.array(item, { minLength: 1, maxLength: 3 })
      )
      .map(([name, start, items]) => e(name, name === 'ol' && start ? { start } : {}, items)),
    fc.tuple(unknownName, attributes, blocks).map(([name, attrs, nodes]) => e(name, attrs, nodes))
  )
}

export const page = fc.array(block(2), { maxLength: 4 }).map(blocks => e('page', {}, blocks))
