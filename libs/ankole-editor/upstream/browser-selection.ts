// Both browser runners measure DOM text positions, without editor state.
export function setTextRange(element: HTMLElement, { anchor, focus }: { anchor: number[]; focus: number[] }) {
  function point([block, offset]: number[]): [Node, number] {
    const paragraph = element.children[block!]!
    const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT)
    let rest = offset!
    while (walker.nextNode()) {
      const text = walker.currentNode as Text
      if (rest <= text.length) return [text, rest]
      rest -= text.length
    }
    if (rest) throw new Error('Invalid fixture offset')
    return [paragraph, 0]
  }
  element.focus()
  window.getSelection()!.setBaseAndExtent(...point(anchor), ...point(focus))
  document.dispatchEvent(new Event('selectionchange'))
}

export function readTextRange(element: HTMLElement) {
  const selection = window.getSelection()!
  function point(node: Node, offset: number) {
    const paragraphs = [...element.children]
    const index = paragraphs.findIndex(paragraph => paragraph === node || paragraph.contains(node))
    if (index < 0) throw new Error('Selection left the document')
    const range = document.createRange()
    range.selectNodeContents(paragraphs[index]!)
    range.setEnd(node, offset)
    return [index, range.toString().length]
  }
  return {
    anchor: point(selection.anchorNode!, selection.anchorOffset),
    focus: point(selection.focusNode!, selection.focusOffset)
  }
}
