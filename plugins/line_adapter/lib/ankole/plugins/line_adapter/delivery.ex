defmodule Ankole.Plugins.LineAdapter.Delivery do
  @moduledoc false

  @behaviour Ankole.Conversations.Delivery.Adapter

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Signals.Bindings
  alias Ankole.Logging
  alias Ankole.Plugins.LineAdapter.Client
  alias Ankole.Plugins.LineAdapter.Config
  alias Ankole.Plugins.LineAdapter.ErrorPolicy
  alias Ankole.Plugins.LineAdapter.Presentation
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Conversations.External
  alias Ankole.Conversations.Delivery.Intent

  @push_path "/v2/bot/message/push"
  @divider "────────"

  # LINE keeps a retry key for 24 hours after the first request that carried
  # it. The row is created immediately before that first request, so the row
  # age bounds the key age; the margin absorbs clock skew and the spacing of
  # the gateway's retry ladder.
  @retry_key_retention_seconds 24 * 60 * 60
  @retry_key_safety_seconds 60 * 60

  @impl true
  def deliver(%Intent{} = intent) do
    result =
      with :ok <- reject_outbound_attachments(intent),
           :ok <- retry_key_usable(intent, DateTime.utc_now()),
           {:ok, config} <- Bindings.delivery_config(intent, Config),
           config = Config.runtime_config(config),
           {:ok, requests} <- requests_for_intent(intent),
           {:ok, sent} <- perform_requests(requests, Config.client(config), intent) do
        record_reply_surface(intent, sent)
        {:ok, sent}
      end

    ErrorPolicy.normalize_delivery_result(result)
  end

  # A recovered `sending` row repeats the same requests while LINE still holds
  # the retry key: LINE answers 409 with the original message ids for a request
  # it already accepted. After the retention window a repeat could deliver
  # twice, and LINE has no read-back API for a push, so the outcome is unknown.
  @impl true
  def reconcile(%Intent{} = intent) do
    if retry_key_expired?(intent, DateTime.utc_now()), do: :unknown, else: deliver(intent)
  end

  @spec retry_key_expired?(Intent.t(), DateTime.t()) :: boolean()
  defp retry_key_expired?(%Intent{inserted_at: %DateTime{} = inserted_at}, %DateTime{} = now) do
    DateTime.diff(now, inserted_at, :second) >=
      @retry_key_retention_seconds - @retry_key_safety_seconds
  end

  defp retry_key_expired?(%Intent{}, _now), do: false

  # A retry after the retention window cannot rely on the key to absorb an
  # earlier request that LINE accepted. The row records only its last error,
  # and a long reply is several requests, so a definitive last answer does not
  # prove that no earlier request landed. Every aged retry therefore reports
  # unknown once; the gateway's possible-duplicate flow warns the recipient,
  # and the retry that carries that notice sends.
  defp retry_key_usable(%Intent{} = intent, now) do
    if retry_key_expired?(intent, now) and intent.attempt_count > 1 and
         not duplicate_notice_given?(intent) do
      :unknown
    else
      :ok
    end
  end

  defp duplicate_notice_given?(%Intent{possible_duplicate: true}),
    do: true

  defp duplicate_notice_given?(%Intent{}), do: false

  @doc false
  @spec requests_for_intent(Intent.t()) :: {:ok, [map()]} | {:error, term()}
  def requests_for_intent(%Intent{operation: operation} = intent)
      when operation in [:post, :reply, :card] do
    with {:ok, conversation} <- External.fetch_conversation(intent.conversation_id),
         {:ok, target} <- Presentation.parse_channel(conversation.provider_conversation_id) do
      messages =
        Presentation.text_messages(intent.fallback_visible_text, quote_token(intent, target)) ++
          action_messages(intent)

      {:ok, requests(target, messages)}
    end
  end

  def requests_for_intent(%Intent{operation: :divider} = intent) do
    with {:ok, conversation} <- External.fetch_conversation(intent.conversation_id),
         {:ok, target} <- Presentation.parse_channel(conversation.provider_conversation_id) do
      text =
        case String.trim(to_string(intent.fallback_visible_text || "")) do
          "" -> @divider
          value -> @divider <> "\n" <> value
        end

      {:ok, requests(target, Presentation.text_messages(text))}
    end
  end

  def requests_for_intent(_intent), do: {:error, :unsupported_intent_operation}

  @doc false
  @spec retry_key(Intent.t(), non_neg_integer()) :: String.t()
  def retry_key(%Intent{} = intent, index) when is_integer(index) and index >= 0 do
    <<time_low::32, time_mid::16, _version::4, time_high::12, _variant::2, clock::14, node::48,
      _rest::binary>> =
      :crypto.hash(
        :sha256,
        Enum.join([intent.agent_uid, intent.binding_name, intent.outbound_key, index], "\n")
      )

    <<time_low::32, time_mid::16, 4::4, time_high::12, 2::2, clock::14, node::48>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp requests(target, messages) do
    messages
    |> Presentation.batches()
    |> Enum.with_index()
    |> Enum.map(fn {batch, index} ->
      %{index: index, body: %{"to" => target.chat_id, "messages" => batch}}
    end)
  end

  defp action_messages(%Intent{
         payload: %{"reply_presentation" => presentation},
         source_signal_id: signal_id
       })
       when is_map(presentation) and is_binary(signal_id),
       do: Presentation.action_messages(presentation, signal_id)

  defp action_messages(_intent), do: []

  # A reply that carries buttons is the Signal's reply surface: a managed
  # callback is accepted only for the provider entry that surface holds, and a
  # postback names no message, so the sent message id is recorded here and the
  # postback handler reads it back from this same intent row.
  defp record_reply_surface(
         %Intent{source_signal_id: signal_id} = intent,
         %{created_provider_message_id: provider_message_id}
       )
       when is_binary(signal_id) and is_binary(provider_message_id) do
    if action_messages(intent) != [] do
      case PreviewStates.record_provider_message(
             signal_id,
             provider_message_id
           ) do
        :ok ->
          :ok

        {:error, :reply_preview_source_entry_already_recorded} ->
          :ok

        {:error, reason} ->
          Logging.warning(
            "line_adapter.delivery.reply_surface_not_recorded",
            "LINE reply surface could not be recorded",
            %{signal_id: signal_id, reason: inspect(reason)}
          )

          :ok
      end
    else
      :ok
    end
  end

  defp record_reply_surface(_intent, _sent), do: :ok

  # Quoting shows which group message the Agent answers. In a one-to-one chat
  # every reply already follows the human's message, so the quote is noise.
  defp quote_token(
         %Intent{
           operation: :reply,
           reply_to_provider_message_id: provider_message_id,
           conversation_id: channel_id
         },
         %{chat_type: chat_type}
       )
       when is_binary(provider_message_id) and chat_type in ["group", "room"] do
    case External.get_message(channel_id, provider_message_id) do
      %{external_ref: %{metadata: %{"quote_token" => token}}} when is_binary(token) -> token
      _missing -> nil
    end
  end

  defp quote_token(_intent, _target), do: nil

  defp perform_requests(requests, client, intent) do
    requests
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, results} ->
      case push(client, request, intent) do
        {:ok, sent} -> {:cont, {:ok, [sent | results]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, combine_results(Enum.reverse(results), intent)}
      {:error, _reason} = error -> error
    end
  end

  defp push(client, %{index: index, body: body}, intent) do
    headers = [{"x-line-retry-key", retry_key(intent, index)}]

    case Client.post(client, @push_path, body, headers) do
      {:ok, response} ->
        {:ok, sent_messages(response, body["messages"])}

      {:error, %Client.Error{status: 409, details: details}} ->
        {:ok, sent_messages(details, body["messages"])}

      {:error, _reason} = error ->
        error
    end
  end

  defp sent_messages(%{"sentMessages" => messages}, wire_messages) when is_list(messages) do
    messages
    |> Enum.zip(wire_messages || [])
    |> Enum.map(fn {message, wire} ->
      %{
        created_provider_message_id: message["id"],
        text: wire["text"] || get_in(wire, ["template", "text"]) || wire["altText"],
        payload: %{"attachments" => [], "metadata" => %{"quote_token" => message["quoteToken"]}},
        raw_payload: message
      }
    end)
  end

  defp sent_messages(_response, _wire_messages), do: []

  # The gateway keeps one created entry id per row. A long reply is several
  # LINE messages, and a human can quote any of them, so the row's payload
  # keeps every sent id for the inbound quote check.
  defp combine_results(results, intent) do
    messages = List.flatten(results)
    ids = messages |> Enum.map(& &1[:created_provider_message_id]) |> Enum.filter(&is_binary/1)

    %{
      created_provider_message_id: List.first(ids),
      messages: messages,
      raw_payload: %{"messages" => Enum.map(messages, & &1.raw_payload)},
      payload: Map.put(intent.payload, "line_message_ids", ids)
    }
    |> MapHelpers.compact_map()
  end

  # A bot can send only image, video, and audio messages, each by a public
  # HTTPS URL, and Ankole serves no public file. The text row still goes out.
  defp reject_outbound_attachments(intent) do
    case MapHelpers.fetch_list(intent.payload, "attachments") do
      [] -> :ok
      _attachments -> {:error, :outbound_attachments_not_supported}
    end
  end

  defp format_uuid(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>),
    do: "#{a}-#{b}-#{c}-#{d}-#{e}"
end
