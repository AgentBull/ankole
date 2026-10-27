import { copyFileSync, existsSync, mkdirSync, renameSync } from 'node:fs'
import { platform } from 'node:os'
import { dirname, join } from 'node:path'

import { kernelRoot, runCargo } from './cargo'

const targetDir = join(kernelRoot, 'target/napi-build')

export function nodeAddonPath(): string {
  return join(targetDir, 'ankole_kernel.node')
}

export function buildNodeAddon(options: { release?: boolean } = {}): string {
  runCargo([
    'build',
    '--manifest-path',
    join(kernelRoot, 'Cargo.toml'),
    '--target-dir',
    targetDir,
    '--no-default-features',
    '--features',
    'napi',
    ...(options.release ? ['--release'] : [])
  ])
  return stageNodeAddon(options.release ? 'release' : 'debug')
}

function stageNodeAddon(profile: 'debug' | 'release'): string {
  const built = join(targetDir, profile, libraryFileName())
  if (!existsSync(built)) throw new Error(`The napi build did not write ${built}`)

  const staged = nodeAddonPath()
  mkdirSync(dirname(staged), { recursive: true })
  const temporary = `${staged}.${process.pid}.tmp`
  copyFileSync(built, temporary)
  renameSync(temporary, staged)
  return staged
}

function libraryFileName(): string {
  switch (platform()) {
    case 'darwin':
      return 'libankole_kernel.dylib'
    case 'linux':
      return 'libankole_kernel.so'
    case 'win32':
      return 'ankole_kernel.dll'
    default:
      throw new Error(`The napi build does not support ${platform()}`)
  }
}
