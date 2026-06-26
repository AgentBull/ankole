defmodule Ankole.SignalsGateway.ActorInputTypes do
  @moduledoc """
  Code-defined ActorInput semantics used by SignalsGateway.

  The set of input types and their batching/timing behavior is intentionally
  defined in code, not in DB config: these are runtime contracts the worker
  relies on, and they change with the code that consumes them. `readiness/3`
  produces the `available_at` (when the worker may pick the input up) and the
  `batch_scope` (which inputs coalesce together).
  """

  # A human typically sends a burst of messages (or one message split across
  # lines) in quick succession. These windows debounce that burst into a single
  # actor wake-up instead of one wake per message.
  #
  # Addressed messages get a tight 800ms window — the human is talking *to* the
  # agent and expects a prompt reply, so we only absorb the immediate stutter.
  @batch_window_ms 800
  # Ambient ("may_intervene") observation is not urgent and benefits from seeing
  # more of the room before deciding whether to speak, so it gets a longer
  # 1.5s window. The sliding version of this window in SignalsGateway is what is
  # ultimately bounded by the 60s ambient hard cap.
  @ambient_batch_window_ms 1_500

  @doc """
  Returns the actor consumption path for an ActorInput type.
  """
  # Buckets an input type into the lane the worker consumes it through. `steer`
  # rides the addressed-IM lane because steering is an interactive "talk to the
  # running agent" message, not a generic command. The `binary_part(.., 0, 8)`
  # guard catches any other `command.*` type; the final clause is the catch-all
  # direct lane for one-off inputs.
  @spec consumption_path(String.t()) :: atom()
  def consumption_path("im.message.addressed"), do: :addressed_im
  def consumption_path("command.steer"), do: :addressed_im
  def consumption_path("im.message.may_intervene"), do: :may_intervene
  def consumption_path("session.reset_due"), do: :session_lifecycle
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

  # Ambient inputs have no single human sender (they represent "the room"), so
  # the sender_key is a synthetic per-room key. That makes all ambient
  # observations for one channel/thread collapse onto one batch instead of
  # fanning out per author.
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

  @doc """
  Whether a still-open input belongs to old session-local system work after reset.
  """
  @spec stale_after_session_reset?(String.t() | map()) :: boolean()
  def stale_after_session_reset?(%{type: type}), do: stale_after_session_reset?(type)
  def stale_after_session_reset?("timer.fired"), do: true

  def stale_after_session_reset?(type) when is_binary(type) do
    String.starts_with?(type, "cron.") or String.starts_with?(type, "exec.")
  end

  def stale_after_session_reset?(_type), do: false

  defp fetch_input(input, key) do
    Map.get(input, key) || Map.get(input, Atom.to_string(key))
  end
end
