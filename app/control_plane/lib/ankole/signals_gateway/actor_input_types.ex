defmodule Ankole.SignalsGateway.ActorInputTypes do
  @moduledoc """
  Code-defined ActorInput semantics used by SignalsGateway.

  The set of input types is intentionally defined in code, not in DB config:
  these are runtime contracts the worker relies on, and they change with the
  code that consumes them.

  IM provider-message batching is owned by `SignalsGateway` pending inbound
  batches before ActorInput creation. This module only keeps type-level runtime
  behavior that still applies after an ActorInput has already been formed.
  """

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
  def consumption_path("signal.entry.removed"), do: :lifecycle
  def consumption_path("timer.fired"), do: :internal
  def consumption_path("check_back_later.wakeup"), do: :direct
  def consumption_path("cron.fire"), do: :direct

  def consumption_path(type) when is_binary(type) and binary_part(type, 0, 8) == "command.",
    do: :command

  def consumption_path(_type), do: :direct

  @doc """
  Returns how ActorRuntime should schedule a command input.
  """
  @spec command_runtime_policy(String.t()) ::
          :control_now | :checkpoint_nudge | :worker_turn | :unknown
  def command_runtime_policy("command.new"), do: :control_now
  def command_runtime_policy("command.stop"), do: :control_now
  def command_runtime_policy("command.retry"), do: :control_now
  def command_runtime_policy("command.steer"), do: :checkpoint_nudge
  def command_runtime_policy("command.compress"), do: :worker_turn
  def command_runtime_policy("command." <> _name), do: :unknown
  def command_runtime_policy(_type), do: :unknown

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
end
