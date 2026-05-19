defmodule Feishu.Outbound do
  @moduledoc false

  alias Feishu.{ContentMapper, Source}

  @spec deliver(Source.t() | map(), map() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def deliver(source_config, reply_channel, outbound, opts \\ [])
      when is_map(outbound) and is_list(opts) do
    with {:ok, source} <- Source.normalize(source_config) do
      delivery =
        outbound
        |> stringify_keys()
        |> Map.merge(reply_channel_defaults(reply_channel), fn _key,
                                                               outbound_value,
                                                               _reply_value ->
          outbound_value
        end)
        |> put_delivery_id()

      do_deliver(delivery, source, opts)
    end
  end

  @spec reply_text(map(), Source.t(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def reply_text(command, %Source{} = source, text, opts \\ [])
      when is_map(command) and is_binary(text) and is_list(opts) do
    delivery = %{
      "id" => BullX.Ext.gen_uuid_v7(),
      "op" => "send",
      "scope_id" => map_value(command, "chat_id") || map_value(command, "scope_id"),
      "thread_id" => map_value(command, "thread_id"),
      "reply_to_external_id" => map_value(command, "message_id"),
      "content" => [%{"kind" => "text", "body" => %{"text" => text}}]
    }

    do_deliver(delivery, source, opts)
  end

  defp do_deliver(delivery, %Source{} = source, opts) do
    start_time = System.monotonic_time()
    meta = telemetry_meta(delivery, source)

    try do
      :telemetry.execute(
        [:bullx, :event_bus, :adapter, :delivery, :start],
        %{system_time: System.system_time()},
        meta
      )

      result =
        case Keyword.get(opts, :delivery_fun) do
          fun when is_function(fun, 3) -> fun.(delivery, source, opts)
          _other -> deliver_by_op(delivery, source)
        end

      :telemetry.execute(
        [:bullx, :event_bus, :adapter, :delivery, :stop],
        %{duration: System.monotonic_time() - start_time},
        Map.put(meta, :result, telemetry_result(result))
      )

      result
    catch
      kind, reason ->
        :telemetry.execute(
          [:bullx, :event_bus, :adapter, :delivery, :exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(meta, %{kind: kind, reason: inspect(reason)})
        )

        {:error, Feishu.Error.unknown("Feishu delivery failed")}
    end
  end

  defp deliver_by_op(delivery, %Source{} = source) do
    case op(delivery) do
      :send -> send_message(delivery, source)
      :edit -> edit_message(delivery, source)
      :recall -> recall_message(delivery, source)
      other -> {:error, Feishu.Error.unsupported("unsupported Feishu delivery op", %{op: other})}
    end
  end

  defp send_message(delivery, %Source{} = source) do
    with {:ok, rendered, warnings} <- render_content(content(delivery), source, delivery) do
      case do_send(delivery, source, rendered) do
        {:ok, response} ->
          {:ok, outcome(delivery, "sent", response, warnings)}

        {:error, %FeishuOpenAPI.Error{} = error} when rendered.msg_type == "system" ->
          send_system_notice_fallback(delivery, source, warnings, error)

        {:error, %FeishuOpenAPI.Error{} = error} ->
          {:error, Feishu.Error.map(error)}

        {:reply_failed, %FeishuOpenAPI.Error{} = error} ->
          handle_reply_failure(error, delivery, source)
      end
    else
      {:error, error} when is_map(error) ->
        {:error, error}
    end
  end

  defp edit_message(delivery, %Source{} = source) do
    with {:ok, target_id} <- target_external_id(delivery),
         {:ok, rendered, warnings} <-
           render_content(content(delivery), source, delivery, force_text_notice?: true),
         {:ok, response} <-
           FeishuOpenAPI.patch(Source.client!(source), "/open-apis/im/v1/messages/:message_id",
             path_params: %{message_id: target_id},
             body: %{msg_type: rendered.msg_type, content: rendered.content}
           ) do
      {:ok, outcome(delivery, "sent", response, warnings)}
    else
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Feishu.Error.map(error)}
      {:error, error} when is_map(error) -> {:error, error}
    end
  end

  defp recall_message(delivery, %Source{} = source) do
    with {:ok, target_id} <- target_external_id(delivery),
         {:ok, response} <-
           FeishuOpenAPI.delete(Source.client!(source), "/open-apis/im/v1/messages/:message_id",
             path_params: %{message_id: target_id}
           ) do
      {:ok, outcome(delivery, "recalled", response, [])}
    else
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Feishu.Error.map(error)}
      {:error, error} when is_map(error) -> {:error, error}
    end
  end

  defp do_send(delivery, %Source{} = source, %{msg_type: "system"} = rendered) do
    delivery
    |> Map.put("reply_to_external_id", nil)
    |> send_to_scope(source, rendered)
  end

  defp do_send(delivery, %Source{} = source, rendered) do
    case reply_to_external_id(delivery) do
      reply_id when is_binary(reply_id) and reply_id != "" ->
        case FeishuOpenAPI.post(
               Source.client!(source),
               "/open-apis/im/v1/messages/:message_id/reply",
               path_params: %{message_id: reply_id},
               query: [uuid: delivery_id(delivery)],
               body: %{
                 msg_type: rendered.msg_type,
                 content: rendered.content,
                 uuid: delivery_id(delivery)
               }
             ) do
          {:ok, response} -> {:ok, response}
          {:error, %FeishuOpenAPI.Error{} = error} -> {:reply_failed, error}
        end

      _value ->
        send_to_scope(delivery, source, rendered)
    end
  end

  defp send_to_scope(delivery, %Source{} = source, rendered) do
    with {:ok, scope_id} <- scope_id(delivery) do
      FeishuOpenAPI.post(Source.client!(source), "/open-apis/im/v1/messages",
        query: [receive_id_type: "chat_id", uuid: delivery_id(delivery)],
        body: %{
          receive_id: scope_id,
          msg_type: rendered.msg_type,
          content: rendered.content,
          uuid: delivery_id(delivery)
        }
      )
    end
  end

  defp handle_reply_failure(%FeishuOpenAPI.Error{} = error, delivery, %Source{} = source) do
    case Feishu.Error.reply_target_missing?(error) and present?(map_value(delivery, "scope_id")) do
      true -> send_reply_fallback(delivery, source)
      false -> {:error, Feishu.Error.map(error)}
    end
  end

  defp send_reply_fallback(delivery, %Source{} = source) do
    with {:ok, rendered, warnings} <- render_content(content(delivery), source, delivery),
         fallback_delivery <- Map.put(delivery, "reply_to_external_id", nil),
         {:ok, response} <- send_to_scope(fallback_delivery, source, rendered) do
      {:ok,
       outcome(delivery, "degraded", response, warnings ++ ["reply_target_missing_sent_to_scope"])}
    else
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Feishu.Error.map(error)}
      {:error, error} when is_map(error) -> {:error, error}
    end
  end

  defp send_system_notice_fallback(delivery, %Source{} = source, warnings, error) do
    with {:ok, rendered, fallback_warnings} <-
           render_content(content(delivery), source, delivery, force_text_notice?: true) do
      case do_send(delivery, source, rendered) do
        {:ok, response} ->
          {:ok,
           outcome(
             delivery,
             "degraded",
             response,
             warnings ++ fallback_warnings ++ ["system_notice_failed_degraded_to_text"]
           )}

        {:reply_failed, %FeishuOpenAPI.Error{} = reply_error} ->
          send_rendered_text_to_scope(
            delivery,
            source,
            rendered,
            warnings ++
              fallback_warnings ++
              ["system_notice_failed_degraded_to_text", "reply_target_missing_sent_to_scope"],
            reply_error
          )

        {:error, %FeishuOpenAPI.Error{} = _fallback_error} ->
          {:error, Feishu.Error.map(error)}
      end
    else
      {:error, fallback_error} when is_map(fallback_error) ->
        {:error, fallback_error}
    end
  end

  defp send_rendered_text_to_scope(delivery, %Source{} = source, rendered, warnings, reply_error) do
    case Feishu.Error.reply_target_missing?(reply_error) and
           present?(map_value(delivery, "scope_id")) do
      true ->
        delivery
        |> Map.put("reply_to_external_id", nil)
        |> send_to_scope(source, rendered)
        |> case do
          {:ok, response} -> {:ok, outcome(delivery, "degraded", response, warnings)}
          {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Feishu.Error.map(error)}
        end

      false ->
        {:error, Feishu.Error.map(reply_error)}
    end
  end

  defp render_content(content, source, delivery, opts \\ [])

  defp render_content(nil, _source, _delivery, _opts),
    do: {:error, Feishu.Error.payload("Feishu delivery content is required")}

  defp render_content(content, source, delivery, opts) do
    render_opts =
      opts
      |> Keyword.put_new(:scope_kind, scope_kind(delivery))

    ContentMapper.render_outbound(content, source, render_opts)
  end

  defp outcome(delivery, status, response, warnings) do
    ids =
      case message_id(response) do
        nil -> []
        id -> [id]
      end

    BullX.EventBus.ChannelAdapter.Outcome.build(delivery_id(delivery), status, ids, warnings)
  end

  defp message_id(%{"data" => data}) when is_map(data) do
    Map.get(data, "message_id") ||
      get_in(data, ["message", "message_id"]) ||
      Map.get(data, "open_message_id")
  end

  defp message_id(%{"message_id" => message_id}), do: message_id
  defp message_id(_response), do: nil

  defp op(delivery) do
    case map_value(delivery, "op") do
      "send" -> :send
      :send -> :send
      "edit" -> :edit
      :edit -> :edit
      "recall" -> :recall
      :recall -> :recall
      other -> other
    end
  end

  defp content(delivery), do: map_value(delivery, "content")
  defp delivery_id(delivery), do: map_value(delivery, "id")
  defp reply_to_external_id(delivery), do: map_value(delivery, "reply_to_external_id")

  defp scope_id(delivery) do
    case map_value(delivery, "scope_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, Feishu.Error.payload("Feishu delivery scope_id is required")}
    end
  end

  defp target_external_id(delivery) do
    case map_value(delivery, "target_external_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, Feishu.Error.payload("Feishu delivery requires target_external_id")}
    end
  end

  defp reply_channel_defaults(nil), do: %{}

  defp reply_channel_defaults(reply_channel) when is_map(reply_channel) do
    reply_channel
    |> stringify_keys()
    |> Map.take(["scope_id", "thread_id", "reply_to_external_id", "scope_kind", "chat_type"])
  end

  defp scope_kind(delivery) do
    case map_value(delivery, "scope_kind") || map_value(delivery, "chat_type") do
      "p2p" -> "dm"
      value -> value
    end
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} when is_binary(key) -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(%{} = map), do: stringify_keys(map)
  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value(value), do: value

  defp put_delivery_id(delivery) do
    Map.put(delivery, "id", feishu_delivery_uuid(map_value(delivery, "id")))
  end

  defp feishu_delivery_uuid(id) when is_binary(id) do
    id = String.trim(id)

    case Regex.match?(
           ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/,
           id
         ) do
      true -> String.downcase(id)
      false -> deterministic_delivery_uuid(id)
    end
  end

  defp feishu_delivery_uuid(_id), do: BullX.Ext.gen_uuid_v7()

  defp deterministic_delivery_uuid(""), do: BullX.Ext.gen_uuid_v7()

  defp deterministic_delivery_uuid(id) do
    hash = String.downcase(BullX.Ext.generic_hash(id))

    <<part1::binary-size(8), part2::binary-size(4), _version::binary-size(1),
      part3::binary-size(3), variant_seed::binary-size(1), part4::binary-size(3),
      part5::binary-size(12), _rest::binary>> = hash

    variant =
      variant_seed
      |> String.to_integer(16)
      |> Bitwise.band(0x3)
      |> Kernel.+(0x8)
      |> Integer.to_string(16)

    IO.iodata_to_binary([part1, "-", part2, "-4", part3, "-", variant, part4, "-", part5])
  end

  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp map_value(%_{} = struct, key), do: Map.get(struct, String.to_atom(key))
  defp map_value(_value, _key), do: nil

  defp telemetry_meta(delivery, %Source{} = source) do
    %{
      source_id: source.id,
      adapter_id: "feishu",
      op: op(delivery),
      delivery_id: map_value(delivery, "id"),
      scope_id: map_value(delivery, "scope_id")
    }
  end

  defp telemetry_result({:ok, _outcome}), do: :ok
  defp telemetry_result({:error, %{"kind" => kind}}) when is_binary(kind), do: kind
  defp telemetry_result(_result), do: :error

  defp present?(value), do: is_binary(value) and value != ""
end
