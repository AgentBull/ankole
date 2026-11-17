import { effect, signal, type ReadonlySignal } from '@preact/signals-react'
import { createActor, type Actor, type ActorOptions, type AnyActorLogic, type SnapshotFrom } from 'xstate'

export type SignalMachineHandle<TLogic extends AnyActorLogic> = {
  actor: Actor<TLogic>
  snapshot: ReadonlySignal<SnapshotFrom<TLogic>>
  send: Actor<TLogic>['send']
}

/**
 * Starts an XState v5 actor inside a Preact Signals `createModel` scope, projecting every
 * snapshot transition into a `ReadonlySignal` and stopping the actor automatically when the
 * owning model disposes.
 */
export function createActorSignal<TLogic extends AnyActorLogic>(
  logic: TLogic,
  options?: ActorOptions<TLogic>,
  beforeStop?: (actor: Actor<TLogic>) => void
): SignalMachineHandle<TLogic> {
  const actor = createActor(logic, options)
  const current = signal<SnapshotFrom<TLogic>>(actor.getSnapshot())
  const subscription = actor.subscribe(next => {
    current.value = next
  })
  actor.start()
  current.value = actor.getSnapshot()
  effect(() => () => {
    beforeStop?.(actor)
    subscription.unsubscribe()
    actor.stop()
  })
  return {
    actor,
    snapshot: current,
    send: (event => actor.send(event)) as Actor<TLogic>['send']
  }
}
