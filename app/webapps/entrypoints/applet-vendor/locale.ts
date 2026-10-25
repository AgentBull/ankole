import { activeLocale, loadLocale } from '../../common/i18n'

await Promise.all([loadLocale(activeLocale(), 'pod'), loadLocale('en-US', 'pod')])
