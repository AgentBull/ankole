import { expect, test } from 'bun:test'
import fc from 'fast-check'
import { ChangeSet } from '../src/core/doc'
import { printXml, parseXml } from '../src/document/xml'
import { pageDocument, readTree } from '../src/editor/convert'
import { schema } from '../src/editor/schema'
import {
  boundarySource,
  buildCorpus,
  editChain,
  editBatches,
  parseError,
  readCorpus,
  verifyChain
} from '../scripts/rust-corpus'
import { page } from './arbitrary'

const corpus = readCorpus()

test('the golden file matches the current implementation without rewriting it', () => {
  expect(corpus).toEqual(JSON.parse(JSON.stringify(buildCorpus(corpus.seed))))
  expect(corpus.format).toBe(2)
  expect(corpus.limits).toEqual({ source: 8 * 1024 * 1024, nodes: 100_000, depth: 128 })
})

test('valid and invalid XML reproduce their stored outcomes', () => {
  for (const sample of corpus.xml) {
    const doc = pageDocument(parseXml(sample.xml))
    expect(doc.toJSON()).toEqual(sample.document)
    expect(printXml(readTree(doc))).toBe(sample.canonicalXml)
  }
  for (const sample of corpus.invalid) {
    expect(sample.error).not.toBeNull()
    expect(parseError(sample.xml)).toBe(sample.error)
  }
})

test('all three limits accept the boundary and reject exactly one unit above it', () => {
  for (const boundary of corpus.boundaries) {
    const source = boundarySource(boundary)
    expect(parseError(source)).toBe(boundary.error)
    expect(boundary.error === null).toBe(boundary.name.endsWith('-at'))
  }
  expect(boundarySource(corpus.boundaries.find(boundary => boundary.name === 'source-at')!).length).toBe(
    corpus.limits.source
  )
  expect(boundarySource(corpus.boundaries.find(boundary => boundary.name === 'source-over')!).length).toBe(
    corpus.limits.source + 1
  )
})

test('local batches preserve positions and match both replay paths after every batch', () => {
  for (const sample of corpus.edits) {
    expect(sample.batches.length).toBeGreaterThan(1)
    expect(sample.steps).toHaveLength(sample.batches.length)
    expect(sample.batches.map(batch => batch.clientSeq)).toEqual(sample.batches.map((_, index) => index + 1))
    verifyChain(sample)
  }
  const text = corpus.edits.find(sample => sample.name === 'text-and-marks')!
  const doc = pageDocument(parseXml(text.initialXml))
  // A retained prefix and suffix distinguish a local edit from a whole-document replacement.
  const changes = ChangeSet.fromJSON(schema, text.batches[0]!.changes)
  expect(changes.sections[1]).toBe(-1)
  expect(changes.sections.at(-1)).toBe(-1)
  expect(changes.apply(doc).length).toBeGreaterThan(doc.length)
})

test('random pages and local operations retain their invariant, with shrinking on failure', () => {
  fc.assert(
    fc.property(page, editBatches, (tree, edits) => {
      verifyChain(editChain('property', printXml(tree), edits))
    }),
    {
      seed: process.env.FC_SEED ? Number(process.env.FC_SEED) : 20261005,
      numRuns: 100
    }
  )
})

test('typing into the empty-page placeholder survives the next stored batch', () => {
  const operation = { target: 0, offset: 0, width: 1, text: 'x' }
  verifyChain(
    editChain('empty-page', '<page />', [[{ ...operation, kind: 'insert' }], [{ ...operation, kind: 'insert' }]])
  )
})

test('whitespace marks survive the next stored batch', () => {
  const operation = { target: 0, offset: 0, width: 1, text: 'x' }
  verifyChain(
    editChain('marked-whitespace', '<page><p>a b</p></page>', [
      [{ ...operation, kind: 'mark', width: 2 }],
      [{ ...operation, kind: 'insert', offset: 2 }]
    ])
  )
})
