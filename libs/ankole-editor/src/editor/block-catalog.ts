import { blocks } from '../blocks'
import type { PhraseSet } from '../core/phrases'
import type { GardState } from '../core/state'
import { acceptsFiles } from './file-upload'
import { hostFacet } from './host-context'
import { editorPhrases } from './phrases'
import { isKnowledge, knowledgeBlockTypes } from './knowledge'

/** Block types of the core vocabulary. Block definitions add their own names. */
export const coreBlockTypes = [
  'paragraph',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'table',
  'bullet',
  'number',
  'check',
  'quote',
  'code',
  'divider',
  'columns2',
  'columns3',
  'columns4',
  'columns5',
  'mention',
  'file',
  'page_embed',
  'chart',
  'bookmark'
] as const
export type CoreBlockType = (typeof coreBlockTypes)[number]
export type BlockType = CoreBlockType | (typeof blocks)[number]['name']

export type BlockOption = {
  type: BlockType
  title: PhraseSet.Ref
  detail: PhraseSet.Ref
  keywords?: string
  turnInto: boolean
}

/** Menu entries in SPEC §7.6 order: the core block types, then the installed blocks. */
export const blockOptions: readonly BlockOption[] = [
  {
    type: 'paragraph',
    title: editorPhrases.ref('paragraph_title'),
    detail: editorPhrases.ref('paragraph_detail'),
    keywords: 'text paragraph 正文 段落 文本',
    turnInto: true
  },
  {
    type: 'h1',
    title: editorPhrases.ref('h1_title'),
    detail: editorPhrases.ref('h1_detail'),
    keywords: 'heading header title h1 标题 一级标题 折叠 collapse toggle',
    turnInto: true
  },
  {
    type: 'h2',
    title: editorPhrases.ref('h2_title'),
    detail: editorPhrases.ref('h2_detail'),
    keywords: 'heading header title h2 标题 二级标题 折叠 collapse toggle',
    turnInto: true
  },
  {
    type: 'h3',
    title: editorPhrases.ref('h3_title'),
    detail: editorPhrases.ref('h3_detail'),
    keywords: 'heading header title h3 标题 三级标题 折叠 collapse toggle',
    turnInto: true
  },
  {
    type: 'h4',
    title: editorPhrases.ref('h4_title'),
    detail: editorPhrases.ref('heading_detail'),
    keywords: 'heading header title h4 标题 四级标题 折叠 collapse toggle',
    turnInto: true
  },
  {
    type: 'h5',
    title: editorPhrases.ref('h5_title'),
    detail: editorPhrases.ref('heading_detail'),
    keywords: 'heading header title h5 标题 五级标题 折叠 collapse toggle',
    turnInto: true
  },
  {
    type: 'h6',
    title: editorPhrases.ref('h6_title'),
    detail: editorPhrases.ref('heading_detail'),
    keywords: 'heading header title h6 标题 六级标题 折叠 collapse toggle',
    turnInto: true
  },
  {
    type: 'table',
    title: editorPhrases.ref('table_title'),
    detail: editorPhrases.ref('table_detail'),
    keywords: 'table grid markdown 表格 表 单元格',
    turnInto: false
  },
  {
    type: 'bullet',
    title: editorPhrases.ref('bullet_title'),
    detail: editorPhrases.ref('bullet_detail'),
    keywords: 'bullet list unordered 项目 无序 列表',
    turnInto: true
  },
  {
    type: 'number',
    title: editorPhrases.ref('number_title'),
    detail: editorPhrases.ref('number_detail'),
    keywords: 'numbered list ordered 编号 有序 列表',
    turnInto: true
  },
  {
    type: 'check',
    title: editorPhrases.ref('check_title'),
    detail: editorPhrases.ref('check_detail'),
    keywords: 'todo task checklist checkbox 待办 任务 清单 勾选 待办列表 任务列表',
    turnInto: true
  },
  {
    type: 'quote',
    title: editorPhrases.ref('quote_title'),
    detail: editorPhrases.ref('quote_detail'),
    keywords: 'quote quotation 引用',
    turnInto: true
  },
  {
    type: 'code',
    title: editorPhrases.ref('code_title'),
    detail: editorPhrases.ref('code_detail'),
    keywords: 'code codeblock source 代码 程序',
    turnInto: true
  },
  {
    type: 'divider',
    title: editorPhrases.ref('divider_title'),
    detail: editorPhrases.ref('divider_detail'),
    keywords: 'divider separator horizontal rule 分割线 分隔线',
    turnInto: false
  },
  ...([2, 3, 4, 5] as const).map(count => ({
    type: `columns${count}` as const,
    title: editorPhrases.ref(`columns${count}_title`),
    detail: editorPhrases.ref('columns_detail'),
    keywords: `${count}columns ${count} columns layout 分栏 栏 布局`,
    turnInto: false
  })),
  {
    type: 'mention',
    title: editorPhrases.ref('mention_title'),
    detail: editorPhrases.ref('mention_detail'),
    keywords: 'mention reference @ 提及 引用 页面 文档 主体 成员 agent',
    turnInto: false
  },
  {
    type: 'file',
    title: editorPhrases.ref('file_title'),
    detail: editorPhrases.ref('file_detail'),
    keywords: 'file attachment upload document pdf 文件 附件 上传 文档',
    turnInto: false
  },
  {
    type: 'page_embed',
    title: editorPhrases.ref('page_embed_title'),
    detail: editorPhrases.ref('page_embed_detail'),
    keywords: 'embed page base table applet app workspace 嵌入 多维表 数据表 应用 页面 已有内容',
    turnInto: false
  },
  {
    type: 'chart',
    title: editorPhrases.ref('chart_title'),
    detail: editorPhrases.ref('chart_detail'),
    keywords:
      'chart graph plot bar line pie area scatter combo visualization 图表 统计图 柱状图 折线图 饼图 数据图表 多维表图表',
    turnInto: false
  },
  ...blocks.flatMap((block): BlockOption[] => {
    const entry: BlockOption = {
      type: block.name,
      title: block.insert.title,
      detail: block.insert.detail,
      keywords: block.insert.keywords,
      turnInto: block.insert.turnInto
    }
    if (block.name !== 'media') return [entry]
    return [
      entry,
      {
        type: 'bookmark',
        title: editorPhrases.ref('bookmark_title'),
        detail: editorPhrases.ref('bookmark_detail'),
        keywords: 'bookmark website webpage link url card 网页 网站 网址 链接 卡片 书签',
        turnInto: false
      }
    ]
  })
]

/** All insertion entry points search the same translated block catalogue. */
export function filterBlockOptions(
  state: GardState,
  query: string,
  mode?: 'doc' | 'knowledge'
): readonly BlockOption[] {
  const terms = query.trim().normalize('NFKC').toLowerCase().split(/\s+/)
  const knowledge = mode ? mode === 'knowledge' : isKnowledge(state)
  const files = acceptsFiles(state)
  const pageEmbeds = !knowledge && Boolean(state.facet(hostFacet)?.insertPageEmbed)
  const charts = !knowledge && Boolean(state.facet(hostFacet)?.insertChart)
  return blockOptions.filter(
    option =>
      (!knowledge || knowledgeBlockTypes.has(option.type)) &&
      (option.type !== 'file' || files) &&
      (option.type !== 'page_embed' || pageEmbeds) &&
      (option.type !== 'chart' || charts) &&
      terms.every(term =>
        `${option.type} ${option.title(state)} ${option.detail(state)} ${option.keywords ?? ''}`
          .normalize('NFKC')
          .toLowerCase()
          .includes(term)
      )
  )
}
