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
    build.onResolve({ filter: /\?url$/ }, args => ({
      path: args.path.slice(0, -4),
      namespace: 'vite-url'
    }))
    build.onLoad({ filter: /.*/, namespace: 'vite-url' }, args => ({
      contents: `export default ${JSON.stringify(args.path)}`,
      loader: 'js'
    }))
  }
})
