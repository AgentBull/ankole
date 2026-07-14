import type { WorkerEnvItem } from '../api/generated/types.gen'

/**
 * Lists only whether a value exists. Environment values may contain credentials
 * even when their storage record was not explicitly marked as encrypted.
 */
export function workerEnvValueText(item: WorkerEnvItem): string {
  return item.present ? '••••••' : ''
}
