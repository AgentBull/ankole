import { type Wordgard } from '../editor'
import { GardState, Transaction } from '../state'

const commandHandler = GardState.Facet.define<
  [Command<any>, (wg: Wordgard, param: any) => boolean],
  Map<Command<any>, readonly ((wg: Wordgard, param: any) => boolean)[]>
>({
  combine(handlers) {
    const map = new Map<Command<any>, readonly ((wg: Wordgard, param: any) => boolean)[]>()
    for (const [cmd, handler] of handlers) {
      let list = map.get(cmd) as ((wg: Wordgard, param: any) => boolean)[] | undefined
      if (!list) map.set(cmd, (list = []))
      list.push(handler)
    }
    return map
  }
})

/**
 * A command is a function that takes an editor and an additional
 * parameter, and either...
 *
 *  - returns `false` to indicate that it does not apply to the
 *    current editor state
 *
 *  - performs its action as a side effect and returns `true`
 *
 *  - returns a {@link state.Transaction.Spec transaction spec} that
 *    should be dispatched as its effect
 *
 * This formulation is chosen to cover both side-effecting commands
 * (whose effect may not even directly affect the editor—a command
 * may just open a dialog or change some editor-external state) _and_
 * {@link Command.Pure commands} implemented as pure functions from
 * state to transaction.
 *
 * Extensions can register additional handlers for a command, which
 * will be called in order of precedence (until one returns true)
 * when the command is {@link Command.dispatch dispatched}.
 * Commands are recognized by function identity. So, for example, the
 * `enter` command is both the tag used to indicate invocation of an
 * enter press and the function that implements the default behavior
 * for this action.
 */
export type Command<Param = null> = (target: Wordgard, param: Param) => boolean | Transaction.Spec

export namespace Command {
  /**
   * `Command.Pure` is a subtype of `Command` that relies only on the
   * editor state, and performs no imperative effects. When
   * implementing such a command function, it can be useful to tag it
   * with this type, so that it can be invoked without a full editor
   * component for testing or for use in a context where there is no
   * editor.
   *
   * Note that invoking a command function directly will not activate
   * custom {@link Command.handler handlers}.
   */
  export type Pure<Param = null> = (target: { state: GardState }, param: Param) => false | Transaction.Spec

  /**
   * Create an extension that adds a handler for the given {@link
   * Command command}.
   */
  export function handler<Param>(command: Command<Param>, handler: Command<Param>): GardState.Extension {
    return commandHandler.of([command, handler] as any)
  }

  /**
   * Bind a command with a parameter. The only thing you can do with
   * a bound command is to {@link Command.dispatch dispatch} it.
   */
  export function bind<Param>(command: Command<Param>, param: Param): Command.Bound {
    return { command, param } as Command.Bound
  }

  /** Opaque type used for {@link Command.bind bound} commands. */
  export type Bound = {
    readonly tag: unique symbol
    /** @internal */
    readonly command: Command<any>
    /** @internal */
    readonly param: any
  }

  /**
   * Apply a command to the given editor view. When passing a
   * non-{@link Command.bind bound} command with a parameter, the
   * parameter has to be passed as second argument.
   */
  export function dispatch(wg: Wordgard, command: Command<null> | Command.Bound): boolean
  export function dispatch<Param>(wg: Wordgard, command: Command<Param>, param: Param): boolean
  export function dispatch<Param>(wg: Wordgard, command: Command<any> | Command.Bound, p?: Param): boolean {
    const { command: cmd, param } = typeof command == 'object' ? command : { command, param: p ?? null }
    const handlers = wg.state.facet(commandHandler).get(cmd)
    if (handlers) {
      for (const handler of handlers) {
        const result = handler(wg, param)
        if (result) {
          if (typeof result != 'boolean') wg.dispatch(result)
          return true
        }
      }
    }
    const result = cmd(wg, param)
    if (typeof result != 'boolean') wg.dispatch(result)
    return !!result
  }
}
