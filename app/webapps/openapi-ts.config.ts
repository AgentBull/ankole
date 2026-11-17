import { existsSync } from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { edition, internalsRoot } from './scripts/edition.ts'

const extensionConfig = path.join(internalsRoot, 'webapps/openapi-ts.config.ts')
const extensions =
  edition === 'saas' && existsSync(extensionConfig) ? (await import(pathToFileURL(extensionConfig).href)).default : []

export default [
  ...extensions,
  {
    input: './openapi/pod-v2.json',
    output: { path: './pod/api/generated' },
    plugins: [
      { name: '@hey-api/client-fetch', runtimeConfigPath: './pod/api/client', throwOnError: true },
      { name: '@hey-api/sdk', responseStyle: 'data' }
    ]
  },
  {
    input: './openapi/console-v2.json',
    output: { path: './console/api/v2/generated' },
    plugins: ['@hey-api/client-fetch', '@tanstack/react-query']
  },
  {
    input: './openapi/site-v2.json',
    output: { path: './console/api/v2-site/generated' },
    plugins: ['@hey-api/client-fetch', '@tanstack/react-query']
  },
  {
    input: './openapi/browser-v2.json',
    output: { path: './common/api/generated' },
    plugins: [
      { name: '@hey-api/client-fetch', runtimeConfigPath: './common/internal-api-client', throwOnError: true },
      { name: '@hey-api/sdk', responseStyle: 'data' }
    ]
  }
]
