/**
 * Filesystem locations and loaders for the installation's *default* persona.
 *
 * A "soul" is the agent's character and operating style — the voice and judgment
 * the model adopts — and the "mission" is its standing objective. New agents are
 * seeded from these on-disk templates (see service.ts) before any per-agent
 * override exists. Also declares the roots where built-in skills are vendored, so
 * the library sync and these template loaders share one source of path truth.
 */
import path from 'node:path'

// Resolved from this module's directory so the paths hold regardless of the
// process working directory. `internals/skills` lives one level above the app and
// may be absent (it is a private submodule) — its loader tolerates that.
export const APP_LIBRARY_ROOT = path.resolve(import.meta.dir, '../../../library')
export const APP_SKILLS_ROOT = path.join(APP_LIBRARY_ROOT, 'skills')
export const INTERNALS_SKILLS_ROOT = path.resolve(import.meta.dir, '../../../../internals/skills')
export const DEFAULT_SOUL_TEMPLATE_PATH = path.join(APP_LIBRARY_ROOT, 'templates', 'SOUL.md')
export const DEFAULT_MISSION_TEMPLATE_PATH = path.join(APP_LIBRARY_ROOT, 'templates', 'MISSION.md')

// Last-resort persona used only if the template files are missing, so an agent
// still has a coherent (if minimal) soul rather than an empty system prompt. The
// default mission is empty on purpose: an unconfigured agent has no standing goal.
const FALLBACK_SOUL = 'You are a BullX AI coworker. Reply in plain text.'
const FALLBACK_MISSION = ''

/** Reads the default soul template from disk, falling back to {@link FALLBACK_SOUL} when absent. */
export async function loadDefaultSoulTemplate(): Promise<string> {
  const file = Bun.file(DEFAULT_SOUL_TEMPLATE_PATH)
  if (await file.exists()) return file.text()
  return FALLBACK_SOUL
}

/** Reads the default mission template from disk, falling back to the empty {@link FALLBACK_MISSION} when absent. */
export async function loadDefaultMissionTemplate(): Promise<string> {
  const file = Bun.file(DEFAULT_MISSION_TEMPLATE_PATH)
  if (await file.exists()) return file.text()
  return FALLBACK_MISSION
}
