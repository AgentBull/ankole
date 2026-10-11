import { type Node, type Leaf } from './node'

export class TextOutput {
  text = ''
  started = false

  constructor(
    readonly blockSep: string,
    readonly leafText?: (node: Leaf) => string
  ) {}

  serialize(node: Node): boolean {
    const nodeText = node.isPlot
      ? null
      : node.isText
        ? (node.param as string)
        : node.type.spec.toText
          ? node.type.spec.toText(node)
          : this.leafText
            ? this.leafText(node)
            : ''
    if (node.isLeaf ? node.isBlock && nodeText : node.isTextblock) this.openBlock()
    if (nodeText != null) {
      this.text += nodeText
      this.started = true
    }
    return nodeText != null
  }

  openBlock() {
    if (this.started) this.text += this.blockSep
    else this.started = true
  }
}
