import { RiFlashlightLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import type { Ref, RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { metaSkillsQuery } from '../meta-api'
import { ComposerCompletionList, type CompletionHandle } from './composer-completion'

export type SlashCommand = 'new' | 'learn' | 'invite' | 'rename' | 'page' | 'model' | 'stop'
export type SlashSkillChoice = { slug: string; name: string }

export function SlashCommandPicker({
  existing,
  working,
  hasAgents = true,
  canRename = true,
  canNew = true,
  targetAgentUID,
  personalAssistant = false,
  allowSkills = true,
  query,
  id,
  input,
  handle,
  onChoose,
  onChooseSkill,
  onClose
}: {
  existing: boolean
  working: boolean
  hasAgents?: boolean
  canRename?: boolean
  canNew?: boolean
  targetAgentUID?: string
  personalAssistant?: boolean
  allowSkills?: boolean
  query: string
  id: string
  input: RefObject<HTMLTextAreaElement | null>
  handle: Ref<CompletionHandle>
  onChoose(command: SlashCommand): void
  onChooseSkill?(skill: SlashSkillChoice): void
  onClose(): void
}) {
  const { t } = useTranslation()
  const skillsQuery = useQuery({
    ...metaSkillsQuery(),
    enabled: allowSkills && Boolean(onChooseSkill) && Boolean(targetAgentUID || personalAssistant)
  })
  const normalizedQuery = query.toLocaleLowerCase()
  const commandOptions = (['new', 'learn', 'invite', 'rename', 'page', 'model', 'stop'] as const)
    .filter(
      command =>
        (existing || !['learn', 'invite', 'rename', 'stop'].includes(command)) &&
        (working || command !== 'stop') &&
        (canRename || command !== 'rename') &&
        (canNew || command !== 'new') &&
        (hasAgents || !['model', 'learn'].includes(command))
    )
    .filter(
      command =>
        command.includes(normalizedQuery) ||
        t(`pod.chat_room.command_${command}`).toLocaleLowerCase().includes(normalizedQuery)
    )
    .map(command => ({
      id: `cmd:${command}`,
      content: (
        <>
          <span className="font-mono">/{command}</span>
          <span className="ml-auto text-fg-tertiary">{t(`pod.chat_room.command_${command}`)}</span>
        </>
      ),
      choose: () => onChoose(command)
    }))

  const skillOptions =
    allowSkills && onChooseSkill
      ? [...(skillsQuery.data?.skills ?? [])]
          .filter(skill =>
            targetAgentUID
              ? skill.runtime_agent_uids.includes(targetAgentUID)
              : Boolean(personalAssistant && skill.runtime_assistant_enabled)
          )
          .sort((a, b) => {
            const aPersonal = a.agent_uid ? 0 : 1
            const bPersonal = b.agent_uid ? 0 : 1
            if (aPersonal !== bPersonal) return aPersonal - bPersonal
            return a.name.localeCompare(b.name)
          })
          .filter(skill =>
            `${skill.slug} ${skill.name} ${skill.description}`.toLocaleLowerCase().includes(normalizedQuery)
          )
          .map(skill => ({
            id: `skill:${skill.slug}`,
            content: (
              <>
                <RiFlashlightLine aria-hidden className="size-3.5 shrink-0 text-primary" />
                <span className="truncate font-medium">{skill.name}</span>
                <span className="font-mono text-xs text-fg-tertiary">/{skill.slug}</span>
                {skill.agent_uid ? (
                  <span className="ml-auto shrink-0 rounded-mini bg-muted px-1.5 py-0.5 text-[11px] text-fg-secondary">
                    {t('pod.meta.scope_personal_badge', { defaultValue: 'Personal' })}
                  </span>
                ) : (
                  <span className="ml-auto max-w-52 truncate text-xs text-fg-tertiary">{skill.description}</span>
                )}
              </>
            ),
            choose: () => onChooseSkill({ slug: skill.slug, name: skill.name })
          }))
      : []

  const options = [...skillOptions, ...commandOptions]
  return (
    <ComposerCompletionList
      id={id}
      query={query}
      options={options}
      input={input}
      handle={handle}
      enterSelects={false}
      onClose={onClose}
    />
  )
}
