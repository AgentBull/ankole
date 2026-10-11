import { GardState, Transaction } from '../state'
import { history } from '../history'
import { Leaf, Plot, Node, Pos, ChangeSet } from '../doc'
import { findWrappable, wrapBlockRange, autoJoinBlocks } from '../command'

const inputRule = GardState.Facet.define<InputRule>()

const appender = Transaction.appender.of(applyInputRules)

/** Objects of this type represent input rules. */
export class InputRule {
  /** Rules can be added to a configuration as extension values. */
  extension: GardState.Extension
  /** @internal */
  lookahead: RegExp | undefined
  /** @internal */
  inCode: boolean

  private constructor(
    /** @internal */
    readonly expr: RegExp,
    /** @internal */
    readonly apply: (state: GardState, match: InputRule.MatchArray) => Transaction.Spec | null,
    spec: InputRule.Spec
  ) {
    this.lookahead = spec.lookahead
    this.inCode = !!spec.inCode
    this.extension = [inputRule.of(this), appender]
  }

  /** Define an input rule. */
  static define(spec: InputRule.Spec) {
    return new InputRule(
      ensureAnchor(spec.expr),
      typeof spec.apply == 'string' ? applyString(spec.apply) : spec.apply,
      spec
    )
  }

  /**
   * Build an input rule for automatically wrapping a textblock when
   * a given string is typed. You'll probably want the regexp to
   * start with `^`, so that the pattern can only occur at the start
   * of a textblock. `tag` gives the type of plot to wrap in.
   *
   * When `empty` is given as `true`, the rule only applies when the
   * expression matches the textblock's entire content.
   */
  static wrapping(expr: RegExp, tag: Plot.Tag | ((match: InputRule.MatchArray) => Plot.Tag), empty = false) {
    return InputRule.define({
      expr,
      apply: (state, match) => {
        const wrapper = typeof tag == 'function' ? tag(match) : tag
        const { from, to } = match[0]
        const changes: ChangeSet.Spec[] = [{ from: from.pos, to: to.pos }]
        const range = findWrappable(from, from, wrapper)
        if (!range) return null
        changes.push(wrapBlockRange(range, wrapper))
        return autoJoinBlocks(state, {
          changes,
          annotations: history.isolate.of(true)
        })
      },
      lookahead: empty ? /^$/ : undefined
    })
  }

  /**
   * Build an input rule that changes the type of a textblock when the
   * matched text is typed into it. You'll usually want to start your
   * regexp with `^` so that it is only matched at the start of a
   * textblock. The optional `getAttrs` parameter can be used to compute
   * the new node's attributes, and works the same as in the
   * `InputRule.wrapping` function.
   */
  static textblockType(expr: RegExp, tag: Plot.Tag | ((match: InputRule.MatchArray) => Plot.Tag), empty = false) {
    return InputRule.define({
      expr,
      apply: (state, match) => {
        const { from, to } = match[0]
        const block = typeof tag == 'function' ? tag(match) : tag
        const outer = from.parent.parent
        if (!outer || !state.schema.canContain(outer.node.type, block.type)) return null
        return {
          changes: [{ from: from.pos - 1, to: to.pos, insert: [block] }],
          annotations: history.isolate.of(true)
        }
      },
      lookahead: empty ? /^$/ : undefined
    })
  }
}

export namespace InputRule {
  /** Configuration given to {@link InputRule.define}. */
  export interface Spec {
    /**
     * The regular expression to match against the text before the
     * input. This expression should end in a `$` marker.
     */
    expr: RegExp
    /**
     * Handler to call when this rule matches. `match` will contain
     * the document positions of the full match and all matched
     * groups in `expr`. Should return `true` when it has taken an
     * action, `false` when it didn't. You probably want to include
     * {@link history.history.isolate}`.of(true)` in any
     * transactions you dispatch from a rule handler, so that users
     * can undo the adjustment if it wasn't what they wanted.
     *
     * When given as a string, the full match will be replaced by
     * that string.
     */
    apply: ((state: GardState, match: InputRule.MatchArray) => Transaction.Spec | null) | string
    /**
     * Because the regular expression given in `expr` must end at the
     * cursor, it is matched against a string that stops at the
     * cursor, and cannot look beyond it. You can provide an
     * additional expression here (which should start with `^`) to
     * enforce a lookahead condition.
     */
    lookahead?: RegExp
    /**
     * By default, input rules don't apply inside nodes with the
     * {@link Node.Role.Code `Code` role}. Set this to `true` to
     * allow matches in code.
     */
    inCode?: boolean
  }

  /**
   * An object representing a matched group for an input rule. Holds
   * the start and end positions of the group in the document, along
   * with the matched text content.
   */
  export type Match = { from: Pos; to: Pos; text: string }

  /** An array of {@link InputRule.Match matches}. */
  export type MatchArray = readonly (InputRule.Match | null)[] & { 0: InputRule.Match }

  /** Input rule that converts double dashes to an emdash. */
  export const emDash = InputRule.define({ expr: /--$/, apply: '—' })
  /** Rule that converts three dots to an ellipsis character. */
  export const ellipsis = InputRule.define({ expr: /\.\.\.$/, apply: '…' })
  /** “Smart” opening double quotes. */
  export const openDoubleQuote = InputRule.define({ expr: /(?:^|[\s{[(<'"\u2018\u201C])(")$/, apply: '“' })
  /** “Smart” closing double quotes. */
  export const closeDoubleQuote = InputRule.define({ expr: /"$/, apply: '”' })
  /** ‘Smart’ opening single quotes. */
  export const openSingleQuote = InputRule.define({ expr: /(?:^|[\s{[(<'"\u2018\u201C])(')$/, apply: '‘' })
  /** ‘Smart’ closing single quotes. */
  export const closeSingleQuote = InputRule.define({ expr: /'$/, apply: '’' })

  /** Smart-quote related input rules. */
  export const smartQuotes: readonly InputRule[] = [
    openDoubleQuote,
    closeDoubleQuote,
    openSingleQuote,
    closeSingleQuote
  ]
}

function ensureAnchor(regexp: RegExp) {
  const needsIndex = (regexp as any).hasIndices === false,
    needsAnchor = !regexp.source.endsWith('$')
  if (!needsIndex && !needsAnchor) return regexp
  return new RegExp(needsAnchor ? `(?:${regexp.source})$` : regexp.source, regexp.flags + (needsIndex ? 'd' : ''))
}

function applyString(text: string) {
  return (_state: GardState, match: InputRule.MatchArray) => ({
    changes: { from: match[0].from.pos, to: match[0].to.pos, insert: [Leaf.text(text)] },
    annotations: history.isolate.of(true)
  })
}

function getGroupIndices(match: RegExpMatchArray): ([number, number] | undefined)[] {
  if ((match as any).indices) return (match as any).indices
  const result: ([number, number] | undefined)[] = [[0, match[0].length]]
  for (let i = 1, pos = 0; i < match.length; i++) {
    const found = match[i] ? match[0].indexOf(match[i]!, pos) : -1
    result.push(found < 0 ? undefined : [found, (pos = found + match[i]!.length)])
  }
  return result
}

function applyInputRules(trs: readonly Transaction[], state: GardState): Transaction.Spec | null {
  let typed = -1
  for (let i = trs.length - 1; i >= 0; i--) {
    if (trs[i]!.isUserEvent('input.type')) {
      for (let j = i + 1; j < trs.length; j++) if (trs[j]!.selection) return null
      typed = i
      break
    }
  }
  if (typed < 0) return null
  const cursor = state.sel.head,
    block = cursor.textblockParent
  if (!block) return null
  const map = state.textblockMap(block)
  const curIndex = map.toIndex(cursor.pos)
  const textBefore = map.text.slice(0, curIndex)
  const textAfter = map.text.slice(curIndex)
  rules: for (const rule of state.facet(inputRule)) {
    if (!rule.inCode && block.node.type.hasRole(Node.Role.Code)) continue
    const match = rule.expr.exec(textBefore)
    if (!match || (rule.lookahead && !rule.lookahead.test(textAfter))) continue
    const indices = getGroupIndices(match)
    const docMatch: (InputRule.Match | null)[] = []
    let parent = -1
    for (let i = 0; i < match.length; i++) {
      const text = match[i]
      if (text == null) {
        docMatch.push(null)
      } else {
        const is = indices[i]!
        const from = state.doc.resolve(map.fromIndex(is[0]))
        const to = state.doc.resolve(map.fromIndex(is[1]))
        // All match boundaries must fall in the same parent node
        if (parent < 0) parent = from.parent.before
        if (parent != from.parent.before || parent != to.parent.before) continue rules
        if (!rule.inCode && from.parent.node.type.hasRole(Node.Role.Code)) continue rules
        docMatch.push({ from, to, text })
      }
    }
    const spec = rule.apply(state, docMatch as any as InputRule.MatchArray)
    if (spec) return spec
  }
  return null
}
