import { describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { currentChangelogRelease, releaseVersionPolicy } from './changelog-release'

describe('changelog release metadata', () => {
  test('treats alpha and beta as pre-releases and a release candidate as a release', () => {
    expect(releaseVersionPolicy('1.0.0-alpha.1')).toEqual({
      isPrerelease: true,
      usesCanary: true
    })
    expect(releaseVersionPolicy('1.0.0-beta.2')).toEqual({
      isPrerelease: true,
      usesCanary: true
    })
    expect(releaseVersionPolicy('1.0.0-rc.3')).toEqual({
      isPrerelease: false,
      usesCanary: false
    })
    expect(releaseVersionPolicy('1.0.0')).toEqual({
      isPrerelease: false,
      usesCanary: false
    })
    expect(() => releaseVersionPolicy('1.0.0-preview.1')).toThrow(/unsupported release version/)
  })

  test('extracts the newest version section without changing its Markdown', () => {
    const source = `# Changelog

## Version 0.48.0 (2026-07-30)

- Publish the verified image pair.

- Keep the full release note.

## Version 0.47.0 (2026-07-29)

- Previous release.
`

    expect(currentChangelogRelease(source)).toEqual({
      version: '0.48.0',
      date: '2026-07-30',
      notes: '- Publish the verified image pair.\n\n- Keep the full release note.\n'
    })
  })

  test('extracts a pre-release version and its suffix', () => {
    const source = `# Changelog

## Version 1.0.0-alpha.1 (2026-08-20)

- Pending pre-release.

## Version 0.76.0 (2026-08-19)

- Previous release.
`

    expect(currentChangelogRelease(source)).toEqual({
      version: '1.0.0-alpha.1',
      date: '2026-08-20',
      notes: '- Pending pre-release.\n'
    })
  })

  test('rejects a malformed newest heading, invalid date, or empty notes', () => {
    expect(() =>
      currentChangelogRelease(`# Changelog

## Version 00.48.0 (2026-07-30)

- Invalid version.
`)
    ).toThrow(/first level-two/)

    expect(() =>
      currentChangelogRelease(`# Changelog

## Version 1.0.0-preview.1 (2026-08-20)

- Unsupported pre-release label.
`)
    ).toThrow(/first level-two/)

    expect(() =>
      currentChangelogRelease(`# Changelog

## Version 1.0.0-alpha.01 (2026-08-20)

- Leading zero in the pre-release number.
`)
    ).toThrow(/first level-two/)

    expect(() =>
      currentChangelogRelease(`# Changelog

## Version 0.48.0 (2026-02-30)

- Invalid date.
`)
    ).toThrow(/invalid date/)

    expect(() =>
      currentChangelogRelease(`# Changelog

## Version 0.48.0 (2026-07-30)

## Version 0.47.0 (2026-07-29)

- Previous release.
`)
    ).toThrow(/has no release notes/)
  })

  test('writes the exact release notes through the workflow CLI', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-changelog-release-'))
    const changelog = join(root, 'CHANGELOG.md')
    const notes = join(root, 'output', 'release-notes.md')
    const entrypoint = fileURLToPath(new URL('./changelog-release.ts', import.meta.url))

    try {
      writeFileSync(
        changelog,
        `# Changelog

## Version 1.2.3 (2026-07-30)

- Release body.
`
      )

      const result = Bun.spawnSync([process.execPath, entrypoint, 'extract', changelog, notes], {
        stdin: 'ignore',
        stdout: 'pipe',
        stderr: 'pipe'
      })

      expect(result.exitCode).toBe(0)
      expect(result.stdout.toString()).toBe('1.2.3\n')
      expect(await Bun.file(notes).text()).toBe('- Release body.\n')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('prints shell-safe release policy through the workflow CLI', () => {
    const entrypoint = fileURLToPath(new URL('./changelog-release.ts', import.meta.url))
    const result = Bun.spawnSync([process.execPath, entrypoint, 'classify', '1.0.0-beta.1'], {
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'pipe'
    })

    expect(result.exitCode).toBe(0)
    expect(result.stdout.toString()).toBe('true true\n')
  })
})
