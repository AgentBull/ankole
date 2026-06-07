import type { WebProvider } from '../provider'
import { exaProvider } from './exa'
import { jinaProvider } from './jina'
import { parallelProvider } from './parallel'
import { webfetchProvider } from './webfetch'

/** Built-in web providers, registered before plugin-contributed ones. */
export const builtinWebProviders: readonly WebProvider[] = [
  exaProvider,
  parallelProvider,
  jinaProvider,
  webfetchProvider
]
