defmodule Ankole.Sessions.ToolCatalog do
  @moduledoc "Builds the tool contract for the current run from its owning declarations."

  alias Ankole.Sessions.Tool
  alias Ankole.Sessions.Tools

  @worker_path Path.expand(
                 "../../../../kernel/proto/ankole/runtime_fabric/v1/worker_tools.json",
                 __DIR__
               )
  @external_resource @worker_path
  @worker_tools @worker_path |> File.read!() |> Ankole.JSON.decode!()

  def for_run(run) do
    client =
      Enum.flat_map(
        [
          Tools.Session,
          Tools.Schedule,
          Tools.Jobs,
          Tools.Workflow,
          Tools.Skill,
          Tools.Web,
          Ankole.Sessions.Scheduled,
          Ankole.Sessions.Presentation,
          Tools.Message
        ],
        fn owner ->
          Code.ensure_loaded!(owner)

          declarations =
            if function_exported?(owner, :declarations, 1),
              do: owner.declarations(run),
              else: owner.declarations()

          Enum.map(declarations, &Map.put(&1, "executor", owner))
        end
      )

    worker = Enum.map(@worker_tools, &Map.put(&1, "executor", :worker))

    {tools, hosted} =
      Ankole.Sessions.Run.type(run).tools(
        run,
        Enum.filter(worker ++ client, &Tool.available?(&1, run.kind)),
        run.spec[:hosted_tools] || []
      )

    {Enum.map(tools, &Tool.new(Map.delete(&1, "executor"), &1["executor"])), hosted}
  end

  def wire(tools), do: Enum.map(tools, & &1.schema)

  def find(run, call) do
    Enum.find(run.tools, fn tool ->
      tool.name == call["name"] and
        namespace(tool.schema["namespace"]) == namespace(call["namespace"])
    end)
  end

  def namespace(value) when value in [nil, "", "functions"], do: "functions"
  def namespace(value), do: value
end
