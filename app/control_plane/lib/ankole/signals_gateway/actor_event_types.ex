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

  @interaction_preserving_turn_types ~w(
    signal.entry.removed
    session.reset_due
    command.llm_help
    check_back_later.wakeup
    cron.fire
    webhook.received
    automation_job.emitted
    automation_job.run_failed
    background_agent_job.completed
    background_agent_job.failed
    background_agent_job.waiting
    workflow.run.completed
    workflow.run.failed
    workflow.run.attention
  )

  @doc """
  Whether appending this event makes an older pending interaction stale.

  New human input and control commands supersede an unanswered clarification.
  Asynchronous lifecycle notifications may start a visible Agent Turn, but do
  not express new user intent and therefore preserve the pending interaction.
  """
  @spec supersedes_pending_interaction?(String.t()) :: boolean()
  def supersedes_pending_interaction?(type) when is_binary(type),
    do: type not in @interaction_preserving_turn_types

  def supersedes_pending_interaction?(_type), do: false

  @doc false
  @spec interaction_preserving_turn_types() :: [String.t()]
  def interaction_preserving_turn_types, do: @interaction_preserving_turn_types
end
