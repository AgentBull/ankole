import * as lark from '@larksuiteoapi/node-sdk'
import type { BullXPluginInteractiveConfig } from '@agentbull/bullx-sdk/plugins'
import QRCode from 'qrcode'
import { LarkAdapterConfigError } from './config'

type LarkAppRegistrationResult = {
  client_id: string
  client_secret: string
  user_info?: {
    open_id?: string
    tenant_brand?: 'feishu' | 'lark'
  }
}

export type LarkAppRegistration = (options: {
  onQRCodeReady(info: { url: string; expireIn?: number }): void
  onStatusChange?(info: { status: string; interval?: number }): void
  signal?: AbortSignal
  source?: string
}) => Promise<LarkAppRegistrationResult>

let larkAppRegistrationOverride: LarkAppRegistration | undefined

export function setLarkAppRegistrationForTest(registration: LarkAppRegistration | undefined): void {
  larkAppRegistrationOverride = registration
}

export const larkInteractiveConfig: BullXPluginInteractiveConfig = {
  displayName: {
    'en-US': 'Scan to create app',
    'zh-Hans-CN': '扫码创建应用'
  },
  description: {
    'en-US': 'Use the official Lark / Feishu one-click app creation flow to fill App ID and App Secret.',
    'zh-Hans-CN': '使用飞书 / Lark 官方一键创建应用流程回填 App ID 和 App Secret。'
  },
  async start(context) {
    const register = await resolveLarkAppRegistration()
    const pendingUpdates: Promise<unknown>[] = []
    const result = await register({
      source: 'bullx-agent',
      signal: context.signal,
      onQRCodeReady: info => {
        /*
         * Feishu/Lark's one-click app creation URL is a mobile-app scan target,
         * not a normal browser authorization link. Render a QR code immediately
         * so the operator can scan with the Feishu/Lark mobile client while the
         * server-side registration promise continues to wait for completion.
         */
        const qrUpdate = larkQrCodeHtml(info.url)
          .then(html =>
            context.onUpdate({
              status: {
                'en-US': `Waiting for scan${info.expireIn ? `, expires in ${info.expireIn}s` : ''}`,
                'zh-Hans-CN': `等待扫码${info.expireIn ? `，${info.expireIn} 秒后过期` : ''}`
              },
              html
            })
          )
          .catch(() =>
            context.onUpdate({
              status: {
                'en-US': 'QR code rendering failed; use a QR generator with the registration URL below.',
                'zh-Hans-CN': '二维码渲染失败；请使用下方注册链接生成二维码后扫码。'
              },
              html: larkRegistrationLinkHtml(info.url)
            })
          )
        pendingUpdates.push(qrUpdate)
      },
      onStatusChange: info => {
        void context.onUpdate({
          status: {
            'en-US': `Authorization status: ${info.status}`,
            'zh-Hans-CN': `授权状态：${info.status}`
          }
        })
      }
    })
    /*
     * QR rendering is asynchronous. Wait for queued progress updates before
     * publishing the final credentials so polling clients do not briefly see a
     * completed session without the scan UI that explains what happened.
     */
    await Promise.allSettled(pendingUpdates)

    return {
      status: {
        'en-US': 'App credentials received',
        'zh-Hans-CN': '已获取应用凭据'
      },
      values: {
        appId: result.client_id,
        appSecret: result.client_secret,
        domain: result.user_info?.tenant_brand ?? 'feishu'
      },
      html: result.user_info?.tenant_brand
        ? `<p>Tenant brand: ${escapeHtml(result.user_info.tenant_brand)}</p>`
        : undefined
    }
  }
}

async function resolveLarkAppRegistration(): Promise<LarkAppRegistration> {
  if (larkAppRegistrationOverride) return larkAppRegistrationOverride

  const registerApp = (lark as Record<string, unknown>).registerApp
  if (typeof registerApp === 'function') return registerApp as LarkAppRegistration

  throw new LarkAdapterConfigError('Lark one-click app registration is not available in installed SDK packages')
}

async function larkQrCodeHtml(url: string): Promise<string> {
  const svg = await QRCode.toString(url, {
    type: 'svg',
    margin: 1,
    color: {
      dark: '#111827',
      light: '#ffffff'
    }
  })
  return `<div class="grid gap-3"><div class="inline-flex rounded-md border border-border bg-white p-3 text-black">${svg}</div><p>Use the Lark / Feishu mobile app to scan this QR code.</p>${larkRegistrationLinkHtml(url)}</div>`
}

function larkRegistrationLinkHtml(url: string): string {
  return `<a href="${escapeHtmlAttribute(url)}" target="_blank" rel="noreferrer">${escapeHtml(url)}</a>`
}

function escapeHtmlAttribute(value: string): string {
  return escapeHtml(value)
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, character => htmlEntities[character] ?? character)
}

const htmlEntities: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;'
}
