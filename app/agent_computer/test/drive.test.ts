import { describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startDriveCLIBridge } from '../src/cli/drive/drive-cli-bridge'
import { requestSocketLineBridge } from '../src/core/socket-line-bridge'
import { commandFromArgs } from '../src/cli/drive/drive-cli'
import { assertDrivePath, Drive, maxFilesPerPut } from '../src/drive/drive'
import { downloadFolder, materializeFolder } from '../src/drive/folder-sync'
import { materializeSkills, skillsIndexPath } from '../src/skills/drive_skills'
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

  it('validates drive paths with the control-plane rules', () => {
    expect(assertDrivePath('reports/q3 final.pdf')).toBe('reports/q3 final.pdf')
    for (const path of ['', '/abs', 'a//b', 'a/../b', 'trailing/', './a', 'nul\0byte', 'x'.repeat(256)]) {
      expect(() => assertDrivePath(path)).toThrow('invalid drive path')
    }
  })
})

describe('drive folders', () => {
  it('applies a mode change without downloading unchanged contents', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      const drive = fake.drive()
      const localDir = join(agentHome, 'cache')
      const indexPath = join(agentHome, 'index.json')
      fake.put('skills/run.sh', 'echo ready', { mode: 0o644 })
      await materializeFolder(drive, 'skills', localDir, indexPath)

      fake.put('skills/run.sh', 'echo ready', { mode: 0o755 })
      expect(await materializeFolder(drive, 'skills', localDir, indexPath)).toEqual({ downloaded: 0, removed: 0 })
      expect(statSync(join(localDir, 'run.sh')).mode & 0o777).toBe(0o755)
      expect(fake.calls.filter(call => call.method === 'files.get')).toHaveLength(1)
    }))

  it('rejects a changed file before execution and can prepare a later complete version', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      const localDir = join(agentHome, 'cache')
      const indexPath = join(agentHome, 'index.json')
      fake.put('skills/run.sh', 'echo A', { mode: 0o644 })
      let changed = false
      const drive = new Drive({
        agentHome,
        rpc: async (method, payload, frame, options) => {
          if (method === 'files.get' && !changed) {
            changed = true
            fake.put('skills/run.sh', 'echo B', { mode: 0o755 })
          }
          return fake.rpc(method, payload, frame, options)
        }
      })

      await expect(materializeFolder(drive, 'skills', localDir, indexPath)).rejects.toThrow('changed during download')

      fake.put('skills/run.sh', 'echo A', { mode: 0o644 })
      expect(await materializeFolder(drive, 'skills', localDir, indexPath)).toEqual({ downloaded: 1, removed: 0 })
      expect(readFileSync(join(localDir, 'run.sh'), 'utf8')).toBe('echo A')
      expect(statSync(join(localDir, 'run.sh')).mode & 0o777).toBe(0o644)
      expect(await materializeFolder(drive, 'skills', localDir, indexPath)).toEqual({ downloaded: 0, removed: 0 })
    }))

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

  it('keeps one Automation execution Skill copy unchanged when another preparation updates the cache', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      const cache = join(agentHome, 'installed-skills')
      const first = join(agentHome, 'run-1/skills')
      const second = join(agentHome, 'run-2/skills')
      fake.put('skills/test/SKILL.md', 'version 1')
      await materializeSkills(fake.drive(), cache, first)
      fake.put('skills/test/SKILL.md', 'version 2')
      await materializeSkills(fake.drive(), cache, second)
      expect(readFileSync(join(first, 'test/SKILL.md'), 'utf8')).toBe('version 1')
      expect(readFileSync(join(second, 'test/SKILL.md'), 'utf8')).toBe('version 2')
      expect(existsSync(join(first, '.ankole'))).toBe(false)
    }))

  it('applies file-to-folder and folder-to-file changes in a warm cache', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      const drive = fake.drive()
      const localDir = join(agentHome, 'cache')
      const indexPath = join(agentHome, 'index.json')
      const uploadPath = join(agentHome, 'upload.txt')
      fake.put('folder/a', 'original file')
      await materializeFolder(drive, 'folder', localDir, indexPath)

      writeFileSync(uploadPath, 'new child')
      await drive.commit([{ path: 'folder/a/b', localPath: uploadPath }], ['folder/a'])
      expect(await materializeFolder(drive, 'folder', localDir, indexPath)).toEqual({ downloaded: 1, removed: 1 })
      expect(readFileSync(join(localDir, 'a', 'b'), 'utf8')).toBe('new child')

      writeFileSync(uploadPath, 'replacement file')
      await drive.commit([{ path: 'folder/a', localPath: uploadPath }], ['folder/a'])
      expect(await materializeFolder(drive, 'folder', localDir, indexPath)).toEqual({ downloaded: 1, removed: 1 })
      expect(readFileSync(join(localDir, 'a'), 'utf8')).toBe('replacement file')
      expect(await materializeFolder(drive, 'folder', localDir, indexPath)).toEqual({ downloaded: 0, removed: 0 })
    }))

  it('can retry a tree change after the downloaded bytes arrive but the request fails', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      let failDownload = false
      const drive = new Drive({
        agentHome,
        rpc: async (method, payload, init, options) => {
          const result = await fake.rpc(method, payload, init, options)
          if (failDownload && method === 'files.get') throw new Error('download response lost')
          return result
        }
      })
      const localDir = join(agentHome, 'cache')
      const indexPath = join(agentHome, 'index.json')
      const uploadPath = join(agentHome, 'upload.txt')
      fake.put('folder/a', 'original file')
      await materializeFolder(drive, 'folder', localDir, indexPath)

      writeFileSync(uploadPath, 'new child')
      await drive.commit([{ path: 'folder/a/b', localPath: uploadPath }], ['folder/a'])
      failDownload = true
      const failure = await materializeFolder(drive, 'folder', localDir, indexPath).catch((error: unknown) => error)
      expect(failure instanceof Error && 'errors' in failure ? failure.errors : [failure]).toEqual([
        new Error('download response lost')
      ])
      expect(readFileSync(join(localDir, 'a', 'b'), 'utf8')).toBe('new child')

      failDownload = false
      await materializeFolder(drive, 'folder', localDir, indexPath)
      expect(readFileSync(join(localDir, 'a', 'b'), 'utf8')).toBe('new child')
      expect(await materializeFolder(drive, 'folder', localDir, indexPath)).toEqual({ downloaded: 0, removed: 0 })
    }))

  it('preserves unindexed files that block a folder-to-file change', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      const drive = fake.drive()
      const localDir = join(agentHome, 'cache')
      const indexPath = join(agentHome, 'index.json')
      const uploadPath = join(agentHome, 'upload.txt')
      fake.put('folder/a/b', 'saved child')
      await materializeFolder(drive, 'folder', localDir, indexPath)
      writeFileSync(join(localDir, 'a', 'local.txt'), 'unsaved work')

      writeFileSync(uploadPath, 'replacement file')
      await drive.commit([{ path: 'folder/a', localPath: uploadPath }], ['folder/a'])
      await expect(materializeFolder(drive, 'folder', localDir, indexPath)).rejects.toThrow()
      expect(readFileSync(join(localDir, 'a', 'local.txt'), 'utf8')).toBe('unsaved work')
      expect(existsSync(join(localDir, 'a', 'b'))).toBe(false)
      expect(fake.text('folder/a')).toBe('replacement file')
    }))

  it('materializes changed files only and removes only files that came from the drive', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      const drive = fake.drive()
      const localDir = join(agentHome, 'installed-skills')
      const indexPath = join(localDir, '.ankole', 'drive-index.json')
      fake.put('skills/weather/SKILL.md', '# Weather')
      fake.put('skills/stocks/SKILL.md', '# Stocks')
      mkdirSync(join(localDir, 'local-only'), { recursive: true })
      writeFileSync(join(localDir, 'local-only', 'SKILL.md'), '# Local')

      expect(await materializeFolder(drive, 'skills', localDir, indexPath)).toMatchObject({
        downloaded: 2,
        removed: 0
      })
      const gets = () => fake.calls.filter(call => call.method === 'files.get').length
      expect(gets()).toBe(2)

      fake.put('skills/weather/SKILL.md', '# Weather v2')
      fake.files.delete('skills/stocks/SKILL.md')
      expect(await materializeFolder(drive, 'skills', localDir, indexPath)).toMatchObject({
        downloaded: 1,
        removed: 1
      })
      expect(gets()).toBe(3)
      expect(readFileSync(join(localDir, 'weather', 'SKILL.md'), 'utf8')).toBe('# Weather v2')
      expect(existsSync(join(localDir, 'stocks'))).toBe(false)
      expect(readFileSync(join(localDir, 'local-only', 'SKILL.md'), 'utf8')).toBe('# Local')

      writeFileSync(join(localDir, 'weather', 'SKILL.md'), '# Edited locally')
      expect(await materializeFolder(drive, 'skills', localDir, indexPath)).toMatchObject({ downloaded: 1 })
      expect(readFileSync(join(localDir, 'weather', 'SKILL.md'), 'utf8')).toBe('# Weather v2')
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

describe('installed Skills cache', () => {
  it('prepares concurrent file-to-folder changes from the last completed cache', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      const root = join(agentHome, 'installed-skills')
      fake.put('skills/a', 'original file')
      await materializeSkills(fake.drive(), root)
      fake.files.delete('skills/a')
      fake.put('skills/a/b', 'new child')

      const downloaded = Promise.withResolvers<void>()
      const finishDownload = Promise.withResolvers<void>()
      const first = materializeSkills(
        new Drive({
          agentHome,
          rpc: async (method, payload, frame, options) => {
            const result = await fake.rpc(method, payload, frame, options)
            if (method === 'files.get') {
              downloaded.resolve()
              await finishDownload.promise
            }
            return result
          }
        }),
        root
      )
      await downloaded.promise

      let nextCacheFiles: string[] = []
      const second = materializeSkills(
        new Drive({
          agentHome,
          rpc: async (method, payload, frame, options) => {
            if (method === 'files.list') {
              nextCacheFiles = Object.keys(JSON.parse(readFileSync(skillsIndexPath(root), 'utf8')).files)
            }
            return fake.rpc(method, payload, frame, options)
          }
        }),
        root
      )
      const completed = Promise.allSettled([first, second])
      finishDownload.resolve()

      expect(await completed).toEqual([
        { status: 'fulfilled', value: undefined },
        { status: 'fulfilled', value: undefined }
      ])
      expect(nextCacheFiles).toEqual(['a/b'])
      expect(readFileSync(join(root, 'a', 'b'), 'utf8')).toBe('new child')
      expect(fake.calls.filter(call => call.method === 'files.get')).toHaveLength(2)
    }))

  it('reports a failed preparation and lets the next queued preparation repair the cache', () =>
    withAgentHome(async agentHome => {
      const fake = new FakeDrive(agentHome)
      const root = join(agentHome, 'installed-skills')
      fake.put('skills/a', 'original file')
      await materializeSkills(fake.drive(), root)
      fake.files.delete('skills/a')
      fake.put('skills/a/b', 'new child')

      const failure = new Error('download response lost')
      const failed = materializeSkills(
        new Drive({
          agentHome,
          rpc: async (method, payload, frame, options) => {
            const result = await fake.rpc(method, payload, frame, options)
            if (method === 'files.get') throw failure
            return result
          }
        }),
        root
      )
      const retried = materializeSkills(fake.drive(), root)

      expect(await Promise.allSettled([failed, retried])).toEqual([
        { status: 'rejected', reason: failure },
        { status: 'fulfilled', value: undefined }
      ])
      expect(readFileSync(join(root, 'a', 'b'), 'utf8')).toBe('new child')
      expect(Object.keys(JSON.parse(readFileSync(skillsIndexPath(root), 'utf8')).files)).toEqual(['a/b'])
    }))
})

describe('ankole-files', () => {
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
