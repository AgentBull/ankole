import type { Ref, RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { ComposerCompletionList, type CompletionHandle } from './composer-completion'

export type SlashCommand = 'new' | 'invite' | 'rename' | 'page' | 'model' | 'stop'
export function SlashCommandPicker({
  existing,
  working,
  query,
  id,
  input,
  handle,
  onChoose,
  onClose
}: {
  existing: boolean
  working: boolean
  query: string
  id: string
  input: RefObject<HTMLTextAreaElement | null>
  handle: Ref<CompletionHandle>
  onChoose(command: SlashCommand): void
  onClose(): void
}) {
  const { t } = useTranslation()
  const options = (['new', 'invite', 'rename', 'page', 'model', 'stop'] as const)
    .filter(command => (existing || !['invite', 'rename', 'stop'].includes(command)) && (working || command !== 'stop'))
    .filter(
      command =>
        command.includes(query.toLocaleLowerCase()) ||
        t(`pod.chat_room.command_${command}`).toLocaleLowerCase().includes(query.toLocaleLowerCase())
    )
    .map(command => ({
      id: command,
      content: (
        <>
          <span className="font-mono">/{command}</span>
          <span className="ml-auto text-fg-tertiary">{t(`pod.chat_room.command_${command}`)}</span>
        </>
      ),
      choose: () => onChoose(command)
    }))
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
