import { beforeAll, expect, it } from 'bun:test'
import { buildNodeAddon } from '../../scripts/node-addon'
import { estimateO200kBaseTokens } from './o200k-base-tokens'

beforeAll(() => {
  buildNodeAddon()
}, 600_000)

it('counts the same o200k_base tokens as the kernel', () => {
  expect(estimateO200kBaseTokens('Hello world')).toBe(2)
  expect(estimateO200kBaseTokens('')).toBe(0)
  expect(estimateO200kBaseTokens('记忆系统')).toBe(3)
})
