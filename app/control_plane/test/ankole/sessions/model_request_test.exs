defmodule Ankole.Sessions.ModelRequestTest do
  use ExUnit.Case, async: true
  alias Ankole.Sessions.Model
  alias Ankole.Sessions.Presentation
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Tool
  alias Ankole.Sessions.ToolArguments
  alias Ankole.Sessions.Tools
  alias Ankole.Signals.Signal

  test "a scheduled round with client tools does not force JSON" do
    tool =
      Tool.new(
        %{"type" => "function", "name" => "command", "parameters" => %{"type" => "object"}},
        :worker
      )

    request = Model.request(%{run() | tools: [tool]})
    assert [%{"name" => "command"}] = request["tools"]
    refute Map.has_key?(request, "text")
    refute Map.has_key?(request, "tool_choice")
  end

  test "a scheduled round with hosted tools does not force JSON" do
    request = Model.request(%{run() | hosted_tools: [%{"type" => "brain"}]})
    assert request["tools"] == [%{"type" => "brain"}]
    refute Map.has_key?(request, "text")
  end

  test "scheduled terminal tools do not force a provider JSON format" do
    finish =
      Tool.new(hd(Ankole.Sessions.Scheduled.declarations()), Ankole.Sessions.Scheduled)

    for iteration <- [0, 1, 5] do
      request = Model.request(%{run() | tools: [finish], iteration: iteration})
      assert [%{"name" => "finish_scheduled"}] = request["tools"]
      refute Map.has_key?(request, "text")
      refute Map.has_key?(request, "response_format")
    end
  end

  test "an ordinary round without tools has no scheduled result schema" do
    refute Map.has_key?(Model.request(%{run() | kind: :main}), "text")
  end

  test "function parameters reach the provider without root combinators while calls still follow the declaration" do
    [attachment] = Presentation.declarations()
    [message] = Tools.Message.declarations()
    attachment_tool = Tool.new(attachment, Presentation)
    message_tool = Tool.new(message, Tools.Message)
    run = %{run() | kind: :main, tools: [attachment_tool, message_tool]}

    assert [
             %{"name" => "reply_attachment", "parameters" => attachment_wire, "strict" => false},
             %{"name" => "send_message", "parameters" => message_wire}
           ] = Model.request(run)["tools"]

    assert attachment_wire == Map.delete(attachment["parameters"], "oneOf")
    assert message_wire == message["parameters"]
    assert %{"oneOf" => [_, _]} = message_wire["properties"]["destination"]

    for args <- [%{"node_id" => "node"}, %{"path" => "/drive/report.txt"}] do
      assert {:ok, ^args} = ToolArguments.validate(attachment_tool.schema["parameters"], args)
    end

    for args <- [%{}, %{"node_id" => "node", "path" => "/drive/report.txt"}] do
      call = %{"name" => "reply_attachment", "arguments" => Ankole.JSON.encode!(args)}
      assert {:error, %{failure_kind: "invalid_arguments"}} = Tools.prepare(run, call)
    end
  end

  test "appends server tool_search and programmatic_tool_calling when catalog declares deferred and programmatic tools" do
    read_tool =
      Tool.new(
        %{
          "type" => "function",
          "name" => "pod_list_pages",
          "allowed_callers" => ["direct", "programmatic"],
          "parameters" => %{"type" => "object"}
        },
        Ankole.Sessions.Tools.Pod
      )

    deferred_tool =
      Tool.new(
        %{
          "type" => "function",
          "name" => "set_channel_standing_orders",
          "defer_loading" => true,
          "parameters" => %{"type" => "object"}
        },
        Ankole.Sessions.Tools.Session
      )

    request = Model.request(%{run() | kind: :main, tools: [read_tool, deferred_tool]})

    assert %{"type" => "tool_search", "execution" => "server"} in request["tools"]
    assert %{"type" => "programmatic_tool_calling"} in request["tools"]
  end

  defp run do
    %Run{
      agent_uid: "test-agent",
      session_id: "cron:test",
      signal_id: "test-event",
      epoch: 1,
      event: %Signal{producer: :kernel, type: "cron.fire", data: %{}},
      kind: :scheduled,
      conversation: %{id: "test-conversation"},
      spec: %{
        model_ref: %{
          "provider_id" => "openrouter",
          "model" => "deepseek/deepseek-v4.1-flash",
          "profile" => "primary"
        },
        request_context: %{"ai_agent" => %{}}
      },
      instructions: "Complete this scheduled task.",
      input: []
    }
  end
end
