export default [
  {
    input: './openapi/console.json',
    output: { path: './console/api/generated' },
    plugins: ['@hey-api/client-fetch', '@tanstack/react-query']
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
    input: './openapi/internal.json',
    output: { path: './common/api/generated' },
    plugins: [
      { name: '@hey-api/client-fetch', runtimeConfigPath: './common/internal-api-client', throwOnError: true },
      { name: '@hey-api/sdk', responseStyle: 'data' }
    ]
  }
]
