import { ensureAppletLocales } from '../../common/i18n'

const pending = ensureAppletLocales()
if (pending) await pending
