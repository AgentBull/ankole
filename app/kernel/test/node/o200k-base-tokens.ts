import { existsSync } from 'node:fs'
import { createRequire } from 'node:module'
import { nodeAddonPath } from '../../scripts/node-addon'

const require = createRequire(import.meta.url)

type O200kBaseTokenAddon = {
  estimateO200kBaseTokens(text: string): number
}

let addon: O200kBaseTokenAddon | undefined

export function estimateO200kBaseTokens(text: string): number {
  const count = binding().estimateO200kBaseTokens(text)
  if (!Number.isSafeInteger(count) || count < 0) {
    throw new Error(`o200k_base token count is not a safe integer: ${String(count)}`)
  }
  return count
}

function binding(): O200kBaseTokenAddon {
  if (addon) return addon
  const path = nodeAddonPath()
  if (!existsSync(path)) {
    throw new Error('The o200k_base Node addon is not built. Run bun run --filter @ankole/kernel build:node')
  }
  addon = require(path) as O200kBaseTokenAddon
  return addon
}
