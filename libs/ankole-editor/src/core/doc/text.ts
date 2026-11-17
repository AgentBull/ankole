import { type Node, type Leaf } from './node'

export class TextOutput {
  text = ''
  started = false

  constructor(
    readonly blockSep: string,
    readonly leafText?: (node: Leaf) => string
  ) {}

  private nodeText(node: Node): string | null {
    if (node.isPlot) return null
    if (node.isText) return node.param as string
    if (node.type.spec.toText) return node.type.spec.toText(node)
    return this.leafText ? this.leafText(node) : ''
  }

  serialize(node: Node): boolean {
    const nodeText = this.nodeText(node)
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
