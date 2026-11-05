defmodule Ankole.Plugins.Microsoft365Adapter.ReplyPreview do
  @moduledoc """
  Teams transport for the shared crash-recoverable message preview ledger.

  A reply streams as Bot Framework message activities that Ankole updates in
  place. While a question waits for an answer, the reply is one Adaptive Card
  with its controls; once someone answers or a newer turn supersedes it, a
  refresh replaces the card with the question and its outcome.
  """

  @behaviour Ankole.Conversations.Delivery.PreviewAdapter
  @behaviour Ankole.Plugins.ChunkedMessagePreview

  alias Ankole.I18n
  alias Ankole.Plugins.ChunkedMessagePreview
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.Microsoft365Adapter.AdaptiveCard
  alias Ankole.Plugins.Microsoft365Adapter.Config
  alias Ankole.Plugins.Microsoft365Adapter.Conversations
  alias Ankole.Plugins.Microsoft365Adapter.Delivery
  alias Ankole.Conversations.Delivery.PreviewAdapter.Request
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Signals.Signal
  alias MicrosoftOpenAPI.BotConnector
  alias MicrosoftOpenAPI.Error

  @fallback_chars 3_000
  @gone ["ActivityNotFoundInConversation", "ConversationNotFound"]

  @impl Ankole.Conversations.Delivery.PreviewAdapter
  def update(%Request{} = request), do: deliver(request)

  @impl Ankole.Conversations.Delivery.PreviewAdapter
  def finalize(%Request{} = request) do
    case ChunkedMessagePreview.reconcile(%{request | mode: :terminal}, __MODULE__, "teams") do
      {:error, :teams_partial_delivery} -> :unknown
      result -> normalize(result)
    end
  end

  @impl Ankole.Conversations.Delivery.PreviewAdapter
  def refresh(%Request{} = request), do: deliver(request)

  @impl Ankole.Conversations.Delivery.PreviewAdapter
  def surface_ids(checkpoint), do: ChunkedMessagePreview.surface_ids(checkpoint)

  @impl Ankole.Conversations.Delivery.PreviewAdapter
  def surface_open?(checkpoint), do: ChunkedMessagePreview.surface_open?(checkpoint)

  defp deliver(request) do
    request
    |> ChunkedMessagePreview.reconcile(__MODULE__, "teams")
    |> normalize()
  end

  defp normalize({:error, %Error{}} = error), do: Delivery.normalize_delivery_result(error)

  # A retry could repeat a post that the ledger never confirmed, so a partial
  # delivery waits for an operator.
  defp normalize({:error, :teams_partial_delivery}),
    do:
      {:error,
       {:reply_delivery, :operator_action_required, %{"code" => "teams_delivery_unknown"}}}

  defp normalize(result), do: result

  @impl Ankole.Plugins.ChunkedMessagePreview
  def render_chunks(presentation, %Request{signal: %Signal{} = event} = request) do
    with {:ok, config} <- Config.validate_chat_config(request.config),
         {:ok, target} <- Delivery.delivery_target(event.conversation_id) do
      context = %{
        client: Config.chat_client(config),
        service_url: target.service_url,
        conversation_id: reply_conversation_id(event, target)
      }

      # A durable reply keeps its own fallback text, such as the Pod form link,
      # for clients that cannot show the card.
      fallback = request.delivery && request.delivery.fallback_visible_text

      {:ok, activities(presentation, event.id, fallback), context, event.provider_thread_id}
    end
  end

  @impl Ankole.Plugins.ChunkedMessagePreview
  def upsert_message(context, _event, %{"message_id" => message_id}, activity, index)
      when is_binary(message_id) do
    case BotConnector.update_activity(
           context.client,
           context.service_url,
           context.conversation_id,
           message_id,
           activity
         ) do
      {:ok, response} -> {:ok, message_record(index, message_id), response, nil}
      {:error, %Error{reason: "ActivityNotFoundInConversation"}} -> post(context, activity, index)
      {:error, _reason} = error -> error
    end
  end

  def upsert_message(context, _event, _missing, activity, index),
    do: post(context, activity, index)

  @impl Ankole.Plugins.ChunkedMessagePreview
  def delete_message(context, _event, %{"message_id" => message_id}) do
    case BotConnector.delete_activity(
           context.client,
           context.service_url,
           context.conversation_id,
           message_id
         ) do
      {:ok, _response} -> :ok
      {:error, %Error{reason: reason}} when reason in @gone -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl Ankole.Plugins.ChunkedMessagePreview
  def classify_error(_reason, stage, _changed?)
      when stage in [:checkpoint, :source_entry],
      do: :teams_partial_delivery

  def classify_error(_reason, :upsert, true), do: :teams_partial_delivery
  def classify_error(reason, _stage, _changed?), do: reason

  @doc """
  Renders one reply presentation as the message activities that show it.

  A question that waits for an answer is one Adaptive Card. Any other reply is
  Markdown text, split at the Teams size limit, that ends with the outcome of
  its receipts and its question. `fallback` is the card's text for clients that
  cannot show the card; the presentation's own text stands in without it.
  """
  @spec activities(map(), String.t(), String.t() | nil) :: [map()]
  def activities(presentation, signal_id, fallback \\ nil) do
    presentation = ReplyPresentation.normalize(presentation)

    case AdaptiveCard.render_reply_presentation(presentation, signal_id) do
      {:ok, card} ->
        fallback = fallback || ReplyPresentation.fallback_text(presentation)

        [
          %{
            "type" => "message",
            "text" => String.slice(fallback, 0, @fallback_chars),
            "attachments" => [AdaptiveCard.attachment(card)]
          }
        ]

      :none ->
        [body_text(presentation) | outcome_lines(presentation)]
        |> Enum.join("\n\n")
        |> Delivery.text_activities()
    end
  end

  # Before a live reply has words, the message shows its status.
  defp body_text(%{"state" => state} = presentation) when state in ["debouncing", "working"] do
    if String.trim(presentation["answer"] || "") == "" do
      MapHelpers.optional_text(presentation["meta"] || %{}, "status") ||
        I18n.t("conversations.delivery.cardkit." <> state)
    else
      generated_text(presentation)
    end
  end

  defp body_text(presentation), do: generated_text(presentation)

  defp generated_text(presentation),
    do:
      presentation
      |> ReplyPresentation.fallback_text()
      |> Ankole.Kernel.repair_generated_markdown()

  defp outcome_lines(presentation) do
    receipts =
      for receipt <- presentation["receipts"] || [],
          summary = MapHelpers.optional_text(receipt, "summary") do
        scope = MapHelpers.optional_text(receipt, "scope")
        "✅ " <> if(scope, do: "#{summary} (#{scope})", else: summary)
      end

    receipts ++ interaction_outcome(presentation)
  end

  defp interaction_outcome(%{"interaction_status" => "answered"} = presentation) do
    answer =
      MapHelpers.optional_text(presentation, "interaction_answer") ||
        I18n.t("conversations.delivery.cardkit.answer_received")

    ["✅ " <> answer]
  end

  defp interaction_outcome(%{"interaction_status" => "superseded"}),
    do: [I18n.t("conversations.delivery.cardkit.interaction_superseded")]

  defp interaction_outcome(_presentation), do: []

  # In a channel the reply lives in the thread of the message it answers, so
  # its posts, updates, and deletes all address that thread conversation.
  defp reply_conversation_id(%Signal{} = event, %{channel?: true} = target) do
    root =
      Conversations.thread_root_from_provider_thread_id(
        event.provider_thread_id,
        target.conversation_id
      ) || Ankole.Signals.reply_anchor_provider_message_id(event)

    if is_binary(root),
      do: Conversations.thread_conversation_id(target.conversation_id, root),
      else: target.conversation_id
  end

  defp reply_conversation_id(_event, target), do: target.conversation_id

  defp post(context, activity, index) do
    case BotConnector.post_activity(
           context.client,
           context.service_url,
           context.conversation_id,
           activity
         ) do
      {:ok, %{"id" => message_id} = response} when is_binary(message_id) and message_id != "" ->
        {:ok, message_record(index, message_id), response, nil}

      {:ok, response} ->
        {:error, {:teams_activity_id_missing, response}}

      {:error, _reason} = error ->
        error
    end
  end

  defp message_record(index, message_id), do: %{"index" => index, "message_id" => message_id}
end
