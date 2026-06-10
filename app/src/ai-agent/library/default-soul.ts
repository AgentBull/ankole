import path from 'node:path'

export const APP_LIBRARY_ROOT = path.resolve(import.meta.dir, '../../../library')
export const APP_SKILLS_ROOT = path.join(APP_LIBRARY_ROOT, 'skills')
export const INTERNALS_SKILLS_ROOT = path.resolve(import.meta.dir, '../../../../internals/skills')
export const DEFAULT_SOUL_TEMPLATE_PATH = path.join(APP_LIBRARY_ROOT, 'templates', 'SOUL.md')
export const DEFAULT_MISSION_TEMPLATE_PATH = path.join(APP_LIBRARY_ROOT, 'templates', 'MISSION.md')

const FALLBACK_SOUL = 'You are a BullX AI coworker. Reply in plain text.'
const FALLBACK_MISSION = ''

export async function loadDefaultSoulTemplate(): Promise<string> {
  const file = Bun.file(DEFAULT_SOUL_TEMPLATE_PATH)
  if (await file.exists()) return file.text()
  return FALLBACK_SOUL
}

export async function loadDefaultMissionTemplate(): Promise<string> {
  const file = Bun.file(DEFAULT_MISSION_TEMPLATE_PATH)
  if (await file.exists()) return file.text()
  return FALLBACK_MISSION
}
