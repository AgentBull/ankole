import { t } from 'i18next'

type OfficePaletteCommand = {
  id: string
  label: string
  params: string
}

/**
 * Names and filters engine commands for an Office command palette. WordCraft and DeckCraft label
 * their commands in English, so the palette shows the toolbar's localized name for every command
 * id listed in `nameKeys` and keeps the engine label for the rest. A query matches the localized
 * name, the engine label, the command id, the `location` text, or the parameter summary.
 */
export function searchOfficeCommands<TCommand extends OfficePaletteCommand>(
  commands: readonly TCommand[],
  query: string,
  nameKeys: Readonly<Record<string, string>>,
  location: (command: TCommand) => string
): (TCommand & { name: string })[] {
  const needle = query.trim().toLocaleLowerCase()
  return commands.flatMap(command => {
    const key = nameKeys[command.id]
    const name = key ? t(key) : command.label || command.id
    const fields = [name, command.label, command.id, location(command), command.params]
    return !needle || fields.some(field => field.toLocaleLowerCase().includes(needle)) ? [{ ...command, name }] : []
  })
}
