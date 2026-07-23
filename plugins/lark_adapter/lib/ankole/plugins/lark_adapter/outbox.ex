defmodule Ankole.Plugins.LarkAdapter.Outbox do
  @moduledoc """
  SignalsGateway outbox adapter for Lark / Feishu provider-visible output.
  """

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  alias Ankole.Plugins.LarkAdapter.Card
  alias Ankole.Plugins.LarkAdapter.CardKit
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Emoji
  alias Ankole.Plugins.MapHelpers
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias Ankole.Repo
  alias Ankole.WorkerFiles
  alias FeishuOpenAPI.Error

  import MapHelpers,
    only: [
      compact_map: 1,
      fetch_list: 2,
      fetch_value: 2,
      maybe_put: 3,
      optional_text: 2
    ]

  @max_text_message_chars 4_000
  @final_edit_fallback_codes [230_072, 230_075]
  @unavailable_worker_file_codes ~w(file_not_found not_regular_file)
  # Feishu caps the message `uuid` at 50 characters. Keep Ankole's full key in
  # the outbox and derive only the provider-facing value when it is too long.
  @max_message_uuid_chars 50
  @message_uuid_prefix "ankole-"

  @doc false
  @spec provider_message_uuid(String.t() | nil) :: String.t() | nil
  def provider_message_uuid(nil), do: nil

  def provider_message_uuid(idempotency_key) when is_binary(idempotency_key) do
    if String.length(idempotency_key) <= @max_message_uuid_chars do
      idempotency_key
    else
      digest = :crypto.hash(:sha256, idempotency_key) |> Base.encode16(case: :lower)
      digest_chars = @max_message_uuid_chars - String.length(@message_uuid_prefix)
      @message_uuid_prefix <> String.slice(digest, 0, digest_chars)
    end
  end

  @impl true
  def send(
        %OutboxEntry{
          payload: %{"reply_presentation" => presentation},
          source_actor_event_id: actor_event_id
        } = outbox
      )
      when is_map(presentation) and is_binary(actor_event_id) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{} = event ->
        checkpoint = event.reply_preview_checkpoint || %{}

        CardKit.finalize(%Request{
          actor_event: event,
          presentation: presentation,
          previous_presentation: checkpoint["presentation"],
          checkpoint: checkpoint,
          subject_uid: checkpoint["subject_uid"],
          conversation_id: checkpoint["conversation_id"],
          outbox: outbox,
          mode: :terminal
        })

      nil ->
        {:error, :actor_event_not_found}
    end
  end

  def send(%OutboxEntry{} = outbox) do
    result =
      with {:ok, config} <- config_for_outbox(outbox),
           client <- Config.client(config),
           {:ok, outbox} <- materialize_outbound_attachments(outbox, client),
           {:ok, requests} <- requests_for_outbox(outbox) do
        requests
        |> perform_requests(client, outbox)
        |> with_materialized_payload(outbox.payload)
      end

    normalize_delivery_error(result)
  end

  @impl true
  def reconcile(%OutboxEntry{payload: %{"reply_presentation" => presentation}} = outbox)
      when is_map(presentation),
      do: send(outbox)

  def reconcile(%OutboxEntry{created_source_entry_id: nil}), do: :unknown

  def reconcile(%OutboxEntry{} = outbox) do
    with {:ok, config} <- config_for_outbox(outbox),
         client <- Config.client(config) do
      case FeishuOpenAPI.get(client, "im/v1/messages/:message_id",
             path_params: %{message_id: outbox.created_source_entry_id}
           ) do
        {:ok, body} ->
          {:ok,
           %{
             created_source_entry_id: outbox.created_source_entry_id,
             raw_payload: body,
             recovery_state: %{"exists" => true}
           }}

        {:error, %Error{} = error} ->
          case error_not_found?(error) do
            true -> :unknown
            false -> {:error, error}
          end
      end
    end
  end

  defp requests_for_outbox(%OutboxEntry{operation: :post} = outbox) do
    with {:ok, body} <- message_body(outbox) do
      {:ok, message_requests(:post, "im/v1/messages", outbox, body)}
    end
  end

  defp requests_for_outbox(%OutboxEntry{operation: :reply} = outbox) do
    with {:ok, body} <- message_body(outbox) do
      {:ok,
       message_requests(:post, "im/v1/messages", outbox, body,
         reply_to: outbox.reply_to_source_entry_id
       )}
    end
  end

  defp requests_for_outbox(%OutboxEntry{operation: :edit} = outbox) do
    {:ok, edit_message_requests(outbox)}
  end

  defp requests_for_outbox(%OutboxEntry{operation: :delete} = outbox) do
    {:ok,
     [
       %{
         method: :delete,
         path: "im/v1/messages/:message_id",
         path_params: %{message_id: outbox.target_source_entry_id}
       }
     ]}
  end

  defp requests_for_outbox(%OutboxEntry{operation: operation} = outbox)
       when operation in [:reaction_add, :reaction_remove] do
    reaction_key =
      outbox.payload
      |> fetch_value("reaction_key")
      |> Emoji.provider_key()

    request =
      case operation do
        :reaction_add ->
          %{
            method: :post,
            path: "im/v1/messages/:message_id/reactions",
            path_params: %{message_id: outbox.target_source_entry_id},
            body: %{reaction_type: %{emoji_type: reaction_key}}
          }

        :reaction_remove ->
          %{
            method: :delete,
            path: "im/v1/messages/:message_id/reactions/:reaction_id",
            path_params: %{
              message_id: outbox.target_source_entry_id,
              reaction_id: reaction_key
            }
          }
      end

    {:ok, [request]}
  end

  defp requests_for_outbox(%OutboxEntry{operation: :divider} = outbox) do
    text =
      outbox.fallback_visible_text
      |> to_string()
      |> String.trim()
      |> String.slice(0, 20)

    body = %{
      msg_type: "system",
      content: Card.system_divider_content(text, divider_i18n(outbox.payload))
    }

    {:ok, [message_request(:post, "im/v1/messages", outbox, body)]}
  end

  defp requests_for_outbox(%OutboxEntry{operation: :card} = outbox) do
    with {:ok, card} <- Card.render(outbox.payload) do
      {:ok,
       card
       |> Card.split_by_table()
       |> Enum.with_index(1)
       |> Enum.map(fn {card, index} -> card_message_request(outbox, card, index) end)}
    end
  end

  defp requests_for_outbox(_outbox), do: {:error, :unsupported_outbox_operation}

  defp perform_requests([request], client, outbox) do
    request
    |> perform(client)
    |> maybe_reply_fallback(client, outbox, request)
    |> maybe_final_edit_fallback(client, outbox, request)
  end

  defp perform_requests(requests, client, outbox) when is_list(requests) do
    requests
    |> Enum.reduce_while([], fn request, results ->
      case request
           |> perform(client)
           |> maybe_reply_fallback(client, outbox, request)
           |> maybe_final_edit_fallback(client, outbox, request) do
        {:ok, result} -> {:cont, [result | results]}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _reason} = error ->
        error

      results ->
        {:ok, combined_send_results(Enum.reverse(results))}
    end
  end

  defp perform(%{method: method, path: path} = request, client) do
    opts =
      request
      |> Map.take([:body, :query, :path_params])
      |> Enum.to_list()

    client
    |> FeishuOpenAPI.request(method, path, opts)
    |> normalize_send_response()
  end

  defp maybe_reply_fallback({:error, %Error{} = error}, client, outbox, %{reply_to: reply_to})
       when is_binary(reply_to) do
    case target_gone_error?(error) do
      true ->
        # Lark rejects replies after the target disappears. Posting as a new
        # message preserves operator-visible output instead of losing the outbox.
        :post
        |> message_request("im/v1/messages", outbox, text_body(outbox))
        |> perform(client)

      false ->
        {:error, error}
    end
  end

  defp maybe_reply_fallback(result, _client, _outbox, _request), do: result

  defp maybe_final_edit_fallback(
         {:error, %Error{code: code}},
         client,
         %OutboxEntry{operation: :edit, ai_message_id: ai_message_id} = outbox,
         %{method: :put, body: body}
       )
       when code in @final_edit_fallback_codes and is_binary(ai_message_id) do
    # Text previews can consume Feishu's per-message edit budget before the
    # durable terminal reply arrives. Only that durable AI reply may degrade to
    # a new message; transient preview edits must remain best-effort edits or
    # they would create a new message for every subsequent delta.
    :post
    |> message_request("im/v1/messages", outbox, body)
    |> perform(client)
    |> with_delivered_operation(:post)
  end

  defp maybe_final_edit_fallback(result, _client, _outbox, _request), do: result

  defp with_delivered_operation({:ok, result}, operation) when is_map(result),
    do: {:ok, Map.put(result, :delivered_operation, operation)}

  defp with_delivered_operation(result, _operation), do: result

  @doc false
  @spec target_gone_error?(Error.t()) :: boolean()
  def target_gone_error?(%Error{code: code}), do: code in [23_000, 23_002, 23_006]

  defp normalize_send_response({:ok, %{"data" => data} = body}) when is_map(data) do
    {:ok,
     %{
       created_source_entry_id: data["message_id"],
       provider_thread_id: data["root_id"],
       raw_payload: body
     }
     |> compact_map()}
  end

  defp normalize_send_response({:ok, body}), do: {:ok, %{raw_payload: body}}
  defp normalize_send_response({:error, reason}), do: {:error, reason}

  defp combined_send_results([result]), do: result

  defp combined_send_results(results) do
    first = List.first(results) || %{}

    %{
      created_source_entry_id: first[:created_source_entry_id],
      provider_thread_id: first[:provider_thread_id],
      delivered_operation: first[:delivered_operation],
      raw_payload: %{
        "split" => true,
        "chunks" => Enum.map(results, &raw_payload/1)
      }
    }
    |> compact_map()
  end

  defp raw_payload(result) when is_map(result),
    do: Map.get(result, :raw_payload) || Map.get(result, "raw_payload") || result

  defp with_materialized_payload({:ok, result}, payload) when is_map(result) and is_map(payload),
    do: {:ok, Map.put(result, :payload, payload)}

  defp with_materialized_payload(result, _payload), do: result

  defp normalize_delivery_error({:error, %Error{} = error}) do
    {:error,
     {:provider_error,
      %{
        code: error.code,
        msg: error.msg,
        http_status: error.http_status,
        log_id: error.log_id
      }
      |> compact_map()}}
  end

  defp normalize_delivery_error({:error, :outbound_attachment_path_missing}),
    do: operator_attachment_error("attachment_path_missing")

  defp normalize_delivery_error({:error, :multiple_outbound_attachments_not_supported}),
    do: operator_attachment_error("multiple_attachments_not_supported")

  defp normalize_delivery_error({:error, :outbound_attachment_not_uploaded}),
    do: operator_attachment_error("attachment_not_uploaded")

  defp normalize_delivery_error({:error, {:file_too_large, size, max_bytes}})
       when is_integer(size) and is_integer(max_bytes) do
    operator_attachment_error("attachment_file_too_large", %{
      "size_bytes" => size,
      "max_bytes" => max_bytes
    })
  end

  defp normalize_delivery_error({:error, %{"code" => code}})
       when code in @unavailable_worker_file_codes,
       do: operator_attachment_error("attachment_file_missing", %{"worker_file_code" => code})

  defp normalize_delivery_error(result), do: result

  defp operator_attachment_error(code, detail \\ %{}) do
    {:error, {:reply_delivery, :operator_action_required, Map.put(detail, "code", code)}}
  end

  defp message_request(method, path, outbox, body, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to)
    path = if is_binary(reply_to), do: "im/v1/messages/:message_id/reply", else: path
    path_params = Keyword.get(opts, :path_params, %{})

    path_params =
      if is_binary(reply_to), do: Map.put(path_params, :message_id, reply_to), else: path_params

    idempotency_key = Keyword.get(opts, :idempotency_key, outbox.idempotency_key)
    base_body = maybe_put(body, :uuid, provider_message_uuid(idempotency_key))

    # Replies and new messages use different Lark API shapes. Keeping the branch
    # here makes every outbox operation share one idempotency/body path.
    case reply_to do
      value when is_binary(value) ->
        %{
          method: method,
          path: path,
          path_params: path_params,
          body: base_body,
          reply_to: reply_to
        }

      _value ->
        %{
          method: method,
          path: path,
          path_params: path_params,
          query: [receive_id_type: "chat_id"],
          body: maybe_put(base_body, :receive_id, chat_id_from_channel(outbox.signal_channel_id)),
          reply_to: reply_to
        }
    end
  end

  defp message_requests(method, path, %OutboxEntry{} = outbox, %{msg_type: "text"} = body, opts) do
    text =
      outbox.fallback_visible_text
      |> to_string()
      |> split_text()

    text
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, index} ->
      chunk_outbox = %OutboxEntry{
        outbox
        | fallback_visible_text: chunk,
          idempotency_key: chunk_idempotency_key(outbox.idempotency_key, index)
      }

      chunk_opts =
        if index == 1 do
          opts
        else
          Keyword.delete(opts, :reply_to)
        end

      message_request(
        method,
        path,
        chunk_outbox,
        %{body | content: Card.text_content(chunk)},
        chunk_opts
      )
    end)
  end

  defp message_requests(method, path, outbox, body, opts) do
    [message_request(method, path, outbox, body, opts)]
  end

  defp message_requests(method, path, outbox, body),
    do: message_requests(method, path, outbox, body, [])

  defp edit_message_requests(%OutboxEntry{} = outbox) do
    chunks =
      outbox.fallback_visible_text
      |> to_string()
      |> split_text()

    chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, index} ->
      chunk_outbox = %OutboxEntry{
        outbox
        | fallback_visible_text: chunk,
          idempotency_key: chunk_idempotency_key(outbox.idempotency_key, index)
      }

      case index do
        1 ->
          %{
            method: :put,
            path: "im/v1/messages/:message_id",
            path_params: %{message_id: outbox.target_source_entry_id},
            body: text_body(chunk_outbox)
          }

        _index ->
          message_request(
            :post,
            "im/v1/messages",
            chunk_outbox,
            text_body(chunk_outbox)
          )
      end
    end)
  end

  @doc false
  @spec split_text(String.t()) :: [String.t()]
  def split_text(text) when is_binary(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(@max_text_message_chars)
    |> Enum.map(&Enum.join/1)
    |> case do
      [] -> [""]
      chunks -> chunks
    end
  end

  @doc false
  @spec chunk_idempotency_key(String.t() | nil, pos_integer()) :: String.t() | nil
  def chunk_idempotency_key(nil, _index), do: nil
  def chunk_idempotency_key(key, 1), do: key
  def chunk_idempotency_key(key, index), do: "#{key}:part:#{index}"

  defp card_message_request(%OutboxEntry{} = outbox, card, index) do
    chunk_outbox = %OutboxEntry{
      outbox
      | idempotency_key: chunk_idempotency_key(outbox.idempotency_key, index)
    }

    opts =
      case index do
        1 -> [reply_to: outbox.reply_to_source_entry_id]
        _index -> []
      end

    message_request(
      :post,
      "im/v1/messages",
      chunk_outbox,
      %{
        receive_id: chat_id_from_channel(outbox.signal_channel_id),
        msg_type: "interactive",
        content: Card.message_content(card)
      },
      opts
    )
  end

  defp text_body(%{fallback_visible_text: text}) when is_binary(text) do
    %{msg_type: "text", content: Card.text_content(text)}
  end

  defp text_body(_outbox), do: %{msg_type: "text", content: Card.text_content("")}

  defp message_body(%OutboxEntry{} = outbox) do
    case fetch_list(outbox.payload, "attachments") do
      [] -> {:ok, text_body(outbox)}
      [attachment] -> attachment_body(attachment)
      _attachments -> {:error, :multiple_outbound_attachments_not_supported}
    end
  end

  defp attachment_body(%{} = attachment) do
    cond do
      image_key =
          optional_text(attachment, "provider_image_key") ||
            optional_text(attachment, "image_key") ->
        {:ok, %{msg_type: "image", content: Ankole.JSON.encode!(%{image_key: image_key})}}

      file_key =
          optional_text(attachment, "provider_file_key") || optional_text(attachment, "file_key") ->
        {:ok, %{msg_type: "file", content: Ankole.JSON.encode!(%{file_key: file_key})}}

      true ->
        {:error, :outbound_attachment_not_uploaded}
    end
  end

  defp materialize_outbound_attachments(%OutboxEntry{payload: payload} = outbox, client) do
    case fetch_list(payload, "attachments") do
      [] ->
        {:ok, outbox}

      [attachment] ->
        with {:ok, attachment} <-
               ensure_provider_attachment_key(attachment, client, outbox.agent_uid) do
          {:ok, %OutboxEntry{outbox | payload: Map.put(payload, "attachments", [attachment])}}
        end

      _attachments ->
        {:error, :multiple_outbound_attachments_not_supported}
    end
  end

  defp ensure_provider_attachment_key(%{} = attachment, client, agent_uid) do
    if image_attachment?(attachment) do
      case optional_text(attachment, "provider_image_key") ||
             optional_text(attachment, "image_key") do
        image_key when is_binary(image_key) ->
          {:ok, Map.put(attachment, "provider_image_key", image_key)}

        _missing ->
          upload_worker_image_attachment(attachment, client, agent_uid)
      end
    else
      case optional_text(attachment, "provider_file_key") || optional_text(attachment, "file_key") do
        file_key when is_binary(file_key) ->
          {:ok, Map.put(attachment, "provider_file_key", file_key)}

        _missing ->
          upload_worker_file_attachment(attachment, client, agent_uid)
      end
    end
  end

  defp upload_worker_image_attachment(attachment, client, agent_uid) do
    with relative_path when is_binary(relative_path) <-
           attachment_relative_path(attachment, agent_uid),
         {:ok, %{"content" => content}} <- WorkerFiles.get("user_files", relative_path),
         name <- attachment_name(attachment, relative_path),
         {:ok, %{"data" => data}} <-
           FeishuOpenAPI.upload(client, "im/v1/images",
             fields: [image_type: "message"],
             file_field: :image,
             file: {:iodata, content, name}
           ),
         image_key when is_binary(image_key) <- data["image_key"] do
      {:ok,
       attachment
       |> Map.put("provider_image_key", image_key)
       |> Map.put_new("name", name)}
    else
      nil -> {:error, :outbound_attachment_path_missing}
      {:error, _reason} = error -> error
      _value -> {:error, :outbound_image_upload_failed}
    end
  end

  defp upload_worker_file_attachment(attachment, client, agent_uid) do
    with relative_path when is_binary(relative_path) <-
           attachment_relative_path(attachment, agent_uid),
         {:ok, %{"content" => content}} <-
           WorkerFiles.get("user_files", relative_path),
         name <- attachment_name(attachment, relative_path),
         {:ok, %{"data" => data}} <-
           FeishuOpenAPI.upload(client, "im/v1/files",
             fields: [file_type: "stream", file_name: name],
             file: {:iodata, content, name}
           ),
         file_key when is_binary(file_key) <- data["file_key"] do
      {:ok,
       attachment
       |> Map.put("provider_file_key", file_key)
       |> Map.put_new("name", name)}
    else
      nil -> {:error, :outbound_attachment_path_missing}
      {:error, _reason} = error -> error
      _value -> {:error, :outbound_attachment_upload_failed}
    end
  end

  defp attachment_relative_path(attachment, agent_uid) do
    case optional_text(attachment, "user_files_relative_path") do
      relative when is_binary(relative) ->
        Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative)

      _missing ->
        user_files = Ankole.AgentHomePaths.user_files(agent_uid) <> "/"

        case optional_text(attachment, "agent_computer_path") || optional_text(attachment, "path") do
          ^user_files <> relative ->
            Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative)

          _outside ->
            nil
        end
    end
  end

  defp attachment_name(attachment, relative_path) do
    optional_text(attachment, "name") || Path.basename(relative_path)
  end

  defp image_attachment?(attachment) do
    case optional_text(attachment, "mime_type") do
      "image/" <> _subtype -> true
      _other -> image_filename?(optional_text(attachment, "name"))
    end
  end

  defp image_filename?(name) when is_binary(name) do
    name
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in ~w(.png .jpg .jpeg .gif .webp .bmp .tif .tiff)))
  end

  defp image_filename?(_name), do: false

  defp divider_i18n(%{"i18n" => i18n}) when is_map(i18n) do
    i18n
    |> Enum.flat_map(fn
      {locale, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> []
          text -> [{to_string(locale), String.slice(text, 0, 20)}]
        end

      _entry ->
        []
    end)
    |> Map.new()
  end

  defp divider_i18n(_payload), do: nil

  defp config_for_outbox(%OutboxEntry{} = outbox) do
    with {:ok, config_ref} <- SignalsGateway.outbox_binding_config_ref(outbox),
         {:ok, config} <- Config.load_chat_config_ref(config_ref) do
      {:ok, config}
    else
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp chat_id_from_channel("lark:" <> encoded), do: URI.decode(encoded)
  defp chat_id_from_channel(value), do: value

  defp error_not_found?(%Error{} = error), do: target_gone_error?(error)
end
