import type { BrowserRequest } from '../protocol'
import { ActiveBrowserLimiter } from './active-browser-limiter'
import { SessionActor, type ActorResult } from './session-actor'

export class SessionManager {
  private readonly actors = new Map<string, SessionActor>()
  private readonly limiter: ActiveBrowserLimiter

  constructor(maxActiveBrowsers: number) {
    this.limiter = new ActiveBrowserLimiter(maxActiveBrowsers)
  }

  dispatch(request: BrowserRequest, signal?: AbortSignal): Promise<ActorResult> {
    const key = JSON.stringify([request.route, request.session])
    let actor = this.actors.get(key)
    if (!actor) {
      actor = new SessionActor(request.route, request.session, this.limiter, disposed => {
        if (this.actors.get(key) === disposed) this.actors.delete(key)
      })
      this.actors.set(key, actor)
    }
    return actor.dispatch(request, signal)
  }

  async close(): Promise<void> {
    this.limiter.close()
    await Promise.allSettled([...this.actors.values()].map(actor => actor.close()))
    this.actors.clear()
  }
}
