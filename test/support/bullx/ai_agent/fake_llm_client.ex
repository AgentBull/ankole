defmodule BullX.AIAgent.FakeLLMClient do
  @moduledoc false

  @behaviour BullX.LLM.Client

  alias BullX.LLM.ResolvedModel
  alias ReqLLM.Message.ContentPart

  @requests_key {__MODULE__, :requests}

  @impl BullX.LLM.Client
  def chat(%ResolvedModel{} = resolved, messages, opts) do
    record_request(:chat, resolved, messages, opts)

    case next_response() do
      {:error, reason} ->
        {:error, reason}

      response ->
        {:ok,
         %ReqLLM.Response{
           id: "fake-response",
           model: resolved.model_id,
           message: response.message,
           context: [],
           usage: response.usage,
           finish_reason: response.finish_reason,
           provider_meta: response.provider_meta
         }}
    end
  end

  @impl BullX.LLM.Client
  def stream_chat(%ResolvedModel{} = resolved, messages, opts, stream_opts) do
    record_request(:stream_chat, resolved, messages, opts, stream_opts)

    case next_response() do
      {:error, reason} ->
        {:error, reason}

      %{stream_chunks: chunks} = response ->
        with :ok <- emit_stream_chunks(chunks, response, stream_opts) do
          {:ok, response_to_req(response, resolved)}
        end

      response ->
        response = response_to_req(response, resolved)
        maybe_emit_stream_result(Keyword.get(stream_opts, :on_result), response)

        {:ok, response}
    end
  end

  def push_response(text, tool_calls \\ [], opts \\ []) do
    response = %{
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ContentPart.text(text)],
        tool_calls: normalize_tool_calls(tool_calls)
      },
      finish_reason:
        Keyword.get(opts, :finish_reason, if(tool_calls == [], do: :stop, else: :tool_calls)),
      usage: Keyword.get(opts, :usage, default_usage()),
      provider_meta: Keyword.get(opts, :provider_meta, %{"request_id" => "fake"})
    }

    responses = Process.get(__MODULE__, [])
    Process.put(__MODULE__, responses ++ [response])
  end

  def push_stream_response(chunks, opts \\ []) when is_list(chunks) do
    text = Enum.join(chunks, "")

    response = %{
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ContentPart.text(text)],
        tool_calls: normalize_tool_calls(Keyword.get(opts, :tool_calls, []))
      },
      finish_reason: Keyword.get(opts, :finish_reason, :stop),
      usage: Keyword.get(opts, :usage, default_usage()),
      provider_meta: Keyword.get(opts, :provider_meta, %{"request_id" => "fake"}),
      stream_chunks: chunks,
      notify: Keyword.get(opts, :notify),
      block_after_chunks: Keyword.get(opts, :block_after_chunks, [])
    }

    responses = Process.get(__MODULE__, [])
    Process.put(__MODULE__, responses ++ [response])
  end

  def push_error(reason) do
    responses = Process.get(__MODULE__, [])
    Process.put(__MODULE__, responses ++ [{:error, reason}])
  end

  def reset do
    Process.delete(__MODULE__)
    Process.delete(@requests_key)
  end

  def requests, do: Process.get(@requests_key, [])

  def last_request, do: requests() |> List.last()

  defp record_request(kind, %ResolvedModel{} = resolved, messages, opts, stream_opts \\ []) do
    request = %{
      kind: kind,
      resolved: resolved,
      messages: messages,
      opts: opts,
      stream_opts: stream_opts
    }

    Process.put(@requests_key, requests() ++ [request])
  end

  defp next_response do
    case Process.get(__MODULE__, []) do
      [response | rest] ->
        Process.put(__MODULE__, rest)
        response

      [] ->
        %{
          message: %ReqLLM.Message{
            role: :assistant,
            content: [ContentPart.text("fake assistant")]
          },
          finish_reason: :stop,
          usage: default_usage(),
          provider_meta: %{"request_id" => "fake"}
        }
    end
  end

  defp response_to_req(response, %ResolvedModel{} = resolved) do
    %ReqLLM.Response{
      id: "fake-response",
      model: resolved.model_id,
      message: response.message,
      context: [],
      usage: response.usage,
      finish_reason: response.finish_reason,
      provider_meta: response.provider_meta
    }
  end

  defp emit_stream_chunks(chunks, response, stream_opts) do
    on_result = Keyword.get(stream_opts, :on_result)

    chunks
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {chunk, index}, :ok ->
      case emit_stream_chunk(on_result, chunk) do
        :ok ->
          maybe_notify_stream_chunk(response, index, chunk)
          maybe_block_stream_chunk(response, index)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp emit_stream_chunk(on_result, chunk) when is_function(on_result, 1) do
    on_result.(chunk)
    :ok
  rescue
    exception -> {:error, exception}
  end

  defp emit_stream_chunk(_on_result, _chunk), do: :ok

  defp maybe_emit_stream_result(on_result, response) when is_function(on_result, 1) do
    on_result.(ReqLLM.Response.text(response) || "")
  end

  defp maybe_emit_stream_result(_on_result, _response), do: :ok

  defp maybe_notify_stream_chunk(%{notify: pid}, index, chunk) when is_pid(pid) do
    send(pid, {__MODULE__, :stream_chunk, index, chunk})
  end

  defp maybe_notify_stream_chunk(_response, _index, _chunk), do: :ok

  defp maybe_block_stream_chunk(%{block_after_chunks: indexes}, index) when is_list(indexes) do
    case index in indexes do
      true -> await_stream_continue(index)
      false -> :ok
    end
  end

  defp maybe_block_stream_chunk(_response, _index), do: :ok

  defp await_stream_continue(index) do
    receive do
      {__MODULE__, :continue_stream, ^index} -> :ok
    after
      5_000 -> :ok
    end
  end

  defp default_usage do
    %{
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15
    }
  end

  defp normalize_tool_calls([]), do: nil
  defp normalize_tool_calls(tool_calls), do: Enum.map(tool_calls, &ReqLLM.ToolCall.from_map/1)
end
