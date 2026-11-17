import { relativePathWithin } from '../core/path-boundary'
import { createHash, randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { access, chmod, copyFile, link, mkdir, rename, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { isRecord } from '@agentbull/active-support'
import { nodeErrorCode } from '../common/errors'
import { jsonBytes, jsonObjectFromBytes } from '../fabric/envelope-proto'
import type { RPCRequester, TurnRPCFrame } from '../lanes/rpc-lane'
import type { RuntimeSkillSummary } from '../fabric/generated/ankole/runtime_fabric/v1/rpc_pb'

export const DEFAULT_SKILL_CAS_ROOT = '/var/cache/ankole/skills-cas'

/**
 * Resolves a writable local content-addressed cache directory for Skill files,
 * preferring `/var/cache/ankole/skills-cas` and falling back gracefully to
 * `<os.tmpdir()>/ankole-skills-cas` in non-root or host test environments.
 */
export async function resolveSkillCasRoot(preferredRoot = DEFAULT_SKILL_CAS_ROOT): Promise<string> {
  try {
    await mkdir(preferredRoot, { recursive: true })
    await access(preferredRoot, constants.R_OK | constants.W_OK)
    return preferredRoot
  } catch {
    const fallback = join(tmpdir(), 'ankole-skills-cas')
    await mkdir(fallback, { recursive: true })
    return fallback
  }
}

async function linkOrCopyFromCas(casFilePath: string, targetPath: string, effectiveMode: number): Promise<void> {
  try {
    await link(casFilePath, targetPath)
  } catch (error) {
    const code = nodeErrorCode(error)
    if (code === 'EXDEV' || code === 'EPERM' || code === 'ENOTSUP' || code === 'EACCES') {
      await copyFile(casFilePath, targetPath)
      await chmod(targetPath, effectiveMode)
      return
    }
    throw error
  }
}

async function materializeSkillFileThroughCas(input: {
  casRoot: string
  encodedContent: string
  explicitSha256?: string
  targetPath: string
  effectiveMode: number
}): Promise<{ casFilePath: string; cacheHit: boolean }> {
  const modeSuffix = input.effectiveMode.toString(8)
  const explicitDigest =
    input.explicitSha256 && /^[0-9a-f]{64}$/i.test(input.explicitSha256)
      ? input.explicitSha256.toLowerCase()
      : undefined

  if (explicitDigest) {
    const explicitCasPath = join(input.casRoot, explicitDigest.slice(0, 2), `${explicitDigest}-${modeSuffix}`)
    try {
      await linkOrCopyFromCas(explicitCasPath, input.targetPath, input.effectiveMode)
      return { casFilePath: explicitCasPath, cacheHit: true }
    } catch (error) {
      if (nodeErrorCode(error) !== 'ENOENT') throw error
    }
  }

  const decodedBytes = Buffer.from(input.encodedContent, 'base64')
  const contentDigest = createHash('sha256').update(decodedBytes).digest('hex')
  const shardDir = join(input.casRoot, contentDigest.slice(0, 2))
  const casFilePath = join(shardDir, `${contentDigest}-${modeSuffix}`)

  if (contentDigest !== explicitDigest) {
    try {
      await linkOrCopyFromCas(casFilePath, input.targetPath, input.effectiveMode)
      return { casFilePath, cacheHit: true }
    } catch (error) {
      if (nodeErrorCode(error) !== 'ENOENT') throw error
    }
  }

  await mkdir(shardDir, { recursive: true })
  const stagePath = join(shardDir, `.stage-${randomUUID()}`)
  try {
    await writeFile(stagePath, decodedBytes)
    await chmod(stagePath, input.effectiveMode)
    await rename(stagePath, casFilePath)
  } finally {
    await rm(stagePath, { force: true }).catch(() => undefined)
  }

  await linkOrCopyFromCas(casFilePath, input.targetPath, input.effectiveMode)
  return { casFilePath, cacheHit: false }
}

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
  casRoot?: string
}): Promise<{ root: string; skills: RuntimeSkillSummary[]; cleanup(): Promise<void> }> {
  const root = input.root
  await rm(root, { recursive: true, force: true })
  await mkdir(root, { recursive: true })
  const casRoot = await resolveSkillCasRoot(input.casRoot)
  try {
    const fetchedBundles = await Promise.all(
      input.skills.map(async skill => {
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
        return { skill, files }
      })
    )

    for (const { skill, files } of fetchedBundles) {
      const directory = join(root, skill.skillName)
      for (const file of files) {
        if (!isRecord(file) || typeof file.path !== 'string' || typeof file.content !== 'string') {
          throw new Error(`Invalid Skill bundle file: ${skill.skillName}`)
        }
        const target = resolve(directory, file.path)
        const rel = relativePathWithin(directory, target)
        if (!rel) throw new Error('Skill file escapes its directory')
        await mkdir(dirname(target), { recursive: true })
        const effectiveMode = typeof file.mode === 'number' ? file.mode & 0o555 : 0o444
        await materializeSkillFileThroughCas({
          casRoot,
          encodedContent: file.content,
          explicitSha256: typeof file.sha256 === 'string' ? file.sha256 : undefined,
          targetPath: target,
          effectiveMode
        })
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
