defmodule Ankole.SignalsGateway.ActorRuntime.TurnStartFailure do
  @moduledoc false

  alias Ankole.I18n
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SystemConfig
  alias Ankole.TimeZone

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

  def finalize(result, %ActorEvent{}, %DateTime{}), do: result

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

  # One ActorEvent that never reaches a Worker completes with its own durable
  # notice in the same transaction, so an accepted message is never left silent
  # and never gets a second delivery attempt.
  defp complete_without_turn(actor_event, now, status, fields, commit_notice) do
    Repo.transact(fn repo ->
      case Actors.lock_actor_event_in_tx(repo, actor_event.id) do
        %ActorEvent{completed_at: %DateTime{}} = completed_event ->
          {:ok, Map.merge(fields, %{status: :already_completed, actor_event: completed_event})}

        %ActorEvent{} = locked_event ->
          notice_result = maybe_commit_notice(repo, locked_event, commit_notice)

          with {:ok, completed_event} <-
                 Actors.complete_actor_event_in_tx(repo, locked_event, completed_at: now) do
            {:ok,
             Map.merge(fields, %{
               status: status,
               actor_event: completed_event,
               notice_outbox: notice_outbox(notice_result),
               notice_error: notice_error(notice_result)
             })}
          end

        nil ->
          {:ok, %{status: :idle}}
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
end
