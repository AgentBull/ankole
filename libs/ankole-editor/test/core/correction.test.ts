import { describe, it } from 'bun:test'
import ist from 'ist'
import { GardState, Correction } from '../../src/core/state'
import { Leaf } from '../../src/core/doc'
import { Strong, Emphasis, Paragraph } from '../../src/core/types/schema'
import { Doc, Blockquote } from './types'

import { basicBuilders, eq } from './schema'
const { doc, p, blockquote, h1, $img, em } = basicBuilders

describe('Correction', () => {
  it('is notified of child list changes', () => {
    const notified: number[] = []
    let s = GardState.create({
      doc: doc(p('abc'), blockquote(p('def'))),
      config: Correction.onChildList(Paragraph, node => {
        notified.push(node.pos)
        return null
      })
    })
    s = s.update({ changes: { from: 1, to: 2 } }).state
    ist(notified.join(), '0')
    s = s.update({ changes: { from: 9, insert: [$img] } }).state
    ist(notified.join(), '0,5')
    void s.update({ changes: { from: 0, insert: [p('!')] } }).state
    ist(notified.join(), '0,5,0')
  })

  it('is notified of content changes', () => {
    const notified: number[] = []
    let s = GardState.create({
      doc: doc(blockquote(p('abc'), p('def'))),
      config: Correction.onContent(Blockquote, node => {
        notified.push(node.pos)
        return null
      })
    })
    s = s.update({ changes: { from: 2, insert: [Leaf.text('-')] } }).state
    ist(notified.join(), '0')
    void s.update({
      changes: [
        { from: 1, insert: [p()] },
        { from: 7, insert: [p()] }
      ]
    }).state
    ist(notified.join(), '0,0')
  })

  it('is notified of property changes', () => {
    const notified: number[] = []
    let s = GardState.create({
      doc: doc(p('abc ', em('def'))),
      config: Correction.onMarks(Leaf.Text, node => {
        notified.push(node.pos)
        return null
      })
    })
    s = s.update({ changes: { from: 5, to: 8, remove: Emphasis } }).state
    ist(notified.join(), '1')
    void s.update({ changes: { from: 1, to: 4, add: Strong } }).state
    ist(notified.join(), '1,1')
  })

  it('can apply corrections', () => {
    let s = GardState.create({
      doc: doc(h1('h'), p('abc')),
      config: Correction.onChildList(Doc, node => {
        if (node.node.firstChild!.name == 'Heading') return null
        return { from: node.start, insert: [h1()] }
      })
    })
    s = s.update({ changes: { from: 0, insert: [p('...')] } }).state
    ist(s.doc, doc(h1(), p('...'), h1('h'), p('abc')), eq)
    s = s.update({ changes: { from: 0, to: 7 } }).state
    ist(s.doc, doc(h1('h'), p('abc')), eq)
    s = s.update({ changes: { from: 0, to: 3 } }).state
    ist(s.doc, doc(h1(), p('abc')), eq)
  })

  it('can apply multiple corrections from a single source', () => {
    let s = GardState.create({
      doc: doc(blockquote(h1('h'), p('abc')), blockquote(h1('h'), p('abc'))),
      config: Correction.onChildList(Blockquote, node => {
        if (node.node.firstChild!.name == 'Heading') return null
        return { from: node.start, insert: [h1()] }
      })
    })
    s = s.update({
      changes: [
        { from: 1, to: 4 },
        { from: 11, insert: [p('?')] }
      ]
    }).state
    ist(s.doc, doc(blockquote(h1(), p('abc')), blockquote(h1(), p('?'), h1('h'), p('abc'))), eq)
  })

  it('can apply a correction to a start doc', () => {
    const c = Correction.onContent(Paragraph, node => {
      if (node.node.contentLength) return null
      return { from: node.start, insert: [Leaf.text('.')] }
    })
    const tr = c.scan(GardState.create({ doc: doc(p(), p('a'), p()) }))
    ist(tr)
    ist(tr!.newDoc, doc(p('.'), p('a'), p('.')), eq)
  })
})
