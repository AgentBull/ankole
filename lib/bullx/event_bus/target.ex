defmodule BullX.EventBus.Target do
  @moduledoc """
  Target callback and dispatch boundary for EventBus.

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
