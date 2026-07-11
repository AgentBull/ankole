defmodule Ankole.SubagentDelegations do
  @moduledoc """
  Durable subagent delegation work items and trajectory events.

  This module is the stable context facade. PostgreSQL owns work lifecycle and
  audit truth; the internal modules keep dispatch, lifecycle transitions,
  control actions, queries, and audit persistence as separate responsibilities.
  """

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SubagentDelegations.Audit
  alias Ankole.SubagentDelegations.Control
  alias Ankole.SubagentDelegations.Dispatch
  alias Ankole.SubagentDelegations.Lifecycle
  alias Ankole.SubagentDelegations.Queries

  @doc "Creates one durable work item and its isolated dispatch event atomically."
  defdelegate create_with_dispatch(attrs), to: Dispatch

  @doc false
  defdelegate claim_attempt_in_tx(repo, delegation_id, agent_uid, expected_attempt),
    to: Lifecycle

  @doc false
  defdelegate requeue_unstarted_attempt(delegation_id, agent_uid, expected_attempt),
    to: Lifecycle

  @doc "Delays one still-open delegation actor event without consuming it."
  defdelegate defer_actor_event(actor_event, available_at), to: Dispatch

  @doc "Completes a delegation actor event that no longer needs execution."
  defdelegate complete_actor_event(actor_event), to: Dispatch

  @doc "Consumes a superseded initial dispatch before a queued steer starts work."
  defdelegate complete_open_dispatch(delegation_id, agent_uid), to: Dispatch

  @doc "Commits one lifecycle transition and its parent wakeup atomically."
  def commit_status_with_wakeup(delegation_id, agent_uid, attrs, opts \\ []),
    do: Lifecycle.commit_status_with_wakeup(delegation_id, agent_uid, attrs, opts)

  defp fail_audit_rejection_in_tx(repo, delegation_id, agent_uid, %DateTime{} = now) do
    with {:ok, result} <-
           Lifecycle.commit_status_after_runtime_prefix_in_tx(
             repo,
             delegation_id,
             agent_uid,
             %{
               "status" => "failed",
               "error" => %{
                 "code" => "audit_persistence_rejected",
                 "summary" => "Delegation audit persistence was rejected by the control plane."
               }
             },
             now,
             nil
           ),
         {:ok, :ok} <-
           Dispatch.complete_all_open_events_in_tx(repo, delegation_id, agent_uid, now) do
      {:ok, result}
    end
  end

  @doc false
  def compensate_turn_error_in_tx(
        repo,
        %ActorEvent{agent_uid: agent_uid, session_id: "subagent:" <> delegation_id},
        %{"details_json" => %{"error_code" => "subagent_audit_persistence_rejected"}},
        %DateTime{} = now
      ) do
    fail_audit_rejection_in_tx(repo, delegation_id, agent_uid, now)
  end

  def compensate_turn_error_in_tx(_repo, %ActorEvent{}, _reason, %DateTime{}),
    do: {:ok, nil}

  @doc false
  def finalize_turn_error({:ok, %{turn_error_compensation: compensation} = result}) do
    {:ok,
     result
     |> Map.delete(:turn_error_compensation)
     |> Map.put(:status, :subagent_failed)
     |> Map.put(:subagent_failure, compensation)}
  end

  def finalize_turn_error(result), do: result

  @doc false
  defdelegate pending_steer_events(delegation_id, agent_uid, excluded_event_id), to: Dispatch

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

  @doc false
  defdelegate append_worker_events(delegation_id, agent_uid, events, turn_ref, route),
    to: Audit

  @doc "Fetches one delegation for an agent."
  defdelegate get_delegation_for_agent(delegation_id, agent_uid), to: Queries, as: :get_for_agent

  @doc "Fetches one delegation with its latest trajectory sequence."
  defdelegate get_delegation_summary_for_agent(delegation_id, agent_uid),
    to: Queries,
    as: :get_summary_for_agent

  @doc "Lists trajectory events for one delegation in sequence order."
  defdelegate list_events(delegation_id), to: Queries
end
