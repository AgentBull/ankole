defmodule BullX.EventBus.CommandTarget do
  @moduledoc """
  Target implementation for normalized command Events.

  Dispatch is based on stable code-owned command ids stored in `target_ref`.
  EventBus still owns routing and TargetSession delivery; this module owns only
  command handler lookup and command-side effects.
  """

  @behaviour BullX.EventBus.Target

  alias BullX.EventBus.CommandTarget.Registry

  @callback handle(invocation :: map(), side_channel_entry :: map()) ::
              :ok | {:error, term()}

  @impl BullX.EventBus.Target
  def handle_event(%{target_ref: target_ref} = invocation, side_channel_entry)
      when is_binary(target_ref) do
    with {:ok, handler} <- Registry.fetch_handler(target_ref) do
      handler.handle(invocation, side_channel_entry)
    end
  end

  def handle_event(%{target_ref: target_ref}, _side_channel_entry) do
    {:error, {:invalid_command_target_ref, target_ref}}
  end
end
