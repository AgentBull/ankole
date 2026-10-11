defmodule Ankole.BackgroundAgentJobs.RuntimeProjection do
  @moduledoc """
  Captures the small, non-secret execution projection owned by one Job.

  The projection keeps logical choices stable across Worker loss. Skill files,
  overlays, API keys, and short-lived binding credentials stay with their
  existing owners and are resolved again by the Worker.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv

  @version 1

  @spec capture(module(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def capture(repo, agent_uid, turn_start_spec)
      when is_atom(repo) and is_binary(agent_uid) and is_map(turn_start_spec) do
    with %{} = model_ref <- Map.get(turn_start_spec, :model_ref),
         {:ok, %{"skills" => skills, "agent_plugins" => agent_plugins}} <-
           Library.runtime_catalog_for_agent(agent_uid, repo: repo),
         {:ok, worker_env} <- WorkerEnv.runtime_projection(agent_uid, repo: repo) do
      request_context = Map.get(turn_start_spec, :request_context, %{})

      projection =
        %{
          "version" => @version,
          "model_ref" => model_ref,
          "runtime_policy" => Map.get(request_context, "ai_agent", %{}),
          "skills" => Enum.map(skills, &skill_selection/1),
          "agent_plugins" => Enum.map(agent_plugins, &agent_plugin_selection/1),
          "native_mcp_servers" => [],
          "worker_env" => worker_env,
          "browser" => %{"mode" => "persistent"}
        }
        |> maybe_put_hosted_tools(turn_start_spec)

      {:ok, projection}
    else
      nil -> {:error, :background_agent_job_model_ref_missing}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the Job's Skills: its frozen choices that still exist in the current
  catalog. Standalone Skills come first in name order. Agent Plugin Skills
  follow in the projection's plugin order, in catalog name order inside each
  plugin. Resume can remove a choice but never adds one.
  """
  @spec selected_skills(map(), [map()], [map()]) :: [map()]
  def selected_skills(projection, skills, agent_plugins) do
    names =
      for %{"name" => name} = skill <- projection["skills"],
          skill["agent_plugin_id"] in [nil, ""],
          into: MapSet.new(),
          do: name

    standalone =
      skills
      |> Enum.filter(&(&1["agent_plugin_id"] in [nil, ""] and &1["skill_name"] in names))
      |> Enum.sort_by(& &1["skill_name"])

    plugins = Map.new(agent_plugins, &{&1["id"], &1})
    members = Map.new(skills, &{{&1["agent_plugin_id"], &1["skill_name"]}, &1})

    plugin_skills =
      Enum.flat_map(projection["agent_plugins"], fn %{"id" => id, "skills" => selected} ->
        case plugins[id] do
          nil ->
            []

          plugin ->
            plugin["skills"]
            |> Enum.map(& &1["catalog_name"])
            |> Enum.filter(&(&1 in selected))
            |> Enum.sort()
            |> Enum.map(&Map.fetch!(members, {id, &1}))
        end
      end)

    standalone ++ plugin_skills
  end

  @spec turn_start_overrides(map()) :: {:ok, map()} | {:error, term()}
  def turn_start_overrides(
        %{
          "version" => @version,
          "model_ref" => %{} = model_ref,
          "runtime_policy" => %{} = runtime_policy
        } = projection
      ) do
    with {:ok, hosted_tool_overrides} <- hosted_tool_overrides(projection) do
      {:ok,
       Map.merge(
         %{
           model_ref: model_ref,
           request_context: %{
             "ai_agent" => runtime_policy
           }
         },
         hosted_tool_overrides
       )}
    end
  end

  def turn_start_overrides(_projection),
    do: {:error, :background_agent_job_runtime_projection_invalid}

  defp maybe_put_hosted_tools(projection, turn_start_spec) do
    case Map.fetch(turn_start_spec, :hosted_tools) do
      {:ok, hosted_tools} -> Map.put(projection, "hosted_tools", hosted_tools)
      :error -> projection
    end
  end

  defp hosted_tool_overrides(projection) do
    case Map.fetch(projection, "hosted_tools") do
      {:ok, [_ | _] = hosted_tools} ->
        if Enum.all?(hosted_tools, &is_map/1) do
          {:ok, %{hosted_tools: hosted_tools}}
        else
          {:error, :background_agent_job_runtime_projection_invalid}
        end

      :error ->
        {:ok, %{}}

      _invalid ->
        {:error, :background_agent_job_runtime_projection_invalid}
    end
  end

  defp skill_selection(skill) do
    name = Map.fetch!(skill, "skill_name")
    agent_plugin_id = Map.get(skill, "agent_plugin_id")

    %{
      "id" => if(agent_plugin_id, do: "#{agent_plugin_id}:#{name}", else: name),
      "name" => name,
      "agent_plugin_id" => agent_plugin_id,
      "source_kind" => Map.get(skill, "source_kind"),
      "relative_path" => Map.get(skill, "relative_path")
    }
  end

  defp agent_plugin_selection(agent_plugin) do
    %{
      "id" => Map.fetch!(agent_plugin, "id"),
      "skills" =>
        agent_plugin
        |> Map.fetch!("skills")
        |> Enum.map(&Map.fetch!(&1, "catalog_name"))
        |> Enum.sort()
    }
  end
end
