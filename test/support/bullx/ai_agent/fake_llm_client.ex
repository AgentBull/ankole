defmodule BullX.AIAgent.FakeLLMClient do
  @moduledoc false

  @behaviour BullX.LLM.Client

  alias BullX.LLM.ResolvedModel
  alias ReqLLM.Message.ContentPart

  @impl BullX.LLM.Client
  def chat(%ResolvedModel{} = resolved, _messages, _opts) do
    response = next_response()

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

  def reset do
    Process.delete(__MODULE__)
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
          usage: default_usage()
        }
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
