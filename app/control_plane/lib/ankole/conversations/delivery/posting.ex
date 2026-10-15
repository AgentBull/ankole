defmodule Ankole.Conversations.Delivery.Posting do
  @moduledoc "Commits the external effects of one statement to one validated target."
  alias Ankole.Conversations.{Delivery, PostResult, Statement, Target}
  alias Ankole.Conversations.Delivery.Interactions

  def post_in_tx(repo, target, %Statement{notice: %{} = notice} = statement) do
    with {:ok, intent} <-
           Delivery.commit_notice_in_tx(repo, statement.signal, Statement.text(statement), notice,
             delivery_target: delivery_target(target, statement.signal)
           ) do
      {:ok, %PostResult{intents: List.wrap(intent)}}
    end
  end

  def post_in_tx(_repo, _target, %Statement{outcome: :silent}), do: {:ok, %PostResult{}}

  def post_in_tx(
        repo,
        %Target{} = target,
        %Statement{signal: signal, completion: completion} = statement
      ) do
    route = delivery_target(target, signal)

    opts = [
      delivery_targets: [route],
      delivery_target: route,
      turn_completion_outcome: Atom.to_string(statement.outcome)
    ]

    with {:ok, attachments} <-
           Delivery.commit_reply_attachments_in_tx(
             repo,
             signal,
             completion.final_response.id,
             completion.attachments,
             opts
           ),
         {:ok, replies} <- reply_in_tx(repo, target, statement, opts) do
      {:ok, %PostResult{intents: attachments ++ replies}}
    end
  end

  defp reply_in_tx(
         repo,
         %{primary: true},
         %Statement{completion: %{clarify_prompt: %{} = prompt}} = statement,
         opts
       ) do
    with {:ok, intent} <-
           Delivery.commit_clarify_reply_in_tx(
             repo,
             statement.signal,
             statement.completion.final_response,
             Statement.text(statement),
             prompt["interactive_output"],
             opts
           ),
         {:ok, _} <-
           Interactions.open_in_tx(
             repo,
             statement.signal,
             intent.payload["reply_presentation"],
             statement.now
           ) do
      {:ok, [intent]}
    end
  end

  defp reply_in_tx(repo, _target, %Statement{} = statement, opts) do
    if is_binary(Statement.text(statement)) do
      Delivery.commit_final_reply_in_tx(
        repo,
        statement.signal,
        statement.completion.final_response,
        Statement.text(statement),
        Keyword.put(opts, :attachment_count, length(statement.completion.attachments))
      )
    else
      {:ok, []}
    end
  end

  defp delivery_target(target, signal) do
    fields = Map.take(target, [:binding_name, :conversation_id, :provider_thread_id, :primary])

    key =
      if Ankole.Signals.Signal.scheduled_delivery_snapshot(signal) do
        Ankole.Schedule.Delivery.target_key(%{
          "conversation_id" => target.conversation_id,
          "binding_name" => target.binding_name,
          "provider_thread_id" => target.provider_thread_id
        })
      end

    Map.put(fields, :key, key)
  end
end
