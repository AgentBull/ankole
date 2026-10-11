import { Plot, Node } from '../doc'
import { GardState, Transaction } from '../state'
import { Set, RangeSet, PointSet } from '../set'
import { Decoration } from './decoration'

function offset<T>(
  add: (value: T, from: number, to?: number) => void,
  offset: number
): (value: T, from: number, to?: number) => void {
  return (v, from, to) => add(v, from + offset, to == null ? undefined : to + offset)
}

type Source<D> = (plot: Plot, offset: number, add: (value: D, from: number, to?: number) => void) => void

function init<D, S extends Set<D>>(
  type: Node.Query,
  create: (source: Set.Source<D>) => S,
  source: Source<D>,
  doc: Plot.Doc
): S {
  return create(add => {
    doc.iterate((node, pos) => {
      if (node.isPlot && doc.schema.matchNode(node.type, type)) source(node as Plot, pos + 1, add)
    })
  })
}

function refreshByPred<D, S extends Set<D>>(
  type: Node.Query,
  source: Source<D>,
  doc: Plot.Doc,
  deco: S,
  pred: (plot: Plot) => boolean
): S {
  const recreate: Set.Replacement<D>[] = []
  doc.iterate((node, pos) => {
    if (doc.schema.matchNode(node.type, type) && pred(node as Plot)) {
      recreate.push({
        from: pos,
        to: pos + node.length,
        add: add => source(node as Plot, pos + 1, add)
      })
    }
  })
  return recreate.length ? deco.modify({ replace: recreate as any }) : deco
}

function update<D, S extends Set<D>>(
  config: Config,
  create: (source: Set.Source<D>) => S,
  source: Source<D>,
  deco: S,
  tr: Transaction
): S {
  const doc = tr.newDoc
  const refresh = config.refresh && config.refresh(tr)
  if (refresh === true) return init(config.type, create, source, doc)
  if (refresh) deco = refreshByPred(config.type, source, tr.startState.doc, deco, refresh)
  if (!tr.docChanged && !refresh) return deco
  const recreate: Set.Replacement<D>[] = []
  const clear: { from: number; to: number }[] = []
  tr.changes.iterChangedRanges((fromA, toA, fromB, toB) => {
    let covered = false
    doc.iterate(fromB, toB, (node, pos) => {
      if (doc.schema.matchNode(node.type, config.type)) {
        recreate.push({
          from: pos,
          to: pos + node.length,
          add: add => source(node as Plot, pos + 1, add)
        })
        if (pos < toB && pos + node.length > toB) covered = true
        return false
      }
    })
    if (!covered) {
      const end = tr.startState.doc.resolve(toA)
      const open = end.matchingParent(p => doc.schema.matchNode(p.type, config.type))
      if (open && open.before >= fromA) clear.push({ from: open.before, to: open.after })
    }
  })
  if (clear.length) deco = deco.modify({ replace: clear })
  deco = deco.map(tr.changes, recreate as any)
  return deco
}

type Config = {
  /** The type of plot to decorate. */
  type: Node.Query
  /**
   * A function that produces range decorations for a plot. `from`
   * and `to` should be relative to the start of the plot's content,
   * and be fall entirely within the plot.
   */
  ranges?: (node: Plot, range: (deco: Decoration.Range, from: number, to: number) => void) => void
  /**
   * A function that produces point decorations for a plot. `pos`
   * should be relative to the start of the plot's content.
   */
  points?: (node: Plot, point: (deco: Decoration.Point, pos: number) => void) => void
  /**
   * An optional function that causes the decorations to be recreated
   * on matching transaction, either for the entire document (`true`)
   * or for any plot where the returned predicate returns `true`.
   */
  refresh?: (tr: Transaction) => boolean | ((plot: Plot) => boolean)
}

/**
 * Create an extension that adds decorations to plots matching the
 * given type.
 */
export function decoratePlots(config: Config): GardState.Extension {
  const result: GardState.Extension[] = []
  const { type, points, ranges } = config
  if (points) {
    const source: Source<Decoration.Point> = (plot, start, add) => points(plot, offset(add, start))
    const field = GardState.Field.define<Decoration.Point.Set>({
      create(state) {
        return init<Decoration.Point, Decoration.Point.Set>(type, PointSet.create, source, state.doc)
      },
      update(value, tr) {
        return update(config, PointSet.create, source, value, tr)
      }
    })
    result.push(
      field,
      Decoration.Point.source.of(s => s.field(field))
    )
  }
  if (ranges) {
    const source: Source<Decoration.Range> = (plot, start, add) => ranges(plot, offset(add, start))
    const field = GardState.Field.define<Decoration.Range.Set>({
      create(state) {
        return init(type, RangeSet.create, source, state.doc)
      },
      update(value, tr) {
        return update(config, RangeSet.create, source, value, tr)
      }
    })
    result.push(
      field,
      Decoration.Range.source.of(s => s.field(field))
    )
  }
  return result
}
