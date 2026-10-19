import { plugin } from 'bun'
import path from 'node:path'
import { localeDirectory, prepareEdition } from './edition'
import { podLocaleCatalog } from './pod-locale-catalog'

prepareEdition()
plugin({
  name: 'ankole-locales',
  setup(build) {
    build.onResolve({ filter: /^@ankole\/locales\// }, args => {
      const [file = '', query] = args.path.slice('@ankole/locales/'.length).split('?')
      return {
        path: path.join(localeDirectory, file),
        ...(new URLSearchParams(query).has('pod') ? { namespace: 'ankole-pod-locale' } : {})
      }
    })
    build.onLoad({ filter: /\.json$/, namespace: 'ankole-pod-locale' }, async args => ({
      exports: { default: podLocaleCatalog(await Bun.file(args.path).json()) },
      loader: 'object'
    }))
  }
})
