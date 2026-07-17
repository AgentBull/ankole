defmodule Ankole.AIAgent.Library.AgentPlugins do
  @moduledoc """
  Trusted Agent Plugin discovery and inheritance.

  An Agent Plugin is a standard Codex Plugin package plus Ankole's optional
  `workspace-template/` initialization directory. Package bytes and versions
  stay in the installation library; PostgreSQL stores only sparse per-Agent
  enablement overrides.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library.AgentPlugins.Config
  alias Ankole.AIAgent.Library.AgentPlugins.Contract
  alias Ankole.AIAgent.Library.AgentPlugins.Schemas.AgentPluginOverride
  alias Ankole.AIAgent.Library.AgentPlugins.SourceReader
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.Principals
  alias Ankole.Principals.Agent
  alias Ankole.Repo

  @max_catalog_plugins 256

  @spec sources(keyword()) :: {:ok, [map()]} | {:error, term()}
  def sources(opts \\ []) do
    roots = Keyword.get(opts, :library_roots)
    source_opts = if is_list(roots), do: [roots: roots], else: []
    SourceReader.read_trusted_agent_plugins(source_opts)
  end

  @doc "Returns every Agent Plugin Skill source regardless of parent enablement."
  @spec skill_sources(keyword()) :: {:ok, [map()]} | {:error, term()}
  def skill_sources(opts \\ []) do
    with {:ok, agent_plugins} <- sources(opts),
         {:ok, skill_sources} <-
           agent_plugins
           |> Enum.flat_map(fn agent_plugin ->
             Enum.map(agent_plugin.skills, fn skill ->
               %{
                 skill
                 | source_hash: agent_plugin.content_hash,
                   default_enabled: true,
                   metadata:
                     skill.metadata
                     |> Map.put("agent_plugin_id", agent_plugin.id)
                     |> Map.put("agent_plugin_content_hash", agent_plugin.content_hash)
                     |> Map.put("agent_plugin_version", agent_plugin.version)
               }
             end)
           end)
           |> reject_duplicate_skill_names() do
      {:ok, skill_sources}
    end
  end

  @spec global_capabilities(keyword()) :: {:ok, [map()]} | {:error, term()}
  def global_capabilities(opts \\ []) do
    with {:ok, agent_plugins} <- sources(opts),
         {:ok, defaults} <- defaults(opts) do
      {:ok,
       agent_plugins
       |> Enum.take(@max_catalog_plugins)
       |> Enum.map(&capability(&1, nil, %{}, %{}, defaults))}
    end
  end

  @spec capabilities_for_agent(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def capabilities_for_agent(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         :ok <- ensure_agent(repo, agent_uid),
         {:ok, _sync} <- Ankole.AIAgent.Library.sync_agent_skills(agent_uid, opts),
         {:ok, agent_plugins} <- sources(opts),
         {:ok, defaults} <- defaults(opts) do
      plugin_overrides = plugin_overrides(repo, agent_uid)
      skill_overrides = agent_plugin_skill_overrides(repo, agent_uid)

      {:ok,
       agent_plugins
       |> Enum.take(@max_catalog_plugins)
       |> Enum.map(&capability(&1, agent_uid, plugin_overrides, skill_overrides, defaults))}
    end
  end

  @spec enabled_catalog_for_agent(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def enabled_catalog_for_agent(agent_uid, opts \\ []) do
    with {:ok, capabilities} <- capabilities_for_agent(agent_uid, opts) do
      {:ok,
       capabilities
       |> Enum.filter(& &1["effective_enabled"])
       |> Enum.map(&catalog_entry/1)}
    end
  end

  @spec validate_selection_for_agent(String.t(), [String.t()], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def validate_selection_for_agent(agent_uid, agent_plugin_ids, opts \\ [])

  def validate_selection_for_agent(agent_uid, agent_plugin_ids, opts)
      when is_list(agent_plugin_ids) and length(agent_plugin_ids) <= 16 and is_list(opts) do
    with {:ok, agent_plugin_ids} <- validate_agent_plugin_ids(agent_plugin_ids),
         {:ok, capabilities} <- capabilities_for_agent(agent_uid, opts),
         {:ok, _selected} <- select_capabilities(agent_plugin_ids, capabilities) do
      {:ok, agent_plugin_ids}
    end
  end

  def validate_selection_for_agent(_agent_uid, _agent_plugin_ids, _opts),
    do: {:error, :invalid_agent_plugin_selection}

  @spec set_global_default(String.t(), boolean(), keyword()) :: {:ok, map()} | {:error, term()}
  def set_global_default(agent_plugin_id, enabled, opts \\ [])

  def set_global_default(agent_plugin_id, enabled, opts) when is_boolean(enabled) do
    with :ok <- Contract.validate_identifier(agent_plugin_id),
         {:ok, agent_plugins} <- sources(opts),
         %{} <- Enum.find(agent_plugins, &(&1.id == agent_plugin_id)) do
      Config.put_agent_plugin_default(agent_plugin_id, enabled)
    else
      nil -> {:error, :agent_plugin_not_found}
      {:error, _reason} = error -> error
    end
  end

  def set_global_default(_agent_plugin_id, _enabled, _opts),
    do: {:error, :invalid_agent_plugin_default}

  @spec set_global_skill_default(String.t(), boolean(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def set_global_skill_default(skill_id, enabled, opts \\ [])

  def set_global_skill_default(skill_id, enabled, opts) when is_boolean(enabled) do
    with {:ok, agent_plugins} <- sources(opts),
         true <- member_skill_id?(agent_plugins, skill_id) do
      Config.put_skill_default(skill_id, enabled)
    else
      false -> {:error, :skill_not_found}
      {:error, _reason} = error -> error
    end
  end

  def set_global_skill_default(_skill_id, _enabled, _opts),
    do: {:error, :invalid_skill_default}

  @spec set_agent_override(String.t(), String.t(), boolean() | nil, keyword()) ::
          {:ok, AgentPluginOverride.t() | nil} | {:error, term()}
  def set_agent_override(agent_uid, agent_plugin_id, enabled, opts \\ [])

  def set_agent_override(agent_uid, agent_plugin_id, enabled, opts)
      when is_boolean(enabled) or is_nil(enabled) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         :ok <- ensure_agent(repo, agent_uid),
         :ok <- Contract.validate_identifier(agent_plugin_id),
         {:ok, agent_plugins} <- sources(opts),
         %{} <- Enum.find(agent_plugins, &(&1.id == agent_plugin_id)) do
      persist_agent_override(repo, agent_uid, agent_plugin_id, enabled)
    else
      nil -> {:error, :agent_plugin_not_found}
      {:error, _reason} = error -> error
    end
  end

  def set_agent_override(_agent_uid, _agent_plugin_id, _enabled, _opts),
    do: {:error, :invalid_agent_plugin_override}

  @spec effective_enabled?(String.t(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def effective_enabled?(agent_uid, agent_plugin_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         :ok <- ensure_agent(repo, agent_uid),
         :ok <- Contract.validate_identifier(agent_plugin_id),
         {:ok, agent_plugins} <- sources(opts),
         %{} = agent_plugin <- Enum.find(agent_plugins, &(&1.id == agent_plugin_id)),
         {:ok, defaults} <- defaults(opts) do
      override = Map.get(plugin_overrides(repo, agent_uid), agent_plugin_id)
      {:ok, effective_plugin_enabled(agent_plugin, override, defaults)}
    else
      nil -> {:error, :agent_plugin_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec stable_skill_id(String.t(), String.t()) :: String.t()
  def stable_skill_id(agent_plugin_id, skill_name), do: "#{agent_plugin_id}:#{skill_name}"

  defp capability(agent_plugin, agent_uid, plugin_overrides, skill_overrides, defaults) do
    global_default = global_plugin_default(agent_plugin, defaults)

    override = Map.get(plugin_overrides, agent_plugin.id)
    effective = effective_plugin_enabled(agent_plugin, override, defaults)

    skills =
      Enum.map(agent_plugin.skills, fn skill ->
        id = stable_skill_id(agent_plugin.id, skill.name)
        skill_global_default = Map.get(defaults.skills, id, true)
        skill_override = Map.get(skill_overrides, skill.name)

        skill_enabled =
          if is_boolean(skill_override), do: skill_override, else: skill_global_default

        %{
          "id" => id,
          "name" => skill.name,
          "description" => skill.description,
          "source_kind" => "builtin",
          "agent_plugin_id" => agent_plugin.id,
          "global_default_enabled" => skill_global_default,
          "override_enabled" => if(agent_uid, do: skill_override, else: nil),
          "effective_enabled" => effective and skill_enabled
        }
      end)

    %{
      "id" => agent_plugin.id,
      "description" => agent_plugin.description,
      "version" => agent_plugin.version,
      "content_hash" => agent_plugin.content_hash,
      "global_default_enabled" => global_default,
      "override_enabled" => if(agent_uid, do: override, else: nil),
      "effective_enabled" => effective,
      "skills" => skills
    }
  end

  defp effective_plugin_enabled(agent_plugin, override, defaults) do
    if is_boolean(override), do: override, else: global_plugin_default(agent_plugin, defaults)
  end

  defp global_plugin_default(agent_plugin, defaults) do
    Map.get(defaults.agent_plugins, agent_plugin.id, agent_plugin.id != "lark")
  end

  defp catalog_entry(capability) do
    %{
      "id" => capability["id"],
      "description" => capability["description"],
      "version" => capability["version"],
      "content_hash" => capability["content_hash"],
      "skills" =>
        capability["skills"]
        |> Enum.filter(& &1["effective_enabled"])
        |> Enum.map(fn skill ->
          %{
            "catalog_name" => skill["name"],
            "codex_name" => stable_skill_id(capability["id"], skill["name"])
          }
        end)
    }
  end

  defp select_capabilities(ids, capabilities) do
    by_id = Map.new(capabilities, &{&1["id"], &1})

    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, selected} ->
      case Map.get(by_id, id) do
        nil ->
          {:halt, {:error, {:agent_plugin_not_found, id}}}

        %{"effective_enabled" => false} ->
          {:halt, {:error, {:agent_plugin_disabled, id}}}

        capability ->
          {:cont, {:ok, [capability | selected]}}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_agent_plugin_ids(ids) do
    cond do
      Enum.any?(ids, &(Contract.validate_identifier(&1) != :ok)) ->
        {:error, :invalid_agent_plugin_ids}

      Enum.uniq(ids) != ids ->
        {:error, :duplicate_agent_plugin_id}

      true ->
        {:ok, Enum.sort(ids)}
    end
  end

  defp persist_agent_override(repo, agent_uid, agent_plugin_id, nil) do
    AgentPluginOverride
    |> where(
      [override],
      override.agent_uid == ^agent_uid and override.agent_plugin_id == ^agent_plugin_id
    )
    |> repo.delete_all()

    {:ok, nil}
  end

  defp persist_agent_override(repo, agent_uid, agent_plugin_id, enabled) do
    attrs = %{agent_uid: agent_uid, agent_plugin_id: agent_plugin_id, enabled: enabled}

    %AgentPluginOverride{}
    |> AgentPluginOverride.changeset(attrs)
    |> repo.insert(
      on_conflict: {:replace, [:enabled, :updated_at]},
      conflict_target: [:agent_uid, :agent_plugin_id],
      returning: true
    )
  end

  defp plugin_overrides(repo, agent_uid) do
    AgentPluginOverride
    |> where([override], override.agent_uid == ^agent_uid)
    |> repo.all()
    |> Map.new(&{&1.agent_plugin_id, &1.enabled})
  end

  defp agent_plugin_skill_overrides(repo, agent_uid) do
    AgentSkill
    |> where([skill], skill.agent_uid == ^agent_uid and not is_nil(skill.agent_plugin_id))
    |> repo.all()
    |> Map.new(&{&1.skill_name, &1.enabled_override})
  end

  defp defaults(opts) do
    case Keyword.get(opts, :agent_library_defaults) do
      %{agent_plugins: agent_plugins, skills: skills}
      when is_map(agent_plugins) and is_map(skills) ->
        {:ok, %{agent_plugins: agent_plugins, skills: skills}}

      _value ->
        Config.defaults()
    end
  end

  defp ensure_agent(repo, agent_uid) do
    case repo.get(Agent, agent_uid) do
      %Agent{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  defp member_skill_id?(agent_plugins, skill_id) do
    Enum.any?(agent_plugins, fn agent_plugin ->
      Enum.any?(agent_plugin.skills, fn skill ->
        stable_skill_id(agent_plugin.id, skill.name) == skill_id
      end)
    end)
  end

  defp reject_duplicate_skill_names(sources) do
    duplicates =
      sources
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case duplicates do
      [] -> {:ok, sources}
      _names -> {:error, {:agent_plugin_skill_name_conflicts, duplicates}}
    end
  end
end
