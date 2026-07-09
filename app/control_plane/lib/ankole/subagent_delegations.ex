defmodule Ankole.SubagentDelegations do
  @moduledoc """
  Durable subagent delegation work items and trajectory events.

  This module is the stable context facade. PostgreSQL owns work lifecycle and
  audit truth; the internal modules keep dispatch, lifecycle transitions,
  control actions, queries, and audit persistence as separate responsibilities.
  """

  alias Ankole.SubagentDelegations.Audit
  alias Ankole.SubagentDelegations.Control
  alias Ankole.SubagentDelegations.Dispatch
  alias Ankole.SubagentDelegations.Lifecycle
  alias Ankole.SubagentDelegations.Queries

  @doc "Creates one durable work item and its isolated dispatch event atomically."
  defdelegate create_with_dispatch(attrs), to: Dispatch

  @doc "Claims one bounded execution attempt and its per-agent running slot."
  defdelegate prepare_attempt(delegation_id, agent_uid), to: Lifecycle

  @doc "Delays one still-open delegation actor event without consuming it."
  defdelegate defer_actor_event(actor_event, available_at), to: Dispatch

  @doc "Completes a delegation actor event that no longer needs execution."
  defdelegate complete_actor_event(actor_event), to: Dispatch

  @doc "Consumes a superseded initial dispatch before a queued steer starts work."
  defdelegate complete_open_dispatch(delegation_id, agent_uid), to: Dispatch

  @doc false
  def cleanup_candidates(now \\ DateTime.utc_now(:microsecond), limit \\ 100),
    do: Dispatch.cleanup_candidates(now, limit)

  @doc false
  def mark_codex_home_cleaned(delegation_id, cleaned_at \\ DateTime.utc_now(:microsecond)),
    do: Dispatch.mark_codex_home_cleaned(delegation_id, cleaned_at)

  @doc "Commits one lifecycle transition and its parent wakeup atomically."
  defdelegate commit_status_with_wakeup(delegation_id, agent_uid, attrs), to: Lifecycle

  @doc "Lists work visible from the parent session and channel."
  defdelegate list_for_channel(agent_uid, session_id, signal_channel_id), to: Queries

  @doc "Lists installation-wide Console work with a stable keyset cursor."
  def list_for_console(opts \\ []), do: Queries.list_for_console(opts)

  @doc "Fetches one delegation without chat visibility constraints for Console."
  defdelegate get_delegation(delegation_id), to: Queries, as: :get

  @doc "Projects a delegation into the named Console API contract."
  defdelegate console_projection(delegation), to: Queries

  @doc "Projects one trajectory event into the Console timeline contract."
  defdelegate console_event_projection(event), to: Queries

  @doc "Durably requests cancellation without trusting worker-local state."
  defdelegate request_stop(delegation_id, attrs), to: Control

  @doc "Journals a cross-worker steering command for one delegation."
  defdelegate request_steer(delegation_id, attrs), to: Control

  @doc "Appends one trajectory event after deterministic secret redaction."
  defdelegate append_event(attrs), to: Audit

  @doc "Appends one ordered trajectory event batch atomically."
  defdelegate append_events(delegation_id, agent_uid, events), to: Audit

  @doc "Fetches one delegation for an agent."
  defdelegate get_delegation_for_agent(delegation_id, agent_uid), to: Queries, as: :get_for_agent

  @doc "Fetches one delegation with its latest trajectory sequence."
  defdelegate get_delegation_summary_for_agent(delegation_id, agent_uid),
    to: Queries,
    as: :get_summary_for_agent

  @doc "Lists trajectory events for one delegation in sequence order."
  defdelegate list_events(delegation_id), to: Queries
end
