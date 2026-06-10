import { zonedLocalTimeToUtcMs } from '@agentbull/bullx-native-addons'
import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions, appConfigService } from './app-configure'

export class SystemConfigError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SystemConfigError'
  }
}

export const IanaTimezoneSchema = z.string().min(1).refine(isValidIanaTimezone, {
  message: 'expected a valid IANA timezone'
})

export const SystemTimezoneConfig = defineAppConfig<string>({
  key: 'system.timezone',
  encrypted: false,
  schema: IanaTimezoneSchema,
  defaultValue: osTimezone(),
  description:
    'Installation-wide timezone used by BullX Agent scheduling and local-time policies. Defaults to the host OS timezone when unset.'
})

registerAppConfigDefinitions([SystemTimezoneConfig])

export async function loadSystemTimezone(): Promise<string> {
  const timezone = await appConfigService.get(SystemTimezoneConfig)
  if (!timezone) throw new SystemConfigError('Unable to resolve system.timezone')
  return timezone
}

export function assertValidIanaTimezone(timezone: string): void {
  if (!isValidIanaTimezone(timezone)) throw new SystemConfigError(`Invalid system timezone: ${timezone}`)
}

export function isValidIanaTimezone(timezone: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: timezone }).format(new Date())
    return true
  } catch {
    return false
  }
}

export function osTimezone(): string {
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone
  if (!timezone || !isValidIanaTimezone(timezone)) {
    throw new SystemConfigError('Unable to resolve a valid OS timezone; configure system.timezone')
  }
  return timezone
}

export function zonedLocalTimeToUtc(input: {
  day: number
  hour: number
  minute: number
  month: number
  second?: number
  timezone: string
  year: number
}): Date {
  // Native chrono-tz conversion: ambiguous local times (DST fall-back) take the
  // earlier instant, skipped local times (spring-forward gap) roll past the gap.
  return new Date(
    zonedLocalTimeToUtcMs(
      input.timezone,
      input.year,
      input.month,
      input.day,
      input.hour,
      input.minute,
      input.second ?? 0
    )
  )
}

export function zonedParts(
  timezone: string,
  at: Date
): {
  day: number
  hour: number
  minute: number
  month: number
  second: number
  year: number
} {
  assertValidIanaTimezone(timezone)
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23'
  }).formatToParts(at)
  const value = (type: string) => Number(parts.find(part => part.type === type)?.value)
  return {
    year: value('year'),
    month: value('month'),
    day: value('day'),
    hour: value('hour'),
    minute: value('minute'),
    second: value('second')
  }
}
