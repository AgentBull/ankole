import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startDriveCLIBridge } from '../src/cli/drive/drive-cli-bridge'
import { requestSocketLineBridge } from '../src/core/socket-line-bridge'
import { commandFromArgs } from '../src/cli/drive/drive-cli'
import { assertDrivePath, Drive, maxFilesPerPut } from '../src/drive/drive'
import { downloadFolder } from '../src/drive/folder-sync'
import { FakeDrive } from './support/fake-drive'

function withAgentHome(run: (agentHome: string) => Promise<void>): Promise<void> {
  const agentHome = mkdtempSync(join(tmpdir(), 'ankole-drive-'))
  return run(agentHome).finally(() => rmSync(agentHome, { recursive: true, force: true }))
}

describe('drive client', () => {
  it('puts a directory as one commit, keeps modes, and skips symlinks', () =>
    withAgentHome(async agentHome => {
      const local = join(agentHome, 'skill')
      mkdirSync(join(local, 'scripts'), { recursive: true })
      writeFileSync(join(local, 'SKILL.md'), '# Skill')
      writeFileSync(join(local, 'scripts', 'run.sh'), '#!/bin/sh\n', { mode: 0o755 })
      symlinkSync('/etc/hostname', join(local, 'link'))
      const fake = new FakeDrive(agentHome)

      const files = await fake.drive().put(local, 'skills/weather')

      expect(files.map(file => file.path).sort()).toEqual(['skills/weather/SKILL.md', 'skills/weather/scripts/run.sh'])
      expect(fake.files.get('skills/weather/scripts/run.sh')?.mode).toBe(0o755)
      expect(fake.calls.filter(call => call.method === 'files.commit')).toHaveLength(1)
    }))

  it('rejects a put larger than one commit sends', () =>
    withAgentHome(async agentHome => {
      const local = join(agentHome, 'many')
      mkdirSync(local)
      for (let index = 0; index <= maxFilesPerPut; index += 1) writeFileSync(join(local, `${index}.txt`), '')
      const fake = new FakeDrive(agentHome)

      await expect(fake.drive().put(local, 'many')).rejects.toThrow('put the folder in smaller parts')
      expect(fake.paths()).toEqual([])
    }))

  it('gets a file into the Agent Home with its mode and refuses a target outside it', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      fake.put('reports/q3.sh', 'echo q3', { mode: 0o700 })
      const target = join(agentHome, 'sessions', '10000', 'drive', 'reports', 'q3.sh')

      const file = await fake.drive().get('reports/q3.sh', target)

      expect(file.path).toBe('reports/q3.sh')
      expect(readFileSync(target, 'utf8')).toBe('echo q3')
      expect(statSync(target).mode & 0o777).toBe(0o700)
      await expect(fake.drive().get('reports/q3.sh', join(tmpdir(), 'outside.sh'))).rejects.toThrow(
        'path must be a file inside the Agent Home'
      )
    }))

  it('addresses shared files by stable node ID', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      fake.put('pages/report/notes.txt', 'notes')
      const nodeId = fake.files.get('pages/report/notes.txt')!.nodeId
      await fake.drive().get(nodeId, join(agentHome, 'notes.txt'), { node: true })
      expect(fake.calls.find(call => call.method === 'files.get')?.payload).toMatchObject({ nodeId, path: '' })
    }))

  it('validates drive paths with the control-plane rules', () => {
    expect(assertDrivePath('reports/q3 final.pdf')).toBe('reports/q3 final.pdf')
    for (const path of ['', '/abs', 'a//b', 'a/../b', 'trailing/', './a', 'nul\0byte', 'x'.repeat(256)]) {
      expect(() => assertDrivePath(path)).toThrow('invalid drive path')
    }
  })
})

describe('drive folders', () => {
  it('rejects a folder whose pages belong to different revisions', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      for (let i = 0; i < 1001; i++) fake.put(`script/${String(i).padStart(4, '0')}.ts`, 'v1')
      let pages = 0
      const drive = new Drive({
        agentHome,
        rpc: async (method, payload, frame, options) => {
          if (method === 'files.list' && ++pages === 2) fake.put('script/1000.ts', 'v2')
          return fake.rpc(method, payload, frame, options)
        }
      })
      await expect(drive.list('script')).rejects.toThrow('changed during listing')
    }))

  it('does not return a successful download of an old main and a new module', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      fake.put('script/main.ts', 'main-v1')
      fake.put('script/module.ts', 'module-v1')
      let gets = 0
      const drive = new Drive({
        agentHome,
        rpc: async (method, payload, frame, options) => {
          if (method === 'files.get' && ++gets === 2) {
            fake.put('script/main.ts', 'main-v2')
            fake.put('script/module.ts', 'module-v2')
          }
          return fake.rpc(method, payload, frame, options)
        }
      })
      await expect(downloadFolder(drive, 'script', join(agentHome, 'run'))).rejects.toThrow('changed during download')
      const files = await downloadFolder(drive, 'script', join(agentHome, 'retry'))
      expect(files).toHaveLength(2)
      expect(readFileSync(join(agentHome, 'retry/main.ts'), 'utf8')).toBe('main-v2')
      expect(readFileSync(join(agentHome, 'retry/module.ts'), 'utf8')).toBe('module-v2')
    }))

  it('downloads a folder into an empty directory', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      fake.put('automation/price/main.ts', 'console.log(1)')
      fake.put('automation/price/lib/parse.ts', 'export {}')
      fake.put('automation/pricing/main.ts', 'other job')
      const runDir = join(agentHome, '.ankole', 'automation-runs', 'attempt-1')
      mkdirSync(runDir, { recursive: true })

      const files = await downloadFolder(fake.drive(), 'automation/price', runDir)

      expect(files.map(file => file.path)).toEqual(['automation/price/lib/parse.ts', 'automation/price/main.ts'])
      expect(readFileSync(join(runDir, 'main.ts'), 'utf8')).toBe('console.log(1)')
      expect(readFileSync(join(runDir, 'lib', 'parse.ts'), 'utf8')).toBe('export {}')
    }))
})

describe('ankole-files', () => {
  it('accepts --node before or after the path without consuming positional values', () => {
    for (const args of [
      ['get', '--node', 'pages/p/a.txt'],
      ['get', 'pages/p/a.txt', '--node']
    ]) {
      expect(commandFromArgs(args, '/agents/a')).toEqual({
        operation: 'get',
        path: 'pages/p/a.txt',
        cwd: '/agents/a',
        node: true
      })
    }
    expect(() => commandFromArgs(['put', 'a', 'b', '--node'])).toThrow('unknown option --node')
  })
  it('parses its commands relative to the working directory', () => {
    expect(commandFromArgs(['list', 'inbox', '--limit', '5', '--after', 'inbox/a.txt'], '/agents/a')).toEqual({
      operation: 'list',
      prefix: 'inbox',
      limit: 5,
      after: 'inbox/a.txt'
    })
    expect(commandFromArgs(['get', 'reports/q3.pdf', '--output', 'q3.pdf'], '/agents/a')).toEqual({
      operation: 'get',
      path: 'reports/q3.pdf',
      output: 'q3.pdf',
      cwd: '/agents/a'
    })
    expect(commandFromArgs(['put', 'out', 'reports'], '/agents/a')).toEqual({
      operation: 'put',
      local_path: 'out',
      path: 'reports',
      cwd: '/agents/a'
    })
    expect(commandFromArgs(['rm', 'reports'])).toEqual({ operation: 'rm', path: 'reports' })
    // Folders written with a trailing slash name the same folder.
    expect(commandFromArgs(['list', 'user-files/reports/'], '/agents/a')).toEqual({
      operation: 'list',
      prefix: 'user-files/reports'
    })
    expect(commandFromArgs(['list', '/'], '/agents/a')).toEqual({ operation: 'list', prefix: '' })
    expect(commandFromArgs(['rm', 'reports/'])).toEqual({ operation: 'rm', path: 'reports' })
    expect(commandFromArgs(['put', 'out', 'skills/weather/'], '/agents/a')).toEqual({
      operation: 'put',
      local_path: 'out',
      path: 'skills/weather/',
      cwd: '/agents/a'
    })
    expect(() => commandFromArgs(['rm', '/'])).toThrow()
    expect(() => commandFromArgs(['list', '--after'])).toThrow('--after requires a value')
    expect(() => commandFromArgs(['put', 'only-one'])).toThrow('put takes a local path and a drive path')
    expect(() => commandFromArgs(['mv', 'a', 'b'])).toThrow('must be list, get, put, or rm')
  })

  it('reads more than 1000 files through CLI pagination without gaps or duplicates', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      for (let index = 0; index < 1005; index += 1) fake.put(`reports/${String(index).padStart(4, '0')}.txt`, '')
      const bridge = startDriveCLIBridge({ drive: fake.drive(), workspaceRoot: agentHome, socketRoot: agentHome })

      try {
        const paths: string[] = []
        let after: string | undefined
        do {
          const page = await requestDriveCLI(
            bridge.socketPath,
            commandFromArgs(['list', 'reports', '--limit', '1000', ...(after ? ['--after', after] : [])], agentHome)
          )
          paths.push(...(page.files as Array<{ path: string }>).map(file => file.path))
          after = page.next_after as string | undefined
        } while (after)
        expect(paths).toEqual(fake.paths('reports'))
        expect(paths).toHaveLength(1005)
      } finally {
        bridge.close()
      }
    }))

  it('lists, gets, puts, and removes through the turn-local bridge', () =>
    withAgentHome(async agentHome => {
      const workspaceRoot = join(agentHome, 'sessions', '10000')
      mkdirSync(join(workspaceRoot, 'out'), { recursive: true })
      writeFileSync(join(workspaceRoot, 'out', 'summary.md'), '# Summary')
      writeFileSync(join(workspaceRoot, 'note.md'), '# Note')
      const fake = new FakeDrive(agentHome)
      fake.put('inbox/0123456789abcdef/photo.png', 'png', { source: 'inbound', contentType: 'image/png' })
      fake.put('inbox/fedcba9876543210/notes.txt', 'notes', { source: 'inbound' })
      const bridge = startDriveCLIBridge({ drive: fake.drive(), workspaceRoot, socketRoot: agentHome })

      try {
        const page = await requestDriveCLI(bridge.socketPath, { operation: 'list', prefix: 'inbox', limit: 1 })
        expect(page).toMatchObject({
          files: [{ path: 'inbox/0123456789abcdef/photo.png', content_type: 'image/png', source: 'inbound' }],
          more: true,
          next_after: 'inbox/0123456789abcdef/photo.png'
        })

        const got = await requestDriveCLI(bridge.socketPath, {
          operation: 'get',
          path: 'inbox/0123456789abcdef/photo.png',
          cwd: workspaceRoot
        })
        const localPath = join(workspaceRoot, 'drive', 'inbox', '0123456789abcdef', 'photo.png')
        expect(got.local_path).toBe(localPath)
        expect(readFileSync(localPath, 'utf8')).toBe('png')

        await requestDriveCLI(bridge.socketPath, {
          operation: 'put',
          local_path: 'out',
          path: 'reports/weekly',
          cwd: workspaceRoot
        })
        expect(fake.text('reports/weekly/summary.md')).toBe('# Summary')

        // A target with a trailing slash is a folder, as for cp.
        await requestDriveCLI(bridge.socketPath, {
          operation: 'put',
          local_path: 'note.md',
          path: 'reports/weekly/',
          cwd: workspaceRoot
        })
        await requestDriveCLI(bridge.socketPath, {
          operation: 'put',
          local_path: 'out',
          path: 'archive/',
          cwd: workspaceRoot
        })
        expect(fake.text('reports/weekly/note.md')).toBe('# Note')
        expect(fake.text('archive/summary.md')).toBe('# Summary')

        expect(await requestDriveCLI(bridge.socketPath, { operation: 'rm', path: 'inbox' })).toEqual({ deleted: 2 })
        expect(fake.paths()).toEqual(['archive/summary.md', 'reports/weekly/note.md', 'reports/weekly/summary.md'])
      } finally {
        bridge.close()
      }
    }))
})

function requestDriveCLI(socketPath: string, command: unknown) {
  return requestSocketLineBridge(socketPath, JSON.stringify(command), 'drive CLI bridge returned an invalid response')
}
