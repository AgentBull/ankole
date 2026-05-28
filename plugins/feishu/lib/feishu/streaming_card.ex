defmodule Feishu.StreamingCard do
  @moduledoc false

  alias Feishu.Source

  @streaming_element_id "content"

  @spec consume(Source.t() | map(), map(), String.t(), keyword()) :: :ok | {:error, map()}
  def consume(source_config, reply_address, stream_id, opts \\ [])
      when is_map(reply_address) and is_binary(stream_id) and is_list(opts) do
    with {:ok, source} <- Source.normalize(source_config),
         {:ok, card_id, message_id} <-
           create_and_send_card(source, reply_address, stream_id, opts),
         :ok <- notify_delivery(opts, stream_id, card_id, message_id),
         :ok <- consume_stream(source, card_id, stream_id, opts) do
      :telemetry.execute(
        [:bullx, :im_gateway, :adapter, :stream, :delivered],
        %{count: 1},
        %{
          adapter_id: "feishu",
          source_id: source.id,
          stream_id: stream_id,
          card_id: card_id,
          message_id: message_id
        }
      )

      :ok
    else
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Feishu.Error.map(error)}
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, Feishu.Error.map(reason)}
    end
  end

  defp create_and_send_card(%Source{} = source, reply_address, stream_id, opts) do
    initial_text = BullX.I18n.t("im_gateway.feishu.delivery.stream_thinking")

    with {:ok, card_id} <- create_card(source, initial_text),
         outbound <- card_outbound(stream_id, card_id, reply_address),
         {:ok, result} <- send_card_outbound(source, reply_address, outbound, opts),
         message_id when is_binary(message_id) <- Map.get(result, "primary_external_id") do
      {:ok, card_id, message_id}
    else
      nil -> {:error, Feishu.Error.payload("Feishu streaming card send returned no message_id")}
      {:error, _error} = error -> error
    end
  end

  defp send_card_outbound(%Source{} = source, reply_address, outbound, opts) do
    case Keyword.get(opts, :persist_outbound?, false) do
      true ->
        outbound
        |> Map.put("reply_address", reply_address)
        |> Map.put("provider_occurrence_id", outbound["id"])
        |> Map.put("actor_kind", "agent")
        |> Map.put("actor_principal_id", Keyword.get(opts, :actor_principal_id))
        |> BullX.IMGateway.send_message(Keyword.delete(opts, :persist_outbound?))
        |> case do
          {:ok, %{delivery: delivery}} -> {:ok, delivery}
          {:error, %{reason: reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end

      false ->
        Feishu.Outbound.deliver(source, reply_address, outbound, opts)
    end
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

  defp notify_delivery(opts, stream_id, card_id, message_id) do
    case Keyword.get(opts, :delivery_update_fun) do
      fun when is_function(fun, 1) ->
        _result =
          fun.(%{
            "delivery_id" => stream_id,
            "status" => "sent",
            "primary_external_id" => message_id,
            "external_message_ids" => [message_id],
            "card_id" => card_id
          })

        :ok

      _missing ->
        :ok
    end
  end

  defp consume_stream(%Source{} = source, card_id, stream_id, opts) do
    streaming = Keyword.get(opts, :streaming_output, BullX.MailBox.StreamingOutput)
    update_fun = Keyword.get(opts, :card_update_fun, &put_card_content/4)
    replace_fun = Keyword.get(opts, :card_replace_content_fun, &replace_card_content_element/4)
    finalize_fun = Keyword.get(opts, :card_finalize_fun, &finalize_card/4)
    state = initial_state()

    case consume_stream_to_state(
           streaming,
           stream_id,
           state,
           source,
           card_id,
           update_fun,
           replace_fun
         ) do
      {:ok, state} ->
        finalize_success(source, card_id, state, update_fun, replace_fun, finalize_fun)

      {:error, reason, state} ->
        close_after_failure(source, card_id, state, reason, update_fun, replace_fun, finalize_fun)
        {:error, reason}
    end
  end

  defp consume_stream_to_state(
         streaming,
         stream_id,
         state,
         source,
         card_id,
         update_fun,
         replace_fun
       ) do
    with {:ok, resume} <- streaming.resume_stream(stream_id, nil),
         state <- %{state | terminal_status: terminal_status(resume.status)},
         {:ok, state} <-
           apply_resume_chunks(resume.chunks, state, source, card_id, update_fun, replace_fun),
         {:ok, state} <-
           maybe_follow_stream(
             streaming,
             resume.follow?,
             stream_id,
             state,
             source,
             card_id,
             update_fun,
             replace_fun
           ) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp apply_resume_chunks(chunks, state, source, card_id, update_fun, replace_fun) do
    Enum.reduce_while(chunks, {:ok, state}, fn chunk, {:ok, acc} ->
      acc =
        chunk
        |> chunk_payload()
        |> then(&apply_chunk(acc, &1))
        |> put_last_offset(chunk_offset(chunk))

      case due_update?(acc, source) do
        true ->
          case update_state(source, card_id, acc, update_fun, replace_fun) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            {:error, error} -> {:halt, {:error, error}}
          end

        false ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp maybe_follow_stream(
         _streaming,
         false,
         _stream_id,
         state,
         _source,
         _card_id,
         _update_fun,
         _replace_fun
       ),
       do: {:ok, state}

  defp maybe_follow_stream(
         streaming,
         true,
         stream_id,
         state,
         source,
         card_id,
         update_fun,
         replace_fun
       ) do
    parent = self()
    message_ref = make_ref()

    consumer = fn
      %{type: :chunk} = chunk ->
        send(parent, {message_ref, chunk})

      %{type: :terminal, status: status} ->
        send(parent, {message_ref, %{type: :terminal, status: status}})
    end

    task = Task.async(fn -> streaming.follow_stream(stream_id, state.last_offset, consumer) end)
    drain_follow_messages(task, message_ref, state, source, card_id, update_fun, replace_fun)
  end

  defp drain_follow_messages(task, message_ref, state, source, card_id, update_fun, replace_fun) do
    receive do
      {^message_ref, %{type: :chunk} = event} ->
        state =
          event
          |> Map.get(:chunk)
          |> then(&apply_chunk(state, &1))
          |> put_last_offset(Map.get(event, :offset))

        with {:ok, state} <- maybe_update_state(source, card_id, state, update_fun, replace_fun) do
          drain_follow_messages(
            task,
            message_ref,
            state,
            source,
            card_id,
            update_fun,
            replace_fun
          )
        else
          {:error, reason} ->
            Task.shutdown(task, :brutal_kill)
            {:error, reason}
        end

      {^message_ref, %{type: :terminal, status: status}} ->
        drain_follow_messages(
          task,
          message_ref,
          %{state | terminal_status: terminal_status(status)},
          source,
          card_id,
          update_fun,
          replace_fun
        )

      {ref, :ok} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        {:ok, state}

      {ref, {:error, reason}} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        {:error, reason}

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        {:error, reason}
    end
  end

  defp maybe_update_state(source, card_id, state, update_fun, replace_fun) do
    case due_update?(state, source) do
      true -> update_state(source, card_id, state, update_fun, replace_fun)
      false -> {:ok, state}
    end
  end

  defp initial_state do
    %{
      text: "",
      sequence: 0,
      last_update_ms: 0,
      last_offset: -1,
      terminal_status: nil,
      content_element_ready?: false
    }
  end

  defp chunk_payload(%{chunk: chunk}), do: chunk
  defp chunk_payload(%{"chunk" => chunk}), do: chunk
  defp chunk_payload(chunk), do: chunk

  defp chunk_offset(%{offset: offset}) when is_integer(offset), do: offset
  defp chunk_offset(%{"offset" => offset}) when is_integer(offset), do: offset
  defp chunk_offset(_chunk), do: nil

  defp put_last_offset(state, offset) when is_integer(offset), do: %{state | last_offset: offset}
  defp put_last_offset(state, _offset), do: state

  defp terminal_status(:completed), do: nil
  defp terminal_status(:failed), do: :failed
  defp terminal_status(:interrupted), do: :interrupted
  defp terminal_status(_status), do: nil

  defp final_text(%{terminal_status: :failed}),
    do: BullX.I18n.t("im_gateway.feishu.delivery.stream_failed")

  defp final_text(%{terminal_status: :interrupted}),
    do: BullX.I18n.t("im_gateway.feishu.delivery.stream_cancelled")

  defp final_text(%{text: ""}),
    do: BullX.I18n.t("im_gateway.feishu.delivery.stream_completed_empty")

  defp final_text(%{text: text}), do: stream_text(text)

  defp close_after_failure(source, card_id, state, reason, update_fun, replace_fun, finalize_fun) do
    text = failure_text(reason)
    state = maybe_write_final_text(source, card_id, state, text, update_fun, replace_fun)

    _result = finalize_fun.(source, card_id, text, state.sequence + 1)
    :ok
  end

  defp failure_text(:interrupted), do: BullX.I18n.t("im_gateway.feishu.delivery.stream_cancelled")
  defp failure_text(_reason), do: BullX.I18n.t("im_gateway.feishu.delivery.stream_failed")

  defp finalize_success(source, card_id, state, update_fun, replace_fun, finalize_fun) do
    text = final_text(state)
    state = maybe_write_final_text(source, card_id, state, text, update_fun, replace_fun)

    finalize_fun.(source, card_id, text, state.sequence + 1)
  end

  defp maybe_write_final_text(source, card_id, state, text, update_fun, replace_fun) do
    case write_card_text(source, card_id, state, text, update_fun, replace_fun) do
      {:ok, state} -> state
      {:error, _error} -> state
    end
  end

  defp update_state(source, card_id, state, update_fun, replace_fun) do
    text = stream_text(state.text)

    case write_card_text(source, card_id, state, text, update_fun, replace_fun) do
      {:ok, state} ->
        {:ok, %{state | last_update_ms: System.monotonic_time(:millisecond)}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp write_card_text(source, card_id, state, text, update_fun, replace_fun) do
    sequence = state.sequence + 1

    case put_card_text(source, card_id, text, sequence, state, update_fun, replace_fun) do
      :ok ->
        {:ok,
         %{
           state
           | sequence: sequence,
             content_element_ready?: true
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp put_card_text(
         source,
         card_id,
         text,
         sequence,
         %{content_element_ready?: true},
         update_fun,
         _replace_fun
       ),
       do: update_fun.(source, card_id, text, sequence)

  defp put_card_text(source, card_id, text, sequence, _state, _update_fun, replace_fun),
    do: replace_fun.(source, card_id, text, sequence)

  defp put_card_content(%Source{} = source, card_id, text, sequence) do
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
      {:ok, _response} -> :ok
      {:error, error} -> {:error, Feishu.Error.map(error)}
    end
  end

  defp replace_card_content_element(%Source{} = source, card_id, text, sequence) do
    case FeishuOpenAPI.put(
           Source.client!(source),
           "cardkit/v1/cards/:card_id/elements/:element_id",
           path_params: %{card_id: card_id, element_id: @streaming_element_id},
           body: %{
             element: Jason.encode!(streaming_markdown_element(text)),
             sequence: sequence,
             uuid: BullX.Ext.gen_uuid_v7()
           }
         ) do
      {:ok, _response} -> :ok
      {:error, error} -> {:error, Feishu.Error.map(error)}
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

  defp card_outbound(stream_id, card_id, reply_address) do
    %{
      "id" => stream_id,
      "op" => "send",
      "scope_id" => map_value(reply_address, "scope_id"),
      "thread_id" => map_value(reply_address, "thread_id"),
      "reply_to_external_id" => map_value(reply_address, "reply_to_external_id"),
      "content" => [
        %{
          "kind" => "card",
          "body" => %{
            "format" => "feishu.card.v2",
            "payload" => %{type: "card", data: %{card_id: card_id}}
          }
        }
      ]
    }
  end

  defp apply_chunk(state, %{"replace_text" => text}) when is_binary(text),
    do: %{state | text: text}

  defp apply_chunk(state, %{"text" => text}) when is_binary(text),
    do: %{state | text: state.text <> text}

  defp apply_chunk(state, %{replace_text: text}) when is_binary(text), do: %{state | text: text}

  defp apply_chunk(state, %{text: text}) when is_binary(text),
    do: %{state | text: state.text <> text}

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
        update_multi: true,
        streaming_mode: true,
        summary: %{content: BullX.I18n.t("im_gateway.feishu.delivery.stream_thinking")},
        streaming_config: %{
          print_frequency_ms: %{default: 70, android: 70, ios: 70, pc: 70},
          print_step: %{default: 1, android: 1, ios: 1, pc: 1},
          print_strategy: "fast"
        }
      },
      body: %{
        direction: "vertical",
        horizontal_spacing: "8px",
        vertical_spacing: "8px",
        horizontal_align: "left",
        vertical_align: "top",
        padding: "12px 12px 12px 12px",
        elements: [
          %{
            tag: "div",
            text: %{
              tag: "plain_text",
              content: initial_text,
              text_size: "notation",
              text_align: "left",
              text_color: "grey"
            },
            icon: %{
              tag: "standard_icon",
              token: "ai-common_colorful",
              color: "grey"
            },
            margin: "0px 0px 0px 0px",
            element_id: @streaming_element_id
          }
        ]
      }
    }
  end

  defp streaming_markdown_element(text) do
    %{
      tag: "markdown",
      content: stream_text(text),
      element_id: @streaming_element_id
    }
  end

  defp stream_text(""), do: BullX.I18n.t("im_gateway.feishu.delivery.stream_thinking")
  defp stream_text(text), do: text

  defp truncate_summary(text) when is_binary(text) do
    normalized = text |> String.replace(~r/\s+/, " ") |> String.trim()

    case String.length(normalized) <= 80 do
      true -> normalized
      false -> String.slice(normalized, 0, 77) <> "..."
    end
  end

  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
