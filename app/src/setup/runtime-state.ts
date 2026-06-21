let restartRecommendedAfterSetupCompletion = false

/**
 * Marks that setup completed in the current process after runtime startup.
 *
 * The first identity provider is persisted during setup, but
 * `identityProviderRuntime.start()` already ran earlier in the same process.
 * This in-memory flag lets the console show an operator-facing restart banner
 * without inventing a durable setup sub-state that would survive the restart it
 * is asking for.
 */
export function markSetupCompletionRestartRecommended(): void {
  restartRecommendedAfterSetupCompletion = true
}

/**
 * Reports whether the current process should show a post-setup restart banner.
 */
export function isSetupCompletionRestartRecommended(): boolean {
  return restartRecommendedAfterSetupCompletion
}
