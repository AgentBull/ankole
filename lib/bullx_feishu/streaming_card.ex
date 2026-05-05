defmodule BullXFeishu.StreamingCard do
  @moduledoc """
  Feishu CardKit streaming-card delivery state machine.

  The stream enumerable is process-local and non-replayable. Runtime owns the
  producer side; this module owns Feishu's streaming-card UX: create the CardKit
  card, send a card reference message, batch small text chunks, update the
  streaming markdown element, and close streaming mode when the turn completes.
  """

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Content
  alias BullXGateway.Delivery.Outcome
  alias BullXFeishu.{Config, Delivery, Error}

  @streaming_element_id "content"
  @stream_flush_min_chars 10
  @summary_max_length 80
  @initial_text "正在思考中..."

  @spec stream(BullXGateway.Delivery.t(), Enumerable.t() | nil, Config.t()) ::
          {:ok, Outcome.adapter_success_t()} | {:error, map()}
  def stream(%GatewayDelivery{content: nil}, _enumerable, _config),
    do: {:error, Error.payload("stream content is not replayable")}

  def stream(%GatewayDelivery{} = delivery, nil, _config),
    do:
      {:error, Error.payload("stream content is not replayable", %{"delivery_id" => delivery.id})}

  def stream(%GatewayDelivery{} = delivery, enumerable, %Config{} = config) do
    with {:ok, card_id} <- create_card(config),
         {:ok, %Outcome{} = outcome} <- send_card_reference(delivery, card_id, config),
         {:ok, stream_state} <- consume_and_close(enumerable, config, card_id) do
      {:ok,
       %Outcome{
         outcome
         | delivery_id: delivery.id,
           warnings: outcome.warnings ++ stream_state.warnings
       }}
    end
  end

  defp create_card(%Config{} = config) do
    body = %{
      "type" => "card_json",
      "data" => Jason.encode!(streaming_card_definition(@initial_text))
    }

    case FeishuOpenAPI.post(Config.client!(config), "/open-apis/cardkit/v1/cards", body: body) do
      {:ok, response} -> card_id(response)
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Error.map(error)}
    end
  end

  defp card_id(%{"data" => %{"card_id" => card_id}}) when is_binary(card_id) and card_id != "",
    do: {:ok, card_id}

  defp card_id(response) do
    {:error,
     Error.payload("Feishu card create response missing card_id", %{"response" => response})}
  end

  defp send_card_reference(%GatewayDelivery{} = delivery, card_id, %Config{} = config) do
    delivery
    |> card_reference_delivery(card_id)
    |> Delivery.deliver(config)
  end

  defp card_reference_delivery(%GatewayDelivery{} = delivery, card_id) do
    %GatewayDelivery{
      delivery
      | op: :send,
        content: %Content{
          kind: :card,
          body: %{
            "format" => "feishu.card",
            "fallback_text" => truncate_summary(@initial_text),
            "payload" => %{
              "type" => "card",
              "data" => %{"card_id" => card_id}
            }
          }
        }
    }
  end

  defp consume_and_close(enumerable, %Config{} = config, card_id) do
    case consume_chunks(enumerable, config, card_id) do
      {:ok, state} ->
        close_streaming_card(config, card_id, state)

      {:error, error, state} ->
        close_after_failure(config, card_id, state)
        {:error, error}
    end
  end

  defp consume_chunks(enumerable, %Config{} = config, card_id) do
    initial_state = stream_state()

    try do
      Enum.reduce_while(enumerable, {:ok, initial_state}, fn chunk, {:ok, state} ->
        state = apply_chunk(state, chunk_text(chunk))

        case maybe_flush_pending(config, card_id, state) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          {:error, error} -> {:halt, {:error, error, state}}
        end
      end)
    rescue
      exception -> {:error, Error.map(exception), initial_state}
    catch
      kind, reason -> {:error, Error.map({kind, reason}), initial_state}
    end
  end

  defp stream_state do
    %{
      current_text: "",
      pending_text: nil,
      pending_chars: 0,
      sequence: 1,
      last_update_at: nil,
      warnings: []
    }
  end

  defp chunk_text(chunk) when is_binary(chunk), do: {:append, chunk}
  defp chunk_text(%{text: text}) when is_binary(text), do: {:append, text}
  defp chunk_text(%{"text" => text}) when is_binary(text), do: {:append, text}
  defp chunk_text(%{replace_text: text}) when is_binary(text), do: {:replace, text}
  defp chunk_text(%{"replace_text" => text}) when is_binary(text), do: {:replace, text}
  defp chunk_text(_), do: {:append, ""}

  defp apply_chunk(state, {:append, ""}), do: state

  defp apply_chunk(state, {:append, text}) do
    base_text = state.pending_text || state.current_text

    %{
      state
      | pending_text: base_text <> text,
        pending_chars: state.pending_chars + String.length(text)
    }
  end

  defp apply_chunk(state, {:replace, text}) do
    %{
      state
      | pending_text: text,
        pending_chars: max(state.pending_chars, @stream_flush_min_chars)
    }
  end

  defp maybe_flush_pending(config, card_id, %{pending_chars: chars} = state)
       when chars >= @stream_flush_min_chars do
    flush_pending(config, card_id, state)
  end

  defp maybe_flush_pending(_config, _card_id, state), do: {:ok, state}

  defp close_streaming_card(config, card_id, state) do
    with {:ok, state} <- flush_pending(config, card_id, state),
         {:ok, state} <- close_card_settings(config, card_id, state) do
      {:ok, state}
    end
  end

  defp close_after_failure(config, card_id, state) do
    failed_state =
      state
      |> apply_chunk({:replace, BullX.I18n.t("gateway.feishu.delivery.stream_failed")})

    with {:ok, state} <- flush_pending(config, card_id, failed_state),
         {:ok, _state} <- close_card_settings(config, card_id, state) do
      :ok
    else
      _error -> :ok
    end
  end

  defp flush_pending(_config, _card_id, %{pending_text: nil} = state), do: {:ok, state}

  defp flush_pending(_config, _card_id, %{pending_text: text, current_text: text} = state) do
    {:ok, %{state | pending_text: nil, pending_chars: 0}}
  end

  defp flush_pending(%Config{} = config, card_id, %{pending_text: text} = state) do
    state = next_sequence(state)

    with :ok <- wait_for_update_slot(config, state),
         {:ok, _response} <-
           FeishuOpenAPI.put(
             Config.client!(config),
             "/open-apis/cardkit/v1/cards/:card_id/elements/:element_id/content",
             path_params: %{card_id: card_id, element_id: @streaming_element_id},
             body: %{
               "content" => text,
               "sequence" => state.sequence,
               "uuid" => BullX.Ext.gen_uuid_v7()
             }
           ) do
      {:ok,
       %{
         state
         | current_text: text,
           pending_text: nil,
           pending_chars: 0,
           last_update_at: System.monotonic_time(:millisecond)
       }}
    else
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Error.map(error)}
    end
  end

  defp close_card_settings(%Config{} = config, card_id, state) do
    state = next_sequence(state)

    settings = %{
      "config" => %{
        "streaming_mode" => false,
        "summary" => %{"content" => truncate_summary(state.current_text)}
      }
    }

    case FeishuOpenAPI.patch(
           Config.client!(config),
           "/open-apis/cardkit/v1/cards/:card_id/settings",
           path_params: %{card_id: card_id},
           body: %{
             "settings" => Jason.encode!(settings),
             "sequence" => state.sequence,
             "uuid" => BullX.Ext.gen_uuid_v7()
           }
         ) do
      {:ok, _response} -> {:ok, state}
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Error.map(error)}
    end
  end

  defp wait_for_update_slot(%Config{stream_update_interval_ms: interval_ms}, _state)
       when interval_ms <= 0,
       do: :ok

  defp wait_for_update_slot(%Config{}, %{last_update_at: nil}), do: :ok

  defp wait_for_update_slot(%Config{stream_update_interval_ms: interval_ms}, state) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.last_update_at

    case elapsed_ms < interval_ms do
      true -> Process.sleep(interval_ms - elapsed_ms)
      false -> :ok
    end
  end

  defp next_sequence(state), do: %{state | sequence: state.sequence + 1}

  defp streaming_card_definition(initial_text) do
    %{
      "schema" => "2.0",
      "config" => %{
        "wide_screen_mode" => true,
        "streaming_mode" => true,
        "summary" => %{"content" => truncate_summary(initial_text)},
        "streaming_config" => %{
          "print_frequency_ms" => device_map(70),
          "print_step" => device_map(1),
          "print_strategy" => "fast"
        }
      },
      "body" => %{
        "elements" => [
          %{
            "tag" => "markdown",
            "content" => initial_text,
            "element_id" => @streaming_element_id
          }
        ]
      }
    }
  end

  defp device_map(value) do
    %{
      "default" => value,
      "android" => value,
      "ios" => value,
      "pc" => value
    }
  end

  defp truncate_summary(text) do
    summary =
      text
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> case do
        "" -> BullX.I18n.t("gateway.feishu.delivery.stream_generating")
        value -> value
      end

    case String.length(summary) > @summary_max_length do
      true -> String.slice(summary, 0, @summary_max_length - 3) <> "..."
      false -> summary
    end
  end
end
