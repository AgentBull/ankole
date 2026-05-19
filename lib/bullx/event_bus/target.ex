defmodule BullX.EventBus.Target do
  @moduledoc """
  Target callback and dispatch boundary for EventBus.

  ## Why Targets are an abstraction

  In an OpenClaw / Hermes-style harness, "what receives a message" is
  always the same thing: the assistant's agentic loop. Channels feed it, the
  loop produces an answer. BullX separates routing (`BullX.EventBus`) from
  *what handles a routed Event*: a Target is any code-owned module that
  implements `handle_event/2`. An Event Routing Rule names the target type,
  and EventBus dispatches the Event to the matching handler.

  Currently registered target types: `:ai_agent` (flexible model/tool loop,
  see `BullX.AIAgent`), `:workflow` (explicit branching/approval/parallel
  process steps — under development), `:command` (in-process side effects
  triggered by routed slash-commands), and `:external_agent_harness` (a
  bridge to delegate work to an external runtime — under development).
  Blackhole rules are handled inside `BullX.EventBus.accept/2` itself and
  never reach a Target.

  This split is what lets the same incoming Event flow to different kinds of
  workers based on operator-defined rules — flexible AI judgment for
  ambiguous cases, deterministic Workflows where process structure matters,
  external harnesses for special-purpose agents — all sharing the same Event
  envelope, TargetSession semantics, and audit trail.

  ## Internal contract

  Concrete Target implementations are code-owned modules configured by target
  type. EventBus never derives module names from database strings.
  """

  @callback handle_event(invocation :: map(), side_channel_entry :: map()) ::
              :ok | {:error, term()}

  @target_types [:ai_agent, :workflow, :command, :external_agent_harness]
  @built_in_targets [command: BullX.EventBus.CommandTarget]

  @spec dispatch(map(), map()) :: :ok | {:error, term()}
  def dispatch(%{target_type: target_type} = invocation, side_channel_entry)
      when target_type in @target_types do
    case handler_for(target_type) do
      {:ok, module} -> module.handle_event(invocation, side_channel_entry)
      {:error, reason} -> {:error, reason}
    end
  end

  def dispatch(%{target_type: target_type}, _side_channel_entry) do
    {:error, {:unsupported_target_type, target_type}}
  end

  @spec handler_for(atom()) :: {:ok, module()} | {:error, term()}
  def handler_for(target_type) do
    handlers =
      Keyword.merge(@built_in_targets, Application.get_env(:bullx, :event_bus_targets, []))

    case Keyword.fetch(handlers, target_type) do
      {:ok, module} when is_atom(module) ->
        case function_exported?(module, :handle_event, 2) do
          true -> {:ok, module}
          false -> {:error, {:target_handler_invalid, target_type, module}}
        end

      :error ->
        {:error, {:target_handler_missing, target_type}}
    end
  end
end
