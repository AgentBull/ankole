import { describe, expect, test } from 'bun:test'
import fc from 'fast-check'
import { parseMarkdown, printMarkdown } from '../src/document/markdown'
import { normalizeTree } from '../src/document/normalize'
import { DocumentError, element as e, limits, text as t, type Element } from '../src/document/tree'
import { parseXml, printXml } from '../src/document/xml'
import { page as pages } from './arbitrary'

const page = (...children: Element[]) => e('page', {}, children)
const p = (...children: (Element | string)[]) =>
  e(
    'p',
    {},
    children.map(child => (typeof child === 'string' ? t(child) : child))
  )

// Canonical Markdown, canonical XML and the tree, each written independently.
const pairs: [string, string, string, Element][] = [
  [
    'heading, strong text and a link',
    '# 标题\n\n收入增长了 **17%**，详见 [收入表](https://example.com/revenue)。',
    '<page><h1>标题</h1><p>收入增长了 <strong>17%</strong>，详见 <a href="https://example.com/revenue">收入表</a>。</p></page>',
    page(
      e('h1', {}, [t('标题')]),
      p(
        '收入增长了 ',
        e('strong', {}, [t('17%')]),
        '，详见 ',
        e('a', { href: 'https://example.com/revenue' }, [t('收入表')]),
        '。'
      )
    )
  ],
  [
    'callout and embed',
    '<callout tone="warning">\n  本期数据包含新增产品。\n</callout>\n\n<embed ref="db_q3" />',
    '<page><callout tone="warning"><p>本期数据包含新增产品。</p></callout><embed ref="db_q3" /></page>',
    page(e('callout', { tone: 'warning' }, [p('本期数据包含新增产品。')]), e('embed', { ref: 'db_q3' }))
  ],
  [
    'base embed with a table and a view',
    '<embed ref="db_q3" table="tbl_sales" view="viw_march" />',
    '<page><embed ref="db_q3" table="tbl_sales" view="viw_march" /></page>',
    page(e('embed', { ref: 'db_q3', table: 'tbl_sales', view: 'viw_march' }))
  ],
  [
    'page link and asset image addresses',
    '见 [季度目标](ankole:page/019a2b00-0000-7000-8000-000000000001)。\n\n![图](ankole:asset/3f786850e387550fdab836ed7e6dc881de23001b/chart.png)',
    '<page><p>见 <a href="ankole:page/019a2b00-0000-7000-8000-000000000001">季度目标</a>。</p><p><img alt="图" src="ankole:asset/3f786850e387550fdab836ed7e6dc881de23001b/chart.png" /></p></page>',
    page(
      p('见 ', e('a', { href: 'ankole:page/019a2b00-0000-7000-8000-000000000001' }, [t('季度目标')]), '。'),
      p(e('img', { src: 'ankole:asset/3f786850e387550fdab836ed7e6dc881de23001b/chart.png', alt: '图' }))
    )
  ],
  [
    'exact mixed content of an unknown element',
    '<foo enabled="true">abc<bar x="1">def<baz /></bar>ghi</foo>',
    '<page><foo enabled="true">abc<bar x="1">def<baz /></bar>ghi</foo></page>',
    page(e('foo', { enabled: 'true' }, [t('abc'), e('bar', { x: '1' }, [t('def'), e('baz')]), t('ghi')]))
  ],
  [
    'paragraph attributes',
    '<p align="center" source="manual">居中 **正文**</p>',
    '<page><p align="center" source="manual">居中 <strong>正文</strong></p></page>',
    page(e('p', { align: 'center', source: 'manual' }, [t('居中 '), e('strong', {}, [t('正文')])]))
  ],
  ['empty paragraph', '<p />\n\ntext', '<page><p /><p>text</p></page>', page(p(), p('text'))],
  [
    'task list',
    '- [ ] 核对统计口径\n- 补充说明',
    '<page><ul><li task="todo"><p>核对统计口径</p></li><li><p>补充说明</p></li></ul></page>',
    page(e('ul', {}, [e('li', { task: 'todo' }, [p('核对统计口径')]), e('li', {}, [p('补充说明')])]))
  ],
  [
    'ordered list start',
    '7. first\n8. second',
    '<page><ol start="7"><li><p>first</p></li><li><p>second</p></li></ol></page>',
    page(e('ol', { start: '7' }, [e('li', {}, [p('first')]), e('li', {}, [p('second')])]))
  ],
  [
    'code fence with meta',
    '```ts title=x\nconst x = 1\n```',
    '<page><pre lang="ts" meta="title=x">const x = 1</pre></page>',
    page(e('pre', { lang: 'ts', meta: 'title=x' }, [t('const x = 1')]))
  ],
  [
    'image',
    '![cat](/cat "title")',
    '<page><p><img alt="cat" src="/cat" title="title" /></p></page>',
    page(p(e('img', { src: '/cat', alt: 'cat', title: 'title' })))
  ],
  [
    'formats with and without Markdown syntax',
    'a <u>u</u> <mark>m</mark> <sub>s</sub> <sup>p</sup> ~~d~~ `c`',
    '<page><p>a <u>u</u> <mark>m</mark> <sub>s</sub> <sup>p</sup> <s>d</s> <code>c</code></p></page>',
    page(
      p(
        'a ',
        e('u', {}, [t('u')]),
        ' ',
        e('mark', {}, [t('m')]),
        ' ',
        e('sub', {}, [t('s')]),
        ' ',
        e('sup', {}, [t('p')]),
        ' ',
        e('s', {}, [t('d')]),
        ' ',
        e('code', {}, [t('c')])
      )
    )
  ],
  ['hard break', 'a<br />b', '<page><p>a<br />b</p></page>', page(p('a', e('br'), 'b'))],
  [
    'Markdown blocks inside unknown elements',
    '<columns>\n  <column>\n    左栏支持 **格式** 和列表：\n\n    - 一\n    - 二\n  </column>\n\n  <column>\n    右栏。\n  </column>\n</columns>',
    '<page><columns><column><p>左栏支持 <strong>格式</strong> 和列表：</p><ul><li><p>一</p></li><li><p>二</p></li></ul></column><column><p>右栏。</p></column></columns></page>',
    page(
      e('columns', {}, [
        e('column', {}, [
          p('左栏支持 ', e('strong', {}, [t('格式')]), ' 和列表：'),
          e('ul', {}, [e('li', {}, [p('一')]), e('li', {}, [p('二')])])
        ]),
        e('column', {}, [p('右栏。')])
      ])
    )
  ],
  [
    'link with an extra attribute',
    'See <a href="https://x.com" source="finance">revenue</a>.',
    '<page><p>See <a href="https://x.com" source="finance">revenue</a>.</p></page>',
    page(p('See ', e('a', { href: 'https://x.com', source: 'finance' }, [t('revenue')]), '.'))
  ],
  [
    'GFM table',
    '| a  |  b |\n| :- | -: |\n| 1  |  2 |',
    '<page><table><tr><th align="left"><p>a</p></th><th align="right"><p>b</p></th></tr><tr><td align="left"><p>1</p></td><td align="right"><p>2</p></td></tr></table></page>',
    page(
      e('table', {}, [
        e('tr', {}, [e('th', { align: 'left' }, [p('a')]), e('th', { align: 'right' }, [p('b')])]),
        e('tr', {}, [e('td', { align: 'left' }, [p('1')]), e('td', { align: 'right' }, [p('2')])])
      ])
    )
  ],
  [
    'URL text that is not a link',
    'Visit www\\.example.com',
    '<page><p>Visit www.example.com</p></page>',
    page(p('Visit www.example.com'))
  ],
  [
    'bare URLs are links',
    'see https://example.com/path and www.example.com',
    '<page><p>see <a href="https://example.com/path">https://example.com/path</a> and <a href="http://www.example.com">www.example.com</a></p></page>',
    page(
      p(
        'see ',
        e('a', { href: 'https://example.com/path' }, [t('https://example.com/path')]),
        ' and ',
        e('a', { href: 'http://www.example.com' }, [t('www.example.com')])
      )
    )
  ],
  [
    'attribute characters',
    '<foo note="&#9;&#10;&#13;&amp;&lt;&quot;" />',
    '<page><foo note="&#9;&#10;&#13;&amp;&lt;&quot;" /></page>',
    page(e('foo', { note: '\t\n\r&<"' }))
  ],
  [
    'attribute names and values',
    '<foo __proto__="own" constructor="ctor" empty="" flag="false" open="open" zero="0" />',
    '<page><foo __proto__="own" constructor="ctor" empty="" flag="false" open="open" zero="0" /></page>',
    page(
      e(
        'foo',
        Object.fromEntries([
          ['__proto__', 'own'],
          ['constructor', 'ctor'],
          ['empty', ''],
          ['flag', 'false'],
          ['open', 'open'],
          ['zero', '0']
        ])
      )
    )
  ],
  [
    'quote with blocks',
    '> quote **x**\n>\n> - y',
    '<page><blockquote><p>quote <strong>x</strong></p><ul><li><p>y</p></li></ul></blockquote></page>',
    page(e('blockquote', {}, [p('quote ', e('strong', {}, [t('x')])), e('ul', {}, [e('li', {}, [p('y')])])]))
  ],
  [
    'formats around a link',
    '<span style="color: red">red</span> and **a [link](u) inside**',
    '<page><p><span style="color: red">red</span> and <strong>a <a href="u">link</a> inside</strong></p></page>',
    page(
      p(
        e('span', { style: 'color: red' }, [t('red')]),
        ' and ',
        e('strong', {}, [t('a '), e('a', { href: 'u' }, [t('link')]), t(' inside')])
      )
    )
  ]
]

describe('paired Markdown and XML', () => {
  test.each(pairs)('%s', (_, markdown, xml, tree) => {
    const expected = normalizeTree(tree)
    expect(parseMarkdown(markdown)).toEqual(expected)
    expect(parseXml(xml)).toEqual(expected)
    expect(printMarkdown(expected)).toBe(markdown)
    expect(printXml(expected)).toBe(xml)
  })
})

describe('the normal form keeps what a reader sees', () => {
  test('source line breaks are spaces, except between Chinese or Japanese characters', () => {
    expect(parseMarkdown('English line\nwrapped here\n中文第一行\n第二行。\nかな\n続き')).toEqual(
      page(p('English line wrapped here 中文第一行第二行。かな続き'))
    )
    expect(parseXml('<page><p>\n  a\n  b\n</p></page>')).toEqual(page(p('a b')))
    // A space in code or underlined text is visible, so the break next to it is not at the edge.
    expect(parseMarkdown('` `\n`  `\nx<u> </u>\ny')).toEqual(
      page(p(e('code', {}, [t(' ')]), ' ', e('code', {}, [t('  ')]), ' x', e('u', {}, [t(' ')]), ' y'))
    )
  })
  test('white space at the edges of bold and italic text is plain', () => {
    expect(parseXml('<page><p><strong>bold </strong>after <em> x</em></p></page>')).toEqual(
      page(p(e('strong', {}, [t('bold')]), ' after  ', e('em', {}, [t('x')])))
    )
    expect(printMarkdown(parseMarkdown('*a **b** c*'))).toBe('*a **b** c*')
  })
  test('format order and adjacent formats do not matter', () => {
    expect(parseXml('<page><p><em><strong>x</strong></em><u>a</u><u>b</u></p></page>')).toEqual(
      parseXml('<page><p><strong><em>x</em></strong><u>ab</u></p></page>')
    )
  })
  test('empty formats and spans without attributes have no content', () => {
    expect(parseXml('<page><p><strong /><span>a</span><span /></p></page>')).toEqual(page(p('a')))
  })
  test('adjacent lists of the same kind are one list', () => {
    expect(parseMarkdown('- a\n+ b\n\n1. c\n2) d')).toEqual(
      page(
        e('ul', {}, [e('li', {}, [p('a')]), e('li', {}, [p('b')])]),
        e('ol', {}, [e('li', {}, [p('c')]), e('li', {}, [p('d')])])
      )
    )
    expect(parseXml('<page><ul x="1"><li /></ul><ul y="2"><li /></ul></page>')).toEqual(
      page(e('ul', { x: '1', y: '2' }, [e('li'), e('li')]))
    )
    expect(() => parseXml('<page><ul x="1"><li /></ul><ul x="2"><li /></ul></page>')).toThrow('属性 x 不同')
  })
  test('defaults and empty optional values equal missing attributes', () => {
    expect(parseXml('<page><ol start="1"><li /></ol><p><img alt="" src="x" title="" /></p></page>')).toEqual(
      page(e('ol', {}, [e('li')]), p(e('img', { src: 'x' })))
    )
    expect(parseXml('<page><p style="">a</p><h2 style="">b</h2></page>')).toEqual(page(p('a'), e('h2', {}, [t('b')])))
    expect(parseXml('<page><table><tr><td colspan="1" rowspan="1"><p>c</p></td></tr></table></page>')).toEqual(
      page(e('table', {}, [e('tr', {}, [e('td', {}, [p('c')])])]))
    )
  })
  test('a list without items is not content', () => {
    expect(parseXml('<page><ul><li /></ul><ol start="3" /><ul /><ul><li /></ul></page>')).toEqual(
      page(e('ul', {}, [e('li'), e('li')]))
    )
  })
  test('layout white space in XML is not content', () => {
    expect(parseXml('<page>\n  <widget>\n    some text\n  </widget>\n  <foo>\n    <bar/>\n  </foo>\n</page>')).toEqual(
      page(e('widget', {}, [t('some text')]), e('foo', {}, [e('bar')]))
    )
  })
})

describe('Markdown tags', () => {
  test('a known block element on one line is a block', () => {
    expect(parseMarkdown('<callout tone="info">提示</callout>')).toEqual(
      page(e('callout', { tone: 'info' }, [p('提示')]))
    )
  })
  test('known block elements written one per line are blocks', () => {
    const source =
      '<table>\n  <tr>\n    <th colspan="2">合并的表头</th>\n  </tr>\n  <tr>\n    <td>a</td>\n    <td>b</td>\n  </tr>\n</table>'
    expect(parseMarkdown(source)).toEqual(
      page(
        e('table', {}, [
          e('tr', {}, [e('th', { colspan: '2' }, [p('合并的表头')])]),
          e('tr', {}, [e('td', {}, [p('a')]), e('td', {}, [p('b')])])
        ])
      )
    )
    expect(parseMarkdown('<p align="center">一</p>\n<p align="right">二</p>')).toEqual(
      page(e('p', { align: 'center' }, [t('一')]), e('p', { align: 'right' }, [t('二')]))
    )
    // Text beside a block element is still an error.
    expect(() => parseMarkdown('<callout>x</callout>\n**more**')).toThrow('空行')
  })
  test('an inline element written as a block tag joins a paragraph', () => {
    expect(parseMarkdown('<u>\nunder **line**\n</u>')).toEqual(
      page(p(e('u', {}, [t('under '), e('strong', {}, [t('line')])])))
    )
  })
  test('an unknown element alone on a line is a block element; next to text it is inline', () => {
    expect(parseMarkdown('<chip>x</chip>\n\na <chip>y</chip> b')).toEqual(
      page(e('chip', {}, [t('x')]), p('a ', e('chip', {}, [t('y')]), ' b'))
    )
  })
  test('accepted forms are read and printed canonically', () => {
    const source = '温度<3 度时<br>停止，详见 <a href=报告>说明</a>，a < b。<toggle open>x</toggle>'
    expect(parseMarkdown(source)).toEqual(
      page(
        p(
          '温度<3 度时',
          e('br'),
          '停止，详见 ',
          e('a', { href: '报告' }, [t('说明')]),
          '，a < b。',
          e('toggle', { open: 'open' }, [t('x')])
        )
      )
    )
    expect(printMarkdown(parseMarkdown(source))).toBe(
      '温度\\<3 度时<br />停止，详见 [说明](报告)，a \\< b。<toggle open="open">x</toggle>'
    )
  })
  test('colons, braces and placeholders in code are text', () => {
    expect(parseMarkdown('会议 10:30 开始，ratio 3:1, key:value, {x}, `<job_id>`')).toEqual(
      page(p('会议 10:30 开始，ratio 3:1, key:value, {x}, ', e('code', {}, [t('<job_id>')])))
    )
  })
  test('a code fence inside a block tag can carry extra attributes', () => {
    const tree = page(e('pre', { lang: 'ts', source: 'x' }, [t('const a = 1')]))
    expect(printMarkdown(tree)).toBe('<pre lang="ts" source="x">\n  ```\n  const a = 1\n  ```\n</pre>')
    expect(parseMarkdown(printMarkdown(tree))).toEqual(tree)
  })
})

function rejection(read: () => unknown) {
  try {
    read()
  } catch (error) {
    expect(error).toBeInstanceOf(DocumentError)
    return error as DocumentError
  }
  throw new Error('The source was accepted')
}

describe('rejected Markdown names the place and the repair', () => {
  test.each([
    ['a <!-- note --> b', 1, 3, '注释'],
    ['x\n\nsee <https://x.com>', 3, 5, '尖括号自动链接'],
    ['- `provenance`: report <job_id>, report.md', 1, 24, '<job_id> 没有闭合'],
    ['<a href="u">x</b>', 1, 14, '不匹配'],
    ['<callout>\ntext</callout>', 2, 5, '</callout> 和开始标签不在同一层'],
    ['<p>a\n<br />\nb</p>', 1, 1, '请在同一段里写 </p>'],
    ['[a](<b)c', 1, 7, '字符 )'],
    ['<x a={1} />', 1, 1, '表达式'],
    ['<x a="1" a="2" />', 1, 1, '重复属性'],
    ['<>x</>', 1, 1, '片段'],
    ['<x:y />', 1, 1, '元素名'],
    ['<ul>\n<li task="maybe">x</li>\n</ul>', 2, 1, 'task'],
    ['<table>\n<thead>\n<tr><th>A</th></tr>\n</thead>\n</table>', 2, 1, '请去掉 <thead> 标签'],
    ['text <callout>x</callout> more', 1, 6, '块元素'],
    ['bad\u0000text', 1, 4, 'U+0000']
  ] as const)('%s', (source, line, column, reason) => {
    const error = rejection(() => parseMarkdown(source))
    expect([error.line, error.column]).toEqual([line, column])
    expect(error.message).toContain(reason)
  })
})

test.each([
  '<page><p></page>',
  '<page a="x"/>',
  '<other/>',
  '<page><foo a="1" a="2"/></page>',
  '<page><foo xmlns="urn:x"/></page>',
  '<page><x:foo/></page>',
  '<page><_foo/></page>',
  '<!DOCTYPE page [<!ENTITY x "y">]><page/>',
  '<page><!--comment--></page>',
  '<?process x?><page/>',
  '<?xml version="1.1"?><page/>',
  '<page><p>&nbsp;</p></page>',
  '<page><p>&#0;</p></page>',
  '<page>direct text</page>',
  '<page><pre><p/></pre></page>',
  '<page><br>text</br></page>',
  '<page><p><p/></p></page>',
  '<page><ul><p/></ul></page>',
  '<page><table><tr><td rowspan="0"/></tr></table></page>',
  '<page><td/></page>',
  '<page><p><a>no href</a></p></page>',
  '<page><callout tone="invalid"/></page>'
])('rejects invalid XML or an invalid page: %s', source => {
  rejection(() => parseXml(source))
})

test('the repair for an invalid value names the valid values', () => {
  expect(rejection(() => parseXml('<page><ol start="1234567890"><li /></ol></page>')).fix).toBe(
    'start 的值应为 0 或不超过 9 位的正整数。'
  )
})

test('XML errors point to the element', () => {
  const error = rejection(() => parseXml('<page>\n  <ol start="-1"><li/></ol>\n</page>'))
  expect([error.line, error.column]).toEqual([2, 3])
})

test('the node limit counts each element and text once', () => {
  expect(() => normalizeTree(page(p(...Array.from({ length: 50_000 }, () => e('br')))))).not.toThrow()
  expect(() => normalizeTree(page(...Array.from({ length: 60_000 }, () => e('pre', {}, [t('x')]))))).toThrow(
    '100000 个节点'
  )
})

test('source and depth limits are reported, not truncated', () => {
  expect(() => parseMarkdown('a'.repeat(limits.source + 1))).toThrow('超过')
  expect(() =>
    parseXml(`<page>${'<foo>'.repeat(limits.depth + 1)}${'</foo>'.repeat(limits.depth + 1)}</page>`)
  ).toThrow('嵌套')
})

test.each([
  'https://example.com',
  'www.example.com',
  'me@example.com',
  '{"n":1,"bool":false}',
  'A::Z',
  '10:30',
  'a<b',
  '*x*'
])('keeps literal text from becoming syntax: %s', value => {
  for (const tree of [page(p(value)), page(e('foo', {}, [e('bar', {}, [t(value)])]))]) {
    const markdown = printMarkdown(tree)
    expect(parseMarkdown(markdown)).toEqual(normalizeTree(tree))
    expect(printMarkdown(parseMarkdown(markdown))).toBe(markdown)
  }
})

// White space at the end of a paragraph is printed as a character reference; GFM would read it into a bare URL.
test.each([
  ['www.example.com', 'http://www.example.com', ' '],
  ['https://a.com', 'https://a.com', '. '],
  ['me@example.com', 'mailto:me@example.com', '  ']
])('a link before white space at the end of a paragraph keeps its address: %s', (label, href, after) => {
  const tree = page(p('see ', e('a', { href }, [t(label)]), after))
  const markdown = printMarkdown(tree)
  expect(parseMarkdown(markdown)).toEqual(normalizeTree(tree))
})

test('footnotes are not part of the dialect', () => {
  expect(parseMarkdown('label[^1]\n\n[^1]: /target')).toEqual(page(p('label', e('a', { href: '/target' }, [t('^1')]))))
})

test('generated pages obey the codec laws in both formats', () => {
  fc.assert(
    fc.property(pages, tree => {
      const expected = normalizeTree(tree)
      const markdown = printMarkdown(expected)
      const xml = printXml(expected)
      expect(parseMarkdown(markdown)).toEqual(expected)
      expect(parseXml(xml)).toEqual(expected)
      expect(parseXml(printXml(parseMarkdown(markdown)))).toEqual(expected)
      expect(parseMarkdown(printMarkdown(parseXml(xml)))).toEqual(expected)
      expect(printMarkdown(parseMarkdown(markdown))).toBe(markdown)
      expect(printXml(parseXml(xml))).toBe(xml)
    }),
    { seed: process.env.FC_SEED ? Number(process.env.FC_SEED) : 20261005, numRuns: 300 }
  )
}, 60_000)
