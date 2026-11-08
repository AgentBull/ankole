import { t } from 'i18next'
import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { ENCRYPTED_VALUE_MASK } from '../common/encrypted-value-input'
import i18n, { loadLocale } from '../common/i18n'
import {
  executeEnvVarBatchImport,
  formatDotEnvEntries,
  formatImportOutcomeError,
  inspectDotEnv,
  resolveImportDraftCompletion,
  shouldApplyDecryptedDraftValue,
  type EnvVarEntry
} from './env-vars-dotenv'
import { EnvVarsEditor } from './env-vars-editor'
import {
  AppletMissingEnvBanner,
  AppletSettingsControl,
  appletEnvKeys,
  resolveAppletSettingsInitialTab
} from './applet-settings'
import { AppletFunctionsTab } from './applet-automation'
import { contentKeys, podFileURL, type PageDetail } from './content-api'

beforeAll(async () => {
  await Promise.all(['en-US', 'zh-Hans-CN', 'ja-JP', 'ko-KR'].map(locale => loadLocale(locale)))
})

describe('inspectDotEnv', () => {
  test('parses KEY=VALUE, export prefixes, quotes, multiline values, and trailing comments', () => {
    const raw = [
      '# Leading comment',
      'SIMPLE_KEY=hello_world',
      'export EXPORTED_KEY="line1\\nline2\\"quoted\\""',
      'QUOTED_WITH_HASH="value # inside" # trailing comment',
      "SINGLE_QUOTED='literal # not a comment' # another comment",
      'MULTILINE="first line',
      'second line"',
      'WITH_COMMENT=plain-value # inline comment',
      'SIMPLE_KEY=overridden_last'
    ].join('\n')

    const inspected = inspectDotEnv(raw)
    expect(inspected.errors).toEqual([])
    expect(inspected.items).toEqual([
      { name: 'SIMPLE_KEY', value: 'overridden_last' },
      { name: 'EXPORTED_KEY', value: 'line1\nline2"quoted"' },
      { name: 'QUOTED_WITH_HASH', value: 'value # inside' },
      { name: 'SINGLE_QUOTED', value: 'literal # not a comment' },
      { name: 'MULTILINE', value: 'first line\nsecond line' },
      { name: 'WITH_COMMENT', value: 'plain-value' }
    ])
  })

  test('reports line-numbered syntax, invalid-name, reserved-name, and unclosed-quote diagnostics', () => {
    expect(inspectDotEnv('VALID=1\nBROKEN LINE\n123_BAD=2\nPATH=/bin\nANKOLE_SECRET=x').errors).toEqual([
      { line: 2, reason: 'invalid_syntax' },
      { line: 3, reason: 'invalid_name', name: '123_BAD' },
      { line: 4, reason: 'reserved_name', name: 'PATH' },
      { line: 5, reason: 'reserved_name', name: 'ANKOLE_SECRET' }
    ])

    expect(inspectDotEnv('QUOTED_GARBAGE="ok" trailing').errors).toEqual([
      { line: 1, reason: 'invalid_syntax', name: 'QUOTED_GARBAGE' }
    ])

    expect(inspectDotEnv('OK=1\nUNCLOSED="line1\nline2').errors).toEqual([
      { line: 2, reason: 'unclosed_quote', name: 'UNCLOSED' }
    ])
  })

  test('formatDotEnvEntries round-trips multiline, quoted, whitespace, and hash values losslessly', () => {
    const entries = [
      { name: 'PLAIN_KEY', value: 'alpha-123' },
      { name: 'EMPTY_KEY', value: '' },
      { name: 'MULTILINE_KEY', value: 'line 1\nline 2\t"quoted" \\ slash\rreturn' },
      { name: 'HASH_AND_SPACE', value: '  leading # not a comment  ' },
      { name: 'EQUALS_VALUE', value: 'postgres://user:p=w@db:5432/app?sslmode=require' }
    ]
    const serialized = formatDotEnvEntries(entries)
    const reparsed = inspectDotEnv(serialized)
    expect(reparsed.errors).toEqual([])
    expect(reparsed.items).toEqual(entries)
  })
})

describe('podFileURL', () => {
  const defaultPageID = '019a2b00-0000-7000-8000-000000000001'
  const otherPageID = '019a2b00-0000-7000-8000-000000000002'

  test('normalizes leading slashes across page-relative, page-scoped, and metadata file paths', () => {
    expect(podFileURL(defaultPageID, '/assets/logo.png')).toBe(
      `/api/v2/pod/pages/${defaultPageID}/files/content?path=assets%2Flogo.png`
    )
    expect(podFileURL(defaultPageID, `/pages/${otherPageID}/attachments/pic.png`)).toBe(
      `/api/v2/pod/pages/${otherPageID}/files/content?path=attachments%2Fpic.png`
    )
    expect(podFileURL(defaultPageID, '/metadata/emojis/wave.png')).toBe(
      '/api/v2/pod/metadata/files/content?path=metadata%2Femojis%2Fwave.png'
    )
  })

  test('preserves #hash fragments and sha256 when rebinding canonical Pod file content URLs', () => {
    expect(
      podFileURL(defaultPageID, {
        path: `/api/v2/pod/pages/${otherPageID}/files/content?path=manual.pdf&authentication_ref=stale#page=4`,
        sha256: 'abc123'
      })
    ).toBe(`/api/v2/pod/pages/${otherPageID}/files/content?path=manual.pdf&sha256=abc123#page=4`)

    expect(podFileURL(defaultPageID, 'notes/c#.md')).toBe(
      `/api/v2/pod/pages/${defaultPageID}/files/content?path=notes%2Fc%23.md`
    )
  })
})

describe('executeEnvVarBatchImport and formatImportOutcomeError', () => {
  test('refreshes and notifies once after all entries save', async () => {
    let refreshes = 0
    const notified: string[][] = []
    const savedCalls: string[] = []

    const outcome = await executeEnvVarBatchImport({
      entries: [
        { name: 'API_URL', value: 'https://api.example.com' },
        { name: 'API_KEY', value: 'sk-live-123' },
        { name: 'REGION', value: 'us-east-1' }
      ],
      secret: true,
      putVar: async item => {
        savedCalls.push(`${item.name}=${item.value}:${item.secret}`)
      },
      refresh: async () => {
        refreshes += 1
      },
      onAllSaved: names => {
        notified.push(names)
      }
    })

    expect(savedCalls).toEqual([
      'API_URL=https://api.example.com:true',
      'API_KEY=sk-live-123:true',
      'REGION=us-east-1:true'
    ])
    expect(outcome).toEqual({ saved: ['API_URL', 'API_KEY', 'REGION'], failures: [] })
    expect(refreshes).toBe(1)
    expect(notified).toEqual([['API_URL', 'API_KEY', 'REGION']])
    expect(formatImportOutcomeError(i18n.getFixedT('en-US'), outcome)).toBeNull()
  })

  test('refreshes once without success toast on partial failure and reports saved plus failed keys across locales', async () => {
    let refreshes = 0
    let notified = 0
    const items = [
      { name: 'FIRST_OK', value: '1' },
      { name: 'SECOND_BAD', value: 'line 1\nline 2 # keep' },
      { name: 'THIRD_OK', value: '3' }
    ]

    const outcome = await executeEnvVarBatchImport({
      entries: items,
      secret: false,
      putVar: async item => {
        if (item.name === 'SECOND_BAD') {
          throw new Error('Value required to override secret')
        }
      },
      refresh: async () => {
        refreshes += 1
      },
      onAllSaved: () => {
        notified += 1
      }
    })

    expect(outcome.saved).toEqual(['FIRST_OK', 'THIRD_OK'])
    expect(outcome.failures).toEqual([
      {
        name: 'SECOND_BAD',
        value: 'line 1\nline 2 # keep',
        message: 'Value required to override secret'
      }
    ])
    expect(refreshes).toBe(1)
    expect(notified).toBe(0)
    expect(inspectDotEnv(formatDotEnvEntries(outcome.failures)).items).toEqual([
      { name: 'SECOND_BAD', value: 'line 1\nline 2 # keep' }
    ])

    for (const locale of ['en-US', 'zh-Hans-CN', 'ja-JP', 'ko-KR'] as const) {
      const message = formatImportOutcomeError(i18n.getFixedT(locale), outcome)
      expect(message).toContain('FIRST_OK, THIRD_OK')
      expect(message).toContain('SECOND_BAD (Value required to override secret)')
    }
  })

  test('skips refresh and toast when every entry fails', async () => {
    let refreshes = 0
    let notified = 0
    const outcome = await executeEnvVarBatchImport({
      entries: [{ name: 'ONLY_BAD', value: 'x' }],
      secret: true,
      putVar: async () => {
        throw new Error('Forbidden')
      },
      refresh: async () => {
        refreshes += 1
      },
      onAllSaved: () => {
        notified += 1
      }
    })

    expect(outcome.saved).toEqual([])
    expect(outcome.failures).toEqual([{ name: 'ONLY_BAD', value: 'x', message: 'Forbidden' }])
    expect(refreshes).toBe(0)
    expect(notified).toBe(0)
    expect(formatImportOutcomeError(i18n.getFixedT('en-US'), outcome)).toContain('ONLY_BAD (Forbidden)')
  })
})

describe('shouldApplyDecryptedDraftValue', () => {
  test('applies decrypted plaintext only when the active draft still matches the masked secret request', () => {
    expect(
      shouldApplyDecryptedDraftValue({
        wasEditingTarget: true,
        requestEpoch: 3,
        currentEpoch: 3,
        currentEditingName: 'SECRET_A',
        targetName: 'SECRET_A',
        currentValue: ENCRYPTED_VALUE_MASK
      })
    ).toBe(true)

    expect(
      shouldApplyDecryptedDraftValue({
        wasEditingTarget: true,
        requestEpoch: 3,
        currentEpoch: 4,
        currentEditingName: 'PLAINTEXT_B',
        targetName: 'SECRET_A',
        currentValue: 'public-url'
      })
    ).toBe(false)

    expect(
      shouldApplyDecryptedDraftValue({
        wasEditingTarget: true,
        requestEpoch: 3,
        currentEpoch: 4,
        currentEditingName: 'SECRET_A',
        targetName: 'SECRET_A',
        currentValue: 'sk-replacement'
      })
    ).toBe(false)

    expect(
      shouldApplyDecryptedDraftValue({
        wasEditingTarget: false,
        requestEpoch: 3,
        currentEpoch: 3,
        currentEditingName: null,
        targetName: 'SECRET_A',
        currentValue: ''
      })
    ).toBe(false)
  })
})

describe('resolveImportDraftCompletion', () => {
  test('clears draft and closes panel on full success when import epoch is unchanged', () => {
    expect(
      resolveImportDraftCompletion({
        requestEpoch: 2,
        currentEpoch: 2,
        currentImportText: 'API_URL=https://api.example.com',
        currentImportOpen: true,
        outcome: { saved: ['API_URL'], failures: [] }
      })
    ).toEqual({ importText: '', importOpen: false })
  })

  test('retains only failed entries and keeps panel open on partial failure when import epoch is unchanged', () => {
    expect(
      resolveImportDraftCompletion({
        requestEpoch: 2,
        currentEpoch: 2,
        currentImportText: 'FIRST_OK=alpha\nSECOND_BAD="line 1\\nline 2"',
        currentImportOpen: true,
        outcome: {
          saved: ['FIRST_OK'],
          failures: [{ name: 'SECOND_BAD', value: 'line 1\nline 2', message: 'Rejected' }]
        }
      })
    ).toEqual({
      importText: 'SECOND_BAD="line 1\\nline 2"',
      importOpen: true
    })
  })

  test('preserves newer draft text and open state when user edited or toggled import panel while in flight', () => {
    expect(
      resolveImportDraftCompletion({
        requestEpoch: 2,
        currentEpoch: 3,
        currentImportText: 'NEXT_BATCH=beta',
        currentImportOpen: true,
        outcome: { saved: ['FIRST_OK'], failures: [] }
      })
    ).toEqual({ importText: 'NEXT_BATCH=beta', importOpen: true })

    expect(
      resolveImportDraftCompletion({
        requestEpoch: 2,
        currentEpoch: 4,
        currentImportText: 'NEXT_BATCH=beta',
        currentImportOpen: true,
        outcome: {
          saved: ['FIRST_OK'],
          failures: [{ name: 'SECOND_BAD', value: 'boom', message: 'Rejected' }]
        }
      })
    ).toEqual({ importText: 'NEXT_BATCH=beta', importOpen: true })

    expect(
      resolveImportDraftCompletion({
        requestEpoch: 2,
        currentEpoch: 5,
        currentImportText: '',
        currentImportOpen: false,
        outcome: {
          saved: [],
          failures: [{ name: 'SECOND_BAD', value: 'boom', message: 'Rejected' }]
        }
      })
    ).toEqual({ importText: '', importOpen: false })

    expect(
      resolveImportDraftCompletion({
        requestEpoch: 2,
        currentEpoch: 2,
        requestModeEpoch: 1,
        currentModeEpoch: 2,
        currentImportText: 'FIRST_OK=alpha',
        currentImportOpen: false,
        outcome: { saved: ['FIRST_OK'], failures: [] }
      })
    ).toEqual({ importText: '', importOpen: false })

    expect(
      resolveImportDraftCompletion({
        requestEpoch: 2,
        currentEpoch: 2,
        requestModeEpoch: 1,
        currentModeEpoch: 2,
        currentImportText: 'FIRST_OK=alpha\nSECOND_BAD=boom',
        currentImportOpen: false,
        outcome: {
          saved: ['FIRST_OK'],
          failures: [{ name: 'SECOND_BAD', value: 'boom', message: 'Rejected' }]
        }
      })
    ).toEqual({ importText: 'SECOND_BAD=boom', importOpen: false })
  })
})

describe('EnvVarsEditor markup and secret reveal controls', () => {
  const sampleItems: EnvVarEntry[] = [
    {
      name: 'MISSING_API_KEY',
      secret: true,
      required: true,
      declared: true,
      description: 'Required upstream token',
      present: false,
      source: 'missing',
      inherited_source: null,
      value: null
    },
    {
      name: 'APPLET_SECRET',
      secret: true,
      required: false,
      declared: false,
      description: 'Applet-owned secret',
      present: true,
      source: 'applet',
      inherited_source: 'pod',
      value: null
    },
    {
      name: 'POD_INHERITED_SECRET',
      secret: true,
      required: false,
      declared: false,
      description: null,
      present: true,
      source: 'pod',
      inherited_source: null,
      value: null
    }
  ]

  test('hides reveal toggle when canDecrypt is false while rendering source badges and accessible row labels', () => {
    const html = renderToStaticMarkup(
      <EnvVarsEditor
        items={sampleItems}
        ownSource="applet"
        canDecrypt={false}
        onSave={async () => {}}
        onImport={async () => ({ saved: [], failures: [] })}
        onDelete={async () => {}}
      />
    )

    expect(html).toContain('MISSING_API_KEY')
    expect(html).toContain('APPLET_SECRET')
    expect(html).toContain(t('pod.env_vars.required'))
    expect(html).toContain(t('pod.env_vars.overrides_pod'))
    expect(html).toContain(`aria-label="${t('pod.env_vars.configure')} MISSING_API_KEY"`)
    expect(html).toContain(`aria-label="${t('common.edit')} APPLET_SECRET"`)
    expect(html).toContain(`aria-label="${t('pod.env_vars.reset_inherited')} APPLET_SECRET"`)
    expect(html).not.toContain(`${t('common.reveal_secret')} APPLET_SECRET`)
    expect(html).not.toContain(`${t('common.reveal_secret')} POD_INHERITED_SECRET`)
  })

  test('renders reveal toggle only for own stored secrets when canDecrypt is true, never for inherited secrets', () => {
    const html = renderToStaticMarkup(
      <EnvVarsEditor
        items={sampleItems}
        ownSource="applet"
        canDecrypt
        onSave={async () => {}}
        onImport={async () => ({ saved: [], failures: [] })}
        onDelete={async () => {}}
        onDecrypt={async () => 'decrypted'}
      />
    )

    expect(html).toContain(`aria-label="${t('common.reveal_secret')} APPLET_SECRET"`)
    expect(html).toContain('aria-pressed="false"')
    expect(html).not.toContain(`${t('common.reveal_secret')} POD_INHERITED_SECRET`)
    expect(html).not.toContain(`${t('common.reveal_secret')} MISSING_API_KEY`)
  })
})

describe('AppletMissingEnvBanner', () => {
  const pageID = '019a2b00-0000-7000-8000-000000000099'

  function makeDetail(actions: PageDetail['actions']): PageDetail {
    return {
      page: {
        id: pageID,
        name: 'Research Console',
        title: 'Research Console',
        icon: '🧪',
        type: 'applet',
        position: 'a0',
        inherit_permissions: true,
        metadata: {},
        revision: 1,
        children_view: {},
        created_at: '2026-11-08T00:00:00Z',
        updated_at: '2026-11-08T00:00:00Z',
        deleted_at: null,
        actions,
        role: actions.includes('node_edit') ? 'edit' : 'view'
      },
      ancestors: [],
      actions,
      role: actions.includes('node_edit') ? 'edit' : 'view',
      child_count: 0
    }
  }

  test('shows missing variable names and Configure CTA to editors, and generic guidance without names to viewers', () => {
    const editorClient = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
    editorClient.setQueryData(appletEnvKeys.list(pageID, 1), {
      can_decrypt: false,
      envs: [
        {
          name: 'SERPER_API_KEY',
          secret: true,
          required: true,
          declared: true,
          present: false,
          source: 'missing'
        }
      ]
    })

    const editorHtml = renderToStaticMarkup(
      <QueryClientProvider client={editorClient}>
        <AppletMissingEnvBanner detail={makeDetail(['node_view', 'node_edit'])} />
      </QueryClientProvider>
    )
    expect(editorHtml).toContain('SERPER_API_KEY')
    expect(editorHtml).toContain(t('pod.env_vars.configure_now'))
    editorClient.clear()

    const viewerClient = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
    viewerClient.setQueryData(appletEnvKeys.status(pageID, 1), { missing_required_count: 2 })

    const viewerHtml = renderToStaticMarkup(
      <QueryClientProvider client={viewerClient}>
        <AppletMissingEnvBanner detail={makeDetail(['node_view'])} />
      </QueryClientProvider>
    )
    expect(viewerHtml).toContain(t('pod.env_vars.missing_required_viewer_description'))
    expect(viewerHtml).not.toContain('SERPER_API_KEY')
    expect(viewerHtml).not.toContain(t('pod.env_vars.configure_now'))
    viewerClient.clear()
  })

  test('nests appletEnvKeys under contentKeys.page(pageID) so live republication and Space Settings invalidation match', async () => {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
    const listKey = appletEnvKeys.list(pageID, 1)
    const statusKey = appletEnvKeys.status(pageID, 1)
    const insightsKey = contentKeys.insights(pageID)

    client.setQueryData(listKey, { can_decrypt: false, envs: [] })
    client.setQueryData(statusKey, { missing_required_count: 0 })
    client.setQueryData(insightsKey, {})

    expect(appletEnvKeys.matchesAnyPage(listKey)).toBe(true)
    expect(appletEnvKeys.matchesAnyPage(statusKey)).toBe(true)
    expect(appletEnvKeys.matchesAnyPage(insightsKey)).toBe(false)

    await client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
    expect(client.getQueryState(listKey)?.isInvalidated).toBe(true)
    expect(client.getQueryState(statusKey)?.isInvalidated).toBe(true)
    client.clear()
  })

  test('resolves unified Applet settings initial tab by role, deep link, and explicit tab request', () => {
    expect(resolveAppletSettingsInitialTab({ canEdit: true, hasAutomationLink: false })).toBe('environment')
    expect(resolveAppletSettingsInitialTab({ canEdit: false, hasAutomationLink: false })).toBe('automation')
    expect(resolveAppletSettingsInitialTab({ canEdit: true, hasAutomationLink: true })).toBe('automation')
    expect(
      resolveAppletSettingsInitialTab({ canEdit: true, hasAutomationLink: true, requestedTab: 'environment' })
    ).toBe('environment')
    expect(
      resolveAppletSettingsInitialTab({ canEdit: false, hasAutomationLink: false, requestedTab: 'environment' })
    ).toBe('automation')
    expect(
      resolveAppletSettingsInitialTab({ canEdit: false, hasAutomationLink: false, requestedTab: 'functions' })
    ).toBe('functions')
  })

  test('AppletSettingsControl renders accessible button label with missing-variable warning description for editors', () => {
    const editorClient = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
    editorClient.setQueryData(appletEnvKeys.list(pageID, 1), {
      can_decrypt: true,
      envs: [
        {
          name: 'OPENAI_IMAGE_STYLE',
          secret: false,
          required: true,
          declared: true,
          present: false,
          source: 'missing'
        }
      ]
    })

    const editorControlHtml = renderToStaticMarkup(
      <QueryClientProvider client={editorClient}>
        <AppletSettingsControl detail={makeDetail(['node_view', 'node_edit'])} />
      </QueryClientProvider>
    )
    expect(editorControlHtml).toContain(t('pod.applet_settings.button'))
    expect(editorControlHtml).toContain('aria-describedby=')
    expect(editorControlHtml).toContain(t('pod.applet_settings.missing_env_badge_sr', { count: 1 }))
    editorClient.clear()

    const viewerClient = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
    const viewerControlHtml = renderToStaticMarkup(
      <QueryClientProvider client={viewerClient}>
        <AppletSettingsControl detail={makeDetail(['node_view', 'node_contribute'])} />
      </QueryClientProvider>
    )
    expect(viewerControlHtml).toContain(t('pod.applet_settings.button'))
    expect(viewerControlHtml).not.toContain('aria-describedby=')
    viewerClient.clear()
  })

  test('AppletFunctionsTab renders published HTTP routes, background Actions, and disambiguated Create Job labels', () => {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
    const detail = makeDetail(['node_view', 'node_contribute', 'node_edit'])
    client.setQueryData([...contentKeys.page(pageID), 'functions', detail.page.revision], {
      revision: 3,
      has_backend: true,
      routes: [
        { method: 'GET', path: '/items' },
        { method: 'POST', path: '/items/generate' }
      ],
      actions: [
        {
          key: 'sync_digest',
          concurrency: 'serial_coalesce',
          idempotent: true,
          max_slices: 8
        },
        {
          key: 'rebuild_index',
          concurrency: 'parallel',
          idempotent: false,
          max_slices: 4
        }
      ]
    })

    const html = renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <AppletFunctionsTab detail={detail} canCreateJob onCreateJobForAction={() => {}} />
      </QueryClientProvider>
    )
    expect(html).toContain(t('pod.applet_settings.revision', { revision: 3 }))
    expect(html).toContain('/items/generate')
    expect(html).toContain('sync_digest')
    expect(html).toContain('rebuild_index')
    expect(html).toContain(t('pod.applet_settings.concurrency_serial_coalesce'))
    expect(html).toContain(t('pod.applet_settings.action_idempotent'))
    expect(html).toContain(`aria-label="${t('pod.applet_settings.create_job_for_action')} sync_digest"`)
    expect(html).toContain(`aria-label="${t('pod.applet_settings.create_job_for_action')} rebuild_index"`)
    client.clear()
  })
})
