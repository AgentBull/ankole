import { ms } from '@pleisto/active-support'
import type {
  BullXIdentityProviderAdapter,
  BullXIdentityProviderAdapterFactory,
  BullXIdentityProviderSyncSink
} from '@agentbull/bullx-sdk/plugins'
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
import { identityProviderAdapterRegistry, type IdentityProviderAdapterRegistry } from './registry'

const DEFAULT_RETRY_MS = ms('1m')

/**
 * Snapshot of what the runtime is doing, returned from {@link IdentityProviderRuntime.start}.
 *
 * `degradedProviders` is the operationally interesting field: a provider can be
 * active and "started" yet degraded because its external transport or full sync
 * is currently failing and being retried in the background.
 */
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

/**
 * One live provider instance the runtime is managing.
 *
 * `retryTimers` tracks any pending background retries so they can all be
 * cancelled on stop; leaking them would fire writes against a torn-down runtime.
 */
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
    // Idempotent start: a second call returns the first run's stats instead of
    // spinning up duplicate transports for the same providers.
    if (this.startedStats) return this.startedStats

    const log = options.logger ?? logger
    const registry = options.registry ?? identityProviderAdapterRegistry
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
      // `registry.get` throws on an unknown adapter id, and this is intentionally
      // not guarded: an activation pointing at a missing adapter is a local
      // misconfiguration that should abort startup, not degrade silently.
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
      //
      // Both first attempts are pushed with their rejections swallowed here: a
      // failing provider must mark itself degraded and schedule a retry, but it
      // must not reject the shared `Promise.all` below and take down startup. The
      // failure is still recorded via `logDegraded` inside each task.
      if (provider.start) {
        firstAttempts.push(this.startTransport(runtimeProvider, log, retryMs).catch(() => {}))
      }

      if (provider.fullSync) {
        firstAttempts.push(this.runFullSync(runtimeProvider, log, retryMs).catch(() => {}))
      }
    }

    // Wait for every provider's first attempt so the returned stats reflect a
    // real degraded/healthy verdict rather than a still-pending state.
    await Promise.all(firstAttempts)

    this.startedStats = {
      activeProviders: activeProviders.map(activation => activation.providerId),
      startedProviders,
      degradedProviders: this.degradedProviders()
    }
    return this.startedStats
  }

  /**
   * Tears every provider down: cancels pending retries, stops each adapter, and
   * clears state so a later {@link start} can run cleanly. Resetting
   * `startedStats` is what re-arms the idempotency guard for a fresh start.
   */
  async stop(): Promise<void> {
    for (const provider of this.providers.values()) {
      // Cancel scheduled retries before stopping the adapter so an in-flight
      // timer cannot fire a sync against an adapter that is going away.
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

  /**
   * Builds the host-owned write surface handed to one provider's adapter.
   *
   * The adapter speaks the external API and calls back through this sink; the
   * sink is where provider facts become BullX Principal/group/identity writes via
   * the service layer. The `providerId` is captured here so every callback is
   * automatically scoped to the right provider namespace.
   */
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

  /**
   * Runs one authoritative reconciliation pass for a provider.
   *
   * On success it clears the `full_sync` degraded flag; on failure it records the
   * degradation and schedules a background retry, then re-throws so the caller's
   * first-attempt path can observe the failure (the startup path swallows it).
   */
  private async runFullSync(provider: RuntimeProvider, log: RuntimeLogger, retryMs: number): Promise<void> {
    try {
      const snapshot = await provider.adapter.fullSync?.()
      // An adapter may implement `fullSync` yet return nothing this round (e.g.
      // it relies purely on incremental events); treat that as a no-op success.
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

  /**
   * Starts a provider's realtime/incremental transport (e.g. a Lark WebSocket).
   *
   * Mirrors {@link runFullSync}'s degrade-and-retry contract under the `websocket`
   * stage so a transient connection failure leaves the rest of the runtime up.
   */
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

  /**
   * Schedules a single background retry of a failed stage.
   *
   * The timer removes itself from `retryTimers` before running so the tracking
   * list does not accumulate stale handles across many retries. A retry that
   * fails again re-enters via the stage method, which schedules the next one;
   * this is a self-perpetuating chain, not a fixed retry count, on purpose so a
   * provider keeps trying to recover until it succeeds or the runtime stops.
   */
  private scheduleRetry(provider: RuntimeProvider, fn: () => Promise<void>, retryMs: number): void {
    const timer = setTimeout(() => {
      provider.retryTimers = provider.retryTimers.filter(item => item !== timer)
      void fn().catch(() => {})
    }, retryMs)
    provider.retryTimers.push(timer)
  }

  /**
   * Marks one stage of a provider as failing and logs the scheduled retry.
   *
   * Degradation is tracked per stage (`full_sync`, `websocket`) so a provider
   * whose transport is down but whose last full sync succeeded is still reported
   * accurately, rather than as a single all-or-nothing health bit.
   */
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

  /**
   * Clears one stage's degraded flag after it recovers. The provider drops out of
   * the degraded set only once all of its stages are healthy again.
   */
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

  /**
   * Keeps the cached stats' `degradedProviders` in sync as stages fail and
   * recover in the background.
   *
   * Bails out before startup has captured `startedStats` so a degrade/clear that
   * races the very first attempts does not fabricate a stats object out of order;
   * the initial `start` will publish the correct snapshot once its attempts land.
   */
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

export const identityProviderRuntime = new IdentityProviderRuntime()
