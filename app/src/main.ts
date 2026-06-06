import 'reflect-metadata'
import { logger } from '@/common/logger'
import { startBullXAgent } from '@/core/application'

if (import.meta.main) {
  try {
    await startBullXAgent()
  } catch (error) {
    logger.error({ error }, 'Failed to start BullX Agent')
    process.exit(1)
  }
}
