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
  @programmatic_worker_tools ~w(read_file find grep ls)

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
          Tools.Peers,
          Tools.RelatedContext,
          Tools.Pod,
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

    worker =
      Enum.map(@worker_tools, fn declaration ->
        declaration
        |> maybe_allow_programmatic_worker_tool()
        |> Map.put("executor", :worker)
      end)

    {tools, hosted} =
      Ankole.Sessions.Run.type(run).tools(
        run,
        Enum.filter(worker ++ client, &Tool.available?(&1, run.kind)),
        run.spec[:hosted_tools] || []
      )

    {Enum.map(tools, &Tool.new(Map.delete(&1, "executor"), &1["executor"])), hosted}
  end

  defp maybe_allow_programmatic_worker_tool(%{"name" => name} = declaration)
       when name in @programmatic_worker_tools do
    Map.put_new(declaration, "allowed_callers", ["direct", "programmatic"])
  end

  defp maybe_allow_programmatic_worker_tool(declaration), do: declaration

  # Azure OpenAI Chat Completions rejects a function whose parameters carry one
  # of these keys at the root. Every provider receives the plain object schema,
  # while Tools.prepare/2 still validates each call against the full declaration.
  @provider_rejected_root_keys ~w(oneOf anyOf allOf enum const not)

  def wire(tools), do: Enum.map(tools, &wire_schema(&1.schema))

  defp wire_schema(%{"parameters" => %{} = parameters} = schema),
    do: %{schema | "parameters" => Map.drop(parameters, @provider_rejected_root_keys)}

  defp wire_schema(schema), do: schema

  def find(run, call) do
    Enum.find(run.tools, fn tool ->
      tool.name == call["name"] and
        namespace(tool.schema["namespace"]) == namespace(call["namespace"])
    end)
  end

  def namespace(value) when value in [nil, "", "functions"], do: "functions"
  def namespace(value), do: value
end
