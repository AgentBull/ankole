defmodule Ankole.AIGateway.ReasoningEffortTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.ReasoningEffort

  @claude_map %{"low" => "low", "medium" => "medium", "high" => "high", "xhigh" => "max"}

  test "normalizes OpenAI reasoning effort values and keeps a missing value missing" do
    assert ReasoningEffort.Levels.values() == ~w(none minimal low medium high xhigh max ultra)
    assert ReasoningEffort.normalize(nil) == {:ok, nil}
    assert ReasoningEffort.normalize(:minimal) == {:ok, "minimal"}
    assert ReasoningEffort.normalize(" XHIGH ") == {:ok, "xhigh"}
    assert ReasoningEffort.normalize("MAX") == {:ok, "max"}
    assert ReasoningEffort.normalize(:ultra) == {:ok, "ultra"}
  end

  test "rejects values outside the OpenAI public contract" do
    assert {:error, {:reasoning_effort, {:invalid, "extreme", allowed}}} =
             ReasoningEffort.normalize("extreme")

    assert allowed == ~w(none minimal low medium high xhigh max ultra)
  end

  test "maps provider-specific subsets without inventing a global alias model" do
    ctx = %{provider_options: %{"reasoningEffort" => "xhigh"}}

    assert {:ok, %{"output_config" => %{"effort" => "max"}}} =
             ReasoningEffort.provider_options(ctx,
               target: :output_config,
               map: %{
                 "none" => "none",
                 "minimal" => "minimal",
                 "low" => "low",
                 "medium" => "medium",
                 "high" => "high",
                 "xhigh" => "max"
               }
             )
  end

  test "returns unsupported when a provider map does not include the OpenAI value" do
    ctx = %{provider_options: %{"reasoningEffort" => "minimal"}}
    provider_map = %{"low" => "low", "medium" => "medium", "high" => "high"}

    assert ReasoningEffort.Levels.values(provider_map) == ~w(low medium high)

    assert {:error, {:reasoning_effort, {:unsupported, "minimal", ["low", "medium", "high"]}}} =
             ReasoningEffort.provider_options(ctx,
               target: :reasoning_effort,
               map: provider_map
             )
  end

  test "writes only the provider-native aligned target" do
    ctx = %{
      provider_options: %{
        "reasoningEffort" => "medium",
        "reasoning" => %{"effort" => "low", "exclude" => true}
      }
    }

    assert {:ok, %{"reasoning" => %{"effort" => "medium"}}} =
             ReasoningEffort.provider_options(ctx, target: :reasoning)

    assert {:ok, %{"reasoning_effort" => "medium"}} =
             ReasoningEffort.provider_options(ctx, target: :reasoning_effort)
  end

  test "the official Responses reasoning field overrides the route default" do
    ctx = %{
      request: %{"reasoning" => %{"effort" => "none"}},
      provider_options: %{"reasoningEffort" => "high"}
    }

    assert {:ok, %{"reasoning" => %{"effort" => "none"}}} =
             ReasoningEffort.provider_options(ctx, target: :reasoning)
  end

  test "the packaged model metadata decides the default effort and the accepted levels" do
    # gpt-4o does not reason: no default, and a chosen value fails before the request.
    assert effort("openai", "gpt-4o", %{}) == {:ok, %{}}

    assert {:error, {:reasoning_effort, {:unsupported, "high", []}}} =
             effort("openai", "gpt-4o", %{"reasoningEffort" => "high"})

    assert effort("openai", "gpt-5", %{}) == {:ok, %{"reasoning_effort" => "high"}}

    assert effort("openai", "gpt-5", %{"reasoningEffort" => "low"}) ==
             {:ok, %{"reasoning_effort" => "low"}}

    # Without metadata only a chosen value is sent.
    assert effort("openai", "qa-unknown-model", %{}) == {:ok, %{}}

    assert effort("openai", "qa-unknown-model", %{"reasoningEffort" => "low"}) ==
             {:ok, %{"reasoning_effort" => "low"}}

    # Claude Haiku 4.5 thinks, but it lists no effort levels.
    assert claude_effort("claude-haiku-4-5", %{}) == {:ok, %{}}

    assert claude_effort("claude-opus-4-5", %{}) ==
             {:ok, %{"output_config" => %{"effort" => "high"}}}

    assert {:error, {:reasoning_effort, {:unsupported, "xhigh", ["low", "medium", "high"]}}} =
             claude_effort("claude-opus-4-5", %{"reasoningEffort" => "xhigh"})

    assert claude_effort("claude-sonnet-4-6", %{"reasoningEffort" => "xhigh"}) ==
             {:ok, %{"output_config" => %{"effort" => "max"}}}

    # A provider with its own model catalog keeps the high default.
    assert ReasoningEffort.provider_options(
             %{provider_options: %{}, runtime: runtime("openrouter", "qa/any-model")},
             target: :reasoning
           ) == {:ok, %{"reasoning" => %{"effort" => "high"}}}
  end

  defp effort(provider_kind, model, options) do
    ReasoningEffort.provider_options(
      %{provider_options: options, runtime: runtime(provider_kind, model)},
      target: :reasoning_effort
    )
  end

  defp claude_effort(model, options) do
    ReasoningEffort.provider_options(
      %{provider_options: options, runtime: runtime("claude", model)},
      target: :output_config,
      map: @claude_map
    )
  end

  defp runtime(provider_kind, model) do
    %{
      "provider" => %Provider{provider_id: "qa-#{provider_kind}", provider_kind: provider_kind},
      "model" => model
    }
  end
end
