import type { WorkerConfig } from '../../worker/config'

const fileRoots = ['user_files', 'agent_installed_skills', 'agent_sessions', 'agent_home_documents'] as const

export type FileRoot = (typeof fileRoots)[number]

export function isFileRoot(value: string): value is FileRoot {
  return (fileRoots as readonly string[]).includes(value)
}

export function rootPathFor(config: WorkerConfig, _root: FileRoot): string {
  return config.agentsRoot
}

export function assertFileRootContract(root: FileRoot, relativePath: string): void {
  const segments = relativePath.split('/')
  const suffix = segments.slice(1)
  const valid =
    segments.length >= 2 &&
    /^[a-z0-9][a-z0-9._-]{0,95}$/.test(segments[0] ?? '') &&
    ((root === 'user_files' && suffix[0] === 'user-files') ||
      (root === 'agent_installed_skills' && suffix[0] === 'installed-skills') ||
      (root === 'agent_sessions' && suffix[0] === 'sessions') ||
      (root === 'agent_home_documents' &&
        suffix.length === 1 &&
        ['SOUL.md', 'MISSION.md', 'DESIGN.md'].includes(suffix[0]!)))

  if (!valid) throw new Error(`relative_path does not match ${root} layout: ${relativePath}`)
}
