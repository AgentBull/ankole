import { describe, it } from 'bun:test'
import { Mark } from '../../src/core/doc'
import { Emphasis, Strong, Code } from '../../src/core/types/schema'
import { Link } from './types'
import ist from 'ist'

const Tag = Mark.Type.define<readonly number[]>('Tag', {
  rank: 10,
  set: { compare: (a, b) => a - b },
  shape: { attribute: 'tag', value: ns => ns.join(' '), readAttribute: val => val.split(' ').map(n => Number(n)) }
})
const tag1 = Tag.of([1]),
  tag2 = Tag.of([2]),
  tag12 = Tag.of([1, 2])

describe('Mark', () => {
  describe('eq', () => {
    it('considers identical links to be the same', () => ist(Link.of('http://foo').eq(Link.of('http://foo'))))

    it('considers different links to differ', () => ist(!Link.of('http://foo').eq(Link.of('http://bar'))))
  })

  function set(marks: Mark.Set) {
    let result = Mark.none
    for (const mark of marks) result = mark.addToSet(result)
    return result
  }

  function eqSet(a: Mark.Set, b: Mark.Set) {
    if (a.length != b.length) return false
    for (let i = 0; i < a.length; i++) if (!a[i]!.eq(b[i]!)) return false
    return true
  }

  describe('set-eq', () => {
    it('returns true for simple identical sets', () => ist(set([Emphasis, Strong]), set([Emphasis, Strong]), eqSet))

    it('returns false for different sets', () => ist(!eqSet(set([Emphasis, Strong]), set([Emphasis, Code]))))

    it('returns false when set size differs', () => ist(!eqSet(set([Emphasis, Strong]), set([Emphasis, Strong, Code]))))

    it('recognizes identical links in set', () =>
      ist(set([Link.of('http://foo'), Code]), set([Link.of('http://foo'), Code]), eqSet))

    it('recognizes different links in set', () =>
      ist(!eqSet(set([Link.of('http://foo'), Code]), set([Link.of('http://bar'), Code]))))
  })

  describe('add', () => {
    it('can add to the empty set', () => ist(Emphasis.addToSet([]), [Emphasis], eqSet))

    it('is a no-op when the added thing is in set', () => ist(set([Emphasis, Emphasis]), [Emphasis], eqSet))

    it('adds marks with lower rank before others', () => ist(set([Strong, Emphasis]), [Emphasis, Strong], eqSet))

    it('adds marks with higher rank after others', () =>
      ist(Emphasis.addToSet(set([Strong])), [Emphasis, Strong], eqSet))

    it('replaces different marks with new params', () =>
      ist(
        Link.of('http://bar').addToSet(set([Link.of('http://foo'), Emphasis])),
        [Link.of('http://bar'), Emphasis],
        eqSet
      ))

    it('does nothing when adding an existing link', () =>
      ist(
        Link.of('http://foo').addToSet(set([Emphasis, Link.of('http://foo')])),
        [Link.of('http://foo'), Emphasis],
        eqSet
      ))

    it('puts code marks at the end', () =>
      ist(
        Code.addToSet(set([Link.of('http://foo'), Emphasis, Strong])),
        [Link.of('http://foo'), Emphasis, Strong, Code],
        eqSet
      ))

    it('puts marks with middle rank in the middle', () =>
      ist(Strong.addToSet(set([Emphasis, Code])), [Emphasis, Strong, Code], eqSet))

    it('combines multi-marks', () => ist(tag2.addToSet(set([tag1])), [tag12], eqSet))

    it("doesn't duplicate identical instances of multi-marks", () => ist(tag1.addToSet(set([tag1])), [tag1], eqSet))
  })

  describe('remove', () => {
    it('is a no-op for the empty set', () => ist(Emphasis.removeFromSet([]), [], eqSet))

    it('can remove the last mark from a set', () => ist(Emphasis.removeFromSet([Emphasis]), [], eqSet))

    it("is a no-op when the mark isn't in the set", () => ist(Strong.removeFromSet([Emphasis]), [Emphasis], eqSet))

    it('can remove a mark with params', () =>
      ist(Link.of('http://foo').removeFromSet([Link.of('http://foo')]), [], eqSet))

    it("doesn't remove a mark when its params differ", () =>
      ist(Link.of('http://foo').removeFromSet([Link.of('http://bar')]), [Link.of('http://bar')], eqSet))
  })
})
