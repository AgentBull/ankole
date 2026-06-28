defmodule Ankole.AIGateway.ResponseStream do
  @moduledoc """
  Converts upstream SSE byte chunks into normalized Responses events.

  The parser is two-stage on purpose: `SSE` handles wire framing, while provider
  modules interpret each JSON event according to the upstream API family. This
  keeps OpenAI Responses, Chat Completions, and Anthropic Messages stream logic
  separate while exposing one downstream event sequence.
  """

  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.SSE

  @doc """
  Initializes stream state for one upstream request.
  """
  @spec init(map(), map()) :: {:ok, map()} | {:error, term()}
  def init(runtime, upstream_request) do
    with {:ok, provider} <- Providers.module_for_runtime(runtime) do
      provider_state =
        if function_exported?(provider, :stream_init, 2) do
          apply(provider, :stream_init, [runtime, upstream_request])
        else
          %{}
        end

      {:ok,
       %{
         sse: SSE.new(),
         provider: provider,
         provider_state: provider_state,
         terminal?: false,
         response: nil
       }}
    end
  end

  @doc """
  Feeds one raw upstream byte chunk and returns normalized Responses events.
  """
  @spec decode_chunk(map(), map(), map(), binary()) :: {:ok, [map()], map()} | {:error, term()}
  def decode_chunk(runtime, upstream_request, state, chunk) when is_binary(chunk) do
    with {:ok, messages, sse} <- SSE.feed(state.sse, chunk) do
      state = %{state | sse: sse}
      decode_messages(runtime, upstream_request, state, messages, [])
    end
  end

  @doc """
  Flushes remaining SSE state and verifies the provider emitted a terminal event.

  A closed upstream TCP connection is not success by itself. The downstream SSE
  and WebSocket protocols need an explicit `response.completed`,
  `response.failed`, `response.incomplete`, or `error` event.
  """
  @spec finish(map(), map(), map()) :: {:ok, [map()], map()} | {:error, term()}
  def finish(runtime, upstream_request, state) do
    with {:ok, messages, sse} <- SSE.finish(state.sse),
         {:ok, events, state} <-
           decode_messages(runtime, upstream_request, %{state | sse: sse}, messages, []),
         {:ok, finish_events, state} <- finish_provider(runtime, upstream_request, state) do
      {:ok, events ++ finish_events, state}
    end
  end

  @doc """
  Returns the final normalized response body accumulated by a provider stream.
  """
  @spec response_body(map()) :: map() | nil
  def response_body(%{provider_state: %{response: response}}) when is_map(response), do: response
  def response_body(%{response: response}) when is_map(response), do: response
  def response_body(_state), do: nil

  defp decode_messages(_runtime, _upstream_request, state, [], acc) do
    {:ok, Enum.reverse(acc), state}
  end

  defp decode_messages(runtime, upstream_request, state, [message | messages], acc) do
    with {:ok, events, provider_state} <-
           apply(state.provider, :decode_stream_message, [
             runtime,
             upstream_request,
             state.provider_state,
             message
           ]) do
      state =
        state
        |> Map.put(:provider_state, provider_state)
        |> remember_terminal(events)

      decode_messages(runtime, upstream_request, state, messages, Enum.reverse(events) ++ acc)
    end
  end

  # Providers may have to synthesize a final event when the upstream stream ends.
  # Chat Completions, for example, only becomes a complete Responses body after
  # all deltas have been assembled.
  defp finish_provider(runtime, upstream_request, state) do
    with {:ok, events, provider_state} <-
           apply(state.provider, :finish_stream, [runtime, upstream_request, state.provider_state]) do
      state =
        state
        |> Map.put(:provider_state, provider_state)
        |> remember_terminal(events)

      case state.terminal? do
        true -> {:ok, events, state}
        false -> {:error, :upstream_stream_closed_before_terminal_event}
      end
    end
  end

  defp remember_terminal(state, events) do
    terminal? =
      Enum.any?(events, fn
        %{"type" => type}
        when type in ["response.completed", "response.failed", "response.incomplete", "error"] ->
          true

        _event ->
          false
      end)

    if terminal?, do: %{state | terminal?: true}, else: state
  end
end
