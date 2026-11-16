import { afterAll, beforeAll, describe, expect, it } from 'bun:test'
import i18n from 'i18next'
import { loadLocale } from '../../common/i18n'
import { searchOfficeCommands } from './office-commands'

const commands = [
  { id: 'format.bold', label: 'Bold', params: '', location: 'Home › Font' },
  { id: 'insert.removeLink', label: 'Remove Hyperlink', params: '', location: 'Insert › Links' },
  { id: 'view.ruler', label: 'Ruler', params: 'on?', location: 'View › Show' }
]
const nameKeys = { 'format.bold': 'pod.word.bold', 'insert.removeLink': 'pod.word.remove_link' }
const search = (query: string) =>
  searchOfficeCommands(commands, query, nameKeys, command => command.location).map(({ id, name }) => ({ id, name }))

describe('searchOfficeCommands', () => {
  let previousLanguage = 'en-US'
  beforeAll(async () => {
    previousLanguage = i18n.language || 'en-US'
    await loadLocale('zh-Hans-CN')
    await i18n.changeLanguage('zh-Hans-CN')
  })
  afterAll(async () => {
    await i18n.changeLanguage(previousLanguage)
  })

  it('names mapped commands in the active locale and keeps the engine label for the rest', () => {
    expect(search('')).toEqual([
      { id: 'format.bold', name: '加粗' },
      { id: 'insert.removeLink', name: '移除链接' },
      { id: 'view.ruler', name: 'Ruler' }
    ])
  })

  it('matches the localized name, English label, id, location, and parameters', () => {
    expect(search('链接').map(({ id }) => id)).toEqual(['insert.removeLink'])
    expect(search('hyperlink').map(({ id }) => id)).toEqual(['insert.removeLink'])
    expect(search(' FORMAT.bold ').map(({ id }) => id)).toEqual(['format.bold'])
    expect(search('view › show').map(({ id }) => id)).toEqual(['view.ruler'])
    expect(search('on?').map(({ id }) => id)).toEqual(['view.ruler'])
    expect(search('页眉')).toEqual([])
  })
})
