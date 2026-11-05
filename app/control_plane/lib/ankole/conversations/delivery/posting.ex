defmodule Ankole.Conversations.Delivery.Posting do
  @moduledoc "Commits the external effects of one statement to one validated target."
  alias Ankole.Conversations.{Delivery, PostResult, Statement}
  alias Ankole.Conversations.Target, as: StatementTarget
  alias Ankole.Conversations.Delivery.{ClarifyPrompt, Interactions}

  def post_in_tx(target, %Statement{notice: %{} = notice} = statement) do
    with {:ok, intent} <-
           Delivery.commit_notice_in_tx(statement.signal, Statement.text(statement), notice,
             delivery_target: delivery_target(target, statement.signal)
           ) do
      {:ok, %PostResult{intents: List.wrap(intent)}}
    end
  end

  def post_in_tx(_target, %Statement{outcome: :silent}), do: {:ok, %PostResult{}}

  def post_in_tx(
        %StatementTarget{} = target,
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
             signal,
             completion.final_response.id,
             completion.attachments,
             opts
           ),
         {:ok, replies} <- reply_in_tx(target, statement, opts) do
      {:ok, %PostResult{intents: attachments ++ replies}}
    end
  end

  # A form clarify always carries the Pod form link. A target whose card renders
  # forms gets the form, with the link as a secondary option; any other target
  # gets the question and the link as text. Either way the interaction stays
  # pending until a valid submission or a newer turn.
  defp reply_in_tx(
         %{primary: true} = target,
         %Statement{
           completion: %{
             clarify_prompt: %{"interactive_output" => %{"fields" => [_ | _]} = output}
           }
         } = statement,
         opts
       ) do
    # A form card carries the Pod link as its own button, so only the fallback text repeats it.
    text =
      Statement.text(statement) <>
        "\n\n" <> ClarifyPrompt.form_link_text(statement.signal.id, output)

    if renders_forms?(target) do
      output = Map.put(output, "form_url", ClarifyPrompt.form_url(statement.signal.id, output))

      clarify_reply_in_tx(
        statement,
        Statement.text(statement),
        output,
        [fallback_text: text] ++ opts
      )
    else
      with {:ok, intents} <-
             Delivery.commit_final_reply_in_tx(
               statement.signal,
               statement.completion.final_response,
               text,
               opts
             ),
           {:ok, _} <-
             Interactions.open_in_tx(
               statement.signal,
               List.first(intents).payload["reply_presentation"] || %{},
               statement.now,
               clarify: output
             ) do
        {:ok, intents}
      end
    end
  end

  defp reply_in_tx(
         %{primary: true},
         %Statement{completion: %{clarify_prompt: %{} = prompt}} = statement,
         opts
       ),
       do:
         clarify_reply_in_tx(
           statement,
           Statement.text(statement),
           prompt["interactive_output"],
           opts
         )

  defp reply_in_tx(
         %{primary: true} = target,
         %Statement{completion: %{action_card_prompt: %{} = prompt}} = statement,
         opts
       ) do
    alias Ankole.Conversations.ActionCards
    alias Ankole.Conversations.Delivery.ActionCardPrompt

    tier =
      case Ankole.Signals.Bindings.get_binding(target.binding_id) do
        {:ok, binding} -> ActionCards.channel_tier(binding)
        _ -> :tier2
      end

    with {:ok, _card} <-
           ActionCards.commit_prepared_in_tx(statement.signal, target.conversation_id, prompt) do
      if tier == :tier3 do
        text = ActionCardPrompt.tier3_non_interactive_text(prompt, target.conversation_id)

        Delivery.commit_final_reply_in_tx(
          statement.signal,
          statement.completion.final_response,
          text,
          Keyword.put(opts, :attachment_count, length(statement.completion.attachments))
        )
      else
        with {:ok, intent} <-
               Delivery.commit_clarify_reply_in_tx(
                 statement.signal,
                 statement.completion.final_response,
                 Statement.text(statement),
                 prompt["interactive_output"],
                 opts
               ),
             {:ok, _} <-
               Interactions.open_in_tx(
                 statement.signal,
                 intent.payload["reply_presentation"],
                 statement.now
               ) do
          {:ok, [intent]}
        end
      end
    end
  end

  defp reply_in_tx(_target, %Statement{} = statement, opts) do
    if is_binary(Statement.text(statement)) do
      Delivery.commit_final_reply_in_tx(
        statement.signal,
        statement.completion.final_response,
        Statement.text(statement),
        Keyword.put(opts, :attachment_count, length(statement.completion.attachments))
      )
    else
      {:ok, []}
    end
  end

  defp clarify_reply_in_tx(statement, text, output, opts) do
    with {:ok, intent} <-
           Delivery.commit_clarify_reply_in_tx(
             statement.signal,
             statement.completion.final_response,
             text,
             output,
             opts
           ),
         {:ok, _} <-
           Interactions.open_in_tx(
             statement.signal,
             intent.payload["reply_presentation"],
             statement.now,
             clarify: output
           ) do
      {:ok, [intent]}
    end
  end

  defp renders_forms?(target) do
    with {:ok, binding} <- Ankole.Signals.Bindings.get_binding(target.binding_id),
         {:ok, adapter} <- Ankole.Signals.Adapters.fetch_delivery(binding.adapter) do
      MapSet.member?(Delivery.Adapter.capabilities(adapter), :form)
    else
      _unavailable -> false
    end
  end

  defp delivery_target(target, signal) do
    fields =
      Map.take(target, [
        :binding_id,
        :binding_name,
        :conversation_id,
        :provider_thread_id,
        :primary
      ])

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
