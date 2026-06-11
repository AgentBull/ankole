import type { Computer } from '@agentbull/bullx-computer'
import { listEffectiveLibraryContainerFiles } from '@/ai-agent/library/service'
import { materializeRuntimeCredential } from '@/runtime-credentials/service'

export const CODEX_HOME = '/workspace/temp/.codex'
export const CODEX_AUTH_PATH = 'temp/.codex/auth.json'
export const CODEX_CONFIG_PATH = 'temp/.codex/config.toml'
export const GITHUB_ENV_PATH = 'temp/.bullx/github.env'

interface MaterializeComputerRuntimeCredentialsInput {
  computer: Pick<Computer, 'writeFiles'>
  agentUid: string
}

export interface ComputerRuntimeCredentialMaterializationResult {
  codexAuth: boolean
  codexConfig: boolean
  githubEnv: boolean
  libraryFiles: number
}

export async function materializeComputerRuntimeCredentials(
  input: MaterializeComputerRuntimeCredentialsInput
): Promise<ComputerRuntimeCredentialMaterializationResult> {
  const libraryFiles = await materializeComputerLibraryContainers(input)
  const [codexAuth, codexConfig, githubEnv] = await Promise.all([
    materializeRuntimeCredential({
      computer: input.computer,
      agentUid: input.agentUid,
      consumerKind: 'skill',
      consumerName: 'codex',
      credentialName: 'auth_json',
      path: CODEX_AUTH_PATH
    }),
    materializeRuntimeCredential({
      computer: input.computer,
      agentUid: input.agentUid,
      consumerKind: 'skill',
      consumerName: 'codex',
      credentialName: 'config_toml',
      path: CODEX_CONFIG_PATH
    }),
    materializeRuntimeCredential({
      computer: input.computer,
      agentUid: input.agentUid,
      consumerKind: 'skill',
      consumerName: 'github',
      credentialName: 'env',
      path: GITHUB_ENV_PATH
    })
  ])

  return {
    codexAuth: Boolean(codexAuth),
    codexConfig: Boolean(codexConfig),
    githubEnv: Boolean(githubEnv),
    libraryFiles
  }
}

async function materializeComputerLibraryContainers(
  input: MaterializeComputerRuntimeCredentialsInput
): Promise<number> {
  const files = await listEffectiveLibraryContainerFiles(input.agentUid)
  if (files.length === 0) return 0
  await input.computer.writeFiles(
    files.map(file => ({
      path: `library-containers/${file.virtualPath}`,
      content: file.content,
      mode: 0o644
    }))
  )
  return files.length
}
