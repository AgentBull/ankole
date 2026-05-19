defmodule BullX.AIAgent.ProfileTest do
  use BullX.DataCase, async: true

  alias BullX.AIAgent.Profile

  test "casts executable defaults and ignores unknown fields" do
    assert {:ok, profile} =
             Profile.cast(%{
               "ai_agent" => %{
                 "main_model" => "openai_proxy:gpt-test",
                 "unknown" => "ignored",
                 "toolsets" => %{
                   "web_research" => %{
                     "enabled" => true,
                     "access" => "ordinary",
                     "tools" => %{"web_search" => %{"access" => "privileged"}}
                   }
                 }
               }
             })

    assert profile.main_model == "openai_proxy:gpt-test"
    assert profile.compression_model == profile.main_model
    assert profile.heavy_model == profile.main_model
    assert profile.main_model_reasoning_effort == :medium
    assert profile.context.max_turns == 50
    assert profile.context.time_awareness_granularity == :hour
    assert profile.acl.elevation_strategy == :deny
    assert profile.toolsets["web_research"].tools["web_search"].access == :privileged
  end

  test "rejects invalid profile fields before model calls" do
    assert {:error, {:invalid_profile, errors}} =
             Profile.cast(%{
               "ai_agent" => %{
                 "main_model" => "",
                 "main_model_reasoning_effort" => "magic",
                 "acl" => %{"elevation_strategy" => "approval"},
                 "context" => %{"compression_threshold_ratio" => 1.5}
               }
             })

    assert "main_model is required" in errors
    assert "main_model_reasoning_effort has unsupported value" in errors
    assert "acl.elevation_strategy must be deny" in errors
    assert "context.compression_threshold_ratio must be > 0 and < 1" in errors

    assert {:error, {:invalid_profile, errors}} =
             Profile.cast(%{
               "ai_agent" => %{
                 "main_model" => "openai_proxy:gpt-test",
                 "acl" => "bad"
               }
             })

    assert "acl must be a JSON object" in errors
  end
end
