defmodule AnkoleWeb.AIGatewaySSELimit do
  @moduledoc false

  alias Ankole.AIGateway.MaxToolCalls

  @terminal_event_types ~w(response.completed response.failed response.incomplete)

  defstruct max_tool_calls: nil,
            response_id: nil,
            accumulated_items: [],
            sequence_number: nil

  @type t :: %__MODULE__{
          max_tool_calls: MaxToolCalls.t() | nil,
          response_id: String.t() | nil,
          accumulated_items: [map()],
          sequence_number: non_neg_integer() | nil
        }

  @type action :: :continue | {:stop, iodata()}

  @spec new(map(), map()) :: t()
  def new(request, meta) when is_map(request) and is_map(meta) do
    %__MODULE__{
      max_tool_calls:
        MaxToolCalls.new(
          Map.get(request, "max_tool_calls"),
          Map.get(meta, "api_resolver") || Map.get(meta, :api_resolver)
        )
    }
  end

  @spec observe(t(), iodata()) :: {t(), action()}
  def observe(%__MODULE__{max_tool_calls: nil} = state, _chunk), do: {state, :continue}

  def observe(%__MODULE__{} = state, chunk) do
    case decode_event(chunk) do
      {:ok, %{"type" => type} = event} when type in @terminal_event_types ->
        # A provider terminal event already present in the current chunk wins.
        {%{track_event(state, event) | max_tool_calls: nil}, :continue}

      {:ok, %{} = event} ->
        state = track_event(state, event)

        if MaxToolCalls.stop?(state.max_tool_calls) do
          {state, {:stop, incomplete_chunk(state)}}
        else
          {state, :continue}
        end

      :ignore ->
        {state, :continue}
    end
  end

  @spec done_chunk() :: binary()
  def done_chunk, do: "data: [DONE]\n\n"

  defp track_event(state, event) do
    state
    |> remember_response_id(event)
    |> remember_output_item(event)
    |> remember_sequence_number(event)
    |> Map.update!(:max_tool_calls, &MaxToolCalls.observe(&1, event))
  end

  defp remember_response_id(state, %{"response" => %{"id" => response_id}})
       when is_binary(response_id),
       do: %{state | response_id: state.response_id || response_id}

  defp remember_response_id(state, %{"response_id" => response_id})
       when is_binary(response_id),
       do: %{state | response_id: state.response_id || response_id}

  defp remember_response_id(state, _event), do: state

  defp remember_output_item(state, %{
         "type" => "response.output_item.done",
         "item" => %{} = item
       }),
       do: %{state | accumulated_items: state.accumulated_items ++ [item]}

  defp remember_output_item(state, _event), do: state

  defp remember_sequence_number(state, %{"sequence_number" => sequence_number})
       when is_integer(sequence_number) and sequence_number >= 0,
       do: %{state | sequence_number: sequence_number}

  defp remember_sequence_number(state, _event), do: state

  defp incomplete_chunk(state) do
    event = %{
      "type" => "response.incomplete",
      "response" => %{
        "id" => state.response_id,
        "object" => "response",
        "status" => "incomplete",
        "incomplete_details" => nil,
        "output" => state.accumulated_items,
        "provider_metadata" => %{
          "max_tool_calls" => MaxToolCalls.details(state.max_tool_calls)
        }
      }
    }

    event =
      case state.sequence_number do
        sequence_number when is_integer(sequence_number) ->
          Map.put(event, "sequence_number", sequence_number + 1)

        _missing ->
          event
      end

    "event: response.incomplete\ndata: #{Ankole.JSON.encode!(event)}\n\n"
  end

  defp decode_event(chunk) do
    chunk
    |> IO.iodata_to_binary()
    |> String.split("\n")
    |> Enum.find_value(fn
      "data: [DONE]" -> :done
      "data: " <> data -> {:data, data}
      _line -> nil
    end)
    |> case do
      {:data, data} ->
        case Ankole.JSON.decode(data) do
          {:ok, %{} = event} -> {:ok, event}
          _invalid -> :ignore
        end

      _done_or_missing ->
        :ignore
    end
  end
end
