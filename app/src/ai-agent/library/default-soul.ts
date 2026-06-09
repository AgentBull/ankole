import path from 'node:path'

export const APP_LIBRARY_ROOT = path.resolve(import.meta.dir, '../../../library')
export const APP_SKILLS_ROOT = path.join(APP_LIBRARY_ROOT, 'skills')
export const DEFAULT_SOUL_TEMPLATE_PATH = path.join(APP_LIBRARY_ROOT, 'templates', 'SOUL.md')

const FALLBACK_SOUL = 'You are a BullX AI coworker. Reply in plain text.'

export async function loadDefaultSoulTemplate(): Promise<string> {
  const file = Bun.file(DEFAULT_SOUL_TEMPLATE_PATH)
  if (await file.exists()) return file.text()
  return FALLBACK_SOUL
}
