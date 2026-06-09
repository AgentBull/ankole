import 'reflect-metadata'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'bun:test'
import { eq } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import { AppConfigure, ConfigureKeyType } from '@/common/db-schema/app-configure'

await loadTestEnvFiles()

const { DB, jsonbParam } = await import('@/common/database')
const { appConfigService } = await import('./app-configure')
const {
  SystemConfigError,
  SystemTimezoneConfig,
  assertValidIanaTimezone,
  loadSystemTimezone,
  loadSystemTimezoneWithLegacyBackfill,
  osTimezone
} = await import('./system')

let originalSystemTimezone: string | undefined

beforeAll(async () => {
  originalSystemTimezone = await appConfigService.refresh(SystemTimezoneConfig)
})

beforeEach(async () => {
  await appConfigService.delete(SystemTimezoneConfig)
})

afterAll(async () => {
  if (originalSystemTimezone) {
    await appConfigService.set(SystemTimezoneConfig, originalSystemTimezone)
  } else {
    await appConfigService.delete(SystemTimezoneConfig)
  }
})

describe('system.timezone', () => {
  it('returns the configured installation timezone when present', async () => {
    await appConfigService.set(SystemTimezoneConfig, 'Asia/Shanghai')

    expect(await loadSystemTimezone()).toBe('Asia/Shanghai')
  })

  it('falls back to the OS timezone when system.timezone is missing', async () => {
    expect(await loadSystemTimezone()).toBe(osTimezone())
  })

  it('rejects invalid configured timezones', async () => {
    expect(() => assertValidIanaTimezone('Mars/Olympus')).toThrow(SystemConfigError)
    await expect(appConfigService.set(SystemTimezoneConfig, 'Mars/Olympus')).rejects.toThrow()

    await DB.insert(AppConfigure)
      .values({
        key: SystemTimezoneConfig.key,
        value: jsonbParam({
          type: ConfigureKeyType.PLAINTEXT,
          value: 'Mars/Olympus'
        })
      })
      .onConflictDoUpdate({
        target: AppConfigure.key,
        set: {
          value: jsonbParam({
            type: ConfigureKeyType.PLAINTEXT,
            value: 'Mars/Olympus'
          })
        }
      })

    await expect(loadSystemTimezone()).rejects.toThrow()
    await DB.delete(AppConfigure).where(eq(AppConfigure.key, SystemTimezoneConfig.key))
  })

  it('backfills legacy daily reset timezone only when system.timezone is absent', async () => {
    expect(await loadSystemTimezoneWithLegacyBackfill('Asia/Shanghai')).toBe('Asia/Shanghai')
    expect(await appConfigService.refresh(SystemTimezoneConfig)).toBe('Asia/Shanghai')

    await appConfigService.set(SystemTimezoneConfig, 'Europe/Berlin')

    expect(await loadSystemTimezoneWithLegacyBackfill('Asia/Shanghai')).toBe('Europe/Berlin')
    expect(await appConfigService.refresh(SystemTimezoneConfig)).toBe('Europe/Berlin')
  })
})
