defmodule Ankole.AIGateway.ReasoningEffortTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ReasoningEffort

  test "normalizes OpenAI reasoning effort values and defaults to high" do
    assert ReasoningEffort.values() == ~w(none minimal low medium high xhigh max ultra)
    assert ReasoningEffort.normalize(nil) == {:ok, "high"}
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

    assert ReasoningEffort.values(provider_map) == ~w(low medium high)

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
end
