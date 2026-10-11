import { Wordgard } from '../core/editor'
import { history } from '../core/history'
import { GardState } from '../core/state'
import { parseMarkdown, printMarkdown } from '../document/markdown'
import type { SourceFormat } from '../document/tree'
import { unknownNames } from '../document/vocabulary'
import { parseXml, printXml } from '../document/xml'
import { readTree, replaceTree } from './convert'

export type PageWrite = { format: SourceFormat; source: string; revision: number }
export type PageSnapshot = { revision: number; markdown: string; xml: string }
/** A written page. The warnings name unknown elements and attributes; they are kept as written. */
export type PageApplied = PageSnapshot & { warnings: string[] }

const sessions = new WeakMap<Wordgard, PageSession>()

// Counts the dispatches that changed the document when they apply. Update listeners run only when
// the view draws, a frame later and never while the editor is detached, so a revision taken from
// them misses edits. Registered by `pageSessions`.
const countChanges = Wordgard.transactionListener.of((transactions, editor) => {
  if (transactions.some(tr => tr.docChanged)) sessions.get(editor)?.changed()
})

/** The extension that page sessions need. `editorExtension` includes it. */
export const pageSessions: GardState.Extension = countChanges

/** The local commit boundary for the source panel and for page writes by a model. */
export class PageSession {
  private version = 0
  constructor(private editor: Wordgard) {
    sessions.set(editor, this)
  }
  get revision() {
    return this.version
  }
  /** @internal */
  changed() {
    this.version++
  }
  dispose() {
    if (sessions.get(this.editor) === this) sessions.delete(this.editor)
  }
  read(): PageSnapshot {
    const tree = readTree(this.editor.state.doc)
    return { revision: this.version, markdown: printMarkdown(tree), xml: printXml(tree) }
  }
  /** Replace the page in one undoable step. A stale revision or an active composition rejects the write. */
  apply(write: PageWrite): PageApplied {
    if (this.editor.composing) throw new Error('输入法组合尚未结束，请完成输入后再应用')
    if (write.revision !== this.version) {
      throw new Error('文档已变化，源码草稿已保留。请导出草稿并重新读取文档后合并修改。')
    }
    const tree = write.format === 'xml' ? parseXml(write.source) : parseMarkdown(write.source)
    // A page that cannot be printed must not replace the current page.
    printMarkdown(tree)
    this.editor.dispatch({
      ...replaceTree(this.editor.state, tree),
      annotations: history.isolate.of(true),
      userEvent: 'page.write'
    })
    return { ...this.read(), warnings: unknownNames(tree) }
  }
}
