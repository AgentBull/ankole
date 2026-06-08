import type {
  BullXIdentityProviderAdapter,
  BullXIdentityProviderAdapterFactory,
  BullXIdentityProviderSyncSink
} from '@agentbull/bullx-sdk/plugins'
import { rootContainer, singleton } from '@/common/di'
import type { Runtime } from '@/common/lifecycle'
import { logger } from '@/common/logger'
import { AppEnv } from '@/config/env'
import { appConfigService, type AppConfigJsonValue } from '@/config/app-configure'
import { AdminAuthPublicBaseUrlConfig } from '../admin-auth/config'
import { ActiveIdentityProvidersConfig, identityProviderConfigKey, type IdentityProviderActivation } from './config'
import {
  applyIdentityProviderFullSync,
  deleteIdentityProviderGroup,
  disableIdentityProviderUser,
  syncIdentityProviderUser,
  upsertIdentityProviderGroup
} from './service'
import { IdentityProviderAdapterRegistry } from './registry'

const DEFAULT_RETRY_MS = 60_000

export interface IdentityProviderRuntimeStats {
  activeProviders: string[]
  startedProviders: string[]
  degradedProviders: string[]
}

interface RuntimeLogger {
  info(data: unknown, message: string): void
  warn(data: unknown, message: string): void
  error(data: unknown, message: string): void
}

interface RuntimeProvider {
  providerId: string
  adapterId: string
  adapter: BullXIdentityProviderAdapter
  retryTimers: ReturnType<typeof setTimeout>[]
}

/**
 * Dependency seams for tests and embedders.
 *
 * The production path reads dynamic DB-backed app-config and the process DI
 * registry. Tests pass functions here so external provider failures can be
 * exercised without calling Lark.
 */
export interface IdentityProviderRuntimeStartOptions {
  getActiveProviders?: () => Promise<readonly IdentityProviderActivation[]>
  getProviderConfig?: (providerId: string) => Promise<AppConfigJsonValue | undefined>
  getPublicBaseUrl?: () => Promise<string | undefined>
  isProduction?: boolean
  registry?: IdentityProviderAdapterRegistry
  logger?: RuntimeLogger
  retryMs?: number
}

@singleton()
export class IdentityProviderRuntime implements Runtime<IdentityProviderRuntimeStats> {
  private readonly providers = new Map<string, RuntimeProvider>()
  private readonly degradedStagesByProvider = new Map<string, Set<string>>()
  private startedStats: IdentityProviderRuntimeStats | null = null

  /**
   * Starts active identity provider instances and runs their first external
   * attempts before returning startup stats.
   *
   * Local configuration/schema errors still throw before the server listens:
   * unknown adapter ids, duplicate provider ids, or invalid encrypted provider
   * config mean the installation is misconfigured. Provider API/WS failures do
   * not fail startup; they are logged as degraded, returned in stats, and retried
   * in the background.
   */
  async start(options: IdentityProviderRuntimeStartOptions = {}): Promise<IdentityProviderRuntimeStats> {
    if (this.startedStats) return this.startedStats

    const log = options.logger ?? logger
    const registry = options.registry ?? rootContainer.resolve(IdentityProviderAdapterRegistry)
    const retryMs = options.retryMs ?? DEFAULT_RETRY_MS
    const activations =
      (await (options.getActiveProviders ?? (() => appConfigService.get(ActiveIdentityProvidersConfig)))()) ?? []
    const publicBaseUrl = await (
      options.getPublicBaseUrl ?? (() => appConfigService.get(AdminAuthPublicBaseUrlConfig))
    )()
    const activeProviders = activations.filter(activation => activation.enabled !== false)
    const startedProviders: string[] = []
    const firstAttempts: Promise<void>[] = []

    for (const activation of activeProviders) {
      const factory = registry.get(activation.adapter) as BullXIdentityProviderAdapterFactory
      const config = await (options.getProviderConfig ?? defaultProviderConfig)(activation.providerId)
      const provider = await factory.create({
        providerId: activation.providerId,
        config,
        publicBaseUrl,
        isProduction: options.isProduction ?? AppEnv.IS_PRODUCTION,
        syncSink: this.createSink(activation.providerId),
        logger: log
      })
      const runtimeProvider: RuntimeProvider = {
        providerId: activation.providerId,
        adapterId: activation.adapter,
        adapter: provider,
        retryTimers: []
      }
      this.providers.set(activation.providerId, runtimeProvider)
      startedProviders.push(activation.providerId)

      // Attach realtime transport first, then run the startup full sync. The
      // transport catches new incremental events while the full sync reconciles
      // facts that changed before this process was ready.
      if (provider.start) {
        firstAttempts.push(this.startTransport(runtimeProvider, log, retryMs).catch(() => {}))
      }

      if (provider.fullSync) {
        firstAttempts.push(this.runFullSync(runtimeProvider, log, retryMs).catch(() => {}))
      }
    }

    await Promise.all(firstAttempts)

    this.startedStats = {
      activeProviders: activeProviders.map(activation => activation.providerId),
      startedProviders,
      degradedProviders: this.degradedProviders()
    }
    return this.startedStats
  }

  async stop(): Promise<void> {
    for (const provider of this.providers.values()) {
      for (const timer of provider.retryTimers) clearTimeout(timer)
      await provider.adapter.stop?.()
    }

    this.providers.clear()
    this.degradedStagesByProvider.clear()
    this.startedStats = null
  }

  getProviderAdapter(providerId: string): BullXIdentityProviderAdapter | undefined {
    return this.providers.get(providerId)?.adapter
  }

  private createSink(providerId: string): BullXIdentityProviderSyncSink {
    return {
      applyFullSync: async snapshot => {
        await applyIdentityProviderFullSync(providerId, snapshot)
      },
      upsertUser: async user => {
        await syncIdentityProviderUser(providerId, user)
      },
      disableUser: (externalId, metadata) => disableIdentityProviderUser(providerId, externalId, metadata),
      upsertGroup: async group => {
        await upsertIdentityProviderGroup(providerId, group)
      },
      deleteGroup: externalId => deleteIdentityProviderGroup(providerId, externalId),
      requestFullSync: async reason => {
        const provider = this.providers.get(providerId)
        if (!provider?.adapter.fullSync) return

        // Contact scope changes can make any number of local users/groups
        // stale. Treat the event as a request to re-run the same authoritative
        // reconciliation pass used at startup.
        logger.info({ providerId, reason }, 'Identity provider requested full sync')
        await this.runFullSync(provider, logger, DEFAULT_RETRY_MS)
      }
    }
  }

  private async runFullSync(provider: RuntimeProvider, log: RuntimeLogger, retryMs: number): Promise<void> {
    try {
      const snapshot = await provider.adapter.fullSync?.()
      if (!snapshot) return

      const stats = await applyIdentityProviderFullSync(provider.providerId, snapshot)
      this.clearDegraded(provider, 'full_sync')
      log.info(
        {
          providerId: provider.providerId,
          adapter: provider.adapterId,
          stage: 'full_sync',
          stats
        },
        'Identity provider full sync completed'
      )
    } catch (error) {
      this.logDegraded(provider, 'full_sync', error, retryMs, log)
      this.scheduleRetry(provider, () => this.runFullSync(provider, log, retryMs), retryMs)
      throw error
    }
  }

  private async startTransport(provider: RuntimeProvider, log: RuntimeLogger, retryMs: number): Promise<void> {
    try {
      await provider.adapter.start?.()
      this.clearDegraded(provider, 'websocket')
      log.info(
        {
          providerId: provider.providerId,
          adapter: provider.adapterId,
          stage: 'websocket'
        },
        'Identity provider transport started'
      )
    } catch (error) {
      this.logDegraded(provider, 'websocket', error, retryMs, log)
      this.scheduleRetry(provider, () => this.startTransport(provider, log, retryMs), retryMs)
      throw error
    }
  }

  private scheduleRetry(provider: RuntimeProvider, fn: () => Promise<void>, retryMs: number): void {
    const timer = setTimeout(() => {
      provider.retryTimers = provider.retryTimers.filter(item => item !== timer)
      void fn().catch(() => {})
    }, retryMs)
    provider.retryTimers.push(timer)
  }

  private logDegraded(
    provider: RuntimeProvider,
    stage: string,
    error: unknown,
    retryMs: number,
    log: RuntimeLogger
  ): void {
    const stages = this.degradedStagesByProvider.get(provider.providerId) ?? new Set<string>()
    stages.add(stage)
    this.degradedStagesByProvider.set(provider.providerId, stages)
    this.refreshStartedStats()
    log.warn(
      {
        providerId: provider.providerId,
        adapter: provider.adapterId,
        stage,
        retryMs,
        error
      },
      'Identity provider degraded; retry scheduled'
    )
  }

  private clearDegraded(provider: RuntimeProvider, stage: string): void {
    const stages = this.degradedStagesByProvider.get(provider.providerId)
    if (!stages) return

    stages.delete(stage)
    if (stages.size === 0) this.degradedStagesByProvider.delete(provider.providerId)
    this.refreshStartedStats()
  }

  private degradedProviders(): string[] {
    return [...this.degradedStagesByProvider.keys()]
  }

  private refreshStartedStats(): void {
    if (!this.startedStats) return

    this.startedStats = {
      ...this.startedStats,
      degradedProviders: this.degradedProviders()
    }
  }
}

async function defaultProviderConfig(providerId: string): Promise<AppConfigJsonValue | undefined> {
  return appConfigService.getByKey(identityProviderConfigKey(providerId))
}

export const identityProviderRuntime = rootContainer.resolve(IdentityProviderRuntime)
