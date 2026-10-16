import { expect, test } from 'bun:test'
import i18n, { loadLocale } from '../../app/webapps/common/i18n'

test('the private frontend suite reads the same merged catalog as production', async () => {
  await loadLocale('en-US')
  expect(i18n.t('edition_fixture.message', { lng: 'en-US' })).toBe('Private catalog build fixture')
})
