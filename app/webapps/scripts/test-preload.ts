import { plugin } from 'bun'
import path from 'node:path'
import { localeDirectory, prepareEdition } from './edition'

prepareEdition()
plugin({
  name: 'ankole-locales',
  setup(build) {
    build.onResolve({ filter: /^@ankole\/locales\// }, args => ({
      path: path.join(localeDirectory, args.path.slice('@ankole/locales/'.length))
    }))
  }
})
