defmodule Ankole.AIGateway.ReasoningEffortTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ReasoningEffort

  test "normalizes OpenAI reasoning effort values and defaults to high" do
    assert ReasoningEffort.values() == ~w(none minimal low medium high xhigh)
    assert ReasoningEffort.normalize(nil) == {:ok, "high"}
    assert ReasoningEffort.normalize(:minimal) == {:ok, "minimal"}
    assert ReasoningEffort.normalize(" XHIGH ") == {:ok, "xhigh"}
  end

  test "rejects values outside the OpenAI public contract" do
    assert {:error, {:reasoning_effort, {:invalid, "max", allowed}}} =
             ReasoningEffort.normalize("max")

    assert allowed == ~w(none minimal low medium high xhigh)
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
end
