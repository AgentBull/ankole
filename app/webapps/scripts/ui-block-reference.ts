// Writes the Skill reference for chat `ui` blocks from the catalog that the chat renderer uses.
import path from 'node:path'
import { uiBlockCatalog } from '../pod/chat/ui-block/catalog'
import { repositoryRoot } from './edition'

await Bun.write(
  path.join(repositoryRoot, 'app/library/skills/visualization/references/chat-ui-block.md'),
  `${uiBlockCatalog.prompt()}\n`
)
