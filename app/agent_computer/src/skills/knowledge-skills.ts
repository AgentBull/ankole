import { relativePathWithin } from '../core/path-boundary'
import { chmod, mkdir, rm, symlink, writeFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { isRecord } from '@agentbull/active-support'
import { jsonBytes, jsonObjectFromBytes } from '../fabric/envelope_proto'
import type { RPCRequester, TurnRPCFrame } from '../lanes/rpc_lane'
import type { RuntimeSkillSummary } from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

/** The model's turn directory resolves inside the command's mounted namespace. */
export async function linkMountedSkills(root: string): Promise<() => Promise<void>> {
  await rm(root, { recursive: true, force: true })
  await mkdir(dirname(root), { recursive: true })
  await symlink('/drive/Skills', root)
  return () => rm(root, { recursive: true, force: true })
}

/** Materializes the enabled packages for one execution. */
export async function materializeKnowledgeSkills(input: {
  root: string
  frame: TurnRPCFrame
  skills: RuntimeSkillSummary[]
  rpc: RPCRequester
}): Promise<{ root: string; skills: RuntimeSkillSummary[]; cleanup(): Promise<void> }> {
  const root = input.root
  await rm(root, { recursive: true, force: true })
  await mkdir(root, { recursive: true })
  try {
    for (const skill of input.skills) {
      const response = await input.rpc(
        'pod.read',
        {
          operation: 'skills.bundle',
          paramsJson: jsonBytes({ name: skill.skillName })
        },
        input.frame,
        { retryOnDisconnect: true }
      )
      const body = jsonObjectFromBytes(response.bodyJson, 'Skill bundle')
      const result = isRecord(body?.result) ? body.result : body
      const files = result?.files
      if (!Array.isArray(files)) throw new Error(`Skill bundle has no files: ${skill.skillName}`)
      const directory = join(root, skill.skillName)
      for (const file of files) {
        if (!isRecord(file) || typeof file.path !== 'string' || typeof file.content !== 'string') {
          throw new Error(`Invalid Skill bundle file: ${skill.skillName}`)
        }
        const target = resolve(directory, file.path)
        const rel = relativePathWithin(directory, target)
        if (!rel) throw new Error('Skill file escapes its directory')
        await mkdir(dirname(target), { recursive: true })
        await writeFile(target, Buffer.from(file.content, 'base64'))
        await chmod(target, typeof file.mode === 'number' ? file.mode & 0o555 : 0o444)
      }
    }
    return {
      root,
      skills: input.skills.map(skill => ({
        ...skill,
        sourceKind: 'installed',
        skillRoot: '',
        relativePath: skill.skillName
      })),
      cleanup: () => rm(root, { recursive: true, force: true })
    }
  } catch (error) {
    await rm(root, { recursive: true, force: true })
    throw error
  }
}
