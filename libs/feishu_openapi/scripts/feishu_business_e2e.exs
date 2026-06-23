defmodule FeishuOpenAPIBusinessE2E do
  @moduledoc false

  import Bitwise

  require Logger

  alias FeishuOpenAPI.Event
  alias FeishuOpenAPI.Event.Dispatcher

  @default_download_root Path.join(System.tmp_dir!(), "feishu_oapi_business_e2e")
  @streaming_element_id "content"
  @required_env_vars ~w(FEISHU_APP_ID FEISHU_APP_SECRET)

  def run do
    Logger.configure(level: :info)

    env = load_env!()
    ensure_seen_store!()

    config = %{
      download_root: Map.get(env, "FEISHU_E2E_DOWNLOAD_DIR", @default_download_root)
    }

    client = FeishuOpenAPI.new(env["FEISHU_APP_ID"], env["FEISHU_APP_SECRET"])

    dispatcher = build_dispatcher(client, config)

    {:ok, _pid} =
      FeishuOpenAPI.WS.Client.start_link(
        client: client,
        dispatcher: dispatcher,
        auto_reconnect: true
      )

    Logger.info("""
    feishu business e2e listener started
    download_root=#{config.download_root}

    manual scenarios:
      1. by default, any received message runs the full REST + CardKit flow
      2. send an image or file message to exercise message-resource download
      3. add/remove a reaction or recall a message to observe WS event delivery
    """)

    wait_forever()
  end

  defp build_dispatcher(client, config) do
    Dispatcher.new()
    |> Dispatcher.on("im.message.receive_v1", fn _event_type, event ->
      Task.start(fn -> handle_receive(client, config, event) end)
      :ok
    end)
    |> Dispatcher.on("im.message.recalled_v1", fn _event_type, event ->
      Logger.info("received recalled event: #{inspect(event.content)}")
      :ok
    end)
    |> Dispatcher.on("im.message.reaction.created_v1", fn _event_type, event ->
      Logger.info("received reaction-created event: #{inspect(event.content)}")
      :ok
    end)
    |> Dispatcher.on("im.message.reaction.deleted_v1", fn _event_type, event ->
      Logger.info("received reaction-deleted event: #{inspect(event.content)}")
      :ok
    end)
  end

  defp handle_receive(client, config, %Event{content: content})
       when is_map(content) do
    message = Map.get(content, "message") || %{}
    sender = Map.get(content, "sender") || %{}
    sender_user_id = get_in(sender, ["sender_id", "user_id"])
    sender_type = Map.get(sender, "sender_type")
    message_id = Map.get(message, "message_id")
    chat_id = Map.get(message, "chat_id")
    parent_message_id = Map.get(message, "parent_id")
    msg_type = Map.get(message, "message_type")
    raw_content = Map.get(message, "content")

    Logger.info(
      "received message event message_id=#{inspect(message_id)} chat_id=#{inspect(chat_id)} " <>
        "type=#{inspect(msg_type)} sender_type=#{inspect(sender_type)} " <>
        "sender_user_id=#{inspect(sender_user_id)} " <>
        "parent_message_id=#{inspect(parent_message_id)}"
    )

    maybe_download_message_resource(client, config, message_id, msg_type, raw_content)

    with true <- user_sender?(sender_type),
         true <- first_trigger_for?(message_id) do
      Logger.info("matched e2e receive trigger message_id=#{inspect(message_id)}")

      if is_binary(sender_user_id) do
        run_business_flow(client, config, message_id, chat_id, sender_user_id, parent_message_id)
      else
        Logger.warning("triggered message #{inspect(message_id)} is missing sender.user_id")
      end
    end
  rescue
    exception ->
      Logger.error("receive handler crashed: " <> Exception.format(:error, exception, __STACKTRACE__))
  end

  defp handle_receive(_client, _config, event) do
    Logger.warning("unexpected receive event payload: #{inspect(event)}")
    :ok
  end

  defp run_business_flow(client, config, message_id, chat_id, sender_user_id, parent_message_id) do
    Logger.info(
      "running business e2e flow for message_id=#{message_id} chat_id=#{inspect(chat_id)} " <>
        "sender_user_id=#{sender_user_id} parent_message_id=#{inspect(parent_message_id)}"
    )

    message_record = fetch_message_record!(client, message_id)
    effective_chat_id = message_record["chat_id"] || chat_id || raise("message #{message_id} missing chat_id")
    user = fetch_user!(client, sender_user_id)
    chat = fetch_chat!(client, effective_chat_id)

    maybe_download_message_record_resource(client, config, message_id, message_record)

    parent_message_record =
      if is_binary(parent_message_id) do
        record = fetch_message_record!(client, parent_message_id)
        maybe_download_message_record_resource(client, config, parent_message_id, record)
        record
      end

    created_message_id =
      create_text_message!(
        client,
        effective_chat_id,
        "[feishu_oapi e2e] create_message ok for #{message_id}"
      )

    delete_message!(client, created_message_id)

    reply_message_id =
      reply_interactive_card!(
        client,
        message_id,
        build_summary_card_markdown(
          user,
          chat,
          message_record,
          parent_message_record,
          "REST lookup + reply card OK"
        )
      )

    update_card_message!(
      client,
      reply_message_id,
      build_summary_card_markdown(
        user,
        chat,
        message_record,
        parent_message_record,
        "REST lookup + update card OK"
      )
    )

    {stream_message_id, card_id} =
      run_streaming_card_flow!(
        client,
        message_id,
        build_streaming_updates(user, chat, message_record, parent_message_record)
      )

    Logger.info("""
    business e2e flow finished
      source_message_id=#{message_id}
      created_message_id=#{created_message_id}
      reply_message_id=#{reply_message_id}
      stream_message_id=#{stream_message_id}
      card_id=#{card_id}
    """)
  rescue
    exception ->
      Logger.error(
        "business e2e flow failed for message_id=#{inspect(message_id)}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )
  end

  defp fetch_user!(client, user_id) do
    response =
      FeishuOpenAPI.get!(
        client,
        "contact/v3/users/:user_id",
        path_params: %{user_id: user_id},
        query: [user_id_type: "user_id"]
      )

    get_in(response, ["data", "user"]) || raise("contact/v3/users/#{user_id} returned no user")
  end

  defp fetch_message_record!(client, message_id) do
    response =
      FeishuOpenAPI.get!(
        client,
        "im/v1/messages/:message_id",
        path_params: %{message_id: message_id},
        query: [user_id_type: "user_id"]
      )

    case get_in(response, ["data", "items"]) do
      [record | _] when is_map(record) -> record
      _ -> raise("im/v1/messages/#{message_id} returned no items")
    end
  end

  defp fetch_chat!(client, chat_id) do
    response =
      FeishuOpenAPI.get!(
        client,
        "im/v1/chats/:chat_id",
        path_params: %{chat_id: chat_id},
        query: [user_id_type: "user_id"]
      )

    get_in(response, ["data"]) || raise("im/v1/chats/#{chat_id} returned no data")
  end

  defp create_text_message!(client, chat_id, text) do
    response =
      FeishuOpenAPI.post!(
        client,
        "im/v1/messages",
        query: [receive_id_type: "chat_id"],
        body: %{
          receive_id: chat_id,
          msg_type: "text",
          content: text_content(text),
          uuid: uuid4()
        }
      )

    get_in(response, ["data", "message_id"]) || raise("create message returned no message_id")
  end

  defp update_card_message!(client, message_id, markdown) do
    FeishuOpenAPI.put!(
      client,
      "im/v1/messages/:message_id",
      path_params: %{message_id: message_id},
      body: %{msg_type: "interactive", content: Torque.encode!(build_markdown_card(markdown))}
    )

    :ok
  end

  defp delete_message!(client, message_id) do
    FeishuOpenAPI.delete!(
      client,
      "im/v1/messages/:message_id",
      path_params: %{message_id: message_id}
    )

    :ok
  end

  defp reply_interactive_card!(client, message_id, markdown) do
    response =
      FeishuOpenAPI.post!(
        client,
        "im/v1/messages/:message_id/reply",
        path_params: %{message_id: message_id},
        body: %{
          msg_type: "interactive",
          content: Torque.encode!(build_markdown_card(markdown)),
          reply_in_thread: false,
          uuid: uuid4()
        }
      )

    get_in(response, ["data", "message_id"]) || raise("reply message returned no message_id")
  end

  defp run_streaming_card_flow!(client, source_message_id, updates) when is_list(updates) do
    create_response =
      FeishuOpenAPI.post!(
        client,
        "cardkit/v1/cards",
        body: %{
          type: "card_json",
          data: Torque.encode!(build_streaming_card_definition(List.first(updates)))
        }
      )

    card_id = get_in(create_response, ["data", "card_id"]) || raise("card create returned no card_id")

    reply_response =
      FeishuOpenAPI.post!(
        client,
        "im/v1/messages/:message_id/reply",
        path_params: %{message_id: source_message_id},
        body: %{
          msg_type: "interactive",
          content: Torque.encode!(%{type: "card", data: %{card_id: card_id}}),
          reply_in_thread: false,
          uuid: uuid4()
        }
      )

    stream_message_id =
      get_in(reply_response, ["data", "message_id"]) ||
        raise("streaming card reply returned no message_id")

    updates
    |> Enum.with_index(1)
    |> Enum.each(fn {content, sequence} ->
      Process.sleep(600)

      FeishuOpenAPI.put!(
        client,
        "cardkit/v1/cards/:card_id/elements/:element_id/content",
        path_params: %{card_id: card_id, element_id: @streaming_element_id},
        body: %{
          content: content,
          sequence: sequence,
          uuid: uuid4()
        }
      )
    end)

    final_summary = truncate_summary(List.last(updates))

    FeishuOpenAPI.patch!(
      client,
      "cardkit/v1/cards/:card_id/settings",
      path_params: %{card_id: card_id},
      body: %{
        settings: Torque.encode!(%{
          config: %{
            streaming_mode: false,
            summary: %{content: final_summary}
          }
        }),
        sequence: length(updates) + 1,
        uuid: uuid4()
      }
    )

    {stream_message_id, card_id}
  end

  defp maybe_download_message_resource(_client, _config, nil, _msg_type, _raw_content), do: :ok
  defp maybe_download_message_resource(_client, _config, _message_id, nil, _raw_content), do: :ok
  defp maybe_download_message_resource(_client, _config, _message_id, _msg_type, nil), do: :ok

  defp maybe_download_message_resource(client, config, message_id, msg_type, raw_content) do
    case resource_from_message(msg_type, raw_content) do
      {:ok, resource_type, file_key} ->
        path = download_resource!(client, config, message_id, file_key, resource_type)

        Logger.info(
          "downloaded receive_v1 resource message_id=#{message_id} file_key=#{file_key} path=#{path}"
        )

      :skip ->
        :ok
    end
  rescue
    exception ->
      Logger.error(
        "resource download failed for receive_v1 message_id=#{inspect(message_id)}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )
    end

  defp maybe_download_message_record_resource(client, config, message_id, record) when is_map(record) do
    msg_type = Map.get(record, "msg_type")
    raw_content = get_in(record, ["body", "content"])
    maybe_download_message_resource(client, config, message_id, msg_type, raw_content)
  end

  defp user_sender?(nil), do: true
  defp user_sender?("user"), do: true
  defp user_sender?(_other), do: false

  defp resource_from_message("image", raw_content) do
    with {:ok, %{"image_key" => file_key}} when is_binary(file_key) <- Torque.decode(raw_content) do
      {:ok, "image", file_key}
    else
      _ -> :skip
    end
  end

  defp resource_from_message("file", raw_content) do
    with {:ok, %{"file_key" => file_key}} when is_binary(file_key) <- Torque.decode(raw_content) do
      {:ok, "file", file_key}
    else
      _ -> :skip
    end
  end

  defp resource_from_message(_msg_type, _raw_content), do: :skip

  defp download_resource!(client, config, message_id, file_key, resource_type) do
    path =
      Path.join([
        config.download_root,
        sanitize_path_segment(message_id),
        sanitize_path_segment(file_key)
      ])

    File.mkdir_p!(Path.dirname(path))

    %{body: body, filename: filename} =
      case FeishuOpenAPI.download(
             client,
             "im/v1/messages/:message_id/resources/:file_key",
             path_params: %{message_id: message_id, file_key: file_key},
             query: [type: resource_type]
           ) do
        {:ok, result} ->
          result

        {:error, error} ->
          raise error
      end

    target =
      case filename do
        nil -> path
        name -> path <> "-" <> sanitize_path_segment(name)
      end

    File.write!(target, body)
    target
  end

  defp build_summary_card_markdown(
         user,
         chat,
         message_record,
         parent_message_record,
         status_line
       ) do
    sender_name =
      Map.get(user, "name") ||
        Map.get(user, "en_name") ||
        Map.get(user, "mobile") ||
        Map.get(user, "user_id") ||
        "unknown"

    chat_name = Map.get(chat, "name") || Map.get(chat, "chat_id") || "unknown"
    msg_type = Map.get(message_record, "msg_type") || "unknown"
    parent_msg_type = parent_message_record && Map.get(parent_message_record, "msg_type")

    """
    **feishu_oapi business e2e**

    - sender: #{sender_name}
    - chat: #{chat_name}
    - msg_type: #{msg_type}
    - parent_msg_type: #{parent_msg_type || "none"}
    - status: #{status_line}
    """
  end

  defp build_streaming_updates(user, chat, message_record, parent_message_record) do
    sender_name =
      Map.get(user, "name") ||
        Map.get(user, "en_name") ||
        Map.get(user, "mobile") ||
        "unknown"

    chat_name = Map.get(chat, "name") || Map.get(chat, "chat_id") || "unknown"
    msg_type = Map.get(message_record, "msg_type") || "unknown"
    parent_msg_type = parent_message_record && Map.get(parent_message_record, "msg_type")

    [
      "streaming step 1: sender=#{sender_name}",
      "streaming step 2: chat=#{chat_name}",
      "streaming step 3: msg_type=#{msg_type}",
      "streaming step 4: parent_msg_type=#{parent_msg_type || "none"}",
      "streaming step 5: cardkit content/settings flow finished"
    ]
  end

  defp build_markdown_card(markdown) do
    %{
      schema: "2.0",
      config: %{wide_screen_mode: true, update_multi: true},
      body: %{
        elements: [
          %{
            tag: "markdown",
            content: markdown
          }
        ]
      }
    }
  end

  defp build_streaming_card_definition(initial_text) do
    %{
      schema: "2.0",
      config: %{
        wide_screen_mode: true,
        streaming_mode: true,
        summary: %{content: "[Generating...]"},
        streaming_config: %{
          print_frequency_ms: %{default: 70, android: 70, ios: 70, pc: 70},
          print_step: %{default: 1, android: 1, ios: 1, pc: 1},
          print_strategy: "fast"
        }
      },
      body: %{
        elements: [
          %{
            tag: "markdown",
            content: initial_text,
            element_id: @streaming_element_id
          }
        ]
      }
    }
  end

  defp text_content(text), do: Torque.encode!(%{text: text})

  defp truncate_summary(text) when is_binary(text) do
    normalized = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(normalized) <= 80 do
      normalized
    else
      String.slice(normalized, 0, 77) <> "..."
    end
  end

  defp truncate_summary(_text), do: "feishu_oapi business e2e"

  defp sanitize_path_segment(value) when is_binary(value) do
    String.replace(value, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]) |> IO.iodata_to_binary()
  end

  defp ensure_seen_store! do
    case Process.whereis(__MODULE__.SeenStore) do
      nil -> Agent.start_link(fn -> MapSet.new() end, name: __MODULE__.SeenStore)
      _pid -> {:ok, __MODULE__.SeenStore}
    end

    :ok
  end

  defp first_trigger_for?(nil), do: false

  defp first_trigger_for?(message_id) when is_binary(message_id) do
    Agent.get_and_update(__MODULE__.SeenStore, fn seen ->
      if MapSet.member?(seen, message_id) do
        {false, seen}
      else
        {true, MapSet.put(seen, message_id)}
      end
    end)
  end

  defp load_env! do
    path = Path.expand(".env.local", File.cwd!())

    unless File.exists?(path) do
      raise ".env.local not found at #{path}"
    end

    env =
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        case parse_env_line(line) do
          nil -> acc
          {key, value} -> Map.put(acc, key, value)
        end
      end)

    Enum.each(@required_env_vars, fn key ->
      unless is_binary(env[key]) and env[key] != "" do
        raise ".env.lcoal is missing required key #{key}"
      end
    end)

    env
  end

  defp parse_env_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        nil

      String.starts_with?(trimmed, "#") ->
        nil

      true ->
        case Regex.run(~r/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/, trimmed, capture: :all_but_first) do
          [key, raw_value] -> {key, parse_env_value(String.trim(raw_value))}
          _ -> nil
        end
    end
  end

  defp parse_env_value("\"" <> raw) do
    raw
    |> String.trim_trailing()
    |> String.trim_trailing("\"")
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp parse_env_value("'" <> raw) do
    raw
    |> String.trim_trailing()
    |> String.trim_trailing("'")
  end

  defp parse_env_value(raw) do
    raw
    |> String.split(~r/\s+#/, parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp wait_forever do
    receive do
    after
      :infinity -> :ok
    end
  end
end

FeishuOpenAPIBusinessE2E.run()
