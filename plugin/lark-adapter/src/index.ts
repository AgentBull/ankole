import type {
  BullXExternalGatewayAdapterFactoryContext,
  BullXIdentityProviderAdapter,
  BullXIdentityProviderAdapterFactoryContext,
  BullXPlugin,
  BullXPluginSetupField
} from '@agentbull/bullx-sdk/plugins'
import type { z } from 'zod'
import { LarkAdapterConfigError, larkChannelConfigSchema, larkIdentityProviderConfigSchema } from './config'
import { larkInteractiveConfig } from './interactive-config'
import { BullXLarkChatAdapter } from './chat-adapter'
import { BullXLarkIdentityProviderAdapter } from './identity-adapter'

export { setLarkAppRegistrationForTest } from './interactive-config'
export { LarkAdapterConfigError } from './config'
export type { LarkChannelConfig, LarkIdentityProviderConfig } from './config'
export { resetLarkSharedConnectionsForTest } from './connection'
export { decodeThreadId, encodeThreadId, fromLarkEmojiType } from './lark-helpers'

// Lark chat-channel setup and identity-provider setup are intentionally separate
// config/save boundaries. These helpers only share the verbatim app-credential
// fields between the two setup forms; they do NOT merge the two config shapes.
const larkDomainOptions = [
  { value: 'feishu', label: 'Feishu' },
  { value: 'lark', label: 'Lark' }
]

const larkAppCredentialFields: BullXPluginSetupField[] = [
  {
    path: ['appId'],
    type: 'text',
    label: { 'en-US': 'App ID', 'zh-Hans-CN': 'App ID' }
  },
  {
    path: ['appSecret'],
    type: 'password',
    secret: true,
    label: { 'en-US': 'App Secret', 'zh-Hans-CN': 'App Secret' }
  }
]

function larkDomainField(zhLabel: string): BullXPluginSetupField {
  return {
    path: ['domain'],
    type: 'select',
    label: { 'en-US': 'Domain', 'zh-Hans-CN': zhLabel },
    defaultValue: 'feishu',
    options: larkDomainOptions
  }
}

export function createBullXLarkAdapter(context: BullXExternalGatewayAdapterFactoryContext) {
  const parsed = larkChannelConfigSchema.safeParse(context.config)
  if (!parsed.success) {
    throw new LarkAdapterConfigError(
      `Invalid Lark adapter config for channel ${context.channel.name}: ${zodIssueSummary(parsed.error)}`,
      { cause: parsed.error }
    )
  }

  return new BullXLarkChatAdapter(context, parsed.data)
}

export function createBullXLarkIdentityProvider(
  context: BullXIdentityProviderAdapterFactoryContext
): BullXIdentityProviderAdapter {
  const parsed = larkIdentityProviderConfigSchema.safeParse(context.config)
  if (!parsed.success) {
    throw new LarkAdapterConfigError(
      `Invalid Lark identity provider config for ${context.providerId}: ${zodIssueSummary(parsed.error)}`,
      { cause: parsed.error }
    )
  }

  if (parsed.data.oidc.enabled && context.isProduction && !context.publicBaseUrl) {
    throw new LarkAdapterConfigError(
      `admin_auth.public_base_url is required for Lark OIDC provider ${context.providerId}`
    )
  }

  return new BullXLarkIdentityProviderAdapter(context, parsed.data)
}

export const larkAdapterPlugin = {
  metadata: {
    id: 'lark-adapter',
    apiVersion: 1,
    displayName: 'Lark / Feishu Chat Adapter',
    description: 'First-party Lark and Feishu adapters for chat ingress, login, and directory sync.'
  },
  externalGatewayAdapters: [
    {
      id: 'lark',
      setup: {
        displayName: {
          'en-US': 'Lark / Feishu',
          'zh-Hans-CN': '飞书 / Lark'
        },
        description: {
          'en-US': 'Connect one BullX Agent channel to a Lark or Feishu self-built app.',
          'zh-Hans-CN': '将一个 BullX Agent 的聊天入口连接到飞书或 Lark 自建应用。'
        },
        defaultChannelName: 'lark',
        defaultConfig: {
          appId: '',
          appSecret: '',
          domain: 'feishu',
          group_message_mode: 'observe_all',
          platformSubjectNamespace: 'lark-main',
          userName: 'BullX'
        },
        fields: [
          ...larkAppCredentialFields,
          larkDomainField('运营主体'),
          {
            path: ['platformSubjectNamespace'],
            type: 'text',
            label: {
              'en-US': 'Platform namespace',
              'zh-Hans-CN': '平台用户命名空间'
            },
            description: {
              'en-US':
                'Namespace used when this chat channel records Lark actor subjects, for example lark-main. Use the same value for channels in the same Lark tenant.',
              'zh-Hans-CN':
                '此 chat channel 记录 Lark actor 时使用的平台用户命名空间，例如 lark-main。同一个飞书租户下的多个 channel 可以使用同一个值。'
            },
            defaultValue: 'lark-main'
          },
          {
            path: ['group_message_mode'],
            type: 'select',
            label: {
              'en-US': 'Group message mode',
              'zh-Hans-CN': '群消息模式'
            },
            description: {
              'en-US':
                'addressed_only only accepts @ mentions. observe_all mirrors non-@ group messages only. may_intervene mirrors them and delivers ambient events to the agent.',
              'zh-Hans-CN':
                'addressed_only 只接收 @ 消息。observe_all 只镜像群内非 @ 消息；may_intervene 会镜像并把它们作为 ambient 事件投递给 agent。'
            },
            defaultValue: 'observe_all',
            options: [
              {
                value: 'observe_all',
                label: {
                  'en-US': 'Observe all',
                  'zh-Hans-CN': '观测全部'
                }
              },
              {
                value: 'addressed_only',
                label: {
                  'en-US': 'Addressed only',
                  'zh-Hans-CN': '只处理被点名'
                }
              },
              {
                value: 'may_intervene',
                label: {
                  'en-US': 'May intervene',
                  'zh-Hans-CN': '可介入'
                }
              }
            ]
          },
          {
            path: ['userName'],
            type: 'text',
            label: {
              'en-US': 'Bot display name',
              'zh-Hans-CN': '机器人显示名'
            },
            defaultValue: 'BullX'
          }
        ],
        interactiveConfig: larkInteractiveConfig
      },
      create: createBullXLarkAdapter
    }
  ],
  identityProviderAdapters: [
    {
      id: 'lark',
      setup: {
        displayName: {
          'en-US': 'Lark / Feishu',
          'zh-Hans-CN': '飞书 / Lark'
        },
        description: {
          'en-US': 'OIDC login and contact sync for a Lark or Feishu self-built app.',
          'zh-Hans-CN': '使用飞书或 Lark 自建应用完成 OIDC 登录和通讯录同步。'
        },
        defaultProviderId: 'lark-main',
        defaultConfig: {
          appId: '',
          appSecret: '',
          domain: 'feishu',
          oidc: {
            enabled: true,
            scopes: ['contact:user.employee_id:readonly']
          },
          sync: {
            users: true,
            departments: true,
            websocket: true,
            pageSize: 50
          }
        },
        fields: [
          ...larkAppCredentialFields,
          larkDomainField('域'),
          {
            path: ['oidc', 'enabled'],
            type: 'checkbox',
            label: {
              'en-US': 'Enable OIDC login',
              'zh-Hans-CN': '启用 OIDC 登录'
            },
            defaultValue: true
          },
          {
            path: ['sync', 'users'],
            type: 'checkbox',
            label: {
              'en-US': 'Sync users',
              'zh-Hans-CN': '同步用户'
            },
            defaultValue: true
          },
          {
            path: ['sync', 'departments'],
            type: 'checkbox',
            label: {
              'en-US': 'Sync departments',
              'zh-Hans-CN': '同步部门'
            },
            defaultValue: true
          },
          {
            path: ['sync', 'websocket'],
            type: 'checkbox',
            label: {
              'en-US': 'Sync contact changes in realtime',
              'zh-Hans-CN': '实时同步通讯录变更'
            },
            defaultValue: true
          },
          {
            path: ['sync', 'pageSize'],
            type: 'number',
            label: {
              'en-US': 'Page size',
              'zh-Hans-CN': '分页大小'
            },
            defaultValue: 50
          }
        ]
      },
      create: createBullXLarkIdentityProvider
    }
  ]
} satisfies BullXPlugin

function zodIssueSummary(error: z.ZodError): string {
  return error.issues.map(issue => `${issue.path.join('.') || '<root>'}: ${issue.message}`).join('; ')
}

export default larkAdapterPlugin
