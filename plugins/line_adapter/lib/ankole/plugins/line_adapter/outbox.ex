defmodule Ankole.Plugins.LineAdapter.Outbox do
  @moduledoc false

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  alias Ankole.{Logging, Repo, SignalsGateway}
  alias Ankole.Plugins.LineAdapter.{Client, Config, ErrorPolicy, Presentation}
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway.{Actors, Entry, OutboxEntry}

  @push_path "/v2/bot/message/push"
  @divider "────────"

  # LINE keeps a retry key for 24 hours after the first request that carried
  # it. The row is created immediately before that first request, so the row
  # age bounds the key age; the margin absorbs clock skew and the spacing of
  # the gateway's retry ladder.
  @retry_key_retention_seconds 24 * 60 * 60
  @retry_key_safety_seconds 60 * 60

  @impl true
  def send(%OutboxEntry{} = outbox) do
    result =
      with :ok <- reject_outbound_attachments(outbox),
           :ok <- retry_key_usable(outbox, DateTime.utc_now()),
           {:ok, config} <- config_for_outbox(outbox),
           {:ok, requests} <- requests_for_outbox(outbox),
           {:ok, sent} <- perform_requests(requests, Config.client(config), outbox) do
        record_reply_surface(outbox, sent)
        {:ok, sent}
      end

    ErrorPolicy.normalize_delivery_result(result)
  end

  # A recovered `sending` row repeats the same requests while LINE still holds
  # the retry key: LINE answers 409 with the original message ids for a request
  # it already accepted. After the retention window a repeat could deliver
  # twice, and LINE has no read-back API for a push, so the outcome is unknown.
  @impl true
  def reconcile(%OutboxEntry{} = outbox) do
    if retry_key_expired?(outbox, DateTime.utc_now()), do: :unknown, else: send(outbox)
  end

  @doc false
  @spec retry_key_expired?(OutboxEntry.t(), DateTime.t()) :: boolean()
  def retry_key_expired?(%OutboxEntry{inserted_at: %DateTime{} = inserted_at}, %DateTime{} = now) do
    DateTime.diff(now, inserted_at, :second) >=
      @retry_key_retention_seconds - @retry_key_safety_seconds
  end

  def retry_key_expired?(%OutboxEntry{}, _now), do: false

  # A retry after the retention window cannot rely on the key to absorb an
  # earlier request that LINE accepted. The row records only its last error,
  # and a long reply is several requests, so a definitive last answer does not
  # prove that no earlier request landed. Every aged retry therefore reports
  # unknown once; the gateway's possible-duplicate flow warns the recipient,
  # and the retry that carries that notice sends.
  defp retry_key_usable(%OutboxEntry{} = outbox, now) do
    if retry_key_expired?(outbox, now) and outbox.attempt_count > 1 and
         not duplicate_notice_given?(outbox) do
      :unknown
    else
      :ok
    end
  end

  defp duplicate_notice_given?(%OutboxEntry{recovery_state: %{"possible_duplicate" => true}}),
    do: true

  defp duplicate_notice_given?(%OutboxEntry{}), do: false

  @doc false
  @spec requests_for_outbox(OutboxEntry.t()) :: {:ok, [map()]} | {:error, term()}
  def requests_for_outbox(%OutboxEntry{operation: operation} = outbox)
      when operation in [:post, :reply, :card] do
    with {:ok, target} <- Presentation.parse_channel(outbox.signal_channel_id) do
      messages =
        Presentation.text_messages(outbox.fallback_visible_text, quote_token(outbox, target)) ++
          action_messages(outbox)

      {:ok, requests(target, messages)}
    end
  end

  def requests_for_outbox(%OutboxEntry{operation: :divider} = outbox) do
    with {:ok, target} <- Presentation.parse_channel(outbox.signal_channel_id) do
      text =
        case String.trim(to_string(outbox.fallback_visible_text || "")) do
          "" -> @divider
          value -> @divider <> "\n" <> value
        end

      {:ok, requests(target, Presentation.text_messages(text))}
    end
  end

  def requests_for_outbox(_outbox), do: {:error, :unsupported_outbox_operation}

  @doc false
  @spec retry_key(OutboxEntry.t(), non_neg_integer()) :: String.t()
  def retry_key(%OutboxEntry{} = outbox, index) when is_integer(index) and index >= 0 do
    <<time_low::32, time_mid::16, _version::4, time_high::12, _variant::2, clock::14, node::48,
      _rest::binary>> =
      :crypto.hash(
        :sha256,
        Enum.join([outbox.agent_uid, outbox.binding_name, outbox.outbound_key, index], "\n")
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

  defp action_messages(%OutboxEntry{
         payload: %{"reply_presentation" => presentation},
         source_actor_event_id: actor_event_id
       })
       when is_map(presentation) and is_binary(actor_event_id),
       do: Presentation.action_messages(presentation, actor_event_id)

  defp action_messages(_outbox), do: []

  # A reply that carries buttons is the ActorEvent's reply surface: a managed
  # callback is accepted only for the provider entry that surface holds, and a
  # postback names no message, so the sent message id is recorded here and the
  # postback handler reads it back from this same outbox row.
  defp record_reply_surface(
         %OutboxEntry{source_actor_event_id: actor_event_id} = outbox,
         %{created_source_entry_id: source_entry_id}
       )
       when is_binary(actor_event_id) and is_binary(source_entry_id) do
    if action_messages(outbox) != [] do
      case Actors.record_reply_preview_source_entry(actor_event_id, source_entry_id) do
        :ok ->
          :ok

        {:error, :reply_preview_source_entry_already_recorded} ->
          :ok

        {:error, reason} ->
          Logging.warning(
            "line_adapter.outbox.reply_surface_not_recorded",
            "LINE reply surface could not be recorded",
            %{actor_event_id: actor_event_id, reason: inspect(reason)}
          )

          :ok
      end
    else
      :ok
    end
  end

  defp record_reply_surface(_outbox, _sent), do: :ok

  # Quoting shows which group message the Agent answers. In a one-to-one chat
  # every reply already follows the human's message, so the quote is noise.
  defp quote_token(
         %OutboxEntry{
           operation: :reply,
           reply_to_source_entry_id: source_entry_id,
           signal_channel_id: channel_id
         },
         %{chat_type: chat_type}
       )
       when is_binary(source_entry_id) and chat_type in ["group", "room"] do
    case Repo.get_by(Entry, signal_channel_id: channel_id, source_entry_id: source_entry_id) do
      %Entry{metadata: %{"quote_token" => token}} when is_binary(token) -> token
      _missing -> nil
    end
  end

  defp quote_token(_outbox, _target), do: nil

  defp perform_requests(requests, client, outbox) do
    requests
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, results} ->
      case push(client, request, outbox) do
        {:ok, sent} -> {:cont, {:ok, [sent | results]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, combine_results(Enum.reverse(results), outbox)}
      {:error, _reason} = error -> error
    end
  end

  defp push(client, %{index: index, body: body}, outbox) do
    headers = [{"x-line-retry-key", retry_key(outbox, index)}]

    case Client.post(client, @push_path, body, headers) do
      {:ok, response} -> {:ok, sent_messages(response)}
      {:error, %Client.Error{status: 409, details: details}} -> {:ok, sent_messages(details)}
      {:error, _reason} = error -> error
    end
  end

  defp sent_messages(%{"sentMessages" => messages}) when is_list(messages) do
    messages
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn message ->
      MapHelpers.compact_map(%{"id" => message["id"], "quote_token" => message["quoteToken"]})
    end)
  end

  defp sent_messages(_response), do: []

  # The gateway keeps one created entry id per row. A long reply is several
  # LINE messages, and a human can quote any of them, so the row's payload
  # keeps every sent id for the inbound quote check.
  defp combine_results(results, outbox) do
    messages = List.flatten(results)
    ids = messages |> Enum.map(& &1["id"]) |> Enum.filter(&is_binary/1)

    %{
      created_source_entry_id: List.first(ids),
      raw_payload: %{"messages" => messages},
      payload: Map.put(outbox.payload, "line_message_ids", ids)
    }
    |> MapHelpers.compact_map()
  end

  # A bot can send only image, video, and audio messages, each by a public
  # HTTPS URL, and Ankole serves no public file. The text row still goes out.
  defp reject_outbound_attachments(outbox) do
    case MapHelpers.fetch_list(outbox.payload, "attachments") do
      [] -> :ok
      _attachments -> {:error, :outbound_attachments_not_supported}
    end
  end

  defp config_for_outbox(outbox) do
    with {:ok, config_ref} <- SignalsGateway.outbox_binding_config_ref(outbox),
         {:ok, config} <- Config.load_config_ref(config_ref) do
      {:ok, config}
    else
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp format_uuid(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>),
    do: "#{a}-#{b}-#{c}-#{d}-#{e}"
end
