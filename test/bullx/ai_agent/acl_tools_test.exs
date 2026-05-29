defmodule BullX.AIAgent.ACLToolsTest.PrivilegedTool do
  @moduledoc false

  def execute(_args, _context), do: {:ok, %{"ok" => true}}
end

defmodule BullX.AIAgent.ACLToolsTest.PrivilegedToolSet do
  @moduledoc false

  def toolset do
    %{
      id: "ops",
      default_enabled: true,
      tools: [
        %{
          name: "delete_record",
          description: "Delete a durable record.",
          parameter_schema: [],
          access: :privileged,
          module: BullX.AIAgent.ACLToolsTest.PrivilegedTool
        }
      ]
    }
  end
end

defmodule BullX.AIAgent.ACLToolsTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{ACL, Profile, Tools}
  alias BullX.AIAgent.Tools.Dispatcher
  alias BullX.AuthZ
  alias BullX.Plugins.{Extension, Registry}
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

    resource = ACL.resource(agent.uid)

    assert {:denied, :forbidden} = ACL.authorize(caller.uid, agent.uid, :ordinary, %{})

    {:ok, _grant} =
      AuthZ.create_permission_grant(%{
        principal_uid: caller.uid,
        resource_pattern: resource,
        action: "invoke"
      })

    assert :allowed = ACL.authorize(caller.uid, agent.uid, :ordinary, %{})
    assert {:denied, :forbidden} = ACL.authorize(caller.uid, agent.uid, :privileged, %{})

    {:ok, _grant} =
      AuthZ.create_permission_grant(%{
        principal_uid: caller.uid,
        resource_pattern: resource,
        action: "invoke_privileged"
      })

    assert :allowed = ACL.authorize(caller.uid, agent.uid, :privileged, %{})
  end

  test "ToolSet expansion is not caller-ACL visibility filtering" do
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
            "web" => %{"enabled" => false},
            "ops" => %{"enabled" => true}
          }
        }
      })

    registry = plugin_registry()

    rendered =
      Tools.enabled_tools(profile, caller.uid, agent.uid, %{}, %{plugin_registry: registry})

    assert Enum.any?(rendered, &(&1.entry.name == "clarify"))
    assert Enum.any?(rendered, &(&1.entry.name == "delete_record"))
  end

  test "dispatcher denies unauthorized privileged tool calls" do
    {:ok, %{principal: caller}} =
      Principals.create_human(%{uid: "ai-agent-tool-denied-caller", display_name: "Caller"})

    {:ok, %{principal: agent}} =
      Principals.create_agent(%{
        uid: "ai-agent-tool-denied-agent",
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
          "toolsets" => %{"web" => %{"enabled" => false}, "ops" => %{"enabled" => true}}
        }
      })

    seed = %{
      caller_principal_uid: caller.uid,
      agent_uid: agent.uid,
      conversation_id: "conversation-1",
      trigger_type: "test",
      trigger_id: "trigger-1",
      acl_context: %{},
      plugin_registry: plugin_registry(),
      metadata: %{}
    }

    result =
      Dispatcher.execute_call(
        profile,
        %{id: "call_1", name: "delete_record", arguments: %{}},
        seed,
        %{id: "assistant-1"}
      )

    assert result["is_error"] == true
    assert result["error"]["code"] == "tool_denied"
  end

  defp plugin_registry do
    %Registry{
      enabled_ids: MapSet.new(["test_tools"]),
      extensions: [
        %Extension{
          plugin_id: "test_tools",
          point: Tools.Registry.extension_point(),
          id: "ops",
          module: BullX.AIAgent.ACLToolsTest.PrivilegedToolSet
        }
      ]
    }
  end
end
