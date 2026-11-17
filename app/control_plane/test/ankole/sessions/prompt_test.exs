defmodule Ankole.Sessions.PromptTest do
  use ExUnit.Case, async: true
  alias Ankole.Sessions.Prompt

  @reply_rule "Keep the body of a chat reply within about 150 Chinese characters or 100 English words"
  @peer_rule "You are working in an asynchronous peer exchange."

  test "chat channels carry the reply length rule, external IM hides it, peer exchanges the peer rule, and channel-less sessions neither" do
    for channel <- [room(:participants), room(nil)] do
      prompt = Prompt.system(opts(channel))
      assert prompt =~ @reply_rule
      refute prompt =~ @peer_rule
    end

    for kind <- ["im_dm", "im_group"] do
      im_prompt = Prompt.system(opts(%{room(:participants) | kind: kind, adapter: "lark"}))
      refute im_prompt =~ @reply_rule
      refute im_prompt =~ @peer_rule
    end

    prompt = Prompt.system(opts(room(:agent_peer)))
    assert prompt =~ @peer_rule
    refute prompt =~ @reply_rule

    prompt = Prompt.system(opts(nil))
    refute prompt =~ @peer_rule
    refute prompt =~ @reply_rule
  end

  test "the instructions describe the mounted Drive whatever this turn's Worker reports" do
    mounted = Prompt.mounted_drive_instructions()
    assert mounted =~ "/drive/MyDrive"
    assert mounted =~ "-maxdepth"
    refute mounted =~ "/drive/my/"
    refute mounted =~ "/drive/spaces/"

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

  test "Pod placement instructions distinguish personal assistants from AI colleagues and carry owner UID to Jobs" do
    assistant_opts =
      room(:participants)
      |> opts()
      |> put_in([:context, :agent], %{
        display_name: "Alex's assistant",
        role: "",
        type: :personal_assistant,
        owner_principal_uid: "alex"
      })
      |> put_in([:context, :documents, "design"], %{"content" => ""})
      |> put_in([:context, :agent_plugins], [])

    assistant_prompt = Prompt.system(assistant_opts)
    assert assistant_prompt =~ "Owner UID: alex"
    assert assistant_prompt =~ ~s(private_owner_uid: "alex")
    assert assistant_prompt =~ "consider whether it fits better in your owner's Private section"
    assert assistant_prompt =~ "Lean toward Private"
    refute assistant_prompt =~ "to Private by default"
    assert assistant_prompt =~ "ankole-pod pages.tree"
    assert assistant_prompt =~ "ask the user"

    wire = Ankole.Sessions.TurnEnvelope.agent_context(assistant_opts.context)
    assert wire.conversation.pod_instructions =~ ~s(private_owner_uid: "alex")
    assert wire.conversation.pod_instructions =~ "Lean toward Private"

    colleague_opts =
      room(:participants)
      |> opts()
      |> put_in([:context, :agent, :type], :ai_colleague)

    colleague_prompt = Prompt.system(colleague_opts)
    refute colleague_prompt =~ "Owner UID:"
    refute colleague_prompt =~ "Lean toward Private"
    assert colleague_prompt =~ "inspect the current Workspace directory structure"
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
