defmodule Ankole.Sessions.WakeRecycle do
  @moduledoc """
  Prompt-cache-aware cold-wake model conversation rotation.

  When a Session resumes after its upstream prompt cache has gone cold and its
  accumulated model history is large—or after an extended multi-day idle gap on
  an external IM channel—`Admission` ends the active `AIGateway` conversation
  atomically inside `admit_in_tx/5` and opens a successor marked for a
  deterministic wake briefing on its first model request.

  Rotation runs exclusively when `event.last_attempt_at` is `nil`, inside the
  same transaction that stamps `last_attempt_at`, so crash retries never end a
  conversation or inject a briefing twice.
  """

  alias Ankole.AIGateway
  alias Ankole.AIGateway.CompactionHistory
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Conversations
  alias Ankole.Conversations.Conversation, as: PublicConversation
  alias Ankole.Conversations.Delivery.Interactions
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Signals.Signal
  alias Ankole.Workflow

  @config_key "sessions.wake_recycle"
  @default_policy %{
    "min_cold_gap_seconds" => 3_600,
    "min_context_tokens" => 128_000,
    "im_max_idle_seconds" => 259_200
  }
  @min_seconds 60
  @max_seconds 31_536_000
  @min_tokens 1_024
  @max_tokens 10_000_000

  @callback_prefixes ["background_agent_job.", "workflow.run."]
  @exempt_event_types [
    "command.new",
    "signal.action.invoked",
    "conversation.action_card.executed"
  ]

  @spec definition() :: Definition.t()
  def definition do
    AppConfigure.define(
      scope: :tenant,
      key: @config_key,
      encrypted: false,
      schema: Schema.new(&validate_policy/1),
      default_value: @default_policy,
      description:
        "Cold-wake model conversation recycle thresholds (idle gap seconds, minimum context tokens, and external IM maximum idle seconds)."
    )
  end

  @spec policy() :: %{String.t() => pos_integer()}
  def policy do
    {:ok, value} = AppConfigure.get(definition())
    value
  end

  @spec maybe_recycle_in_tx(Signal.t(), map(), DateTime.t()) :: :ok | {:error, term()}
  def maybe_recycle_in_tx(%Signal{} = event, %{kind: :main}, %DateTime{} = now) do
    if eligible_signal?(event) and not session_has_live_work?(event) do
      evaluate_and_recycle_in_tx(event, now)
    else
      :ok
    end
  end

  def maybe_recycle_in_tx(%Signal{}, _plan, %DateTime{}), do: :ok

  defp eligible_signal?(%Signal{last_attempt_at: %DateTime{}}), do: false

  defp eligible_signal?(%Signal{type: type, data: data}) do
    not (type in @exempt_event_types or
           Enum.any?(@callback_prefixes, &String.starts_with?(type, &1)) or
           answered_interaction_signal?(data))
  end

  defp answered_interaction_signal?(%{"answered_interaction_id" => id})
       when is_binary(id) and id != "",
       do: true

  defp answered_interaction_signal?(_data), do: false

  defp session_has_live_work?(%Signal{
         id: signal_id,
         agent_uid: agent_uid,
         session_id: session_id
       }) do
    other_running_signal?(agent_uid, session_id, signal_id) or
      BackgroundAgentJobs.live_job_ids_for_owner_sessions([session_id], agent_uid) != [] or
      live_workflow_run?(agent_uid, session_id)
  end

  defp other_running_signal?(agent_uid, session_id, current_signal_id) do
    Ankole.Signals.list_signals!(
      query: [
        filter: [
          agent_uid: agent_uid,
          session_id: session_id,
          status: :running
        ],
        select: [:id],
        limit: 2
      ]
    )
    |> Enum.any?(&(&1.id != current_signal_id))
  end

  defp live_workflow_run?(agent_uid, session_id) do
    Workflow.list_runs!(
      query: [
        filter: [
          agent_uid: agent_uid,
          owner_session_id: session_id,
          status: :running
        ],
        select: [:id],
        limit: 1
      ]
    ) != []
  end

  defp evaluate_and_recycle_in_tx(%Signal{agent_uid: uid, session_id: session} = event, now) do
    with %AIGateway.Schemas.Conversation{} = active <-
           ModelHistory.active_conversation(uid, session),
         {:ok, visible} when visible != [] <-
           AIGateway.visible_response_chain(uid, active.id) do
      last_message = List.last(visible)

      last_activity_at =
        last_message.updated_at || last_message.inserted_at || active.updated_at ||
          active.inserted_at

      idle_gap = max(DateTime.diff(now, last_activity_at, :second), 0)
      context_tokens = CompactionHistory.history_usage_tokens(visible)
      {:ok, thresholds} = AppConfigure.get_in_tx(definition())

      case recycle_reason(event, idle_gap, context_tokens, thresholds) do
        {:ok, reason} ->
          recycle_conversation_in_tx(
            uid,
            session,
            event,
            active,
            now,
            idle_gap,
            context_tokens,
            reason
          )

        :none ->
          :ok
      end
    else
      _no_active_or_empty -> :ok
    end
  end

  defp recycle_reason(event, idle_gap, context_tokens, thresholds) do
    cond do
      idle_gap >= thresholds["min_cold_gap_seconds"] and
          context_tokens >= thresholds["min_context_tokens"] ->
        {:ok, "cold_prompt_cache_large_context"}

      external_im_conversation?(event) and idle_gap >= thresholds["im_max_idle_seconds"] ->
        {:ok, "im_extended_idle"}

      true ->
        :none
    end
  end

  defp external_im_conversation?(%Signal{conversation_id: id}) when is_binary(id) do
    case Conversations.get_conversation!(id) do
      %PublicConversation{kind: :external, external_kind: kind}
      when kind in [:im_dm, :im_group] ->
        true

      _other ->
        false
    end
  end

  defp external_im_conversation?(%Signal{}), do: false

  defp recycle_conversation_in_tx(
         uid,
         session,
         event,
         predecessor_snapshot,
         now,
         idle_gap,
         context_tokens,
         reason
       ) do
    with {:ok, closed} <- ModelHistory.end_active_conversation_in_tx(uid, session, now),
         {:ok, _superseded} <- Interactions.supersede_for_wake_recycle_in_tx(event, now) do
      source = closed || predecessor_snapshot

      successor_metadata =
        source
        |> ModelHistory.successor_origin_metadata(event)
        |> Map.put("wake_briefing", %{
          "previous_conversation_id" => source.id,
          "reason" => reason,
          "recycled_at" => DateTime.to_iso8601(now),
          "idle_gap_seconds" => idle_gap,
          "previous_context_tokens" => context_tokens
        })

      with {:ok, _successor} <-
             AIGateway.ensure_conversation_in_tx(uid, session, successor_metadata),
           do: :ok
    end
  end

  defp validate_policy(value) when is_map(value) do
    normalized = Ankole.Attrs.normalize_external_attrs(value)

    with {:ok, min_cold_gap} <-
           validate_range(normalized["min_cold_gap_seconds"], @min_seconds, @max_seconds),
         {:ok, min_tokens} <-
           validate_range(normalized["min_context_tokens"], @min_tokens, @max_tokens),
         {:ok, im_max_idle} <-
           validate_range(normalized["im_max_idle_seconds"], @min_seconds, @max_seconds) do
      {:ok,
       %{
         "min_cold_gap_seconds" => min_cold_gap,
         "min_context_tokens" => min_tokens,
         "im_max_idle_seconds" => im_max_idle
       }}
    end
  end

  defp validate_policy(_value), do: {:error, :invalid_wake_recycle_policy}

  defp validate_range(value, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp validate_range(_value, _min, _max), do: {:error, :invalid_wake_recycle_policy}
end
