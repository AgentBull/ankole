import type { BlockDefinition } from '../editor/block'
import { resourceBlocks } from './resources'
import { callout } from './callout'
import { embed } from './embed'
import { math } from './math'
import { mermaid } from './mermaid'
import { infographic } from './infographic'

/** Blocks with their own editing node. Add a block here to install it. */
export const blocks: readonly BlockDefinition[] = [callout, embed, ...resourceBlocks, math, mermaid, infographic]
