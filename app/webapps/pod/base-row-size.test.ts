import { expect, test } from 'bun:test'
import { baseGridRowEstimate } from './base-row-size'

test('the base grid estimates the desktop row height when no viewport query exists', () => {
  expect(baseGridRowEstimate()).toBe(32)
})
