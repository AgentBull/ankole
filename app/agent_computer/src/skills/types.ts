import type { AnkoleSkillRuntime } from './effective-skill'

export type InstalledSkillObservation = {
  skill_name: string
  description: string
  default_enabled: boolean
  tags: string[]
  category?: string
  ankole_runtime?: AnkoleSkillRuntime
}
