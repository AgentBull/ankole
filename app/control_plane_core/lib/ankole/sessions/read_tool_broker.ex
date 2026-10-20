defmodule Ankole.Sessions.ReadToolBroker do
  @moduledoc "The fenced Job adapter for the Sessions read-tool owners."
  alias Ankole.AIAgent.Library
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.ToolArguments
  alias Ankole.Sessions.ToolResult
  alias Ankole.Sessions.Tools
  alias Ankole.RuntimeFabric.V1, as: Proto
  alias Ankole.AgentWorkers.RPCWire

  def handle_read(%JobTurnRef{} = turn, %Proto.ReadToolRequest{} = request, ctx) do
    with {:ok, owner, declaration} <- declaration(request.name),
         {:ok, args} <- Ankole.JSON.decode(request.arguments_json),
         {:ok, args} <- ToolArguments.validate(declaration["parameters"], args),
         {:ok, result} <- execute(owner, turn.agent_uid, request, args) do
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

  defp declaration(name) do
    owner = if name == "skill_view", do: Tools.Skill, else: Tools.Web

    case Enum.find(owner.declarations(), &(&1["name"] == name)) do
      nil -> {:error, :unknown_read_tool}
      tool -> {:ok, owner, tool}
    end
  end

  defp execute(Tools.Skill, agent_uid, _request, args) do
    with {:ok, skills} <- Library.runtime_skills_for_agent(agent_uid),
         do: Tools.Skill.view(agent_uid, args, "background_job", skills)
  end

  defp execute(Tools.Web, agent_uid, request, args) do
    with {:ok, cache} <- decode_object(request.web_cache_json),
         {:ok, rendered} <- decode_object(request.rendered_body_json),
         :ok <- validate_context(cache, rendered) do
      cache = Map.new(cache, fn {url, page} -> {url, %{at: page["at"], page: page["page"]}} end)
      run = %{agent_uid: agent_uid, web_cache: cache}

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
