defmodule BullX.LLM.Providers.Deepseek do
  @moduledoc """
  DeepSeek AI provider – OpenAI-compatible Chat Completions API.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  DeepSeek is fully OpenAI-compatible, so no custom request/response handling is needed.

  ## Authentication

  Requires a DeepSeek API key from https://platform.deepseek.com/

  ## Configuration

      # Add to .env file (automatically loaded)
      DEEPSEEK_API_KEY=your-api-key

  ## Examples

      # Basic usage
      ReqLLM.generate_text("deepseek:deepseek-chat", "Hello!")

      # With custom parameters
      ReqLLM.generate_text("deepseek:deepseek-reasoner", "Write a function",
        temperature: 0.2,
        max_tokens: 2000
      )

      # Streaming
      ReqLLM.stream_text("deepseek:deepseek-chat", "Tell me a story")
      |> Enum.each(&IO.write/1)

  ## Models

  DeepSeek offers several models including:

  - `deepseek-chat` - General purpose conversational model
  - `deepseek-reasoner` - Reasoning and problem-solving

  See https://platform.deepseek.com/docs for full model documentation.
  """

  use ReqLLM.Provider,
    id: :deepseek,
    default_base_url: "https://api.deepseek.com",
    default_env_key: "DEEPSEEK_API_KEY"

  use ReqLLM.Provider.Defaults

  @provider_schema []

  @impl ReqLLM.Provider
  def build_body(request) do
    body = ReqLLM.Provider.Defaults.default_build_body(request)

    messages =
      case Map.get(body, :messages) do
        nil ->
          nil

        msgs when is_list(msgs) ->
          Enum.map(msgs, &ensure_assistant_reasoning_content/1)

        other ->
          other
      end

    if messages do
      Map.put(body, :messages, messages)
    else
      body
    end
  end

  defp ensure_assistant_reasoning_content(msg) do
    if assistant_message?(msg) and not has_reasoning_content?(msg) do
      Map.put(msg, :reasoning_content, "")
    else
      msg
    end
  end

  defp assistant_message?(msg) when is_map(msg) do
    Map.get(msg, :role) == "assistant" or Map.get(msg, "role") == "assistant"
  end

  defp assistant_message?(_msg), do: false

  defp has_reasoning_content?(msg) when is_map(msg) do
    Map.has_key?(msg, :reasoning_content) or Map.has_key?(msg, "reasoning_content")
  end

  defp has_reasoning_content?(_msg), do: false
end
