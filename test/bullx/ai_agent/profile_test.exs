defmodule BullX.AIAgent.ProfileTest do
  use BullX.DataCase, async: true

  alias BullX.AIAgent.Profile

  test "casts executable defaults and ignores unknown fields" do
    assert {:ok, profile} =
             Profile.cast(%{
               "ai_agent" => %{
                 "main_llm" => %{
                   "provider_id" => "openai_proxy",
                   "model" => "gpt-test",
                   "context_window" => 65_536
                 },
                 "mission" => "Answer finance questions.",
                 "unknown" => "ignored",
                 "toolsets" => %{
                   "web" => %{"enabled" => false},
                   "future_plugin" => %{"enabled" => true}
                 }
               }
             })

    assert profile.main_llm.provider_id == "openai_proxy"
    assert profile.main_llm.model == "gpt-test"
    assert profile.main_llm.reasoning_effort == :medium
    assert profile.main_llm.context_window == 65_536
    assert profile.main_llm.max_completion_tokens == nil
    assert profile.compression_llm.reasoning_effort == :low
    assert profile.heavy_llm.reasoning_effort == :high
    assert profile.context.max_turns == 50
    assert profile.context.time_awareness_granularity == :hour
    assert profile.acl.elevation_strategy == :deny
    assert profile.toolsets["web"].enabled == false
    assert profile.toolsets["future_plugin"].enabled == true
  end

  test "rejects invalid profile fields before model calls" do
    assert {:error, {:invalid_profile, errors}} =
             Profile.cast(%{
               "ai_agent" => %{
                 "main_llm" => %{
                   "provider_id" => "",
                   "model" => "gpt-test",
                   "reasoning_effort" => "magic"
                 },
                 "mission" => "",
                 "acl" => %{"elevation_strategy" => "approval"},
                 "context" => %{"compression_threshold_ratio" => 1.5}
               }
             })

    assert "main_llm.provider_id is required" in errors
    assert "main_llm.reasoning_effort has unsupported value" in errors
    assert "mission is required" in errors
    assert "acl.elevation_strategy must be deny" in errors
    assert "context.compression_threshold_ratio must be > 0 and < 1" in errors

    assert {:error, {:invalid_profile, errors}} =
             Profile.cast(%{
               "ai_agent" => %{
                 "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
                 "mission" => "Answer finance questions.",
                 "acl" => "bad"
               }
             })

    assert "acl must be a JSON object" in errors
  end

  test "rejects unsupported ToolSet profile fields and disabling basic" do
    assert {:error, {:invalid_profile, errors}} =
             Profile.cast(%{
               "ai_agent" => %{
                 "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
                 "mission" => "Answer finance questions.",
                 "toolsets" => %{
                   "basic" => %{"enabled" => false},
                   "web" => %{"enabled" => true, "tools" => %{}},
                   "ops" => %{}
                 }
               }
             })

    assert "toolset basic cannot be disabled" in errors
    assert "toolset web has unsupported fields: tools" in errors
    assert "toolset ops.enabled is required" in errors
  end
end
