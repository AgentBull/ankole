import { Node, Pos, ChangeSet, Plot } from '../doc'
import { Transaction } from './transaction'
import { GardState } from './state'

enum CorrectionEvent {
  ChildList = 0,
  Content = 1,
  Marks = 2
}

type PlanElt = { node: Pos.Node; correction: Correction }

// The number of parent levels above the start of the range that the range leaves in `doc`. A change
// that replaces the range also changes the child lists of the plots at those levels.
function rangeClimb(doc: Plot.Doc, from: number, to: number) {
  let climb = 0
  for (let parent = doc.resolve(from).parent; parent.parent && to > parent.end; parent = parent.parent) climb++
  return climb
}

function scanChanges(changes: ChangeSet, doc: Plot.Doc, corrections: readonly Correction[], startDoc?: Plot.Doc) {
  const childList: Correction[] = [],
    content: Correction[] = [],
    marks: Correction[] = []
  const buckets = [childList, content, marks]
  for (const c of corrections) buckets[c.event]!.push(c)

  const plan: PlanElt[] = []
  // Plots checked for content corrections, and plots checked for child-list corrections
  const queried: Set<number> = new Set(),
    childListQueried: Set<number> = new Set(),
    newNode = childList.concat(content)
  let updateWalker: Pos.Walker | undefined
  const { schema } = doc
  const checkMarks = (node: Node, pos: number, parent: Pos.Plot, index: number) => {
    for (const correction of marks) {
      if (schema.matchNode(node.type, correction.query)) {
        plan.push({ node: Pos.Node.create(parent, node, pos, index), correction })
      }
    }
  }
  if (marks.length) {
    updateWalker = {
      enterPlot: checkMarks,
      skip(node: Node, pos: number, parent: Pos.Plot, index: number) {
        // Back up to the start of the node
        if (node.isText && !parent.node.content.includes(node)) {
          for (let off = parent.start, i = 0; ; i++) {
            const next = parent.node.content[i]!,
              end = off + next.length
            if (end > pos) {
              node = next!
              pos = off
              break
            }
            off = end
          }
          if (queried.has(pos)) return
          queried.add(pos)
        }
        checkMarks(node, pos, parent, index)
      },
      leavePlot() {}
    }
  }
  const changeWalker: Pos.Walker = {
    enterPlot(node, pos, parent, index) {
      queried.add(pos)
      childListQueried.add(pos)
      this.skip(node, pos, parent, index)
    },
    skip(node, pos, parent, index) {
      if (node.isPlot) {
        for (const correction of newNode) {
          if (schema.matchNode(node.type, correction.query)) {
            plan.push({ node: Pos.Plot.create(parent, node, pos, index), correction })
          }
        }
      }
    },
    leavePlot() {}
  }

  let pos = doc.resolve(0)
  for (let i = 0, posA = 0, { sections } = changes; i < sections.length;) {
    let len = sections[i++]!,
      ins = sections[i++]!
    if (ins == -1 || (ins == -2 && !updateWalker)) {
      if (i == sections.length) break
      pos = pos.advance(len)
      posA += len
    } else if (ins == -2) {
      while (i < sections.length && sections[i + 1] == -2) {
        len += sections[i++]!
        i++
      }
      pos = pos.walk(len, updateWalker!)
      posA += len
    } else {
      while (i < sections.length && sections[i + 1]! >= 0) {
        len += sections[i++]!
        ins += sections[i++]!
      }
      const start = pos.pos,
        end = start + ins
      // A deletion that joins blocks can show as a change in one text block of `doc`. The child
      // lists of the plots that the deleted range left in the start document changed too.
      let climb = startDoc && len ? rangeClimb(startDoc, posA, posA + len) : 0
      posA += len
      for (let checkChildList = childList!.length > 0, parent = pos.parent; ;) {
        const key = parent.start - 1,
          seen = queried.has(key)
        // An earlier change checked this plot and its ancestors, but maybe not the child lists that
        // this change still has to check
        if (seen && !checkChildList) break
        if (checkChildList) {
          if (!childListQueried.has(key)) {
            childListQueried.add(key)
            for (const correction of childList!) {
              if (schema.matchNode(parent.node.type, correction.query)) plan.push({ node: parent, correction })
            }
          }
          if (start >= parent.start && end <= parent.end && climb-- <= 0) checkChildList = false
        }
        if (!seen) {
          queried.add(key)
          for (const correction of content!) {
            if (schema.matchNode(parent.node.type, correction.query)) plan.push({ node: parent, correction })
          }
        }
        if (!parent.parent || (!content!.length && !checkChildList)) break
        parent = parent.parent
      }
      pos = pos.walk(ins, changeWalker)
    }
  }
  return plan
}

const corrections = GardState.Facet.define<Correction>()

const planCache = new WeakMap<Transaction, PlanElt[]>()

/**
 * The class representing a correction. Counts as an editor
 * extension.
 *
 * Corrections install themselves as {@link Transaction.extender
 * transaction extenders} that check modified nodes and, if
 * necessary, apply fixes to enforce constraints. In normal
 * operation, this means that they guarantee the constraints
 * implemented in the transaction are enforced.
 *
 * They do not activate for {@link Transaction.remote remote}
 * transactions, because acting on those can cause collaborative
 * editing setups to malfunction (for example, causing all peers to
 * repeatedly try to correct the same issue, causing an endless loop
 * of updates or other chaos). The collab module has special
 * provisions for integrating corrections in the step transformation
 * in a safe way, but that requires you to explicitly tell it to use
 * them, both on the {@link collab.Config.corrections client} and
 * the {@link collab.transformUpdate server}.
 */
export class Correction {
  /**
   * To take effect, corrections must be included in an editor
   * configuration.
   */
  extension: GardState.Extension

  private constructor(
    /** @internal */
    readonly event: CorrectionEvent,
    /** @internal */
    readonly query: Node.Query,
    /** @internal */
    readonly correct: (node: Pos.Node) => ChangeSet.Spec | null
  ) {
    this.extension = [corrections.of(this as any), Transaction.extender.of(tr => this.extend(tr))]
  }

  /** @internal */
  extend(tr: Transaction) {
    if (!tr.docChanged || tr.annotation(Transaction.remote)) return null
    let plan = planCache.get(tr)
    if (!plan) {
      planCache.set(
        tr,
        (plan = scanChanges(tr.changes, tr.newDoc, tr.startState.facet(corrections), tr.startState.doc))
      )
    }
    const changes: ChangeSet.Spec[] = []
    for (const elt of plan) {
      if (elt.correction == this) {
        const change = this.correct(elt.node)
        if (change) changes.push(change)
      }
    }
    return changes.length ? { changes, sequential: true } : null
  }

  /**
   * This method can be used to run a correction agains all matching
   * nodes in an existing document. If the correction makes any
   * changes, the method returns a transaction with those changes.
   */
  scan(state: GardState) {
    const changes: ChangeSet.Spec[] = []
    state.doc.iterate((node, pos) => {
      if (state.schema.matchNode(node.type, this.query) && (this.event == CorrectionEvent.Marks || node.isPlot)) {
        const change = this.correct(state.doc.resolveNode(pos)!)
        if (change) changes.push(change)
      }
    })
    if (changes.length) return state.update({ changes })
    return null
  }

  /**
   * Create a correction that runs whenever the child list of a node
   * that matches the given query changes, or such a node is inserted
   * into the document.
   */
  static onChildList(query: Node.Query, correct: (node: Pos.Plot) => ChangeSet.Spec | null) {
    return new Correction(CorrectionEvent.ChildList, query, correct as any)
  }

  /**
   * Create a correction that runs whenever any content inside a node
   * that matches the given query changes, or such a node is inserted
   * into the document.
   */
  static onContent(query: Node.Query, correct: (node: Pos.Plot) => ChangeSet.Spec | null) {
    return new Correction(CorrectionEvent.Content, query, correct as any)
  }

  /**
   * Define a correction that runs whenever the set of marks on a
   * matching tag changes.
   */
  static onMarks(query: Node.Query, correct: (node: Pos.Node) => ChangeSet.Spec | null) {
    return new Correction(CorrectionEvent.Marks, query, correct)
  }

  /**
   * Check the ranges touched by the given change set against the
   * given list of corrections. Return a change set if any changes
   * need to be made. (This isn't how you normally use corrections,
   * but can be useful in a situation where you aren't working with
   * an editor state transaction.) Pass the document before the
   * changes as `startDoc` so that a deletion that joined blocks
   * also checks the plots that it left.
   */
  static check(changes: ChangeSet, doc: Plot.Doc, corrections: readonly Correction[], startDoc?: Plot.Doc) {
    if (!corrections.length || changes.empty) return null
    const plan = scanChanges(changes, doc, corrections, startDoc),
      changed: ChangeSet.Spec[] = []
    for (const c of corrections) {
      for (const elt of plan) {
        if (elt.correction == c) {
          const change = c.correct(elt.node)
          if (change) changed.push(change)
        }
      }
    }
    return changed.length ? ChangeSet.create(doc, changed) : null
  }
}
