import { Elt, Leaf, Mark, Node, Schema, type ChangeSet } from '../../core/doc'
import { Decoration, type Wordgard } from '../../core/editor'
import { Widget } from '../../core/editor/decoration'
import { element } from '../../document/tree'
import type { ResourceAttributes, ResourceKind } from '../../document/resources'
import { vocabulary } from '../../document/vocabulary'
import { Attrs, extraAttrs, extraOf, markSet, markValue } from '../../editor/attributes'
import type { BlockDefinition } from '../../editor/block'
import { insertBlock } from '../../editor/block-insert'
import { editorPhrases } from '../../editor/phrases'

export type { ResourceAttributes, ResourceKind } from '../../document/resources'

function resourceShape(kind: ResourceKind) {
  return Elt.mk('div', { class: 'editor-resource', 'data-resource': kind, contenteditable: 'false' })
}

/** A widget protects React-owned descendants from the editor's content mutation observer. */
export const resourceWidget = Widget.define<ResourceKind | 'embed'>({
  render: kind => {
    const container = document.createElement('div')
    container.className = 'editor-resource'
    container.dataset.resource = kind
    return container
  },
  propagateEvent: false
})

const leaf = (kind: ResourceKind) =>
  Leaf.define({ media: 'Media', bookmark: 'Bookmark' }[kind], {
    group: Node.Group.Content,
    selectable: true,
    shape: { structure: resourceShape(kind), selector: `div[data-resource="${kind}"]` }
  })

const nodes = { media: leaf('media'), bookmark: leaf('bookmark') }

/** Resource metadata belongs to the document; uploaded bytes belong to the host's asset store. */
const resourceFields = ['src', 'title', 'description', 'image', 'mime', 'size', 'kind', 'view'] as const
const fields = Object.fromEntries(
  resourceFields.map(name => [
    name,
    Mark.Type.define<string>(`Resource_${name}`, {
      target: Object.values(nodes),
      validate: value => {
        const pattern = vocabulary.media!.attributes[name]
        if (typeof value !== 'string' || (pattern && !pattern.test(value))) {
          throw new TypeError(`Invalid resource ${name}`)
        }
      },
      shape: { attribute: `data-${name}`, value: 0 }
    })
  ])
) as Record<(typeof resourceFields)[number], Mark.Type<string>>

export function resourceAttributes(node: Node): ResourceAttributes {
  return Object.fromEntries(
    resourceFields.flatMap(name => {
      const value = markValue(node, fields[name])
      return value === undefined ? [] : [[name, value]]
    })
  )
}

/** Only fields present in the patch change; other fields keep their current values. */
export function resourceChanges(node: Node, from: number, attrs: ResourceAttributes): ChangeSet.Spec[] {
  return resourceFields.flatMap(name => {
    if (!Object.hasOwn(attrs, name)) return []
    const value = attrs[name]
    const previous = markValue(node, fields[name])
    if (previous === value) return []
    return [value === undefined ? { from, remove: fields[name].of(previous!) } : { from, add: fields[name].of(value) }]
  })
}

const keywords = {
  media: 'media image picture img photo video movie 图片 图像 媒体 照片 视频 影片',
  bookmark: 'bookmark website webpage link url card 网页 网站 网址 链接 卡片 书签'
}

export const resourceBlocks: readonly BlockDefinition[] = (Object.keys(nodes) as ResourceKind[]).map((kind, index) => ({
  name: kind,
  type: nodes[kind].type,
  schema: [
    nodes[kind],
    ...(index === 0 ? Object.values(fields) : []),
    Schema.Override.markTarget(Attrs, target => [target, nodes[kind]])
  ],
  extension: [Decoration.Tag.shape(nodes[kind], () => resourceWidget.of(kind))],
  import: node =>
    nodes[kind].withMarks(
      markSet([
        ...resourceFields.map(name => node.attrs[name] !== undefined && fields[name].of(node.attrs[name])),
        extraAttrs(node.attrs, resourceFields)
      ])
    ),
  read: node => element(kind, { ...extraOf(node), ...resourceAttributes(node) }),
  insert: {
    title: editorPhrases.ref(`${kind}_title`),
    detail: editorPhrases.ref(`${kind}_detail`),
    keywords: keywords[kind],
    turnInto: false,
    insert: editor => insertBlock(editor, nodes[kind])
  }
}))

function resourceNode(kind: ResourceKind, attrs: ResourceAttributes) {
  return resourceBlocks
    .find(block => block.name === kind)!
    .import(element(kind, attrs as Record<string, string>), { blocks: () => [], code: () => [] })
}

export function insertResource(editor: Wordgard, kind: ResourceKind, attrs: ResourceAttributes): boolean {
  if (editor.state.readOnly || editor.composing) return false
  insertBlock(editor, resourceNode(kind, attrs))
  return true
}
