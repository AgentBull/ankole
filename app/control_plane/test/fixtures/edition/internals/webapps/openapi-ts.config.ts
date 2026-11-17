import path from 'node:path'
import { fileURLToPath } from 'node:url'

const directory = path.dirname(fileURLToPath(import.meta.url))

export default [
  ...[
    ['fixture-v2', 'api'],
    ['fixture-pod-v2', 'pod-api']
  ].map(([name, output]) => ({
    input: path.join(directory, `openapi/${name}.json`),
    output: { path: path.join(directory, `${output}/generated`) },
    plugins: [
      {
        name: '@hey-api/client-fetch',
        runtimeConfigPath: path.join(directory, `${output}/client`),
        throwOnError: true
      },
      { name: '@hey-api/sdk', responseStyle: 'data' }
    ]
  })),
  {
    input: path.join(directory, 'openapi/fixture-site-v2.json'),
    output: { path: path.join(directory, 'site-api/generated') },
    plugins: ['@hey-api/client-fetch', '@tanstack/react-query']
  }
]
