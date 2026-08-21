defmodule Ankole.Plugins.Microsoft365Adapter.Outbox do
  @moduledoc false

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.Microsoft365Adapter.{AdaptiveCard, Config, Conversations}
  alias Ankole.Plugins.Microsoft365Adapter.Markdown
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.OutboxEntry
  alias MicrosoftOpenAPI.BotConnector
  alias MicrosoftOpenAPI.Error

  # Teams caps messages around 28 KB of payload; splitting at 12k characters
  # mirrors the Slack adapter's conservative chunking.
  @max_text_chars 12_000

  # `outbound_reconciliation` is deliberately not declared: the Bot Connector
  # has no read-back API, so the gateway owns bounded durable-reply recovery.
  @impl true
  def send(%OutboxEntry{} = outbox) do
    with :ok <- reject_outbound_attachments(outbox),
         {:ok, config} <- config_for_outbox(outbox),
         {:ok, target} <- delivery_target(outbox) do
      send_requests(outbox, config, target)
    end
  end

  defp reject_outbound_attachments(outbox) do
    case MapHelpers.fetch_list(outbox.payload, "attachments") do
      [] -> :ok
      _attachments -> {:error, :outbound_attachments_not_supported}
    end
  end

  @doc false
  @spec requests_for_outbox(OutboxEntry.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def requests_for_outbox(%OutboxEntry{operation: operation} = outbox, target)
      when operation in [:post, :reply] do
    conversation_id = request_conversation_id(outbox, target)

    requests =
      outbox.fallback_visible_text
      |> to_string()
      |> split_text()
      |> Enum.map(fn text ->
        %{
          kind: :post,
          conversation_id: conversation_id,
          activity: message_activity(text)
        }
      end)

    {:ok, requests}
  end

  def requests_for_outbox(%OutboxEntry{operation: :edit} = outbox, target) do
    conversation_id = target_conversation_id(outbox, target)

    requests =
      outbox.fallback_visible_text
      |> to_string()
      |> split_text()
      |> Enum.with_index(1)
      |> Enum.map(fn
        {text, 1} ->
          %{
            kind: :update,
            conversation_id: conversation_id,
            activity_id: outbox.target_source_entry_id,
            activity: message_activity(text)
          }

        {text, _index} ->
          %{kind: :post, conversation_id: conversation_id, activity: message_activity(text)}
      end)

    {:ok, requests}
  end

  def requests_for_outbox(%OutboxEntry{operation: :delete} = outbox, target) do
    {:ok,
     [
       %{
         kind: :delete,
         conversation_id: target_conversation_id(outbox, target),
         activity_id: outbox.target_source_entry_id,
         idempotent_errors: ["ActivityNotFoundInConversation", "ConversationNotFound"]
       }
     ]}
  end

  def requests_for_outbox(%OutboxEntry{operation: :divider} = outbox, target) do
    text =
      outbox.fallback_visible_text
      |> to_string()
      |> String.trim()
      |> truncate(150)

    {:ok,
     [
       %{
         kind: :post,
         conversation_id: request_conversation_id(outbox, target),
         activity: message_activity("———\n_" <> text <> "_")
       }
     ]}
  end

  def requests_for_outbox(%OutboxEntry{operation: :card} = outbox, target) do
    with {:ok, card} <- AdaptiveCard.render(outbox.payload) do
      fallback =
        outbox.fallback_visible_text
        |> to_string()
        |> truncate(3_000)

      activity = %{
        "type" => "message",
        "text" => fallback,
        "attachments" => [AdaptiveCard.attachment(card)]
      }

      {:ok,
       [
         %{
           kind: :post,
           conversation_id: request_conversation_id(outbox, target),
           activity: activity
         }
       ]}
    end
  end

  def requests_for_outbox(_outbox, _target), do: {:error, :unsupported_outbox_operation}

  defp send_requests(outbox, config, target) do
    client = Config.chat_client(config)

    with {:ok, requests} <- requests_for_outbox(outbox, target) do
      requests
      |> Enum.reduce_while([], fn request, results ->
        case perform(request, client, target.service_url) do
          {:ok, result} -> {:cont, [result | results]}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:error, _reason} = error ->
          error

        results ->
          {:ok, combine_results(Enum.reverse(results)) |> Map.put(:payload, outbox.payload)}
      end
    end
  end

  defp perform(%{kind: :post} = request, client, service_url) do
    client
    |> BotConnector.post_activity(service_url, request.conversation_id, request.activity)
    |> normalize_result(request)
  end

  defp perform(%{kind: :update} = request, client, service_url) do
    client
    |> BotConnector.update_activity(
      service_url,
      request.conversation_id,
      request.activity_id,
      request.activity
    )
    |> normalize_result(request)
  end

  defp perform(%{kind: :delete} = request, client, service_url) do
    client
    |> BotConnector.delete_activity(service_url, request.conversation_id, request.activity_id)
    |> normalize_result(request)
  end

  defp normalize_result({:ok, body}, request) do
    {:ok,
     %{
       created_source_entry_id: if(request.kind == :post, do: Map.get(body, "id")),
       raw_payload: body
     }
     |> MapHelpers.compact_map()}
  end

  defp normalize_result({:error, %Error{reason: reason} = error}, request) do
    if reason in Map.get(request, :idempotent_errors, []) do
      {:ok, %{raw_payload: %{"already_absent_or_applied" => true}}}
    else
      normalize_delivery_result({:error, error})
    end
  end

  # The library carries no reason taxonomy beyond rate limit and transport;
  # Graph and Bot Connector auth failures arrive as raw code strings with a
  # 401/403 status, so the status decides the operator class.
  @doc false
  @spec normalize_delivery_result({:error, Error.t()}) :: {:error, term()}
  def normalize_delivery_result({:error, %Error{} = error}) do
    action =
      cond do
        Error.retryable?(error) -> :retryable
        error.status in [401, 403] -> :operator_action_required
        true -> :permanent
      end

    {:error,
     {:reply_delivery, action,
      MapHelpers.compact_map(%{
        reason: error.reason,
        http_status: error.status,
        retry_after_seconds: error.retry_after
      })}}
  end

  defp message_activity(text) do
    %{
      "type" => "message",
      "textFormat" => "markdown",
      "text" => Markdown.from_markdown(text)
    }
  end

  # Posts and replies target the channel conversation: posting to the base id
  # starts a new thread in a channel (and is a plain message in chats), while
  # replying in a channel posts into `{base};messageid={root}`.
  defp request_conversation_id(%OutboxEntry{operation: :reply} = outbox, target) do
    if target.channel? and is_binary(outbox.reply_to_source_entry_id) do
      Conversations.thread_conversation_id(
        target.conversation_id,
        outbox.reply_to_source_entry_id
      )
    else
      target.conversation_id
    end
  end

  defp request_conversation_id(_outbox, target), do: target.conversation_id

  # Edits and deletes address an existing activity, which for channel thread
  # replies lives in the thread conversation. The outbox row's provider thread
  # id carries the root; a missing thread id falls back to treating the target
  # as a thread root, which also covers chats.
  defp target_conversation_id(%OutboxEntry{} = outbox, target) do
    if target.channel? do
      root =
        Conversations.thread_root_from_provider_thread_id(
          outbox.provider_thread_id,
          target.conversation_id
        ) || outbox.target_source_entry_id

      case root do
        nil -> target.conversation_id
        root -> Conversations.thread_conversation_id(target.conversation_id, root)
      end
    else
      target.conversation_id
    end
  end

  defp combine_results([result]), do: result

  defp combine_results(results) do
    first = List.first(results) || %{}

    %{
      created_source_entry_id: first[:created_source_entry_id],
      raw_payload: %{"split" => true, "chunks" => Enum.map(results, & &1.raw_payload)}
    }
    |> MapHelpers.compact_map()
  end

  defp split_text(text) do
    case text
         |> String.graphemes()
         |> Enum.chunk_every(@max_text_chars)
         |> Enum.map(&Enum.join/1) do
      [] -> [""]
      chunks -> chunks
    end
  end

  defp truncate(text, size), do: String.slice(text, 0, size)

  defp config_for_outbox(outbox) do
    with {:ok, config_ref} <- SignalsGateway.outbox_binding_config_ref(outbox),
         {:ok, config} <- Config.load_chat_config_ref(config_ref) do
      {:ok, config}
    else
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
    end
  end

  # serviceUrl is only ever learned from inbound traffic (D11); an outbox row
  # whose channel mirror never saw the provider fails loudly instead of
  # guessing a regional connector host.
  @doc false
  @spec delivery_target(OutboxEntry.t()) :: {:ok, map()} | {:error, term()}
  def delivery_target(%OutboxEntry{signal_channel_id: signal_channel_id}) do
    with conversation_id when is_binary(conversation_id) <-
           Conversations.conversation_id_from_signal(signal_channel_id) || :invalid,
         %Channel{} = channel <- Repo.get(Channel, signal_channel_id) || :missing_channel,
         metadata <- channel.metadata || %{},
         service_url when is_binary(service_url) <-
           MapHelpers.optional_text(metadata, "service_url") || :missing_service_url do
      {:ok,
       %{
         conversation_id: conversation_id,
         service_url: service_url,
         channel?: MapHelpers.optional_text(metadata, "conversation_type") == "channel"
       }}
    else
      :invalid -> {:error, :invalid_signal_channel_id}
      :missing_channel -> {:error, :missing_channel_mirror}
      :missing_service_url -> {:error, :missing_service_url}
    end
  end
end
