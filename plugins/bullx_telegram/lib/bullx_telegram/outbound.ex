defmodule BullxTelegram.Outbound do
  @moduledoc false

  alias BullxTelegram.{ContentMapper, Error, Source}

  import BullX.Utils.Map, only: [maybe_put: 3]

  @hard_limit 4_096

  @spec deliver(Source.t() | map(), map() | nil, map(), keyword()) :: {:ok, map()} | {:error, map()}
  def deliver(source_config, reply_channel, outbound, opts \\ [])
      when is_map(outbound) and is_list(opts) do
    with {:ok, source} <- Source.normalize(source_config) do
      delivery =
        outbound
        |> stringify_keys()
        |> Map.merge(reply_channel_defaults(reply_channel), fn _key, outbound_value, _reply_value ->
          outbound_value
        end)
        |> put_delivery_id()

      do_deliver(delivery, source, opts)
    end
  end

  @spec reply_text(map(), Source.t(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def reply_text(command, %Source{} = source, text, opts \\ []) do
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
    case Keyword.get(opts, :delivery_fun) do
      fun when is_function(fun, 3) -> fun.(delivery, source, opts)
      _value -> deliver_by_op(delivery, source)
    end
  catch
    _kind, _reason -> {:error, Error.unknown("Telegram delivery failed")}
  end

  defp deliver_by_op(delivery, source) do
    case op(delivery) do
      :send -> send_message(delivery, source)
      :edit -> edit_message(delivery, source)
      other -> {:error, Error.unsupported("unsupported Telegram delivery op", %{op: inspect(other)})}
    end
  end

  defp send_message(delivery, %Source{} = source) do
    with {:ok, texts, warnings} <- ContentMapper.render_outbound(content(delivery)),
         {:ok, responses} <- send_texts(texts, delivery, source, true) do
      {:ok, outcome(delivery, "sent", responses, warnings)}
    else
      {:reply_failed, error} -> handle_reply_failure(error, delivery, source)
      {:error, %{} = error} -> {:error, Error.map(error)}
      {:error, reason} -> {:error, Error.map(reason)}
    end
  end

  defp edit_message(delivery, %Source{} = source) do
    with {:ok, target_id} <- target_external_id(delivery),
         {:ok, [text], warnings} <- single_edit_text(content(delivery)),
         {:ok, response} <- request(source, "editMessageText", edit_params(delivery, target_id, text)) do
      {:ok, outcome(delivery, "sent", [response], warnings)}
    else
      {:error, error} ->
        case Error.not_modified?(error) do
          true -> {:ok, outcome(delivery, "sent", [], ["message_unchanged"])}
          false -> {:error, Error.map(error)}
        end
    end
  end

  defp send_texts(texts, delivery, source, use_reply?) do
    texts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {text, index}, {:ok, acc} ->
      params = send_params(delivery, text, use_reply? and index == 0)

      case request(source, "sendMessage", params) do
        {:ok, response} -> {:cont, {:ok, [response | acc]}}
        {:error, error} when use_reply? and index == 0 -> {:halt, {:reply_failed, error}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, responses} -> {:ok, Enum.reverse(responses)}
      other -> other
    end
  end

  defp handle_reply_failure(error, delivery, source) do
    case Error.reply_target_missing?(error) and present?(map_value(delivery, "scope_id")) do
      true ->
        with {:ok, texts, warnings} <- ContentMapper.render_outbound(content(delivery)),
             fallback <- Map.put(delivery, "reply_to_external_id", nil),
             {:ok, responses} <- send_texts(texts, fallback, source, false) do
          {:ok,
           outcome(
             delivery,
             "degraded",
             responses,
             warnings ++ ["reply_target_missing_sent_to_scope"]
           )}
        end

      false ->
        {:error, Error.map(error)}
    end
  end

  defp request(source, method, params), do: Source.request(source, method, params)

  defp send_params(delivery, text, use_reply?) do
    %{"chat_id" => map_value(delivery, "scope_id"), "text" => text}
    |> maybe_put("message_thread_id", integer_id(map_value(delivery, "thread_id")))
    |> maybe_put_reply(delivery, use_reply?)
  end

  defp edit_params(delivery, target_id, text) do
    %{
      "chat_id" => map_value(delivery, "scope_id"),
      "message_id" => integer_id(target_id),
      "text" => text
    }
    |> maybe_put("message_thread_id", integer_id(map_value(delivery, "thread_id")))
  end

  defp maybe_put_reply(params, delivery, true) do
    case integer_id(map_value(delivery, "reply_to_external_id")) do
      nil -> params
      message_id -> Map.put(params, "reply_parameters", %{"message_id" => message_id})
    end
  end

  defp maybe_put_reply(params, _delivery, _use_reply?), do: params

  defp single_edit_text(content) do
    with {:ok, [text], warnings} <- ContentMapper.render_outbound(content),
         true <- ContentMapper.utf16_units(text) <= @hard_limit do
      {:ok, [text], warnings}
    else
      false -> {:error, Error.payload("Telegram edit text exceeds 4096 UTF-16 units")}
      {:ok, _texts, _warnings} -> {:error, Error.payload("Telegram edit requires one text message")}
      {:error, error} -> {:error, error}
    end
  end

  defp outcome(delivery, status, responses, warnings) do
    ids = Enum.map(responses, &message_id/1) |> Enum.reject(&is_nil/1)
    BullX.EventBus.ChannelAdapter.Outcome.build(delivery_id(delivery), status, ids, warnings)
  end

  defp message_id(%{"message_id" => id}), do: to_string(id)
  defp message_id(_response), do: nil
  defp op(delivery), do: case(map_value(delivery, "op"), do: ("send" -> :send; :send -> :send; "edit" -> :edit; :edit -> :edit; other -> other))
  defp content(delivery), do: map_value(delivery, "content")
  defp delivery_id(delivery), do: map_value(delivery, "id")

  defp target_external_id(delivery) do
    case map_value(delivery, "target_external_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, Error.payload("Telegram edit requires target_external_id")}
    end
  end

  defp reply_channel_defaults(nil), do: %{}

  defp reply_channel_defaults(reply_channel) when is_map(reply_channel) do
    reply_channel
    |> stringify_keys()
    |> Map.take(["scope_id", "thread_id", "reply_to_external_id"])
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
  defp put_delivery_id(%{"id" => id} = delivery) when is_binary(id) and id != "", do: delivery
  defp put_delivery_id(delivery), do: Map.put(delivery, "id", BullX.Ext.gen_uuid_v7())
  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp map_value(_value, _key), do: nil
  defp integer_id(nil), do: nil
  defp integer_id(value) when is_integer(value), do: value
  defp integer_id(value) when is_binary(value), do: case(Integer.parse(value), do: ({id, ""} -> id; _value -> nil))
  defp present?(value), do: is_binary(value) and value != ""
end
