defmodule Ankole.Plugins.LarkAdapter.Delivery do
  @moduledoc """
  Conversation Delivery adapter for Lark / Feishu provider-visible output.
  """

  @behaviour Ankole.Conversations.Delivery.Adapter

  alias Ankole.Signals.Bindings
  alias Ankole.I18n
  alias Ankole.Plugins.LarkAdapter.Card
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.DriveUpload
  alias Ankole.Plugins.LarkAdapter.Emoji
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Delivery.Intent
  alias FeishuOpenAPI.Error

  import MapHelpers,
    only: [
      compact_map: 1,
      fetch_list: 2,
      fetch_value: 2,
      put_present: 3,
      optional_text: 2
    ]

  @max_text_message_chars 4_000
  @max_im_file_bytes 30 * 1024 * 1024
  @final_edit_fallback_codes [230_072, 230_075]
  @drive_operator_action_codes [
    91_204,
    99_991_672,
    106_1004,
    106_1044,
    106_1061,
    106_1073,
    106_1101,
    106_2507,
    106_3002,
    106_9701
  ]
  @drive_permanent_codes [106_1002, 106_1043, 106_1109, 106_3001]
  # Feishu caps the message `uuid` at 50 characters. Keep Ankole's full key in
  # the intent and derive only the provider-facing value when it is too long.
  @max_message_uuid_chars 50
  @message_uuid_prefix "ankole-"

  @impl true
  defdelegate open_conversation(binding, principal_uid),
    to: Ankole.Conversations.External,
    as: :existing_direct_conversation

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
  def deliver(%Intent{} = intent) do
    result =
      with {:ok, config} <- Bindings.delivery_config(intent, Config),
           client <- Config.client(config),
           {:ok, intent} <- materialize_outbound_attachments(intent, client),
           {:ok, requests} <- requests_for_intent(intent) do
        requests
        |> perform_requests(client, intent)
        |> with_materialized_intent(intent)
      end

    normalize_delivery_error(result)
  end

  @impl true
  def reconcile(%Intent{created_provider_message_id: nil}), do: :unknown

  def reconcile(%Intent{} = intent) do
    with {:ok, config} <- Bindings.delivery_config(intent, Config),
         client <- Config.client(config) do
      case FeishuOpenAPI.get(client, "im/v1/messages/:message_id",
             path_params: %{message_id: intent.created_provider_message_id}
           ) do
        {:ok, body} ->
          {:ok,
           %{
             created_provider_message_id: intent.created_provider_message_id,
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

  defp requests_for_intent(%Intent{operation: :post} = intent) do
    with {:ok, body} <- message_body(intent) do
      {:ok, message_requests(:post, "im/v1/messages", intent, body)}
    end
  end

  defp requests_for_intent(%Intent{operation: :reply} = intent) do
    with {:ok, body} <- message_body(intent) do
      {:ok,
       message_requests(:post, "im/v1/messages", intent, body,
         reply_to: intent.reply_to_provider_message_id
       )}
    end
  end

  defp requests_for_intent(%Intent{operation: :edit} = intent) do
    {:ok, edit_message_requests(intent)}
  end

  defp requests_for_intent(%Intent{operation: :delete} = intent) do
    {:ok,
     [
       %{
         method: :delete,
         path: "im/v1/messages/:message_id",
         path_params: %{message_id: intent.target_provider_message_id}
       }
     ]}
  end

  defp requests_for_intent(%Intent{operation: operation} = intent)
       when operation in [:reaction_add, :reaction_remove] do
    reaction_key =
      intent.payload
      |> fetch_value("reaction_key")
      |> Emoji.provider_key()

    request =
      case operation do
        :reaction_add ->
          %{
            method: :post,
            path: "im/v1/messages/:message_id/reactions",
            path_params: %{message_id: intent.target_provider_message_id},
            body: %{reaction_type: %{emoji_type: reaction_key}}
          }

        :reaction_remove ->
          %{
            reaction_remove: %{
              message_id: intent.target_provider_message_id,
              reaction_type: reaction_key
            }
          }
      end

    {:ok, [request]}
  end

  defp requests_for_intent(%Intent{operation: :divider} = intent) do
    text =
      intent.fallback_visible_text
      |> to_string()
      |> String.trim()
      |> String.slice(0, 20)

    body = %{
      msg_type: "system",
      content: Card.system_divider_content(text, divider_i18n(intent.payload))
    }

    {:ok, [message_request(:post, "im/v1/messages", intent, body)]}
  end

  defp requests_for_intent(%Intent{operation: :card} = intent) do
    with {:ok, card} <- Card.render(intent.payload) do
      {:ok,
       card
       |> Card.split_by_table()
       |> Enum.with_index(1)
       |> Enum.map(fn {card, index} -> card_message_request(intent, card, index) end)}
    end
  end

  defp requests_for_intent(_intent), do: {:error, :unsupported_intent_operation}

  defp perform_requests([request], client, intent) do
    request
    |> perform(client)
    |> maybe_reply_fallback(client, intent, request)
    |> maybe_final_edit_fallback(client, intent, request)
  end

  defp perform_requests(requests, client, intent) when is_list(requests) do
    requests
    |> Enum.reduce_while([], fn request, results ->
      case request
           |> perform(client)
           |> maybe_reply_fallback(client, intent, request)
           |> maybe_final_edit_fallback(client, intent, request) do
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

  # Lark's reaction DELETE takes the reaction instance id from the add
  # response, not the emoji key, and Ankole does not persist provider reaction
  # ids. Resolve the app's own instance at send time; no matching instance
  # means the reaction is already gone, which is the requested outcome.
  defp perform(
         %{reaction_remove: %{message_id: message_id, reaction_type: reaction_type}},
         client
       ) do
    case find_own_reaction_id(client, message_id, reaction_type) do
      {:ok, nil} ->
        {:ok, %{raw_payload: %{"reaction_absent" => true}}}

      {:ok, reaction_id} ->
        perform(
          %{
            method: :delete,
            path: "im/v1/messages/:message_id/reactions/:reaction_id",
            path_params: %{message_id: message_id, reaction_id: reaction_id}
          },
          client
        )

      {:error, _reason} = error ->
        error
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
    |> with_request_text(request)
  end

  defp with_request_text({:ok, result}, request) do
    {:ok,
     result
     |> Map.put(:text, request[:text])
     |> Map.put(:payload, request[:message_payload] || %{"attachments" => []})}
  end

  defp with_request_text(result, _request), do: result

  defp find_own_reaction_id(client, message_id, reaction_type) do
    FeishuOpenAPI.Pagination.stream(client, "im/v1/messages/:message_id/reactions",
      path_params: %{message_id: message_id},
      query: [reaction_type: reaction_type, page_size: 50]
    )
    |> Enum.reduce_while({:ok, nil}, fn
      {:ok, item}, acc ->
        operator = MapHelpers.fetch_map(item, "operator", %{})

        if optional_text(operator, "operator_type") == "app" and
             optional_text(operator, "operator_id") == client.app_id do
          {:halt, {:ok, optional_text(item, "reaction_id")}}
        else
          {:cont, acc}
        end

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp maybe_reply_fallback({:error, %Error{} = error}, client, intent, %{
         reply_to: reply_to,
         body: body
       })
       when is_binary(reply_to) do
    case target_gone_error?(error) do
      true ->
        # Lark rejects replies after the target disappears. Posting as a new
        # message preserves operator-visible output instead of losing the intent.
        :post
        |> message_request("im/v1/messages", intent, body)
        |> perform(client)

      false ->
        {:error, error}
    end
  end

  defp maybe_reply_fallback(result, _client, _intent, _request), do: result

  defp maybe_final_edit_fallback(
         {:error, %Error{code: code}},
         client,
         %Intent{operation: :edit, ai_message_id: ai_message_id} = intent,
         %{method: :put, body: body}
       )
       when code in @final_edit_fallback_codes and is_binary(ai_message_id) do
    # Text previews can consume Feishu's per-message edit budget before the
    # durable terminal reply arrives. Only that durable AI reply may degrade to
    # a new message; transient preview edits must remain best-effort edits or
    # they would create a new message for every subsequent delta.
    :post
    |> message_request("im/v1/messages", intent, body)
    |> perform(client)
    |> with_delivered_operation(:post)
  end

  defp maybe_final_edit_fallback(result, _client, _intent, _request), do: result

  defp with_delivered_operation({:ok, result}, operation) when is_map(result),
    do: {:ok, Map.put(result, :delivered_operation, operation)}

  defp with_delivered_operation(result, _operation), do: result

  @doc false
  @spec target_gone_error?(Error.t()) :: boolean()
  def target_gone_error?(%Error{code: code}), do: code in [23_000, 23_002, 23_006]

  defp normalize_send_response({:ok, %{"data" => data} = body}) when is_map(data) do
    {:ok,
     %{
       created_provider_message_id: data["message_id"],
       provider_thread_id: data["root_id"],
       raw_payload: body
     }
     |> compact_map()}
  end

  defp normalize_send_response({:ok, body}), do: {:ok, %{raw_payload: body}}
  defp normalize_send_response({:error, reason}), do: {:error, reason}

  defp combined_send_results([result]), do: Map.put(result, :messages, [result])

  defp combined_send_results(results) do
    first = List.first(results) || %{}

    %{
      created_provider_message_id: first[:created_provider_message_id],
      provider_thread_id: first[:provider_thread_id],
      delivered_operation: first[:delivered_operation],
      messages: results,
      raw_payload: %{
        "split" => true,
        "chunks" => Enum.map(results, &raw_payload/1)
      }
    }
    |> compact_map()
  end

  defp raw_payload(result) when is_map(result), do: Map.get(result, :raw_payload, result)

  defp with_materialized_intent({:ok, result}, %Intent{} = intent)
       when is_map(result) do
    {:ok,
     result
     |> Map.put(:payload, intent.payload)
     |> Map.put(:fallback_visible_text, intent.fallback_visible_text)}
  end

  defp with_materialized_intent(result, _intent), do: result

  defp normalize_delivery_error({:error, %Error{code: 234_006} = error}) do
    operator_attachment_error("attachment_exceeds_lark_im_limit", %{
      "max_bytes" => @max_im_file_bytes,
      "provider" => provider_error_detail(error)
    })
  end

  # App token and permission failures (the 999916xx family) need an operator
  # and wake on a binding update; transport, throttle, and 5xx retry; any
  # other provider rejection of a plain send is permanent.
  defp normalize_delivery_error({:error, %Error{} = error}) do
    action =
      cond do
        retryable_provider_error?(error) -> :retryable
        error.code in [999_916_63, 999_916_64, 999_916_68] -> :operator_action_required
        true -> :permanent
      end

    {:error,
     {:reply_delivery, action,
      %{
        code: error.code,
        msg: error.msg,
        http_status: error.http_status,
        log_id: error.log_id
      }
      |> compact_map()}}
  end

  defp normalize_delivery_error(
         {:error, {:large_file_upload_failed, stage, %Error{code: code} = error}}
       )
       when code in @drive_operator_action_codes do
    operator_attachment_error("large_file_cloud_upload_requires_operator_action", %{
      "stage" => Atom.to_string(stage),
      "provider" => provider_error_detail(error)
    })
  end

  defp normalize_delivery_error(
         {:error, {:large_file_upload_failed, stage, %Error{code: code} = error}}
       )
       when code in @drive_permanent_codes do
    permanent_attachment_error("large_file_cloud_upload_rejected", %{
      "stage" => Atom.to_string(stage),
      "provider" => provider_error_detail(error)
    })
  end

  defp normalize_delivery_error({:error, {:large_file_upload_failed, stage, reason}})
       when is_atom(reason) do
    permanent_attachment_error("large_file_cloud_upload_invalid_response", %{
      "stage" => Atom.to_string(stage),
      "reason" => Atom.to_string(reason)
    })
  end

  defp normalize_delivery_error({:error, {:large_file_recipient_missing, channel_kind}}) do
    operator_attachment_error("large_file_recipient_missing", %{
      "channel_kind" => to_string(channel_kind)
    })
  end

  defp normalize_delivery_error({:error, :outbound_attachment_empty}),
    do: permanent_attachment_error("attachment_empty")

  defp normalize_delivery_error({:error, :outbound_attachment_not_uploaded}),
    do: operator_attachment_error("attachment_not_uploaded")

  defp normalize_delivery_error({:error, {:file_too_large, size, max_bytes}})
       when is_integer(size) and is_integer(max_bytes) do
    operator_attachment_error("attachment_file_too_large", %{
      "size_bytes" => size,
      "max_bytes" => max_bytes
    })
  end

  defp normalize_delivery_error(result), do: result

  defp retryable_provider_error?(%Error{code: code}) when code in [:transport, :rate_limited],
    do: true

  defp retryable_provider_error?(%Error{http_status: status})
       when status in [408, 409, 425, 429],
       do: true

  defp retryable_provider_error?(%Error{http_status: status})
       when is_integer(status) and status >= 500,
       do: true

  defp retryable_provider_error?(%Error{}), do: false

  defp operator_attachment_error(code, detail \\ %{}) do
    {:error, {:reply_delivery, :operator_action_required, Map.put(detail, "code", code)}}
  end

  defp permanent_attachment_error(code, detail \\ %{}) do
    {:error, {:reply_delivery, :permanent, Map.put(detail, "code", code)}}
  end

  defp provider_error_detail(%Error{} = error) do
    %{
      "code" => error.code,
      "msg" => error.msg,
      "http_status" => error.http_status,
      "log_id" => error.log_id
    }
    |> compact_map()
  end

  defp message_request(method, path, intent, body, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to)
    path = if is_binary(reply_to), do: "im/v1/messages/:message_id/reply", else: path
    path_params = Keyword.get(opts, :path_params, %{})

    path_params =
      if is_binary(reply_to), do: Map.put(path_params, :message_id, reply_to), else: path_params

    idempotency_key = Keyword.get(opts, :idempotency_key, intent.idempotency_key)
    base_body = Map.put_new(body, :uuid, provider_message_uuid(idempotency_key))

    # Replies and new messages use different Lark API shapes. Keeping the branch
    # here makes every intent operation share one idempotency/body path.
    case reply_to do
      value when is_binary(value) ->
        %{
          method: method,
          path: path,
          path_params: path_params,
          body: base_body,
          text: intent.fallback_visible_text,
          message_payload: intent.payload,
          reply_to: reply_to
        }

      _value ->
        %{
          method: method,
          path: path,
          path_params: path_params,
          query: [receive_id_type: "chat_id"],
          body: put_present(base_body, :receive_id, chat_id_from_channel(intent.conversation_id)),
          text: intent.fallback_visible_text,
          message_payload: intent.payload,
          reply_to: reply_to
        }
    end
  end

  defp message_requests(method, path, %Intent{} = intent, %{msg_type: "text"} = body, opts) do
    text =
      intent.fallback_visible_text
      |> to_string()
      |> split_text()

    text
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, index} ->
      chunk_intent = %Intent{
        intent
        | fallback_visible_text: chunk,
          payload: Map.put(intent.payload, "attachments", []),
          idempotency_key: chunk_idempotency_key(intent.idempotency_key, index)
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
        chunk_intent,
        %{body | content: Card.text_content(chunk)},
        chunk_opts
      )
    end)
  end

  defp message_requests(method, path, intent, body, opts) do
    [message_request(method, path, intent, body, opts)]
  end

  defp message_requests(method, path, intent, body),
    do: message_requests(method, path, intent, body, [])

  defp edit_message_requests(%Intent{} = intent) do
    chunks =
      intent.fallback_visible_text
      |> to_string()
      |> split_text()

    chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, index} ->
      chunk_intent = %Intent{
        intent
        | fallback_visible_text: chunk,
          payload: Map.put(intent.payload, "attachments", []),
          idempotency_key: chunk_idempotency_key(intent.idempotency_key, index)
      }

      case index do
        1 ->
          %{
            method: :put,
            path: "im/v1/messages/:message_id",
            path_params: %{message_id: intent.target_provider_message_id},
            body: text_body(chunk_intent),
            text: chunk,
            message_payload: %{"attachments" => []}
          }

        _index ->
          message_request(
            :post,
            "im/v1/messages",
            chunk_intent,
            text_body(chunk_intent)
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

  defp card_message_request(%Intent{} = intent, card, index) do
    chunk_intent = %Intent{
      intent
      | idempotency_key: chunk_idempotency_key(intent.idempotency_key, index)
    }

    opts =
      case index do
        1 -> [reply_to: intent.reply_to_provider_message_id]
        _index -> []
      end

    message_request(
      :post,
      "im/v1/messages",
      chunk_intent,
      %{
        receive_id: chat_id_from_channel(intent.conversation_id),
        msg_type: "interactive",
        content: Card.message_content(card)
      },
      opts
    )
  end

  defp text_body(%{fallback_visible_text: text}) when is_binary(text) do
    %{msg_type: "text", content: Card.text_content(text)}
  end

  defp text_body(_intent), do: %{msg_type: "text", content: Card.text_content("")}

  defp message_body(%Intent{} = intent) do
    case fetch_list(intent.payload, "attachments") do
      [] -> {:ok, text_body(intent)}
      [attachment] -> attachment_body(attachment)
    end
  end

  defp attachment_body(%{} = attachment) do
    cond do
      optional_text(attachment, "provider_drive_url") ->
        {:ok, %{msg_type: "text", content: Card.text_content(large_file_message(attachment))}}

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

  defp materialize_outbound_attachments(%Intent{payload: payload} = intent, client) do
    case fetch_list(payload, "attachments") do
      [] ->
        {:ok, intent}

      [attachment] ->
        with {:ok, attachment} <-
               ensure_provider_attachment_key(attachment, client, intent) do
          intent = %Intent{intent | payload: Map.put(payload, "attachments", [attachment])}
          {:ok, with_attachment_delivery_text(intent, attachment)}
        end
    end
  end

  defp ensure_provider_attachment_key(%{} = attachment, client, %Intent{} = intent) do
    if image_attachment?(attachment) do
      case optional_text(attachment, "provider_image_key") ||
             optional_text(attachment, "image_key") do
        image_key when is_binary(image_key) ->
          {:ok, Map.put(attachment, "provider_image_key", image_key)}

        _missing ->
          upload_image_attachment(attachment, client)
      end
    else
      cond do
        optional_text(attachment, "provider_drive_url") ->
          {:ok, attachment}

        file_key =
            optional_text(attachment, "provider_file_key") ||
              optional_text(attachment, "file_key") ->
          {:ok, Map.put(attachment, "provider_file_key", file_key)}

        true ->
          upload_file_attachment(attachment, client, intent)
      end
    end
  end

  defp upload_image_attachment(attachment, client) do
    with {:ok, content} <- Ankole.Conversations.Delivery.attachment_content(attachment),
         name <- attachment_name(attachment),
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
      {:error, _reason} = error -> error
      _value -> {:error, :outbound_image_upload_failed}
    end
  end

  defp upload_file_attachment(attachment, client, %Intent{} = intent) do
    with {:ok, content} <- Ankole.Conversations.Delivery.attachment_content(attachment),
         true <- byte_size(content) > 0 || {:error, :outbound_attachment_empty},
         name <- attachment_name(attachment) do
      if large_im_file?(byte_size(content)) do
        upload_worker_file_to_drive(
          attachment,
          client,
          intent,
          content,
          name,
          :preflight_size
        )
      else
        upload_worker_file_to_im(attachment, client, intent, content, name)
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp upload_worker_file_to_im(attachment, client, intent, content, name) do
    case FeishuOpenAPI.upload(client, "im/v1/files",
           fields: [file_type: "stream", file_name: name],
           file: {:iodata, content, name}
         ) do
      {:ok, %{"data" => %{"file_key" => file_key}}} when is_binary(file_key) ->
        {:ok,
         attachment
         |> Map.put("provider_file_key", file_key)
         |> Map.put_new("name", name)}

      {:error, %Error{code: 234_006}} ->
        upload_worker_file_to_drive(
          attachment,
          client,
          intent,
          content,
          name,
          :provider_234006
        )

      {:error, _reason} = error ->
        error

      _value ->
        {:error, :outbound_attachment_upload_failed}
    end
  end

  defp upload_worker_file_to_drive(
         attachment,
         client,
         %Intent{} = intent,
         content,
         name,
         fallback_reason
       ) do
    with {:ok, recipient} <- drive_recipient(intent),
         {:ok, upload} <-
           DriveUpload.upload(client, content, name, recipient, %{
             agent_uid: intent.agent_uid,
             binding_name: intent.binding_name,
             outbound_key: intent.outbound_key,
             operation: intent.operation,
             fallback_reason: fallback_reason
           }) do
      {:ok,
       attachment
       |> Map.put("provider_drive_file_token", upload.file_token)
       |> Map.put("provider_drive_url", upload.url)
       |> Map.put("provider_drive_block_num", upload.block_num)
       |> Map.put("size_bytes", byte_size(content))
       |> Map.put_new("name", name)}
    end
  end

  @doc false
  @spec large_im_file?(non_neg_integer()) :: boolean()
  def large_im_file?(size) when is_integer(size) and size >= 0,
    do: size > @max_im_file_bytes

  defp drive_recipient(%Intent{} = intent) do
    case Ankole.Conversations.get_conversation!(intent.conversation_id) do
      %Conversation{external_kind: :im_group} ->
        {:ok,
         %{
           member_type: "openchat",
           member_id: chat_id_from_channel(intent.conversation_id)
         }}

      %Conversation{external_kind: kind, metadata: metadata} when kind in [:im_dm, :unknown] ->
        direct_drive_recipient(intent, metadata, kind)

      %Conversation{external_kind: kind} ->
        {:error, {:large_file_recipient_missing, kind}}

      nil ->
        direct_drive_recipient(intent, %{}, :missing)
    end
  end

  defp direct_drive_recipient(intent, metadata, channel_kind) do
    case optional_text(metadata, "peer_open_id") || signal_open_id(intent) do
      open_id when is_binary(open_id) ->
        {:ok, %{member_type: "openid", member_id: open_id}}

      nil ->
        {:error, {:large_file_recipient_missing, channel_kind}}
    end
  end

  defp signal_open_id(%Intent{source_signal_id: signal_id})
       when is_binary(signal_id) do
    case Ankole.Signals.get_signal!(signal_id) do
      %Signal{data: data} when is_map(data) ->
        get_in(data, ["entry", "author", "metadata", "open_id"]) ||
          data
          |> get_in(["entries"])
          |> List.wrap()
          |> Enum.reverse()
          |> Enum.find_value(&get_in(&1, ["author", "metadata", "open_id"]))

      _missing ->
        nil
    end
  end

  defp signal_open_id(_intent), do: nil

  defp with_attachment_delivery_text(%Intent{} = intent, attachment) do
    case optional_text(attachment, "provider_drive_url") do
      url when is_binary(url) ->
        %Intent{intent | fallback_visible_text: large_file_message(attachment)}

      nil ->
        intent
    end
  end

  defp large_file_message(attachment) do
    I18n.t("conversations.delivery.reply.large_file_drive_link", %{
      "name" => optional_text(attachment, "name") || "file",
      "url" => optional_text(attachment, "provider_drive_url") || ""
    })
  end

  defp attachment_name(attachment) do
    optional_text(attachment, "name") ||
      Path.basename(optional_text(attachment, "path") || "file")
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

  defp chat_id_from_channel(conversation_id) do
    "lark:" <> encoded = Ankole.Conversations.External.provider_conversation_id!(conversation_id)
    URI.decode(encoded)
  end

  defp error_not_found?(%Error{} = error), do: target_gone_error?(error)
end
