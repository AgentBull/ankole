defmodule Ankole.Sessions.Notices do
  @moduledoc false

  alias Ankole.Conversations.Target, as: StatementTarget
  alias Ankole.AIAgent.TokenQuota
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.DeadLetterNoticeConfig
  alias Ankole.Sessions.AsyncWorkUnit
  alias Ankole.Signals.Sanitizer
  alias Ankole.I18n
  alias Ankole.Logging
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.Queue
  alias Ankole.Conversations.Delivery.Preview
  alias Ankole.SystemConfig
  alias Ankole.TimeZone

  defp workflow_model_unavailable(
         {:error, {:model_profile_unavailable, profile, reason}},
         %Signal{} = event,
         now
       ) do
    result =
      event
      |> Ankole.Sessions.fail_workflow_model(profile, reason, now)
      |> Ankole.Errors.reason()
      |> Ankole.Workflow.cleanup_terminal_transition()

    with {:ok, _} <- result do
      complete_without_turn(event, now, :model_profile_unavailable, %{profile: profile}, fn _,
                                                                                            _ ->
        {:ok, nil}
      end)
    end
  end

  @doc false
  def workflow_model_unavailable_in_tx(repo, event, profile, reason, now) do
    with {:ok, call_id} <- Ankole.Workflow.parse_task_session_id(event.session_id) do
      Ankole.Workflow.TaskLifecycle.model_unavailable_in_tx(
        repo,
        call_id,
        event.agent_uid,
        event.session_id,
        profile,
        reason,
        now
      )
    end
  end

  @spec finalize(
          {:ok, map()} | {:error, term()},
          Signal.t(),
          DateTime.t()
        ) :: {:ok, map()} | {:error, term()}
  def finalize(
        {:error, {:model_profile_unavailable, profile, reason}},
        %Signal{} = signal,
        %DateTime{} = now
      )
      when is_binary(profile) do
    if Run.kind(signal) == :workflow_task do
      workflow_model_unavailable(
        {:error, {:model_profile_unavailable, profile, reason}},
        signal,
        now
      )
    else
      complete_without_turn(
        signal,
        now,
        :model_profile_unavailable,
        %{profile: profile, profile_error: reason},
        fn repo, locked_event ->
          text =
            I18n.t("conversations.delivery.reply.model_profile_unavailable", %{
              "profile" => profile,
              "ref" => locked_event.id
            })

          post_in_tx(repo, locked_event, :model_profile_unavailable, text, %{"profile" => profile})
        end
      )
    end
  end

  def finalize(
        {:error, {:agent_token_quota_exceeded, window}},
        %Signal{} = signal,
        %DateTime{} = now
      )
      when is_map(window) do
    complete_without_turn(
      signal,
      now,
      :agent_token_quota_exceeded,
      %{token_quota: window},
      fn repo, locked_event ->
        text = token_quota_notice_text(window, locked_event.id)

        post_in_tx(repo, locked_event, :token_quota_exceeded, text)
      end
    )
  end

  def finalize({:error, :tenant_suspended}, %Signal{last_attempt_at: nil} = event, now) do
    event
    |> Ankole.Sessions.reject_suspended_input(now)
    |> Ankole.Errors.reason()
    |> log_notice_failure(:tenant_suspended)
  end

  def finalize(result, %Signal{}, %DateTime{}), do: result

  @doc false
  def reject_suspended_input_in_tx(repo, event, now) do
    :ok = lock_work_in_tx(repo, event)
    :ok = Queue.lock_session_in_tx(repo, event.agent_uid, event.session_id)

    case Ankole.Signals.lock_signal_in_tx(repo, event.id) do
      %Signal{last_attempt_at: nil, status: live_status} = current
      when live_status in [:queued, :running] ->
        with {:ok, workflow_transition} <- reject_unstarted_workflow_task(repo, current, now),
             {:ok, completed} <-
               Ankole.Sessions.Queue.mark_event_completed_in_tx(repo, current, now) do
          notice =
            maybe_commit_notice(repo, completed, fn repo, input ->
              text = I18n.t("conversations.delivery.reply.tenant_suspended", %{"ref" => input.id})

              post_in_tx(repo, input, :tenant_suspended, text)
            end)

          {:ok,
           %{
             status: :tenant_suspended,
             workflow_transition: workflow_transition,
             signal: completed,
             posted: notice_posted(notice),
             notice_error: notice_error(notice)
           }}
        end

      %Signal{} = current ->
        # A concurrent admission already owns this attempt. Rejecting another
        # input in its session must never finalize that admitted turn.
        {:ok, %{status: :unchanged, signal: current}}

      nil ->
        {:ok, %{status: :idle}}
    end
  end

  @doc false
  def lock_work_in_tx(repo, event) do
    case Ankole.Workflow.parse_task_session_id(event.session_id) do
      {:ok, _call_id} ->
        with {:ok, %{run: run}} <-
               Ankole.Workflow.Slot.lock_session_work_in_tx(
                 repo,
                 event.agent_uid,
                 event.session_id
               ) do
          Queue.lock_sessions_in_tx(repo, [
            {event.agent_uid, event.session_id},
            {run.agent_uid, run.owner_session_id}
          ])
        end

      :error ->
        :ok
    end
  end

  defp reject_unstarted_workflow_task(repo, event, now) do
    case Ankole.Workflow.parse_task_session_id(event.session_id) do
      {:ok, call_id} ->
        case Ankole.Workflow.TaskLifecycle.fail_unstarted_task_in_tx(
               repo,
               call_id,
               event.agent_uid,
               "tenant_suspended",
               "The tenant does not accept new work.",
               now
             ) do
          {:ok, transition} -> {:ok, transition}
          {:error, {:workflow_task_not_queued, :running}} -> {:ok, nil}
          {:error, _} = error -> error
        end

      _ ->
        {:ok, nil}
    end
  end

  @doc """
  Returns the user notice text of one exceeded token quota window.
  """
  @spec token_quota_notice_text(map(), Ecto.UUID.t()) :: String.t()
  def token_quota_notice_text(window, signal_id) when is_map(window) do
    I18n.t("conversations.delivery.reply.token_quota_exceeded", %{
      "used" => Map.fetch!(window, :used_tokens),
      "limit" => Map.fetch!(window, :limit_tokens),
      "resets_at" => local_instant(Map.fetch!(window, :window_ends_at)),
      "ref" => signal_id
    })
  end

  # A chat reader lives in the installation timezone, like scheduled work does.
  defp local_instant(%DateTime{} = instant) do
    with {:ok, timezone} <- SystemConfig.timezone(),
         {:ok, local} <- TimeZone.shift(instant, timezone) do
      DateTime.to_iso8601(local)
    else
      _utc -> DateTime.to_iso8601(instant)
    end
  end

  # Rejection can follow a crashed run. Recover its committed tool results
  # before closing its input and writing the notice.
  defp complete_without_turn(signal, _now, status, fields, commit_notice) do
    signal
    |> Ankole.Sessions.complete_without_turn(status, fields, commit_notice)
    |> Ankole.Errors.reason()
    |> log_notice_failure(status)
  end

  @doc false
  def complete_without_turn_in_tx(repo, signal, status, fields, commit_notice) do
    with {:ok, result} <- Run.reject_input_in_tx(repo, signal, :stopped, status) do
      if result.status == :completed do
        notice_result = maybe_commit_notice(repo, result.reply_event, commit_notice)

        {:ok,
         result
         |> Map.merge(fields)
         |> Map.merge(%{
           status: status,
           posted: notice_posted(notice_result),
           notice_error: notice_error(notice_result)
         })}
      else
        {:ok, Map.merge(result, fields)}
      end
    end
  end

  # An ambient group message has not asked the agent to speak. A turn that
  # cannot start must not turn every observed message into a warning.
  defp maybe_commit_notice(
         _repo,
         %Signal{producer: :kernel, type: "im.message.may_intervene"},
         _commit_notice
       ),
       do: {:ok, %Ankole.Conversations.PostResult{}}

  defp maybe_commit_notice(repo, %Signal{} = signal, commit_notice) do
    with {:ok, targets} <- Ankole.Sessions.Presentation.targets_in_tx(repo, signal) do
      if Enum.any?(targets, &StatementTarget.reply_eligible?(&1, signal)),
        do: commit_notice.(repo, signal),
        else: {:ok, %Ankole.Conversations.PostResult{}}
    end
  end

  @doc "Posts one runtime notice through the statement destination contract."
  def post_in_tx(repo, event, kind, text, params \\ %{}) do
    {prefix, source, state, empty_error} =
      case kind do
        :dead_letter ->
          {"ai-dead-letter", "session_dead_letter_notice", "failed",
           :empty_dead_letter_notice_text}

        :stopped ->
          {"ai-turn-stopped", "session_turn_stopped", "stopped", :empty_stopped_turn_notice_text}

        :model_profile_unavailable ->
          {"ai-model-profile-unavailable", "session_model_profile_unavailable_notice", "failed",
           :empty_model_profile_unavailable_notice_text}

        :token_quota_exceeded ->
          {"ai-token-quota-exceeded", "session_token_quota_exceeded_notice", "failed",
           :empty_token_quota_exceeded_notice_text}

        :tenant_suspended ->
          {"ai-tenant-suspended", "session_tenant_suspended_notice", "failed",
           :empty_tenant_suspended_notice_text}
      end

    statement = %Ankole.Conversations.Statement{
      signal: event,
      text: text,
      notice: %{
        prefix: prefix,
        empty_error: empty_error,
        metadata: Map.put(params, "source", source),
        state: state
      }
    }

    Ankole.Sessions.Presentation.post_in_tx(repo, event, statement)
  end

  defp notice_posted({:ok, %Ankole.Conversations.PostResult{} = posted}), do: posted
  defp notice_posted(_), do: %Ankole.Conversations.PostResult{}

  defp notice_error({:error, reason}), do: reason
  defp notice_error(_result), do: nil

  defp log_notice_failure({:ok, %{notice_error: nil}} = result, _status), do: result

  defp log_notice_failure(
         {:ok, %{signal: %Signal{} = event, notice_error: reason}} = result,
         status
       ) do
    Logging.warning(
      "sessions.turn_start_notice_failed",
      "turn start notice not committed",
      %{signal_id: event.id, status: status, reason: inspect(reason)}
    )

    result
  end

  defp log_notice_failure(result, _status), do: result

  @doc false
  def commit_context_withdrawal_notice_in_tx(repo, events, fallback, now) do
    (Enum.reverse(events) ++ [fallback])
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(fn event ->
      Preview.channel_reply_eligible?(event) and
        Signal.reply_anchor_provider_message_id(event) in Signal.input_provider_message_ids(event)
    end)
    |> Enum.reduce_while({:ok, %Ankole.Conversations.PostResult{}}, fn event, _result ->
      anchor = %{
        event
        | provider_message_id: Signal.reply_anchor_provider_message_id(event),
          data: %{}
      }

      case Queue.ensure_event_source_live_in_tx(repo, anchor, now) do
        {:error, :signal_canceled} ->
          {:cont, {:ok, %Ankole.Conversations.PostResult{}}}

        result when result in [:ok, {:error, :signal_context_canceled}] ->
          {:halt, commit_context_withdrawal_notice(repo, event)}
      end
    end)
  end

  defp commit_context_withdrawal_notice(repo, event) do
    text = I18n.t("conversations.delivery.reply.context_withdrawn")
    post_in_tx(repo, event, :stopped, text, %{"reason" => "context_withdrawn"})
  end

  @doc false
  def commit_dead_letter_notice_in_tx(_repo, %Signal{}, :human_access_revoked),
    do: {:ok, %Ankole.Conversations.PostResult{}}

  def commit_dead_letter_notice_in_tx(repo, %Signal{} = event, reason),
    do: post_in_tx(repo, event, :dead_letter, dead_letter_notice_text(repo, event, reason))

  defp dead_letter_notice_text(%Signal{} = event),
    do: I18n.t("conversations.delivery.reply.dead_letter", %{"ref" => event.id})

  defp dead_letter_notice_text(repo, %Signal{} = event, reason) do
    text =
      dead_letter_quota_text(event, reason) ||
        AsyncWorkUnit.dead_letter_notice_text(event) ||
        dead_letter_notice_text(event)

    if DeadLetterNoticeConfig.enabled_in_tx?(repo) do
      detail = Sanitizer.preview(reason)

      text <>
        "\n" <>
        I18n.t("conversations.delivery.reply.dead_letter_error_details", %{"detail" => detail})
    else
      text
    end
  end

  # A turn that crossed the quota while it ran gets the quota text. The generic
  # retry text would be wrong, because no retry can succeed before the period
  # ends or an operator resets the quota.
  defp dead_letter_quota_text(%Signal{} = event, reason) do
    with true <- token_quota_turn_error?(reason),
         {:ok, %{usage: %{} = window}} <- TokenQuota.status(event.agent_uid) do
      token_quota_notice_text(window, event.id)
    else
      _other_reason -> nil
    end
  end

  defp token_quota_turn_error?(%{"code" => "agent_token_quota_exceeded"}), do: true

  defp token_quota_turn_error?(%{"details_json" => %{} = details}),
    do: details["error_code"] == "agent_token_quota_exceeded"

  defp token_quota_turn_error?(_reason), do: false
end
