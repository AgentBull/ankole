defmodule Ankole.Sessions.WorkflowTaskToolsTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.HostedTools.Brain
  alias Ankole.Sessions.WorkflowTask

  test "a task's read-only Brain catalog passes the hosted declaration contract" do
    {_tools, hosted} = WorkflowTask.tools(nil, [], [%{"type" => "brain"}])

    assert {:ok, %{operations: operations, inject?: false}} =
             Brain.declaration(%{"tools" => hosted})

    assert operations == ~w(recall entity)
  end

  test "a task retains Web search and excludes other hosted capabilities" do
    search = %{"type" => "web_search", "search_context_size" => "high"}
    tools = [:task_tool]

    assert {^tools, [^search]} =
             WorkflowTask.tools(nil, tools, [search, %{"type" => "image_generation"}])
  end
end
