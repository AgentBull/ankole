defmodule Ankole.AIGateway.ReasoningEffortTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ReasoningEffort

  test "normalizes OpenAI reasoning effort values and defaults to high" do
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

    assert {:ok, %{"effort" => "max"}} =
             ReasoningEffort.provider_options(ctx,
               target_key: "effort",
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

    assert {:error, {:reasoning_effort, {:unsupported, "minimal", ["high", "low", "medium"]}}} =
             ReasoningEffort.provider_options(ctx,
               map: %{"low" => "low", "medium" => "medium", "high" => "high"}
             )
  end
end
