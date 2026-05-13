defmodule Feishu.StreamingCard do
  @moduledoc false

  alias Feishu.Source

  @streaming_element_id "content"

  @spec stream(term(), Enumerable.t(), Source.t()) :: {:ok, map()} | {:error, map()}
  def stream(delivery, enumerable, %Source{} = source) do
    case Enumerable.impl_for(enumerable) do
      nil -> {:error, Feishu.Error.payload("stream content is not replayable")}
      _impl -> run(delivery, enumerable, source)
    end
  end

  defp run(delivery, enumerable, %Source{} = source) do
    initial_text = BullX.I18n.t("gateway.feishu.delivery.stream_generating")

    with {:ok, card_id} <- create_card(source, initial_text),
         {:ok, message_id} <- send_card(delivery, source, card_id),
         {:ok, text, sequence} <- consume_updates(enumerable, delivery, source, card_id),
         :ok <- finalize_card(source, card_id, text, sequence + 1) do
      {:ok,
       %{
         "delivery_id" => delivery_id(delivery),
         "status" => "sent",
         "external_message_ids" => [message_id],
         "primary_external_id" => message_id,
         "warnings" => []
       }}
    else
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Feishu.Error.map(error)}
      {:error, error} when is_map(error) -> {:error, error}
      {:error, reason} -> {:error, Feishu.Error.map(reason)}
    end
  catch
    kind, reason ->
      {:error,
       Feishu.Error.payload("Feishu stream delivery failed", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end

  defp create_card(%Source{} = source, initial_text) do
    case FeishuOpenAPI.post(Source.client!(source), "cardkit/v1/cards",
           body: %{
             type: "card_json",
             data: Jason.encode!(streaming_card_definition(initial_text))
           }
         ) do
      {:ok, %{"data" => %{"card_id" => card_id}}} when is_binary(card_id) and card_id != "" ->
        {:ok, card_id}

      {:ok, _response} ->
        {:error, Feishu.Error.payload("Feishu CardKit create returned no card_id")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp send_card(delivery, %Source{} = source, card_id) do
    rendered = %{
      msg_type: "interactive",
      content: Jason.encode!(%{type: "card", data: %{card_id: card_id}})
    }

    case reply_to_external_id(delivery) do
      reply_id when is_binary(reply_id) and reply_id != "" ->
        send_card_reply(delivery, source, reply_id, rendered)

      _missing ->
        send_card_to_scope(delivery, source, rendered)
    end
  end

  defp send_card_reply(delivery, %Source{} = source, reply_id, rendered) do
    case FeishuOpenAPI.post(Source.client!(source), "im/v1/messages/:message_id/reply",
           path_params: %{message_id: reply_id},
           query: [uuid: delivery_id(delivery)],
           body: %{
             msg_type: rendered.msg_type,
             content: rendered.content,
             reply_in_thread: false,
             uuid: delivery_id(delivery)
           }
         ) do
      {:ok, response} -> message_id_result(response)
      {:error, error} -> {:error, error}
    end
  end

  defp send_card_to_scope(delivery, %Source{} = source, rendered) do
    with {:ok, scope_id} <- scope_id(delivery) do
      case FeishuOpenAPI.post(Source.client!(source), "im/v1/messages",
             query: [receive_id_type: "chat_id", uuid: delivery_id(delivery)],
             body: %{
               receive_id: scope_id,
               msg_type: rendered.msg_type,
               content: rendered.content,
               uuid: delivery_id(delivery)
             }
           ) do
        {:ok, response} -> message_id_result(response)
        {:error, error} -> {:error, error}
      end
    end
  end

  defp consume_updates(enumerable, delivery, %Source{} = source, card_id) do
    start_state = %{text: "", sequence: 0, last_update_ms: 0}

    enumerable
    |> Enum.reduce_while(start_state, fn chunk, state ->
      state = apply_chunk(state, chunk)

      case due_update?(state, source) do
        true -> put_card_content(delivery, source, card_id, state)
        false -> {:cont, state}
      end
    end)
    |> flush_final_update(delivery, source, card_id)
  catch
    kind, reason ->
      failed_text = BullX.I18n.t("gateway.feishu.delivery.stream_failed")
      _result = finalize_card(source, card_id, failed_text, 1)

      {:error,
       Feishu.Error.payload("Feishu stream delivery failed", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end

  defp flush_final_update({:error, _error} = error, _delivery, _source, _card_id), do: error

  defp flush_final_update(state, delivery, %Source{} = source, card_id) do
    text = stream_text(state.text)

    case put_card_content(delivery, source, card_id, %{state | text: text}, force?: true) do
      {:cont, %{text: text, sequence: sequence}} -> {:ok, text, sequence}
      {:halt, {:error, error}} -> {:error, error}
    end
  end

  defp put_card_content(delivery, %Source{} = source, card_id, state) do
    put_card_content(delivery, source, card_id, state, [])
  end

  defp put_card_content(_delivery, %Source{} = source, card_id, state, _opts) do
    sequence = state.sequence + 1
    text = stream_text(state.text)

    case FeishuOpenAPI.put(
           Source.client!(source),
           "cardkit/v1/cards/:card_id/elements/:element_id/content",
           path_params: %{card_id: card_id, element_id: @streaming_element_id},
           body: %{
             content: text,
             sequence: sequence,
             uuid: BullX.Ext.gen_uuid_v7()
           }
         ) do
      {:ok, _response} ->
        {:cont,
         %{
           state
           | text: text,
             sequence: sequence,
             last_update_ms: System.monotonic_time(:millisecond)
         }}

      {:error, error} ->
        {:halt, {:error, Feishu.Error.map(error)}}
    end
  end

  defp finalize_card(%Source{} = source, card_id, text, sequence) do
    summary = truncate_summary(stream_text(text))

    case FeishuOpenAPI.patch(Source.client!(source), "cardkit/v1/cards/:card_id/settings",
           path_params: %{card_id: card_id},
           body: %{
             settings:
               Jason.encode!(%{
                 config: %{
                   streaming_mode: false,
                   summary: %{content: summary}
                 }
               }),
             sequence: sequence,
             uuid: BullX.Ext.gen_uuid_v7()
           }
         ) do
      {:ok, _response} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp apply_chunk(state, %{"replace_text" => text}) when is_binary(text) do
    %{state | text: text}
  end

  defp apply_chunk(state, %{"text" => text}) when is_binary(text) do
    %{state | text: state.text <> text}
  end

  defp apply_chunk(state, %{replace_text: text}) when is_binary(text) do
    %{state | text: text}
  end

  defp apply_chunk(state, %{text: text}) when is_binary(text) do
    %{state | text: state.text <> text}
  end

  defp apply_chunk(state, text) when is_binary(text), do: %{state | text: state.text <> text}
  defp apply_chunk(state, _chunk), do: state

  defp due_update?(%{last_update_ms: 0}, _source), do: true

  defp due_update?(%{last_update_ms: last_update_ms}, %Source{} = source) do
    System.monotonic_time(:millisecond) - last_update_ms >= source.stream_update_interval_ms
  end

  defp streaming_card_definition(initial_text) do
    %{
      schema: "2.0",
      config: %{
        wide_screen_mode: true,
        streaming_mode: true,
        summary: %{content: BullX.I18n.t("gateway.feishu.delivery.stream_generating")},
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

  defp message_id_result(response) do
    case message_id(response) do
      message_id when is_binary(message_id) and message_id != "" -> {:ok, message_id}
      _missing -> {:error, Feishu.Error.payload("Feishu streaming card send returned no message_id")}
    end
  end

  defp message_id(%{"data" => data}) when is_map(data) do
    Map.get(data, "message_id") ||
      get_in(data, ["message", "message_id"]) ||
      Map.get(data, "open_message_id")
  end

  defp message_id(%{"message_id" => message_id}), do: message_id
  defp message_id(_response), do: nil

  defp stream_text(""), do: BullX.I18n.t("gateway.feishu.delivery.stream_generating")
  defp stream_text(text), do: text

  defp truncate_summary(text) when is_binary(text) do
    normalized = text |> String.replace(~r/\s+/, " ") |> String.trim()

    case String.length(normalized) <= 80 do
      true -> normalized
      false -> String.slice(normalized, 0, 77) <> "..."
    end
  end

  defp delivery_id(delivery), do: map_value(delivery, "id") || BullX.Ext.gen_uuid_v7()
  defp reply_to_external_id(delivery), do: map_value(delivery, "reply_to_external_id")

  defp scope_id(delivery) do
    case map_value(delivery, "scope_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, Feishu.Error.payload("Feishu delivery scope_id is required")}
    end
  end

  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp map_value(%_{} = struct, key), do: Map.get(struct, String.to_atom(key))
  defp map_value(_value, _key), do: nil
end
