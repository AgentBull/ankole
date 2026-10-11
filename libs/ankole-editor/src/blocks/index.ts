import type { BlockDefinition } from '../editor/block'
import { callout } from './callout'
import { database } from './database'

/** Blocks with their own editing node. Add a block here to install it. */
export const blocks: readonly BlockDefinition[] = [callout, database]
