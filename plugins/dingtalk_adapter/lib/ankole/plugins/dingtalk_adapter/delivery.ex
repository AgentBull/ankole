defmodule Ankole.Plugins.DingTalkAdapter.Delivery do
  @moduledoc """
  Conversation Delivery adapter for DingTalk provider-visible output.

  Supports `post_entry` (text and single attachment), `delete_entry` (recall by
  `processQueryKey`), and `card` (a template-hosted card instance rendered by
  `InteractiveCard`; without a configured `cardTemplateId` the row's
  `fallback_visible_text` posts as a plain message instead). DingTalk has no
  anchored reply, no message edit, and no outbound reconciliation, so those
  capabilities are not declared. Conversations.Delivery finalizes a terminal AI reply
  (`reply_presentation` payload with a source Signal) through `AICard`, the
  declared `preview_module`; such a row without a source Signal posts
  its plain Markdown text here.

  A successful send returns `processQueryKey` (the provider message id used as the
  outbound entry id and recall handle). `/robot/*/send` has no idempotency
  parameter and no history query, so a crash after send but before recording that
  id leaves a documented duplicate window; card instances are idempotent by
  `outTrackId`.
  """

  @behaviour Ankole.Conversations.Delivery.Adapter

  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Plugins.DingTalkAdapter.InteractiveCard
  alias Ankole.Plugins.DingTalkAdapter.Markdown
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Repo
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Delivery.Intent
  alias DingTalkOpenAPI.Error
  alias DingTalkOpenAPI.Robot

  import MapHelpers, only: [fetch_list: 2, optional_text: 2]

  @image_extensions ~w(.png .jpg .jpeg .gif .webp .bmp .heic .heif)
  # Per the send API doc's listed sampleFile types.
  @file_extensions ~w(.xlsx .pdf .zip .rar .doc .docx .ppt .pptx .txt .csv .md .xls .7z .gz .svg .html .json)

  @impl true
  def deliver(%Intent{payload: %{"reply_presentation" => presentation}} = intent)
      when is_map(presentation) do
    deliver_text(intent)
  end

  def deliver(%Intent{operation: :post} = intent), do: deliver_post(intent)
  def deliver(%Intent{operation: :delete} = intent), do: deliver_delete(intent)
  def deliver(%Intent{operation: :card} = intent), do: deliver_card(intent)
  def deliver(%Intent{}), do: {:error, :unsupported_intent_operation}

  defp deliver_post(%Intent{} = intent) do
    case fetch_list(intent.payload, "attachments") do
      [] -> deliver_text(intent)
      [attachment] -> deliver_attachment(intent, attachment)
    end
  end

  defp deliver_text(%Intent{} = intent) do
    with {:ok, config} <- Bindings.delivery_config(intent, Config),
         client <- Config.client(config),
         {:ok, target} <- resolve_target(intent) do
      robot_code = Config.effective_robot_code(config)

      chunks =
        intent.fallback_visible_text
        |> to_string()
        |> Markdown.to_dingtalk()
        |> Markdown.split()
        |> Markdown.display_chunks()

      send_text_chunks(client, robot_code, target, chunks, intent, config)
    end
    |> normalize_delivery_result()
  end

  # A card row without a configured template still delivers its durable intent:
  # the gateway guarantees `fallback_visible_text` on card operations, so the
  # fallback posts as a plain message rather than parking the row unsupported.
  defp deliver_card(%Intent{} = intent) do
    with {:ok, config} <- Bindings.delivery_config(intent, Config) do
      case card_template_id(config) do
        nil ->
          deliver_text(intent)

        template_id ->
          client = Config.client(config)
          robot_code = Config.effective_robot_code(config)

          with {:ok, target} <- resolve_target(intent) do
            InteractiveCard.deliver(client, template_id, robot_code, target, intent)
          end
          |> normalize_delivery_result()
      end
    end
  end

  defp card_template_id(config) do
    case MapHelpers.optional_text(config, "cardTemplateId") do
      id when is_binary(id) -> id
      _absent -> nil
    end
  end

  defp send_text_chunks(client, robot_code, target, chunks, intent, config) do
    chunks
    |> Enum.reduce_while([], fn chunk, results ->
      msg_key = if Markdown.formatted?(chunk), do: "sampleMarkdown", else: "sampleText"
      msg_param = text_msg_param(msg_key, chunk, config)

      case send_message(client, robot_code, target, msg_key, msg_param) do
        {:ok, result} -> {:cont, [Map.put(result, :text, chunk) | results]}
        {:error, _reason} when results != [] -> {:halt, :unknown}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      :unknown -> :unknown
      {:error, _reason} = error -> error
      results -> {:ok, combined_result(Enum.reverse(results), intent.payload)}
    end
  end

  defp text_msg_param("sampleMarkdown", chunk, config) do
    %{"title" => markdown_title(chunk, config), "text" => chunk}
  end

  defp text_msg_param("sampleText", chunk, _config), do: %{"content" => chunk}

  # sampleMarkdown requires a non-empty title. Use the first heading/line,
  # falling back to the configured output display name.
  defp markdown_title(chunk, config) do
    first_line =
      chunk
      |> String.split("\n", parts: 2)
      |> List.first()
      |> to_string()
      |> String.replace(~r/^#+\s*/, "")
      |> String.trim()

    case first_line do
      "" -> Map.get(config, "userName", "钉钉 / DingTalk")
      line -> String.slice(line, 0, 40)
    end
  end

  defp deliver_attachment(%Intent{} = intent, attachment) do
    with {:ok, config} <- Bindings.delivery_config(intent, Config),
         client <- Config.client(config),
         {:ok, target} <- resolve_target(intent),
         # The extension gate runs before the worker read: an unsupported type
         # must fail without pulling bytes it can never send.
         {:ok, media_type} <- media_type(attachment),
         {:ok, content, name} <- read_attachment(attachment),
         {:ok, msg_key, msg_param} <- upload_and_build(client, media_type, content, name) do
      robot_code = Config.effective_robot_code(config)

      client
      |> send_message(robot_code, target, msg_key, msg_param)
      |> case do
        {:ok, result} -> {:ok, Map.put(result, :payload, intent.payload)}
        {:error, _reason} = error -> error
      end
    end
    |> normalize_delivery_result()
  end

  defp read_attachment(attachment) do
    with {:ok, content} <- Ankole.Conversations.Delivery.attachment_content(attachment) do
      {:ok, content, attachment_name(attachment)}
    end
  end

  defp media_type(attachment) do
    name = attachment_name(attachment)

    ext = name |> Path.extname() |> String.downcase()

    cond do
      ext in @image_extensions -> {:ok, :image}
      ext in @file_extensions -> {:ok, :file}
      true -> {:error, :unsupported_file_type}
    end
  end

  defp upload_and_build(client, :image, content, name) do
    with {:ok, media_id} <- Robot.upload_media(client, "image", content, name) do
      {:ok, "sampleImageMsg", %{"photoURL" => media_id}}
    end
  end

  defp upload_and_build(client, :file, content, name) do
    ext = name |> Path.extname() |> String.downcase()

    with {:ok, media_id} <- Robot.upload_media(client, "file", content, name) do
      {:ok, "sampleFile",
       %{
         "mediaId" => media_id,
         "fileName" => name,
         "fileType" => String.trim_leading(ext, ".")
       }}
    end
  end

  defp deliver_delete(%Intent{target_provider_message_id: nil}),
    do: {:error, :unsupported_target}

  defp deliver_delete(%Intent{target_provider_message_id: process_query_key} = intent) do
    with {:ok, config} <- Bindings.delivery_config(intent, Config),
         client <- Config.client(config),
         {:ok, target} <- resolve_target(intent) do
      robot_code = Config.effective_robot_code(config)

      result =
        case target do
          {:dm, _user_id} ->
            Robot.batch_recall_oto(client,
              robot_code: robot_code,
              process_query_keys: [process_query_key]
            )

          {:group, conversation_id} ->
            Robot.recall_group(client,
              open_conversation_id: conversation_id,
              robot_code: robot_code,
              process_query_keys: [process_query_key]
            )
        end

      case result do
        {:ok, body} -> {:ok, %{raw_payload: body}}
        {:error, _reason} = error -> error
      end
    end
    |> normalize_delivery_result()
  end

  defp send_message(client, robot_code, {:dm, user_id}, msg_key, msg_param) do
    client
    |> Robot.batch_send_oto(
      robot_code: robot_code,
      user_ids: [user_id],
      msg_key: msg_key,
      msg_param: msg_param
    )
    |> send_result()
  end

  defp send_message(client, robot_code, {:group, conversation_id}, msg_key, msg_param) do
    client
    |> Robot.send_group_message(
      open_conversation_id: conversation_id,
      robot_code: robot_code,
      msg_key: msg_key,
      msg_param: msg_param
    )
    |> send_result()
  end

  defp send_result({:ok, %{"flowControlledStaffIdList" => [_ | _]} = body}) do
    {:error, %Error{reason: :rate_limited, message: "per-user flow control", raw: body}}
  end

  defp send_result({:ok, %{"processQueryKey" => pqk} = body}) when is_binary(pqk) do
    {:ok, %{created_provider_message_id: pqk, raw_payload: body}}
  end

  defp send_result({:ok, body}), do: {:ok, %{raw_payload: body}}
  defp send_result({:error, _reason} = error), do: error

  defp combined_result([result], _payload), do: Map.put(result, :messages, [result])

  defp combined_result([first | _] = results, _payload) do
    %{
      created_provider_message_id: first[:created_provider_message_id],
      messages: results,
      raw_payload: %{"split" => true, "chunks" => Enum.map(results, & &1[:raw_payload])}
    }
  end

  defp combined_result([], _payload), do: %{raw_payload: %{}}

  defp resolve_target(%Intent{conversation_id: conversation_id}) do
    case Repo.get_by(Conversation, id: conversation_id) do
      %Conversation{external_kind: :im_dm, metadata: metadata} ->
        case optional_text(metadata, "dm_user_id") do
          user_id when is_binary(user_id) -> {:ok, {:dm, user_id}}
          nil -> {:error, :dm_recipient_unknown}
        end

      %Conversation{provider_conversation_id: provider_id} ->
        {:ok, {:group, decode_channel(provider_id)}}

      nil ->
        {:error, :external_conversation_not_found}
    end
  end

  defp decode_channel("dingtalk:" <> encoded), do: URI.decode(encoded)
  defp decode_channel(value), do: value

  defp attachment_name(attachment) do
    optional_text(attachment, "name") || Path.basename(optional_text(attachment, "path") || "")
  end

  @doc false
  @spec normalize_delivery_result(term()) :: term()
  def normalize_delivery_result({:error, %Error{} = error}) do
    action =
      cond do
        Error.retryable?(error) -> :retryable
        error.reason in [:auth, :quota_exhausted] -> :operator_action_required
        true -> :permanent
      end

    {:error,
     {:reply_delivery, action,
      MapHelpers.compact_map(%{
        reason: error.reason,
        code: error.code,
        message: error.message,
        http_status: error.http_status,
        retry_after_seconds: error.retry_after
      })}}
  end

  def normalize_delivery_result(result), do: result
end
