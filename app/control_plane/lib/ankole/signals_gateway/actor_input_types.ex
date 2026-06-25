defmodule Ankole.SignalsGateway.ActorInputTypes do
  @moduledoc """
  Code-defined ActorInput semantics used by SignalsGateway.
  """

  @batch_window_ms 800
  @ambient_batch_window_ms 1_500

  @doc """
  Returns the actor consumption path for an ActorInput type.
  """
  @spec consumption_path(String.t()) :: atom()
  def consumption_path("im.message.addressed"), do: :addressed_im
  def consumption_path("command.steer"), do: :addressed_im
  def consumption_path("im.message.may_intervene"), do: :may_intervene
  def consumption_path("signal.entry.deleted"), do: :lifecycle
  def consumption_path("signal.entry.recalled"), do: :lifecycle
  def consumption_path("timer.fired"), do: :internal

  def consumption_path(type) when is_binary(type) and binary_part(type, 0, 8) == "command.",
    do: :command

  def consumption_path(_type), do: :direct

  @doc """
  Computes readiness metadata for one ActorInput.
  """
  @spec readiness(String.t(), map(), DateTime.t()) :: map()
  def readiness("im.message.addressed", input, now) do
    available_at = DateTime.add(now, @batch_window_ms, :millisecond)

    %{
      available_at: available_at,
      batch_scope: %{
        "binding_name" => fetch_input(input, :binding_name),
        "signal_channel_id" => fetch_input(input, :signal_channel_id),
        "provider_thread_id" => fetch_input(input, :provider_thread_id)
      },
      sender_key: fetch_input(input, :sender_key)
    }
  end

  def readiness("im.message.may_intervene", input, now) do
    available_at = DateTime.add(now, @ambient_batch_window_ms, :millisecond)

    %{
      available_at: available_at,
      batch_scope: %{
        "binding_name" => fetch_input(input, :binding_name),
        "signal_channel_id" => fetch_input(input, :signal_channel_id),
        "provider_thread_id" => fetch_input(input, :provider_thread_id)
      },
      sender_key:
        "ambient:" <>
          Enum.join(
            [
              fetch_input(input, :binding_name),
              fetch_input(input, :signal_channel_id),
              fetch_input(input, :provider_thread_id)
            ],
            ":"
          )
    }
  end

  def readiness(_type, _input, now) do
    %{available_at: now, batch_scope: nil, sender_key: nil}
  end

  defp fetch_input(input, key) do
    Map.get(input, key) || Map.get(input, Atom.to_string(key))
  end
end
