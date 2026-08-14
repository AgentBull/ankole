defmodule Ankole.BackgroundAgentJobs.RuntimeProjection do
  @moduledoc """
  Captures the small, non-secret execution projection owned by one Job.

  The projection keeps logical choices stable across Worker loss. Skill files,
  overlays, API keys, and short-lived binding credentials stay with their
  existing owners and are resolved again by the Worker.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Compaction
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv

  @version 1

  @spec capture(module(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def capture(repo, agent_uid, turn_start_spec)
      when is_atom(repo) and is_binary(agent_uid) and is_map(turn_start_spec) do
    with %{} = model_ref <- Map.get(turn_start_spec, :model_ref),
         {:ok, skills} <- Library.skills_for_system_prompt(agent_uid, repo: repo),
         {:ok, agent_plugins} <- AgentPlugins.enabled_catalog_for_agent(agent_uid, repo: repo),
         {:ok, worker_env} <- WorkerEnv.runtime_projection(agent_uid, repo: repo) do
      request_context = Map.get(turn_start_spec, :request_context, %{})

      projection =
        %{
          "version" => @version,
          "model_ref" => model_ref,
          "runtime_policy" => Map.get(request_context, "ai_agent", %{}),
          "codex" => %{
            "remote_compaction_v2" => remote_compaction_v2?(agent_uid, model_ref)
          },
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

  @spec turn_start_overrides(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def turn_start_overrides(projection, opts \\ [])

  def turn_start_overrides(
        %{
          "version" => @version,
          "model_ref" => %{} = model_ref,
          "runtime_policy" => %{} = runtime_policy
        } = projection,
        opts
      ) do
    model_ref =
      if legacy_model_ref?(model_ref) do
        complete_legacy_model_ref(model_ref, current_model_ref(model_ref, opts))
      else
        model_ref
      end

    with {:ok, codex} <- codex_projection(projection),
         {:ok, hosted_tool_overrides} <- hosted_tool_overrides(projection) do
      {:ok,
       Map.merge(
         %{
           model_ref: model_ref,
           request_context: %{
             "model_ref" => model_ref,
             "ai_agent" => runtime_policy,
             "codex" => codex
           }
         },
         hosted_tool_overrides
       )}
    end
  end

  def turn_start_overrides(_projection, _opts),
    do: {:error, :background_agent_job_runtime_projection_invalid}

  @doc false
  @spec complete_legacy_capabilities(map(), map()) :: map()
  def complete_legacy_capabilities(
        %{"model_ref" => %{} = frozen_ref} = projection,
        %{model_ref: %{} = turn_model_ref}
      ) do
    if legacy_model_ref?(frozen_ref) and same_model?(frozen_ref, turn_model_ref) do
      Map.put(projection, "model_ref", copy_model_capabilities(frozen_ref, turn_model_ref))
    else
      projection
    end
  end

  def complete_legacy_capabilities(projection, _turn_start_spec), do: projection

  defp current_model_ref(model_ref, opts) do
    case Keyword.get(opts, :current_model_ref) do
      %{} = current ->
        current

      _missing ->
        case Keyword.get(opts, :agent_uid) do
          agent_uid when is_binary(agent_uid) ->
            ModelProfiles.complete_legacy_model_ref(agent_uid, model_ref)

          _unavailable ->
            nil
        end
    end
  end

  defp complete_legacy_model_ref(model_ref, current_model_ref) do
    cond do
      not legacy_model_ref?(model_ref) ->
        model_ref

      same_model?(model_ref, current_model_ref) ->
        copy_model_capabilities(model_ref, current_model_ref)

      true ->
        Map.put(model_ref, "input_modalities", ["text"])
    end
  end

  defp copy_model_capabilities(model_ref, current_model_ref) do
    model_ref
    |> Map.put(
      "input_modalities",
      normalize_input_modalities(Map.get(current_model_ref, "input_modalities"))
    )
    |> copy_optional_capability(current_model_ref, "vision_fallback_model_ref")
  end

  defp copy_optional_capability(model_ref, current_model_ref, key) do
    case Map.get(current_model_ref, key) do
      %{} = value -> Map.put(model_ref, key, value)
      _missing -> Map.delete(model_ref, key)
    end
  end

  defp normalize_input_modalities(modalities) when is_list(modalities) do
    modalities = modalities |> Enum.map(&to_string/1) |> Enum.uniq()
    if "text" in modalities, do: modalities, else: ["text" | modalities]
  end

  defp normalize_input_modalities(_modalities), do: ["text"]

  defp legacy_model_ref?(model_ref) do
    case Map.get(model_ref, "input_modalities") do
      [_ | _] -> false
      _missing -> true
    end
  end

  defp same_model?(frozen_ref, current_ref) when is_map(current_ref) do
    Enum.all?(["provider_kind", "model"], fn key ->
      value = Map.get(frozen_ref, key)
      is_binary(value) and value != "" and value == Map.get(current_ref, key)
    end)
  end

  defp same_model?(_frozen_ref, _current_ref), do: false

  defp remote_compaction_v2?(agent_uid, model_ref) do
    Map.get(model_ref, "provider_kind") == "chatgpt_subscription" and
      Compaction.prefer_upstream?(agent_uid)
  end

  defp codex_projection(%{
         "codex" => %{"remote_compaction_v2" => remote_compaction_v2}
       })
       when is_boolean(remote_compaction_v2),
       do: {:ok, %{"remote_compaction_v2" => remote_compaction_v2}}

  defp codex_projection(projection) do
    if Map.has_key?(projection, "codex") do
      {:error, :background_agent_job_runtime_projection_invalid}
    else
      {:ok, %{"remote_compaction_v2" => false}}
    end
  end

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
