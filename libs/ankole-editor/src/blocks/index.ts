import type { BlockDefinition } from '../editor/block'
import { callout } from './callout'
import { embed } from './embed'

/** Blocks with their own editing node. Add a block here to install it. */
export const blocks: readonly BlockDefinition[] = [callout, embed]
