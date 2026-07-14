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
    Repo.transact(fn repo ->
      case Actors.lock_actor_event_in_tx(repo, actor_event.id) do
        %ActorEvent{completed_at: %DateTime{}} = completed_event ->
          {:ok,
           %{
             status: :already_completed,
             actor_event: completed_event,
             profile: profile,
             profile_error: reason
           }}

        %ActorEvent{} = locked_event ->
          notice_result = maybe_commit_notice(repo, locked_event, profile)

          with {:ok, completed_event} <-
                 Actors.complete_actor_event_in_tx(repo, locked_event, completed_at: now) do
            {:ok,
             %{
               status: :model_profile_unavailable,
               actor_event: completed_event,
               profile: profile,
               profile_error: reason,
               notice_outbox: notice_outbox(notice_result),
               notice_error: notice_error(notice_result)
             }}
          end

        nil ->
          {:ok, %{status: :idle}}
      end
    end)
    |> log_notice_failure()
  end

  def finalize(result, %ActorEvent{}, %DateTime{}), do: result

  # An ambient group message has not asked the agent to speak. A missing light
  # profile must not turn every observed message into a configuration warning.
  defp maybe_commit_notice(_repo, %ActorEvent{type: "im.message.may_intervene"}, _profile),
    do: {:ok, nil}

  defp maybe_commit_notice(repo, %ActorEvent{} = actor_event, profile) do
    if AIReplyPreview.im_visible_event?(actor_event) do
      text =
        I18n.t("signals_gateway.reply.model_profile_unavailable", %{
          "profile" => profile,
          "ref" => actor_event.id
        })

      Outbox.commit_model_profile_unavailable_notice_outbox_in_tx(
        repo,
        actor_event,
        profile,
        text
      )
    else
      {:ok, nil}
    end
  end

  defp notice_outbox({:ok, %OutboxEntry{} = outbox}), do: outbox
  defp notice_outbox(_result), do: nil

  defp notice_error({:error, reason}), do: reason
  defp notice_error(_result), do: nil

  defp log_notice_failure({:ok, %{notice_error: nil}} = result), do: result

  defp log_notice_failure(
         {:ok, %{actor_event: %ActorEvent{} = event, notice_error: reason}} = result
       ) do
    Logging.warning(
      "signals_gateway.actor_runtime.model_profile_notice_failed",
      "model profile configuration notice not committed",
      %{actor_event_id: event.id, reason: inspect(reason)}
    )

    result
  end

  defp log_notice_failure(result), do: result
end
