import type { JsonObject } from '@pleisto/active-support'

export type InstalledSkillObservation = {
  skill_name: string
  relative_path?: string
  description: string
  default_enabled?: boolean
  metadata?: JsonObject
  content_hash?: string
  xxh3_128?: string
  file_count?: number
}
