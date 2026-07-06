import { describe, expect, test } from 'bun:test'

import { buildEnvSetupArgs } from './env-setup'

describe('buildEnvSetupArgs', () => {
  test('keeps the default installer path explicit and compact', () => {
    expect(
      buildEnvSetupArgs({
        'dry-run': false,
        'system-packages': true,
        docker: true,
        rust: true,
        elixir: true,
        bun: true
      })
    ).toEqual([])
  })

  test('passes only disabled installer switches through to the shell script', () => {
    expect(
      buildEnvSetupArgs({
        'dry-run': true,
        'system-packages': false,
        docker: false,
        rust: true,
        elixir: false,
        bun: true
      })
    ).toEqual(['--dry-run', '--no-system-packages', '--no-docker', '--no-elixir'])
  })
})
