import path from 'node:path'
import { defineCommand } from '@crustjs/core'

import { packageRootPath, runChild, styledWarn } from '../utils'

type EnvSetupFlags = {
  'dry-run': boolean
  'system-packages': boolean
  docker: boolean
  rust: boolean
  elixir: boolean
  bun: boolean
}

export function buildEnvSetupArgs(flags: EnvSetupFlags): string[] {
  return [
    ...(flags['dry-run'] ? ['--dry-run'] : []),
    ...(flags['system-packages'] ? [] : ['--no-system-packages']),
    ...(flags.docker ? [] : ['--no-docker']),
    ...(flags.rust ? [] : ['--no-rust']),
    ...(flags.elixir ? [] : ['--no-elixir']),
    ...(flags.bun ? [] : ['--no-bun'])
  ]
}

export function envSetupCommand() {
  return defineCommand(
    'env-setup',
    { description: 'Install the host toolchain required for Ankole development.' },
    command =>
      command
        .flags(
          {
            name: 'dry-run',
            type: 'boolean',
            description: 'Print installer commands without running them.',
            default: false
          },
          {
            name: 'system-packages',
            type: 'boolean',
            description: 'Install OS build packages required by Erlang, Rust, and native dependencies.',
            default: true
          },
          {
            name: 'docker',
            type: 'boolean',
            description: 'Install Docker Engine/Desktop when Docker is missing.',
            default: true
          },
          {
            name: 'rust',
            type: 'boolean',
            description: 'Install Rust with rustup, clippy, and rustfmt.',
            default: true
          },
          {
            name: 'elixir',
            type: 'boolean',
            description: 'Install Erlang/OTP and Elixir through mise.',
            default: true
          },
          {
            name: 'bun',
            type: 'boolean',
            description: 'Install the Bun version pinned by the repository.',
            default: true
          }
        )
        .action(async ({ flags }) => {
          if (process.platform === 'win32') {
            console.warn(
              styledWarn(
                'Windows is not supported by Ankole devkit env-setup yet. Use macOS, Linux, WSL2, or Codespaces.'
              )
            )
            return
          }

          const script = path.join(packageRootPath, 'scripts', 'env-setup.sh')
          await runChild('/usr/bin/env', ['bash', script, ...buildEnvSetupArgs(flags as EnvSetupFlags)])
        })
  )
}
