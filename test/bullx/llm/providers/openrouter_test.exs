defmodule BullX.LLM.Providers.OpenRouterTest do
  use ExUnit.Case, async: true

  alias BullX.LLM.Providers.OpenRouter

  test "provider schema adds BullX OpenRouter reasoning options" do
    schema = OpenRouter.provider_schema().schema

    assert Keyword.fetch!(schema, :openrouter_reasoning_effort)[:type] ==
             {:in, [:none, :minimal, :low, :medium, :high, :xhigh, :default]}

    assert Keyword.fetch!(schema, :openrouter_reasoning)[:type] == :map
  end

  test "encodes reasoning effort through OpenRouter unified reasoning object" do
    body =
      request(openrouter_reasoning_effort: :high)
      |> OpenRouter.encode_body()
      |> decoded_body()

    assert body["reasoning"] == %{"effort" => "high"}
    refute Map.has_key?(body, "reasoning_effort")
  end

  test "explicit OpenRouter reasoning object wins over effort default" do
    body =
      request(
        openrouter_reasoning_effort: :high,
        openrouter_reasoning: %{"max_tokens" => 2000}
      )
      |> OpenRouter.encode_body()
      |> decoded_body()

    assert body["reasoning"] == %{"max_tokens" => 2000}
    refute Map.has_key?(body, "reasoning_effort")
  end

  test "translates reasoning token budget to OpenRouter reasoning object" do
    {opts, warnings} =
      OpenRouter.translate_options(:chat, %{id: "openai/gpt-oss-120b"},
        reasoning_token_budget: 2000
      )

    assert warnings == []
    assert opts[:openrouter_reasoning] == %{max_tokens: 2000}
    refute Keyword.has_key?(opts, :reasoning_token_budget)
  end

  defp request(options) do
    request_options =
      Keyword.merge(
        [
          operation: :chat,
          model: "openai/gpt-oss-120b",
          messages: []
        ],
        options
      )

    Req.Request.new()
    |> Req.Request.register_options(Keyword.keys(request_options))
    |> Req.Request.merge_options(request_options)
  end

  defp decoded_body(%Req.Request{} = request), do: Jason.decode!(request.body)
end
