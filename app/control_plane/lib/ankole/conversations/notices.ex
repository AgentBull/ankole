defmodule Ankole.Conversations.Notices do
  @moduledoc false

  alias Ankole.AIAgent.TokenQuota
  alias Ankole.Conversations.Run
  alias Ankole.SignalsGateway.ActorRuntime.DeadLetterNoticeConfig
  alias Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.I18n
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SystemConfig
  alias Ankole.TimeZone

  defp workflow_model_unavailable(
         {:error, {:model_profile_unavailable, profile, reason}},
         %ActorEvent{} = event,
         now
       ) do
    failure = %{
      "ok" => false,
      "code" => "workflow_task_model_profile_unavailable",
      "summary" => "Model profile #{profile} is unavailable: #{inspect(reason)}",
      "retryable" => false
    }

    result =
      Repo.transact(fn repo ->
        with {:ok, call_id} <- Ankole.Workflow.parse_task_session_id(event.session_id),
             {:ok, %{call: call}} <- Ankole.Workflow.get_task_for_agent(call_id, event.agent_uid) do
          if call.status == "running",
            do:
              Ankole.Workflow.submit_result_in_tx(
                repo,
                call_id,
                event.agent_uid,
                event.session_id,
                failure
              ),
            else:
              Ankole.Workflow.fail_unstarted_task(
                call_id,
                event.agent_uid,
                failure["code"],
                failure["summary"],
                now
              )
        end
      end)
      |> Ankole.Workflow.cleanup_terminal_transition()

    with {:ok, _} <- result do
      complete_without_turn(event, now, :model_profile_unavailable, %{profile: profile}, fn _,
                                                                                            _ ->
        {:ok, nil}
      end)
    end
  end

  @spec finalize(
          {:ok, map()} | {:error, term()},
          ActorEvent.t(),
          DateTime.t()
        ) :: {:ok, map()} | {:error, term()}
  def finalize(
        {:error, {:model_profile_unavailable, profile, reason}},
        %ActorEvent{} = actor_event,
        %DateTime{} = now
      )
      when is_binary(profile) do
    if Run.kind(actor_event) == :workflow_task do
      workflow_model_unavailable(
        {:error, {:model_profile_unavailable, profile, reason}},
        actor_event,
        now
      )
    else
      complete_without_turn(
        actor_event,
        now,
        :model_profile_unavailable,
        %{profile: profile, profile_error: reason},
        fn repo, locked_event ->
          text =
            I18n.t("signals_gateway.reply.model_profile_unavailable", %{
              "profile" => profile,
              "ref" => locked_event.id
            })

          Outbox.commit_model_profile_unavailable_notice_outbox_in_tx(
            repo,
            locked_event,
            profile,
            text
          )
        end
      )
    end
  end

  def finalize(
        {:error, {:agent_token_quota_exceeded, window}},
        %ActorEvent{} = actor_event,
        %DateTime{} = now
      )
      when is_map(window) do
    complete_without_turn(
      actor_event,
      now,
      :agent_token_quota_exceeded,
      %{token_quota: window},
      fn repo, locked_event ->
        Outbox.commit_token_quota_exceeded_notice_outbox_in_tx(
          repo,
          locked_event,
          token_quota_notice_text(window, locked_event.id)
        )
      end
    )
  end

  def finalize({:error, :tenant_suspended}, %ActorEvent{last_attempt_at: nil} = event, now) do
    Repo.transact(fn repo -> reject_suspended_input_in_tx(repo, event, now) end)
    |> log_notice_failure(:tenant_suspended)
  end

  def finalize(result, %ActorEvent{}, %DateTime{}), do: result

  @doc false
  def reject_suspended_input_in_tx(repo, event, now) do
    case Ankole.SignalsGateway.Actors.lock_actor_event_in_tx(repo, event.id) do
      %ActorEvent{last_attempt_at: nil, completed_at: nil, input_state: "open"} = current ->
        with :ok <- reject_unstarted_workflow_task(current, now),
             {:ok, completed} <-
               Ankole.SignalsGateway.Actors.mark_event_completed_in_tx(repo, current, now) do
          notice =
            maybe_commit_notice(repo, completed, fn repo, input ->
              text = I18n.t("signals_gateway.reply.tenant_suspended", %{"ref" => input.id})
              Outbox.commit_tenant_suspended_notice_outbox_in_tx(repo, input, text)
            end)

          {:ok,
           %{
             status: :tenant_suspended,
             actor_event: completed,
             notice_outbox: notice_outbox(notice),
             notice_error: notice_error(notice)
           }}
        end

      %ActorEvent{} = current ->
        # A concurrent admission already owns this attempt. Rejecting another
        # input in its session must never finalize that admitted turn.
        {:ok, %{status: :unchanged, actor_event: current}}

      nil ->
        {:ok, %{status: :idle}}
    end
  end

  defp reject_unstarted_workflow_task(event, now) do
    case Ankole.Workflow.parse_task_session_id(event.session_id) do
      {:ok, call_id} ->
        case Ankole.Workflow.fail_unstarted_task(
               call_id,
               event.agent_uid,
               "tenant_suspended",
               "The tenant does not accept new work.",
               now
             ) do
          {:ok, _} -> :ok
          {:error, {:workflow_task_not_queued, "running"}} -> :ok
          {:error, _} = error -> error
        end

      _ ->
        :ok
    end
  end

  @doc """
  Returns the user notice text of one exceeded token quota window.
  """
  @spec token_quota_notice_text(map(), Ecto.UUID.t()) :: String.t()
  def token_quota_notice_text(window, actor_event_id) when is_map(window) do
    I18n.t("signals_gateway.reply.token_quota_exceeded", %{
      "used" => Map.fetch!(window, :used_tokens),
      "limit" => Map.fetch!(window, :limit_tokens),
      "resets_at" => local_instant(Map.fetch!(window, :window_ends_at)),
      "ref" => actor_event_id
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
  defp complete_without_turn(actor_event, _now, status, fields, commit_notice) do
    Repo.transact(fn repo ->
      with {:ok, result} <- Run.reject_input_in_tx(repo, actor_event, :stopped, status) do
        if result.status == :completed do
          notice_result = maybe_commit_notice(repo, result.reply_event, commit_notice)

          {:ok,
           result
           |> Map.merge(fields)
           |> Map.merge(%{
             status: status,
             notice_outbox: notice_outbox(notice_result),
             notice_error: notice_error(notice_result)
           })}
        else
          {:ok, Map.merge(result, fields)}
        end
      end
    end)
    |> log_notice_failure(status)
  end

  # An ambient group message has not asked the agent to speak. A turn that
  # cannot start must not turn every observed message into a warning.
  defp maybe_commit_notice(_repo, %ActorEvent{type: "im.message.may_intervene"}, _commit_notice),
    do: {:ok, nil}

  defp maybe_commit_notice(repo, %ActorEvent{} = actor_event, commit_notice) do
    if AIReplyPreview.channel_reply_eligible?(actor_event) do
      commit_notice.(repo, actor_event)
    else
      {:ok, nil}
    end
  end

  defp notice_outbox({:ok, %OutboxEntry{} = outbox}), do: outbox
  defp notice_outbox(_result), do: nil

  defp notice_error({:error, reason}), do: reason
  defp notice_error(_result), do: nil

  defp log_notice_failure({:ok, %{notice_error: nil}} = result, _status), do: result

  defp log_notice_failure(
         {:ok, %{actor_event: %ActorEvent{} = event, notice_error: reason}} = result,
         status
       ) do
    Logging.warning(
      "signals_gateway.actor_runtime.turn_start_notice_failed",
      "turn start notice not committed",
      %{actor_event_id: event.id, status: status, reason: inspect(reason)}
    )

    result
  end

  defp log_notice_failure(result, _status), do: result

  @doc false
  def commit_context_withdrawal_notice_in_tx(repo, events, fallback, now) do
    (Enum.reverse(events) ++ [fallback])
    |> Enum.uniq_by(& &1.id)
    |> Enum.filter(fn event ->
      AIReplyPreview.channel_reply_eligible?(event) and
        ActorEvent.reply_anchor_source_entry_id(event) in ActorEvent.input_source_entry_ids(event)
    end)
    |> Enum.reduce_while({:ok, nil}, fn event, _result ->
      anchor = %{
        event
        | source_entry_id: ActorEvent.reply_anchor_source_entry_id(event),
          payload: %{}
      }

      case Actors.ensure_event_source_live_in_tx(repo, anchor, now) do
        {:error, :actor_event_canceled} ->
          {:cont, {:ok, nil}}

        :ok ->
          {:halt, commit_context_withdrawal_notice(repo, event)}
      end
    end)
  end

  defp commit_context_withdrawal_notice(repo, event) do
    text = I18n.t("signals_gateway.reply.context_withdrawn")

    case Outbox.commit_stopped_turn_notice_outbox_in_tx(repo, event, text, "context_withdrawn") do
      {:error, reason} = error ->
        if Outbox.unroutable_reply_reason?(reason) do
          Logging.warning(
            "conversations.context_withdrawal_notice_unroutable",
            "context withdrawal notice has no reachable route",
            %{actor_event_id: event.id, reason: inspect(reason, limit: 20)}
          )

          {:ok, nil}
        else
          error
        end

      result ->
        result
    end
  end

  @doc false
  def commit_dead_letter_notice_in_tx(_repo, %ActorEvent{}, :human_access_revoked), do: {:ok, nil}

  def commit_dead_letter_notice_in_tx(repo, %ActorEvent{} = event, reason) do
    if AIReplyPreview.channel_reply_eligible?(event) do
      text = dead_letter_notice_text(repo, event, reason)

      case Outbox.commit_dead_letter_notice_outbox_in_tx(repo, event, text) do
        {:ok, notice} -> {:ok, notice}
        {:error, reason} -> skip_unroutable_dead_letter_notice(event, reason)
      end
    else
      {:ok, nil}
    end
  end

  defp dead_letter_notice_text(%ActorEvent{} = event),
    do: I18n.t("signals_gateway.reply.dead_letter", %{"ref" => event.id})

  defp dead_letter_notice_text(repo, %ActorEvent{} = event, reason) do
    text =
      dead_letter_quota_text(event, reason) ||
        AsyncWorkUnit.dead_letter_notice_text(event) ||
        dead_letter_notice_text(event)

    if DeadLetterNoticeConfig.enabled_in_tx?(repo) do
      detail = Sanitizer.preview(reason)

      text <>
        "\n" <>
        I18n.t("signals_gateway.reply.dead_letter_error_details", %{"detail" => detail})
    else
      text
    end
  end

  # A turn that crossed the quota while it ran gets the quota text. The generic
  # retry text would be wrong, because no retry can succeed before the period
  # ends or an operator resets the quota.
  defp dead_letter_quota_text(%ActorEvent{} = event, reason) do
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

  # A deleted route, or a channel that never accepts replies, has nowhere to put
  # this notice. Failing here would roll back whichever transaction decided the
  # dead letter — a worker takeover, a worker expiry, or a turn abort — so one
  # unreachable old event could stop a whole worker from being replaced. The
  # dead-lettered event row remains the checkable record of that failure.
  defp skip_unroutable_dead_letter_notice(%ActorEvent{} = event, reason) do
    if Outbox.unroutable_reply_reason?(reason) do
      Logging.warning(
        "signals_gateway.actor_runtime.dead_letter_notice_unroutable",
        "actor dead letter notice has no reachable route",
        %{
          actor_event_id: event.id,
          agent_uid: event.agent_uid,
          binding_name: event.binding_name,
          reason: inspect(reason, limit: 20)
        }
      )

      {:ok, nil}
    else
      {:error, reason}
    end
  end
end
