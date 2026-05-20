defmodule BullX.AIAgent.ACLToolsTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{ACL, Profile, Tools}
  alias BullX.AuthZ
  alias BullX.Principals

  test "ACL maps invoke and invoke_privileged through AuthZ" do
    {:ok, %{principal: caller}} =
      Principals.create_human(%{uid: "ai-agent-acl-caller", display_name: "Caller"})

    {:ok, %{principal: agent}} =
      Principals.create_agent(%{
        uid: "ai-agent-acl-agent",
        display_name: "Agent",
        profile: %{
          "ai_agent" => %{
            "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
            "mission" => "Handle ACL tests."
          }
        }
      })

    resource = ACL.resource(agent.id)

    assert {:denied, :forbidden} = ACL.authorize(caller.id, agent.id, :ordinary, %{})

    {:ok, _grant} =
      AuthZ.create_permission_grant(%{
        principal_id: caller.id,
        resource_pattern: resource,
        action: "invoke"
      })

    assert :allowed = ACL.authorize(caller.id, agent.id, :ordinary, %{})
    assert {:denied, :forbidden} = ACL.authorize(caller.id, agent.id, :privileged, %{})

    {:ok, _grant} =
      AuthZ.create_permission_grant(%{
        principal_id: caller.id,
        resource_pattern: resource,
        action: "invoke_privileged"
      })

    assert :allowed = ACL.authorize(caller.id, agent.id, :privileged, %{})
  end

  test "ToolSet expansion filters privileged tools by ACL" do
    {:ok, %{principal: caller}} =
      Principals.create_human(%{uid: "ai-agent-tool-caller", display_name: "Caller"})

    {:ok, %{principal: agent}} =
      Principals.create_agent(%{
        uid: "ai-agent-tool-agent",
        display_name: "Agent",
        profile: %{
          "ai_agent" => %{
            "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
            "mission" => "Handle tool ACL tests."
          }
        }
      })

    {:ok, profile} =
      Profile.cast(%{
        "ai_agent" => %{
          "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
          "mission" => "Handle tool ACL tests.",
          "toolsets" => %{
            "web_research" => %{
              "enabled" => true,
              "tools" => %{
                "web_search" => %{"access" => "privileged"}
              }
            }
          }
        }
      })

    {:ok, _grant} =
      AuthZ.create_permission_grant(%{
        principal_id: caller.id,
        resource_pattern: ACL.resource(agent.id),
        action: "invoke"
      })

    assert [] = Tools.enabled_tools(profile, caller.id, agent.id, %{})

    {:ok, _grant} =
      AuthZ.create_permission_grant(%{
        principal_id: caller.id,
        resource_pattern: ACL.resource(agent.id),
        action: "invoke_privileged"
      })

    assert [%{entry: %{name: "web_search"}, access: :privileged, tool: tool}] =
             Tools.enabled_tools(profile, caller.id, agent.id, %{})

    assert %ReqLLM.Tool{name: "web_search"} = tool
  end
end
