import { describe, expect, test } from 'bun:test'
import {
  getCaptureSnapshotAttr,
  registerCaptureSnapshot,
  resolveCaptureSnapshotsInSubtree
} from './dom-capture-snapshot'
import { applyResolvedSnapshotsToClone, prepareClonedArticleImages } from './select-screenshot'
import { SelectShareLightbox } from './select-share-lightbox'

class MiniNode {
  readonly attrs = new Map<string, string>()
  readonly children: MiniNode[] = []
  parent: MiniNode | null = null
  style: { cssText: string } = { cssText: '' }
  src = ''
  alt = ''

  constructor(readonly tagName: string) {}

  setAttribute(name: string, value: string) {
    this.attrs.set(name, value)
  }

  getAttribute(name: string) {
    return this.attrs.get(name) ?? null
  }

  removeAttribute(name: string) {
    this.attrs.delete(name)
  }

  appendChild(child: MiniNode) {
    child.parent = this
    this.children.push(child)
    return child
  }

  replaceWith(replacement: MiniNode) {
    if (!this.parent) return
    const idx = this.parent.children.indexOf(this)
    if (idx !== -1) {
      replacement.parent = this.parent
      this.parent.children[idx] = replacement
      this.parent = null
    }
  }

  cloneNode(): MiniNode {
    const copy = new MiniNode(this.tagName)
    for (const [k, v] of this.attrs) copy.attrs.set(k, v)
    copy.style = { cssText: this.style.cssText }
    copy.src = this.src
    copy.alt = this.alt
    for (const child of this.children) copy.appendChild(child.cloneNode())
    return copy
  }

  querySelectorAll(selector: string): MiniNode[] {
    const out: MiniNode[] = []
    const attrName = getCaptureSnapshotAttr()
    const visit = (node: MiniNode) => {
      for (const child of node.children) {
        if (selector === `[${attrName}]` && child.attrs.has(attrName)) {
          out.push(child)
        } else if (selector === child.tagName) {
          out.push(child)
        }
        visit(child)
      }
    }
    visit(this)
    return out
  }
}

describe('DOM capture snapshot replacement & share lightbox', () => {
  test('replaces sandboxed Mermaid iframe card in cloned DOM with snapshot <img>', async () => {
    const root = new MiniNode('div')
    const mermaidCard = new MiniNode('div')
    mermaidCard.appendChild(new MiniNode('iframe'))
    root.appendChild(mermaidCard)

    const unregister = registerCaptureSnapshot(mermaidCard as unknown as HTMLElement, () => ({
      dataUrl: 'data:image/svg+xml;charset=utf-8,%3Csvg%3E%3C%2Fsvg%3E',
      width: 420,
      height: 240,
      alt: 'Mermaid diagram'
    }))

    const snapshots = await resolveCaptureSnapshotsInSubtree(root as unknown as ParentNode)
    expect(snapshots.size).toBe(1)

    const clone = root.cloneNode()
    const fakeDoc = {
      createElement: (tag: string) => new MiniNode(tag)
    } as unknown as Document

    applyResolvedSnapshotsToClone(clone as unknown as ParentNode, snapshots, fakeDoc)

    expect(clone.querySelectorAll('iframe')).toHaveLength(0)
    const imgs = clone.querySelectorAll('img')
    expect(imgs).toHaveLength(1)
    expect(imgs[0]?.alt).toBe('Mermaid diagram')
    expect(imgs[0]?.src).toContain('data:image/svg+xml')

    unregister()
    expect(mermaidCard.getAttribute(getCaptureSnapshotAttr())).toBeNull()
  })

  test('prepareClonedArticleImages inlines live images before inserting Mermaid snapshot so indices never shift', async () => {
    const liveArticle = new MiniNode('article')
    const avatar = new MiniNode('img')
    avatar.src = '/avatars/alice.png'
    liveArticle.appendChild(avatar)

    const mermaidCard = new MiniNode('div')
    mermaidCard.appendChild(new MiniNode('iframe'))
    liveArticle.appendChild(mermaidCard)

    const trailingImg = new MiniNode('img')
    trailingImg.src = '/attachments/chart.png'
    liveArticle.appendChild(trailingImg)

    const unregister = registerCaptureSnapshot(mermaidCard as unknown as HTMLElement, () => ({
      dataUrl: 'data:image/png;base64,MERMAID_PNG',
      width: 700,
      height: 360,
      alt: 'Mermaid diagram'
    }))

    try {
      const snapshots = await resolveCaptureSnapshotsInSubtree(liveArticle as unknown as ParentNode)
      const clone = liveArticle.cloneNode()
      const fakeDoc = {
        createElement: (tag: string) => new MiniNode(tag)
      } as unknown as Document

      await prepareClonedArticleImages(
        liveArticle as unknown as ParentNode,
        clone as unknown as ParentNode,
        snapshots,
        fakeDoc,
        async (live, cloned) => {
          cloned.src = `data:image/png;base64,INLINED:${live.src}`
        }
      )

      const imgs = clone.querySelectorAll('img')
      expect(imgs).toHaveLength(3)
      expect(imgs[0]?.src).toBe('data:image/png;base64,INLINED:/avatars/alice.png')
      expect(imgs[1]?.src).toBe('data:image/png;base64,MERMAID_PNG')
      expect(imgs[1]?.style.cssText).toContain('width:700px')
      expect(imgs[2]?.src).toBe('data:image/png;base64,INLINED:/attachments/chart.png')
    } finally {
      unregister()
    }
  })

  test('SelectShareLightbox component module exports cleanly', () => {
    expect(typeof SelectShareLightbox).toBe('function')
  })
})
