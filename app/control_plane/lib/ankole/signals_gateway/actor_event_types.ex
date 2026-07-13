defmodule Ankole.SignalsGateway.ActorEventTypes do
  @moduledoc """
  Code-defined ActorEvent semantics used by SignalsGateway.

  The set of event types is intentionally defined in code, not in DB config:
  these are runtime contracts the worker relies on, and they change with the
  code that consumes them.

  IM provider-message batching is owned by `SignalsGateway` pending inbound
  batches before ActorEvent creation. This module only keeps type-level runtime
  behavior that still applies after an ActorEvent has already been formed.
  """

  @live_turn_command_types ~w(command.new command.stop command.retry command.steer command.compress)

  @doc """
  Command events that may wake a session while another event has a live delivery.
  """
  @spec live_turn_command_types() :: [String.t()]
  def live_turn_command_types, do: @live_turn_command_types

  @doc """
  Whether an event may interrupt a live turn for the same actor session.
  """
  @spec live_turn_command_event?(String.t()) :: boolean()
  def live_turn_command_event?(type),
    do: command_runtime_policy(type) in [:control_now, :checkpoint_nudge]

  @doc """
  Returns how ActorRuntime should schedule a command event.
  """
  @spec command_runtime_policy(String.t()) ::
          :control_now | :checkpoint_nudge | :worker_turn | :unknown
  def command_runtime_policy("command.new"), do: :control_now
  def command_runtime_policy("command.stop"), do: :control_now
  def command_runtime_policy("command.retry"), do: :control_now
  def command_runtime_policy("command.steer"), do: :checkpoint_nudge
  def command_runtime_policy("command.compress"), do: :control_now
  def command_runtime_policy("command." <> _name), do: :unknown
  def command_runtime_policy(_type), do: :unknown
end
