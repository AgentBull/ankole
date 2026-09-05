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
    case Keyword.fetch(opts, :agent_plugin_sources) do
      {:ok, sources} ->
        {:ok, sources}

      :error ->
        roots = Keyword.get(opts, :library_roots)
        source_opts = if is_list(roots), do: [roots: roots], else: []
        SourceReader.read_trusted_agent_plugins(source_opts)
    end
  end

  @doc "Returns every Agent Plugin Skill source regardless of parent enablement."
  @spec skill_sources(keyword()) :: {:ok, [map()]} | {:error, term()}
  def skill_sources(opts \\ []) do
    with {:ok, agent_plugins} <- sources(opts),
         {:ok, skill_sources} <-
           agent_plugins
           |> Enum.flat_map(& &1.skills)
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
         {:ok, agent_plugins} <- sources(opts),
         {:ok, defaults} <- defaults(opts),
         opts =
           Keyword.merge(opts,
             agent_plugin_sources: agent_plugins,
             agent_library_defaults: defaults
           ),
         {:ok, _sync} <- Ankole.AIAgent.Library.sync_agent_skills(agent_uid, opts) do
      capabilities_from_sources(agent_uid, agent_plugins, opts)
    end
  end

  @doc false
  def capabilities_from_sources(agent_uid, agent_plugins, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, defaults} <- defaults(opts) do
      plugin_overrides = plugin_overrides(repo, agent_uid)
      skill_overrides = agent_plugin_skill_overrides(repo, agent_uid)

      {:ok,
       agent_plugins
       |> Enum.take(@max_catalog_plugins)
       |> Enum.map(&capability(&1, agent_uid, plugin_overrides, skill_overrides, defaults))}
    end
  end

  @doc false
  @spec enabled_catalog([map()]) :: [map()]
  def enabled_catalog(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.filter(& &1["effective_enabled"])
    |> Enum.map(&catalog_entry/1)
  end

  @spec validate_workspace_template_for_agent(String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def validate_workspace_template_for_agent(agent_uid, workspace_template_id, opts \\ [])

  def validate_workspace_template_for_agent(_agent_uid, nil, _opts), do: {:ok, nil}

  def validate_workspace_template_for_agent(agent_uid, workspace_template_id, opts)
      when is_binary(workspace_template_id) and is_list(opts) do
    with :ok <- Contract.validate_identifier(workspace_template_id),
         {:ok, capabilities} <- capabilities_for_agent(agent_uid, opts),
         {:ok, _capability} <- select_workspace_template(workspace_template_id, capabilities) do
      {:ok, workspace_template_id}
    end
  end

  def validate_workspace_template_for_agent(_agent_uid, _workspace_template_id, _opts),
    do: {:error, :invalid_workspace_template_id}

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
      "has_workspace_template" => agent_plugin.has_workspace_template,
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
    Map.get(defaults.agent_plugins, agent_plugin.id, agent_plugin.id not in ~w(github lark))
  end

  defp catalog_entry(capability) do
    %{
      "id" => capability["id"],
      "description" => capability["description"],
      "has_workspace_template" => capability["has_workspace_template"],
      "skills" =>
        capability["skills"]
        |> Enum.filter(& &1["effective_enabled"])
        |> Enum.map(&%{"catalog_name" => &1["name"]})
    }
  end

  defp select_workspace_template(workspace_template_id, capabilities) do
    case Enum.find(capabilities, &(&1["id"] == workspace_template_id)) do
      nil ->
        {:error, {:agent_plugin_not_found, workspace_template_id}}

      %{"effective_enabled" => false} ->
        {:error, {:agent_plugin_disabled, workspace_template_id}}

      %{"has_workspace_template" => false} ->
        {:error, {:agent_plugin_has_no_workspace_template, workspace_template_id}}

      capability ->
        {:ok, capability}
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
        Config.defaults(opts)
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
