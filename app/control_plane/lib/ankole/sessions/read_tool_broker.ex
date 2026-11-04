defmodule Ankole.Sessions.ReadToolBroker do
  @moduledoc "The fenced Job adapter for the Sessions read-tool owners."
  alias Ankole.AIAgent.Library
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.ToolArguments
  alias Ankole.Sessions.ToolResult
  alias Ankole.Sessions.Tools
  alias Ankole.RuntimeFabric.V1, as: Proto
  alias Ankole.AgentWorkers.RPCWire

  # The read-tool owners a Job may call through `tools.read`. Web text crosses
  # this fenced boundary one page at a time for Worker workspace materialization.
  @owners [Tools.Skill, Tools.Web, Tools.Brain, Tools.RelatedContext]

  def handle_read(%JobTurnRef{} = turn, %Proto.ReadToolRequest{} = request, ctx) do
    with {:ok, owner, declaration} <- declaration(request.name),
         {:ok, args} <- Ankole.JSON.decode(request.arguments_json),
         {:ok, args, page_index} <- web_page_index(request.name, args),
         {:ok, args} <- ToolArguments.validate(declaration["parameters"], args),
         :ok <- Tools.authorize_call(turn, declaration["name"], args),
         {:ok, result} <- execute(owner, turn, request, args, page_index) do
      {:ok, project(result)}
    else
      {:error, reason} ->
        {:error,
         RPCWire.error_payload(ctx.request_id, reason,
           fallback_code: "read_tool_failed",
           message_style: :tuple_inspect,
           details_json: %{"tool" => request.name}
         )}
    end
  end

  # Authorize the original model arguments, not the selected transport page.
  defp web_page_index("web_fetch", %{} = args) do
    {index, args} = Map.pop(args, "_workspace_page", 0)

    if is_integer(index) and index >= 0 and is_list(args["urls"]) and
         index < length(args["urls"]) and args["result_offset"] in [nil, 0],
       do: {:ok, args, index},
       else: {:error, :invalid_read_tool_context}
  end

  defp web_page_index(_name, args), do: {:ok, args, nil}

  defp execute(owner, turn, request, args, nil), do: execute(owner, turn, request, args)

  defp execute(Tools.Web, turn, request, args, index) do
    args = args |> Map.put("urls", [Enum.at(args["urls"], index)]) |> Map.delete("result_offset")
    execute(Tools.Web, turn, request, args)
  end

  defp declaration(name) do
    Enum.find_value(@owners, {:error, :unknown_read_tool}, fn owner ->
      case Enum.find(owner.declarations(), &(&1["name"] == name)) do
        nil -> nil
        tool -> {:ok, owner, tool}
      end
    end)
  end

  defp execute(Tools.Skill, turn, _request, args) do
    with {:ok, context} <-
           Ankole.Brain.RequestContext.build(turn.agent_uid, %{"signal_id" => turn.signal_id}),
         {:ok, projection} <-
           Ankole.BackgroundAgentJobs.RuntimeProjection.for_signal(turn.agent_uid, turn.signal_id),
         {:ok, skills} <-
           Library.runtime_skills_for_agent(turn.agent_uid,
             request_context: context,
             runtime_projection: projection
           ),
         do:
           Tools.Skill.view(
             turn.agent_uid,
             args,
             "background_job",
             skills,
             context,
             turn.signal_id
           )
  end

  defp execute(Tools.Brain, turn, request, args), do: Tools.Brain.read(turn, request.name, args)

  defp execute(Tools.RelatedContext, turn, request, args) do
    run = turn |> Map.from_struct() |> Map.put(:event, Ankole.Signals.get_signal!(turn.signal_id))
    Tools.RelatedContext.execute(run, %{"name" => request.name}, args)
  end

  defp execute(Tools.Web, turn, request, args) do
    with {:ok, cache} <- decode_object(request.web_cache_json),
         {:ok, rendered} <- decode_object(request.rendered_body_json),
         :ok <- validate_context(cache, rendered) do
      cache = Map.new(cache, fn {url, page} -> {url, %{at: page["at"], page: page["page"]}} end)
      run = %{agent_uid: turn.agent_uid, web_cache: cache, web_result_mode: :workspace}

      if request.rendered_body_json != <<>>,
        do: Tools.Web.render(run, rendered, args["urls"], args["result_offset"] || 0),
        else: Tools.Web.execute(run, %{"name" => request.name}, args)
    end
  end

  defp decode_object(<<>>), do: {:ok, %{}}

  defp decode_object(bytes) do
    case Ankole.JSON.decode(bytes) do
      {:ok, %{} = value} -> {:ok, value}
      _ -> {:error, :invalid_read_tool_context}
    end
  end

  defp validate_context(cache, rendered) do
    cached? =
      map_size(cache) <= 100 and
        Enum.all?(cache, fn
          {url, %{"at" => at, "page" => page}} when is_binary(url) and is_integer(at) ->
            page?(page)

          _ ->
            false
        end)

    rendered? =
      rendered == %{} or
        (is_list(rendered["results"]) and Enum.all?(rendered["results"], &page?/1))

    if cached? and rendered?, do: :ok, else: {:error, :invalid_read_tool_context}
  end

  defp page?(%{} = page) do
    Enum.all?(~w(text title error), &(is_nil(page[&1]) or is_binary(page[&1]))) and
      (is_nil(page["metadata"]) or is_map(page["metadata"]))
  end

  defp page?(_), do: false

  defp project(%ToolResult{} = result),
    do: ToolResult.encode(result) |> Map.put("web_cache", result.web_cache)

  defp project({:delegate, name, args, _complete}),
    do: %{"delegate" => %{"name" => name, "arguments" => args}}
end
