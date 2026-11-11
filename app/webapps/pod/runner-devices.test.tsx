import { expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../common/i18n'
import type { ListPodRunnerDevicesResponse } from './api/generated/types.gen'
import { RunnerDevicesSettings, runnerDevicesQuery, unboundRunnerColleagues } from './runner-devices'

test('unboundRunnerColleagues returns owned colleagues not yet bound to the device', () => {
  const colleagues: ListPodRunnerDevicesResponse['colleagues'] = [
    { uid: 'alice.pa', displayName: "Alice's Assistant", agentType: 'personal_assistant' },
    { uid: 'quant-bot', displayName: 'Quant Researcher', agentType: 'ai_colleague' },
    { uid: 'ops-bot', displayName: 'Ops Colleague', agentType: 'ai_colleague' }
  ]
  const unbound = unboundRunnerColleagues(
    {
      bindings: [
        {
          agentUID: 'alice.pa',
          displayName: "Alice's Assistant",
          agentType: 'personal_assistant',
          status: 'connected'
        }
      ]
    },
    colleagues
  )
  expect(unbound.map(item => item.uid)).toEqual(['quant-bot', 'ops-bot'])
})

for (const [locale, expectedConnected, expectedDraining, expectedOffline, expectedBindAction, expectedAllBound] of [
  ['en-US', 'Connected', 'Draining', 'Offline', 'Bind', 'All owned AI colleagues are bound to this device.'],
  ['zh-Hans-CN', '已连接', '排空中', '未连接', '绑定', '名下所有 AI 同事均已绑定到此设备。']
] as const) {
  test(`${locale} RunnerDevicesSettings renders bound colleague health badges and unbound colleague selector`, async () => {
    await loadLocale(locale)
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity } } })
    const payload: ListPodRunnerDevicesResponse = {
      colleagues: [
        { uid: 'alice.pa', displayName: "Alice's Assistant", agentType: 'personal_assistant' },
        { uid: 'quant-bot', displayName: 'Quant Researcher', agentType: 'ai_colleague' }
      ],
      devices: [
        {
          id: '01950000-0000-7000-8000-000000000001',
          name: 'Workstation',
          status: 'online',
          bindings: [
            {
              agentUID: 'alice.pa',
              displayName: "Alice's Assistant",
              agentType: 'personal_assistant',
              status: 'connected'
            }
          ]
        },
        {
          id: '01950000-0000-7000-8000-000000000002',
          name: 'Laptop',
          status: 'offline',
          bindings: [
            {
              agentUID: 'alice.pa',
              displayName: "Alice's Assistant",
              agentType: 'personal_assistant',
              status: 'draining'
            },
            {
              agentUID: 'quant-bot',
              displayName: 'Quant Researcher',
              agentType: 'ai_colleague',
              status: 'offline'
            }
          ]
        }
      ]
    }
    client.setQueryData(runnerDevicesQuery().queryKey, payload)

    const html = renderToStaticMarkup(
      <I18nextProvider i18n={i18n.cloneInstance({ lng: locale, initAsync: false })}>
        <QueryClientProvider client={client}>
          <RunnerDevicesSettings />
        </QueryClientProvider>
      </I18nextProvider>
    )

    expect(html).toContain('Workstation')
    expect(html).toContain('Laptop')
    expect(html).toContain('Quant Researcher')
    expect(html).toContain('@alice.pa')
    expect(html).toContain('@quant-bot')
    expect(html).toContain(expectedConnected)
    expect(html).toContain(expectedDraining)
    expect(html).toContain(expectedOffline)
    expect(html).toContain(expectedBindAction)
    expect(html).toContain(expectedAllBound)
  })
}
