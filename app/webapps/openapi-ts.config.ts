const saas =
  process.env.ANKOLE_EDITION === 'saas'
    ? [
        ...(['saas-v2', 'saas-pod-v2'] as const).map(name => ({
          input: `../../internals/webapps/openapi/${name}.json`,
          output: {
            path:
              name === 'saas-v2' ? '../../internals/webapps/api/generated' : '../../internals/webapps/pod-api/generated'
          },
          plugins: [
            {
              name: '@hey-api/client-fetch',
              runtimeConfigPath:
                name === 'saas-v2' ? '../../internals/webapps/api/client' : '../../internals/webapps/pod-api/client',
              throwOnError: true
            },
            { name: '@hey-api/sdk', responseStyle: 'data' }
          ]
        })),
        {
          input: '../../internals/webapps/openapi/saas-site-v2.json',
          output: { path: '../../internals/webapps/site-api/generated' },
          plugins: ['@hey-api/client-fetch', '@tanstack/react-query']
        }
      ]
    : []

export default [
  ...saas,
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
