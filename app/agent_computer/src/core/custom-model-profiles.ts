import { z } from 'zod'
import { compareCodePointStrings } from '../common/ordering'
import type { TurnStart } from '../lanes/actor_lane'

const identifier = /^[a-z][a-z0-9_-]{0,63}$/
const CustomModelProfileSchema = z
  .object({
    name: z.string().regex(identifier),
    description: z.string().min(1).max(200)
  })
  .strict()

export type CustomModelProfile = z.output<typeof CustomModelProfileSchema>

export function availableCustomModelProfiles(turnStart: TurnStart): CustomModelProfile[] {
  const parsed = z.array(CustomModelProfileSchema).safeParse(turnStart.request_context?.custom_model_profiles ?? [])
  if (!parsed.success) throw new Error('turn custom model profile catalog is invalid')

  const profiles = [...parsed.data].sort((left, right) => compareCodePointStrings(left.name, right.name))
  if (new Set(profiles.map(profile => profile.name)).size !== profiles.length) {
    throw new Error('duplicate custom model profile name')
  }
  return profiles
}

export function customModelProfileSchema(customModelProfiles: CustomModelProfile[]): z.ZodType<string> {
  const names = customModelProfiles.map(profile => profile.name)
  return z.enum(names as [string, ...string[]])
}

export function customModelProfileDescription(
  customModelProfiles: CustomModelProfile[],
  defaultProfile: 'coding' | 'primary'
): string {
  if (customModelProfiles.length === 0) {
    return `No custom model profile is available; omit model_profile to use the default ${defaultProfile} profile.`
  }

  return `Available custom model profiles: ${customModelProfiles
    .map(profile => `${profile.name} (${profile.description})`)
    .join(', ')}. Omit model_profile to use the default ${defaultProfile} profile.`
}
