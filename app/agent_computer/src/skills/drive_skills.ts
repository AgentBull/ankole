import { join } from 'node:path'
import { cp, rm } from 'node:fs/promises'
import type { Drive } from '../drive/drive'
import { materializeFolder } from '../drive/folder-sync'

/** Drive folder whose subfolders are the Agent's installed Skills. */
export const DRIVE_SKILLS_FOLDER = 'skills'

// One Worker serves one Agent. Its Turns and Automation Jobs share this cache.
let pendingUpdate = Promise.resolve()

/**
 * Brings the local installed-Skills directory in step with `skills/` in the
 * Agent's drive before a Turn or Automation Job uses it.
 *
 * The drive is where a Skill is installed: from the Console, or by the Agent
 * with `ankole-files put <dir> skills/<name>`. A failed download stops
 * preparation so execution cannot use an incomplete or stale local copy.
 */
export async function materializeSkills(drive: Drive, installedSkillsRoot: string, snapshotRoot?: string) {
  const update = pendingUpdate.then(async () => {
    await materializeFolder(drive, DRIVE_SKILLS_FOLDER, installedSkillsRoot, skillsIndexPath(installedSkillsRoot))
    if (snapshotRoot) {
      await rm(snapshotRoot, { recursive: true, force: true })
      await cp(installedSkillsRoot, snapshotRoot, {
        recursive: true,
        filter: source => source !== join(installedSkillsRoot, '.ankole')
      })
    }
  })
  pendingUpdate = update.then(
    () => undefined,
    () => undefined
  )
  await update
}

/** Local download state; the control plane owns the installed Skills catalog. */
export function skillsIndexPath(installedSkillsRoot: string): string {
  return join(installedSkillsRoot, '.ankole', 'drive-index.json')
}
