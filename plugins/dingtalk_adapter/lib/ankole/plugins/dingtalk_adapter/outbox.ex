defmodule Ankole.Plugins.DingTalkAdapter.Outbox do
  @moduledoc """
  SignalsGateway outbox adapter for DingTalk provider-visible output.

  Supports `post_entry` (text and single attachment), `delete_entry` (recall by
  `processQueryKey`), and `card` (a template-hosted card instance rendered by
  `InteractiveCard`; without a configured `cardTemplateId` the row's
  `fallback_visible_text` posts as a plain message instead). DingTalk has no
  anchored reply, no message edit, and no outbound reconciliation, so those
  capabilities are not declared. A terminal AI reply (`reply_presentation`
  payload) routes through `AICard.finalize/1` — the same module declared as the
  `reply_preview_module` — which seals the streaming card chain or degrades once
  to plain Markdown.

  A successful send returns `processQueryKey` (the provider message id used as the
  outbound entry id and recall handle). `/robot/*/send` has no idempotency
  parameter and no history query, so a crash after send but before recording that
  id leaves a documented duplicate window; card instances are idempotent by
  `outTrackId`.
  """

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  alias Ankole.Plugins.DingTalkAdapter.AICard
  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Plugins.DingTalkAdapter.InteractiveCard
  alias Ankole.Plugins.DingTalkAdapter.Markdown
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.ReplyPreviewAdapter
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias Ankole.WorkerFiles
  alias DingTalkOpenAPI.Error
  alias DingTalkOpenAPI.Robot

  import MapHelpers, only: [fetch_list: 2, optional_text: 2]

  @image_extensions ~w(.png .jpg .jpeg .gif .webp .bmp .heic .heif)
  # Per the send API doc's listed sampleFile types.
  @file_extensions ~w(.xlsx .pdf .zip .rar .doc .docx .ppt .pptx .txt .csv .md .xls .7z .gz .svg .html .json)

  @impl true
  def send(
        %OutboxEntry{
          payload: %{"reply_presentation" => presentation},
          source_actor_event_id: actor_event_id
        } = outbox
      )
      when is_map(presentation) and is_binary(actor_event_id) do
    # The durable terminal AI reply finalizes the streaming card (or degrades to a
    # plain Markdown message when no template is configured).
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{} = event ->
        checkpoint = event.reply_preview_checkpoint || %{}

        ReplyPreviewAdapter.finalize_module(AICard, %Request{
          actor_event: event,
          presentation: presentation,
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

  def send(%OutboxEntry{payload: %{"reply_presentation" => presentation}} = outbox)
      when is_map(presentation) do
    deliver_text(outbox)
  end

  def send(%OutboxEntry{operation: :post} = outbox), do: deliver_post(outbox)
  def send(%OutboxEntry{operation: :delete} = outbox), do: deliver_delete(outbox)
  def send(%OutboxEntry{operation: :card} = outbox), do: deliver_card(outbox)
  def send(%OutboxEntry{}), do: {:error, :unsupported_outbox_operation}

  # post

  defp deliver_post(%OutboxEntry{} = outbox) do
    case fetch_list(outbox.payload, "attachments") do
      [] -> deliver_text(outbox)
      [attachment] -> deliver_attachment(outbox, attachment)
      _attachments -> {:error, :multiple_outbound_attachments_not_supported}
    end
  end

  defp deliver_text(%OutboxEntry{} = outbox) do
    with {:ok, config} <- config_for_outbox(outbox),
         client <- Config.client(config),
         {:ok, target} <- resolve_target(outbox) do
      robot_code = Config.effective_robot_code(config)

      chunks =
        outbox.fallback_visible_text
        |> to_string()
        |> Markdown.to_dingtalk()
        |> Markdown.split()
        |> Markdown.display_chunks()

      send_text_chunks(client, robot_code, target, chunks, outbox, config)
    end
    |> normalize_delivery_result()
  end

  # card

  # A card row without a configured template still delivers its durable intent:
  # the gateway guarantees `fallback_visible_text` on card operations, so the
  # fallback posts as a plain message rather than parking the row unsupported.
  defp deliver_card(%OutboxEntry{} = outbox) do
    with {:ok, config} <- config_for_outbox(outbox) do
      case card_template_id(config) do
        nil ->
          deliver_text(outbox)

        template_id ->
          client = Config.client(config)
          robot_code = Config.effective_robot_code(config)

          with {:ok, target} <- resolve_target(outbox) do
            InteractiveCard.deliver(client, template_id, robot_code, target, outbox)
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

  defp send_text_chunks(client, robot_code, target, chunks, outbox, config) do
    chunks
    |> Enum.reduce_while([], fn chunk, results ->
      msg_key = if Markdown.formatted?(chunk), do: "sampleMarkdown", else: "sampleText"
      msg_param = text_msg_param(msg_key, chunk, config)

      case send_message(client, robot_code, target, msg_key, msg_param) do
        {:ok, result} -> {:cont, [result | results]}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      results -> {:ok, combined_result(Enum.reverse(results), outbox.payload)}
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

  # attachment

  defp deliver_attachment(%OutboxEntry{} = outbox, attachment) do
    with {:ok, config} <- config_for_outbox(outbox),
         client <- Config.client(config),
         {:ok, target} <- resolve_target(outbox),
         # The extension gate runs before the worker read: an unsupported type
         # must fail without pulling bytes it can never send.
         {:ok, media_type} <- media_type(attachment, outbox.agent_uid),
         {:ok, content, name} <- read_attachment(attachment, outbox.agent_uid),
         {:ok, msg_key, msg_param} <- upload_and_build(client, media_type, content, name) do
      robot_code = Config.effective_robot_code(config)

      client
      |> send_message(robot_code, target, msg_key, msg_param)
      |> case do
        {:ok, result} -> {:ok, Map.put(result, :payload, outbox.payload)}
        {:error, _reason} = error -> error
      end
    end
    |> normalize_delivery_result()
  end

  defp read_attachment(attachment, agent_uid) do
    with relative_path when is_binary(relative_path) <-
           attachment_relative_path(attachment, agent_uid),
         {:ok, %{"content" => content}} <- WorkerFiles.get("user_files", relative_path) do
      {:ok, content, attachment_name(attachment, relative_path)}
    else
      nil -> {:error, :outbound_attachment_path_missing}
      {:error, _reason} = error -> error
      _other -> {:error, :outbound_attachment_read_failed}
    end
  end

  defp media_type(attachment, agent_uid) do
    name =
      optional_text(attachment, "name") || attachment_relative_path(attachment, agent_uid) || ""

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

  # delete (recall)

  defp deliver_delete(%OutboxEntry{target_source_entry_id: nil}),
    do: {:error, :unsupported_target}

  defp deliver_delete(%OutboxEntry{target_source_entry_id: process_query_key} = outbox) do
    with {:ok, config} <- config_for_outbox(outbox),
         client <- Config.client(config),
         {:ok, target} <- resolve_target(outbox) do
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

  # send primitive

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
    {:ok, %{created_source_entry_id: pqk, raw_payload: body}}
  end

  defp send_result({:ok, body}), do: {:ok, %{raw_payload: body}}
  defp send_result({:error, _reason} = error), do: error

  defp combined_result([result], _payload), do: result

  defp combined_result([first | _] = results, _payload) do
    %{
      created_source_entry_id: first[:created_source_entry_id],
      raw_payload: %{"split" => true, "chunks" => Enum.map(results, & &1[:raw_payload])}
    }
  end

  defp combined_result([], _payload), do: %{raw_payload: %{}}

  # helpers

  defp resolve_target(%OutboxEntry{signal_channel_id: signal_channel_id}) do
    conversation_id = decode_channel(signal_channel_id)

    case Repo.get(Channel, signal_channel_id) do
      %Channel{kind: :im_dm, metadata: metadata} ->
        case optional_text(metadata, "dm_user_id") do
          user_id when is_binary(user_id) -> {:ok, {:dm, user_id}}
          nil -> {:error, :dm_recipient_unknown}
        end

      _channel_or_nil ->
        {:ok, {:group, conversation_id}}
    end
  end

  defp decode_channel("dingtalk:" <> encoded), do: URI.decode(encoded)
  defp decode_channel(value), do: value

  defp config_for_outbox(%OutboxEntry{} = outbox) do
    with {:ok, config_ref} <- SignalsGateway.outbox_binding_config_ref(outbox),
         {:ok, config} <- Config.load_chat_config_ref(config_ref) do
      {:ok, config}
    else
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
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
