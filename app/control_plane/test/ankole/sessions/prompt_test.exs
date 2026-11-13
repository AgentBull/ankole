defmodule Ankole.Sessions.PromptTest do
  use ExUnit.Case, async: true
  alias Ankole.Sessions.Prompt

  @reply_rule "Keep the body of a chat reply within about 150 Chinese characters or 100 English words"
  @peer_rule "You are working in an asynchronous peer exchange."

  test "chat channels carry the reply length rule, peer exchanges the peer rule, and channel-less sessions neither" do
    for channel <- [room(:participants), room(nil)] do
      prompt = Prompt.system(opts(channel))
      assert prompt =~ @reply_rule
      refute prompt =~ @peer_rule
    end

    prompt = Prompt.system(opts(room(:agent_peer)))
    assert prompt =~ @peer_rule
    refute prompt =~ @reply_rule

    prompt = Prompt.system(opts(nil))
    refute prompt =~ @peer_rule
    refute prompt =~ @reply_rule
  end

  test "the instructions describe the mounted Drive whatever this turn's Worker reports" do
    prompt = Prompt.system(opts(room(:participants)))
    assert prompt =~ Prompt.drive_instructions()

    task = %{
      agent_uid: "agent-1",
      spec: %{request_context: %{"run_id" => "run-1", "call_id" => "call-1", "schema" => %{}}},
      context: %{
        agent: %{display_name: "Agent One"},
        documents: %{"agents" => %{"content" => ""}},
        drive_mount: :unavailable
      }
    }

    assert Prompt.workflow_system(task) =~ Prompt.drive_instructions()
  end

  test "an Agent that can delegate is told to hand Applet development to a background job" do
    rule = "Building or changing an Applet"

    delegating =
      room(:participants)
      |> opts()
      |> Map.put(:available_tool_names, ["create_background_job"])

    assert Prompt.system(delegating) =~ rule
    refute Prompt.system(opts(room(:participants))) =~ rule
  end

  defp room(access_scope) do
    %{
      id: "room-1",
      adapter: nil,
      kind: "native",
      label: "Room",
      page_id: nil,
      access_scope: access_scope,
      signal_origin?: true
    }
  end

  defp opts(origin_channel) do
    %{
      agent_uid: "agent-1",
      workspace_id: 10_000,
      hosted_tools: [],
      available_tool_names: [],
      context: %{
        agent: %{display_name: "Agent One", role: ""},
        documents: %{"agents" => %{"content" => ""}},
        skills: [],
        conversation: %{
          timezone: "UTC",
          started_at: "",
          origin_channel: origin_channel,
          page_id: nil
        }
      }
    }
  end
end
