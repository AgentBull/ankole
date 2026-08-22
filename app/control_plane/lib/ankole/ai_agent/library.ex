defmodule Ankole.AIAgent.Library do
  @moduledoc """
  Agent library state for AI agents.

  Persona docs and overlays are PG semantic state. Skills themselves are
  filesystem bundles: builtin skills ship with the app image, and agent-installed
  skills live under worker-visible storage. `agent_skills` records enablement,
  registry semantics, and file observations; it is not a file content table.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library.AgentPlugins.Config, as: AgentPluginConfig
  alias Ankole.AIAgent.Library.RuntimeCapabilityChanges
  alias Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.AIAgent.Library.Schemas.LibraryBuiltinSyncState
  alias Ankole.AIAgent.Library.SourceReader
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Principals
  alias Ankole.Principals.Agent
  alias Ankole.Repo

  @sync_name "app/library/skills"
  @skill_file "SKILL.md"
  @soul_file "SOUL.md"
  @mission_file "MISSION.md"
  @design_file "DESIGN.md"
  @agent_document_kinds ~w(mission soul design)

  @type agent_document_kind :: String.t()
  @type agent_document :: %{
          required(String.t()) => String.t()
        }

  @type sync_result :: %{
          changed: boolean(),
          content_hash: String.t(),
          skills: non_neg_integer(),
          files: non_neg_integer()
        }

  @type installed_skill_observation :: %{
          required(:skill_name) => String.t(),
          optional(:description) => String.t(),
          optional(:default_enabled) => boolean(),
          optional(:tags) => [String.t()],
          optional(:category) => String.t(),
          optional(:disable_model_invocation) => boolean(),
          optional(:ankole_runtime) => String.t()
        }

  @doc """
  Scans first-party builtin skill files and updates the global sync cursor.

  Per-agent registry rows are created by `sync_agent_skills/2`, because builtin
  skill enablement is now agent-local state.
  """
  @spec sync_builtin_skills(keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync_builtin_skills(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    force? = Keyword.get(opts, :force, false)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, builtin_sources} <- SourceReader.read_builtin_skill_sources(),
         {:ok, agent_plugin_sources} <- AgentPlugins.skill_sources(),
         {:ok, sources} <-
           reject_skill_source_conflicts(builtin_sources ++ agent_plugin_sources) do
      content_hash = SourceReader.catalog_hash(sources)
      current_state = repo.get(LibraryBuiltinSyncState, @sync_name)

      result = %{
        changed: force? or not match?(%{content_hash: ^content_hash}, current_state),
        content_hash: content_hash,
        skills: length(sources),
        files: Enum.reduce(sources, 0, fn source, sum -> sum + length(source.files) end)
      }

      case result.changed do
        false ->
          {:ok, result}

        true ->
          repo.transact(fn repo ->
            upsert_sync_state(repo, content_hash, result, now)
            |> case do
              {:ok, _state} -> {:ok, result}
              {:error, _reason} = error -> error
            end
          end)
      end
    end
  end

  @doc """
  Synchronizes builtin skill registry rows for one agent.

  Agent-installed rows are preserved. They are refreshed only from explicit
  worker file observations, not by scanning a control-plane filesystem path.
  """
  @spec sync_agent_skills(String.t(), keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync_agent_skills(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, sources} <- agent_skill_sources(agent_uid, opts) do
      repo.transact(fn repo -> sync_agent_skills_in_tx(repo, agent_uid, sources, now) end)
    end
  end

  @doc """
  Replaces the agent-installed skill registry from worker file observations.

  The caller obtains these observations from a worker-local scan. This function
  deliberately accepts registry metadata, not a filesystem root, so the control
  plane cannot silently become an NFS scanner.
  """
  @spec replace_installed_skill_observations(
          String.t(),
          [installed_skill_observation()],
          keyword()
        ) ::
          {:ok, sync_result()} | {:error, term()}
  def replace_installed_skill_observations(agent_uid, observations, opts \\ [])

  def replace_installed_skill_observations(agent_uid, observations, opts)
      when is_list(observations) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, builtin_sources} <- SourceReader.read_builtin_skill_sources(),
         {:ok, agent_plugin_sources} <- AgentPlugins.skill_sources(opts),
         {:ok, installed_sources} <- installed_sources_from_observations(observations) do
      repo.transact(fn repo ->
        sync_agent_skills_in_tx(
          repo,
          agent_uid,
          %{
            builtin: builtin_sources ++ agent_plugin_sources,
            installed: installed_sources,
            installed_authoritative?: true
          },
          now
        )
      end)
    end
  end

  def replace_installed_skill_observations(_agent_uid, _observations, _opts),
    do: {:error, :invalid_skill_observations}

  @doc """
  Sets or clears one Agent-specific Skill enablement override.

  This is an operator/control-plane facade. The model-facing worker tools can
  read and append enabled skill content, but they cannot toggle the registry.
  """
  @spec set_agent_skill_override(String.t(), String.t(), boolean() | nil, keyword()) ::
          {:ok, AgentSkill.t()} | {:error, term()}
  def set_agent_skill_override(agent_uid, skill_id, enabled, opts \\ [])

  def set_agent_skill_override(agent_uid, skill_id, enabled, opts)
      when is_boolean(enabled) or is_nil(enabled) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, _result} <- sync_agent_skills(agent_uid, opts),
         {:ok, skill_name, expected_agent_plugin_id} <- normalize_skill_id(skill_id),
         %AgentSkill{} = skill <-
           repo.get_by(AgentSkill, agent_uid: agent_uid, skill_name: skill_name),
         :ok <- validate_skill_owner(skill, expected_agent_plugin_id) do
      skill
      |> AgentSkill.changeset(%{enabled_override: enabled})
      |> repo.update()
    else
      nil -> {:error, :skill_not_found}
      {:error, _reason} = error -> error
    end
  end

  def set_agent_skill_override(_agent_uid, _skill_id, _enabled, _opts),
    do: {:error, :invalid_skill_override}

  @doc "Returns globally inherited Agent Plugin and standalone Skill capabilities."
  @spec global_capabilities(keyword()) :: {:ok, map()} | {:error, term()}
  def global_capabilities(opts \\ []) do
    with {:ok, agent_plugins} <- AgentPlugins.global_capabilities(opts),
         {:ok, builtin_sources} <- SourceReader.read_builtin_skill_sources(),
         {:ok, agent_plugin_sources} <- AgentPlugins.skill_sources(opts),
         {:ok, _sources} <-
           reject_skill_source_conflicts(builtin_sources ++ agent_plugin_sources),
         {:ok, defaults} <- library_defaults(opts) do
      skills =
        Enum.map(builtin_sources, fn source ->
          global_default = Map.get(defaults.skills, source.name, source.default_enabled)

          %{
            "id" => source.name,
            "name" => source.name,
            "description" => source.description,
            "source_kind" => "builtin",
            "agent_plugin_id" => nil,
            "global_default_enabled" => global_default,
            "override_enabled" => nil,
            "effective_enabled" => global_default
          }
        end)

      {:ok, %{"agent_plugins" => agent_plugins, "skills" => skills}}
    end
  end

  @doc "Returns effective Agent Plugin and standalone Skill capabilities for one Agent."
  @spec capabilities_for_agent(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def capabilities_for_agent(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, agent_plugins} <- AgentPlugins.capabilities_for_agent(agent_uid, opts),
         {:ok, defaults} <- library_defaults(opts) do
      skills =
        AgentSkill
        |> where([skill], skill.agent_uid == ^agent_uid and is_nil(skill.agent_plugin_id))
        |> order_by([skill], asc: skill.skill_name)
        |> repo.all()
        |> Enum.map(&standalone_skill_capability(&1, defaults))

      {:ok, %{"agent_plugins" => agent_plugins, "skills" => skills}}
    end
  end

  @spec set_global_skill_default(String.t(), boolean(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def set_global_skill_default(skill_id, enabled, opts \\ [])

  def set_global_skill_default(skill_id, enabled, opts) when is_boolean(enabled) do
    case String.split(skill_id, ":", parts: 2) do
      [_agent_plugin_id, _skill_name] ->
        AgentPlugins.set_global_skill_default(skill_id, enabled, opts)

      [skill_name] ->
        with {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
             {:ok, sources} <- SourceReader.read_builtin_skill_sources(),
             %{} <- Enum.find(sources, &(&1.name == skill_name)) do
          AgentPluginConfig.put_skill_default(skill_name, enabled)
        else
          nil -> {:error, :skill_not_found}
          {:error, _reason} = error -> error
        end
    end
  end

  def set_global_skill_default(_skill_id, _enabled, _opts),
    do: {:error, :invalid_skill_default}

  @doc """
  Seeds writable library state for a newly-created agent.
  """
  @spec seed_agent_library(String.t()) :: :ok | {:error, term()}
  def seed_agent_library(agent_uid) do
    Repo.transact(fn repo -> seed_agent_library_in_tx(repo, agent_uid) end)
  end

  @doc """
  Seeds writable library state inside a caller-owned transaction.
  """
  @spec seed_agent_library_in_tx(module(), String.t()) :: :ok | {:error, term()}
  def seed_agent_library_in_tx(repo, agent_uid) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, sources} <- agent_skill_sources(agent_uid, []),
         {:ok, _soul} <- seed_agent_document_in_tx(repo, agent_uid, "soul"),
         {:ok, _mission} <- seed_agent_document_in_tx(repo, agent_uid, "mission"),
         {:ok, _design} <- seed_agent_document_in_tx(repo, agent_uid, "design"),
         {:ok, _result} <- sync_agent_skills_in_tx(repo, agent_uid, sources, now) do
      :ok
    end
  end

  @doc """
  Lists the skills currently enabled for an agent.
  """
  @spec enabled_skills_for_agent(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def enabled_skills_for_agent(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, agent_plugins} <- AgentPlugins.capabilities_for_agent(agent_uid, opts),
         {:ok, defaults} <- library_defaults(opts) do
      overlay_skills =
        AgentSkillOverlay
        |> where([overlay], overlay.agent_uid == ^agent_uid)
        |> where([overlay], is_nil(overlay.deleted_at))
        |> select([overlay], overlay.skill_name)
        |> repo.all()
        |> MapSet.new()

      all_skills =
        AgentSkill
        |> where([skill], skill.agent_uid == ^agent_uid)
        |> order_by([skill], asc: skill.skill_name)
        |> repo.all()

      parent_enabled = Map.new(agent_plugins, &{&1["id"], &1["effective_enabled"]})

      {:ok,
       all_skills
       |> Enum.map(fn skill ->
         effective = effective_skill_enabled?(skill, defaults, parent_enabled)
         {skill, effective}
       end)
       |> Enum.filter(&elem(&1, 1))
       |> Enum.map(fn {skill, effective} ->
         skill_summary(skill, overlay_skills, effective, defaults)
       end)}
    end
  end

  @doc """
  Reads the effective content of an enabled skill file for an agent.
  """
  @spec skill_view(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def skill_view(agent_uid, skill_name, file_path \\ nil, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, _result} <- sync_agent_skills(agent_uid, opts),
         {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
         {:ok, file_path} <- SourceReader.normalize_virtual_path(file_path || @skill_file),
         :ok <- reject_agent_append_file(file_path),
         {:ok, skill} <- enabled_skill(repo, agent_uid, skill_name, opts) do
      do_skill_view(repo, agent_uid, skill, file_path, opts)
    end
  end

  @doc """
  Replaces an agent-specific skill overlay for an enabled skill.
  """
  @spec replace_skill_overlay(String.t(), String.t(), map(), keyword()) ::
          {:ok, AgentSkillOverlay.t()} | {:error, term()}
  def replace_skill_overlay(agent_uid, skill_name, overlay_json, opts \\ [])

  def replace_skill_overlay(agent_uid, skill_name, overlay_json, opts)
      when is_map(overlay_json) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid, sources, opts} <- prepare_skill_overlay_write(agent_uid, opts) do
      repo.transact(fn repo ->
        with {:ok, _result} <-
               sync_agent_skills_in_tx(repo, agent_uid, sources, DateTime.utc_now(:microsecond)),
             {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
             {:ok, _skill} <- enabled_skill(repo, agent_uid, skill_name, opts) do
          replace_skill_overlay_in_tx(repo, agent_uid, skill_name, overlay_json)
        end
      end)
      |> notify_skill_content_change(agent_uid, repo)
    end
  end

  def replace_skill_overlay(_agent_uid, _skill_name, _overlay_json, _opts),
    do: {:error, :invalid_overlay}

  @doc """
  Replaces an enabled skill overlay only when its current content hash matches.

  An absent overlay has the empty-string hash at this boundary. This is the
  whole-overlay model-facing write path; stale callers must resolve and retry
  instead of silently overwriting a concurrent addition.
  """
  @spec replace_skill_overlay_cas(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, AgentSkillOverlay.t()} | {:error, term()}
  def replace_skill_overlay_cas(
        agent_uid,
        skill_name,
        expected_content_hash,
        overlay_json,
        opts \\ []
      )

  def replace_skill_overlay_cas(
        agent_uid,
        skill_name,
        expected_content_hash,
        overlay_json,
        opts
      )
      when is_binary(expected_content_hash) and is_map(overlay_json) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid, sources, opts} <- prepare_skill_overlay_write(agent_uid, opts) do
      repo.transact(fn repo ->
        with {:ok, _result} <-
               sync_agent_skills_in_tx(repo, agent_uid, sources, DateTime.utc_now(:microsecond)),
             {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
             {:ok, _skill} <- enabled_skill(repo, agent_uid, skill_name, opts),
             :ok <- lock_skill_overlay(repo, agent_uid, skill_name),
             :ok <-
               verify_overlay_hash(
                 active_skill_overlay(repo, agent_uid, skill_name),
                 expected_content_hash
               ) do
          replace_skill_overlay_in_tx(repo, agent_uid, skill_name, overlay_json)
        end
      end)
      |> notify_skill_content_change(agent_uid, repo)
    end
  end

  def replace_skill_overlay_cas(
        _agent_uid,
        _skill_name,
        _expected_content_hash,
        _overlay_json,
        _opts
      ),
      do: {:error, :invalid_overlay}

  @doc """
  Worker `skill_append` tool entry: appends durable notes to the agent's DB overlay text.
  """
  @spec skill_append(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, AgentSkillOverlay.t()} | {:error, term()}
  def skill_append(agent_uid, skill_name, content, opts \\ [])

  def skill_append(agent_uid, skill_name, content, opts) when is_binary(content) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid, sources, opts} <- prepare_skill_overlay_write(agent_uid, opts) do
      repo.transact(fn repo ->
        with {:ok, _result} <-
               sync_agent_skills_in_tx(repo, agent_uid, sources, DateTime.utc_now(:microsecond)),
             {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
             {:ok, _skill} <- enabled_skill(repo, agent_uid, skill_name, opts),
             :ok <- lock_skill_overlay(repo, agent_uid, skill_name) do
          existing =
            repo
            |> active_skill_overlay(agent_uid, skill_name)
            |> skill_overlay_text()

          replace_skill_overlay_in_tx(repo, agent_uid, skill_name, %{
            "text" => append_skill_overlay_text(existing, content)
          })
        end
      end)
      |> notify_skill_content_change(agent_uid, repo)
    end
  end

  def skill_append(_agent_uid, _skill_name, _content, _opts), do: {:error, :invalid_content}

  @doc """
  Returns the active DB overlay for an enabled skill.
  """
  @spec skill_overlay(String.t(), String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def skill_overlay(agent_uid, skill_name, opts \\ []) do
    with {:ok, overlays} <- skill_overlays(agent_uid, [skill_name], opts) do
      [overlay] = Map.values(overlays)
      {:ok, overlay}
    end
  end

  @doc """
  Returns active overlays for an enabled Skill set in one registry sync and two batch reads.

  Validation is all-or-nothing: an invalid, missing, or disabled Skill rejects the
  whole set instead of returning a partial materialization.
  """
  @spec skill_overlays(String.t(), [String.t()], keyword()) ::
          {:ok, %{optional(String.t()) => AgentSkillOverlay.t() | nil}} | {:error, term()}
  def skill_overlays(agent_uid, skill_names, opts \\ [])

  def skill_overlays(agent_uid, skill_names, opts) when is_list(skill_names) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, skill_names} <- normalize_skill_names(skill_names),
         {:ok, _result} <- sync_agent_skills(agent_uid, opts),
         {:ok, agent_plugins} <- AgentPlugins.capabilities_for_agent(agent_uid, opts),
         {:ok, defaults} <- library_defaults(opts),
         parent_enabled = Map.new(agent_plugins, &{&1["id"], &1["effective_enabled"]}),
         {:ok, _skills} <-
           enabled_skills(repo, agent_uid, skill_names, defaults, parent_enabled) do
      overlays =
        AgentSkillOverlay
        |> where([overlay], overlay.agent_uid == ^agent_uid)
        |> where([overlay], overlay.skill_name in ^skill_names)
        |> where([overlay], is_nil(overlay.deleted_at))
        |> repo.all()
        |> Map.new(&{&1.skill_name, &1})

      {:ok, Map.new(skill_names, &{&1, Map.get(overlays, &1)})}
    end
  end

  def skill_overlays(_agent_uid, _skill_names, _opts), do: {:error, :invalid_skill_names}

  @doc """
  Lists the active skill overlays of one agent, most recently changed first.

  An overlay outlives its skill enablement, so a row is listed even when the
  skill is disabled or no longer installed. An unlisted overlay would come back
  silently the next time the skill is enabled.
  """
  @spec list_skill_overlays(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_skill_overlays(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         :ok <- ensure_agent(repo, agent_uid),
         {:ok, defaults} <- library_defaults(opts),
         {:ok, parent_enabled} <- parent_enablement(agent_uid, opts) do
      skills =
        AgentSkill
        |> where([skill], skill.agent_uid == ^agent_uid)
        |> repo.all()
        |> Map.new(&{&1.skill_name, &1})

      overlays =
        AgentSkillOverlay
        |> where([overlay], overlay.agent_uid == ^agent_uid)
        |> where([overlay], is_nil(overlay.deleted_at))
        |> order_by([overlay], desc: overlay.updated_at, asc: overlay.skill_name)
        |> repo.all()
        |> Enum.map(
          &skill_overlay_summary(&1, Map.get(skills, &1.skill_name), defaults, parent_enabled)
        )

      {:ok, overlays}
    end
  end

  @doc """
  Soft-deletes the active skill overlay of one agent skill.

  Deletion does not require the skill to stay enabled, because a disabled skill
  is exactly the case where an operator can no longer reach the overlay through
  a write path.
  """
  @spec delete_skill_overlay(String.t(), String.t(), keyword()) ::
          {:ok, AgentSkillOverlay.t()} | {:error, term()}
  def delete_skill_overlay(agent_uid, skill_name, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         :ok <- ensure_agent(repo, agent_uid),
         {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name) do
      repo.transact(fn repo ->
        with :ok <- lock_skill_overlay(repo, agent_uid, skill_name) do
          delete_skill_overlay_in_tx(repo, active_skill_overlay(repo, agent_uid, skill_name))
        end
      end)
      |> notify_skill_content_change(agent_uid, repo)
    end
  end

  @doc """
  Returns the current agent soul text, falling back to the bundled template.
  """
  @spec get_soul(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_soul(agent_uid, opts \\ []),
    do: get_agent_document_text(agent_uid, "soul", opts)

  @doc """
  Returns the current agent mission text, falling back to the bundled template.
  """
  @spec get_mission(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_mission(agent_uid, opts \\ []),
    do: get_agent_document_text(agent_uid, "mission", opts)

  @doc """
  Returns the current agent visual identity document, falling back to the bundled template.
  """
  @spec get_design(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_design(agent_uid, opts \\ []),
    do: get_agent_document_text(agent_uid, "design", opts)

  @doc """
  Returns the operator-visible MISSION, SOUL, and DESIGN documents for one agent.

  Agents created before the writable rows existed still receive the bundled
  template and its content hash, so a subsequent compare-and-swap write can
  materialize that same effective document without a migration.
  """
  @spec list_agent_documents(String.t(), keyword()) ::
          {:ok, %{required(agent_document_kind()) => agent_document()}} | {:error, term()}
  def list_agent_documents(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         :ok <- ensure_agent(repo, agent_uid) do
      {:ok,
       Map.new(@agent_document_kinds, fn kind ->
         {:ok, spec} = agent_document_spec(kind)
         {kind, agent_document_payload(repo, agent_uid, spec)}
       end)}
    end
  end

  @doc """
  Replaces one agent MISSION, SOUL, or DESIGN document when its current hash matches.

  The advisory transaction lock serializes the missing-row case as well as
  ordinary updates, so two Console editors cannot both accept the same stale
  hash and silently overwrite each other.
  """
  @spec replace_agent_document(
          String.t(),
          agent_document_kind(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, agent_document()} | {:error, term()}
  def replace_agent_document(
        agent_uid,
        kind,
        content,
        expected_content_hash,
        opts \\ []
      )

  def replace_agent_document(agent_uid, kind, content, expected_content_hash, opts)
      when is_binary(kind) and is_binary(content) and is_binary(expected_content_hash) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, spec} <- agent_document_spec(kind) do
      repo.transact(fn repo ->
        with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
             :ok <- ensure_agent(repo, agent_uid),
             :ok <- lock_agent_document(repo, agent_uid, spec.kind),
             current = agent_document_payload(repo, agent_uid, spec),
             :ok <- verify_agent_document_hash(current, expected_content_hash),
             {:ok, entry} <-
               upsert_agent_document_in_tx(repo, agent_uid, spec, content, %{
                 "source" => "console"
               }) do
          with :ok <- Ankole.RuntimeEvents.notify_agent_home_projection(repo, agent_uid) do
            {:ok, agent_document_payload(entry, spec)}
          end
        end
      end)
    end
  end

  def replace_agent_document(_agent_uid, _kind, _content, _expected_content_hash, _opts),
    do: {:error, :invalid_agent_document}

  @doc """
  Returns the compact skill index used by prompt builders.
  """
  @spec skills_for_system_prompt(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def skills_for_system_prompt(agent_uid, opts \\ []) do
    with {:ok, skills} <- enabled_skills_for_agent(agent_uid, opts) do
      {:ok,
       Enum.map(skills, fn skill ->
         metadata = skill["metadata"] || %{}

         %{
           "skill_name" => skill["skill_name"],
           "name" => skill["skill_name"],
           "description" => skill["description"],
           "category" => skill["category"],
           "source_kind" => skill["source_kind"],
           "agent_plugin_id" => skill["agent_plugin_id"],
           "relative_path" => skill["relative_path"],
           "skill_root" => metadata["skill_root"],
           "skill_uri" => skill_uri(skill["skill_name"], @skill_file),
           "metadata" => metadata,
           "disable_model_invocation" => metadata["disable_model_invocation"] == true
         }
       end)}
    end
  end

  defp agent_skill_sources(_agent_uid, opts) do
    with {:ok, builtin_sources} <- SourceReader.read_builtin_skill_sources(),
         {:ok, agent_plugin_sources} <- AgentPlugins.skill_sources(opts),
         {:ok, _all_sources} <-
           reject_skill_source_conflicts(builtin_sources ++ agent_plugin_sources) do
      {:ok,
       %{
         builtin: builtin_sources ++ agent_plugin_sources,
         installed: [],
         installed_authoritative?: false
       }}
    end
  end

  defp prepare_skill_overlay_write(agent_uid, opts) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, sources} <- agent_skill_sources(agent_uid, opts),
         {:ok, defaults} <- library_defaults(opts) do
      {:ok, agent_uid, sources, Keyword.put(opts, :agent_library_defaults, defaults)}
    end
  end

  defp sync_agent_skills_in_tx(repo, agent_uid, sources, now) do
    source_rows =
      Enum.map(sources.builtin, &source_attrs(&1, "builtin", now)) ++
        Enum.map(sources.installed, &source_attrs(&1, "installed", now))

    source_names = MapSet.new(source_rows, & &1.skill_name)

    existing_rows =
      AgentSkill
      |> where([skill], skill.agent_uid == ^agent_uid)
      |> repo.all()

    preserved_installed_rows =
      if sources.installed_authoritative?,
        do: [],
        else: Enum.filter(existing_rows, &(&1.source_kind == "installed"))

    existing_by_name = Map.new(existing_rows, &{&1.skill_name, &1})

    changed_rows =
      Enum.reject(source_rows, &source_row_current?(existing_by_name[&1.skill_name], &1))

    with :ok <- reject_skill_row_conflicts(source_rows ++ preserved_installed_rows),
         :ok <- upsert_agent_skill_rows(repo, agent_uid, changed_rows, now),
         {stale_count, _rows} <-
           stale_agent_skills_query(agent_uid, source_names, sources.installed_authoritative?)
           |> repo.delete_all() do
      {:ok,
       %{
         changed: changed_rows != [] or stale_count > 0,
         content_hash: agent_skill_hash(source_rows),
         skills: length(source_rows),
         files: Enum.reduce(source_rows, 0, fn row, count -> count + row.file_count end)
       }}
    end
  end

  # This sync runs on every Worker context read and Job dispatch, so an
  # unchanged catalog must produce zero row writes.
  defp source_row_current?(nil, _row), do: false

  defp source_row_current?(%AgentSkill{} = current, row) do
    {current.source_kind, current.agent_plugin_id, current.relative_path, current.default_enabled,
     current.description, current.metadata, current.content_hash} ==
      {row.source_kind, row.agent_plugin_id, row.relative_path, row.default_enabled,
       row.description, row.metadata, row.content_hash}
  end

  defp stale_agent_skills_query(agent_uid, source_names, true) do
    AgentSkill
    |> where([skill], skill.agent_uid == ^agent_uid)
    |> where([skill], skill.skill_name not in ^MapSet.to_list(source_names))
  end

  defp stale_agent_skills_query(agent_uid, source_names, false) do
    AgentSkill
    |> where([skill], skill.agent_uid == ^agent_uid)
    |> where([skill], skill.source_kind == "builtin")
    |> where([skill], skill.skill_name not in ^MapSet.to_list(source_names))
  end

  defp source_attrs(source, source_kind, now) do
    %{
      skill_name: source.name,
      source_kind: source_kind,
      agent_plugin_id: source.metadata["agent_plugin_id"],
      relative_path: source.relative_path,
      enabled_override: nil,
      default_enabled: source.default_enabled,
      description: source.description,
      metadata:
        source.metadata
        |> Map.put("source_kind", source_kind)
        |> Map.put("relative_path", source.relative_path),
      content_hash: source.source_hash,
      synced_at: now,
      file_count: length(source.files)
    }
  end

  @agent_skill_conflict_replace [
    :source_kind,
    :agent_plugin_id,
    :relative_path,
    :default_enabled,
    :description,
    :metadata,
    :content_hash,
    :synced_at,
    :updated_at
  ]

  # Creating an Agent seeds every builtin bundle, so a row-at-a-time upsert made
  # Agent creation pay one database round trip per Skill. The changeset still
  # runs on every row, so normalization and validation keep their owner; only
  # the write is batched. `enabled_override` stays out of the replace list, so
  # an operator's per-Skill choice survives a resync.
  defp upsert_agent_skill_rows(_repo, _agent_uid, [], _now), do: :ok

  defp upsert_agent_skill_rows(repo, agent_uid, source_rows, now) do
    source_rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, entries} ->
      attrs =
        row
        |> Map.take([
          :skill_name,
          :source_kind,
          :agent_plugin_id,
          :relative_path,
          :default_enabled,
          :description,
          :metadata,
          :content_hash,
          :synced_at
        ])
        |> Map.put(:agent_uid, agent_uid)
        |> Map.put(:enabled_override, nil)

      %AgentSkill{}
      |> AgentSkill.changeset(attrs)
      |> Ecto.Changeset.apply_action(:insert)
      |> case do
        {:ok, skill} -> {:cont, {:ok, [agent_skill_entry(skill, now) | entries]}}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} ->
        repo.insert_all(AgentSkill, Enum.reverse(entries),
          on_conflict: {:replace, @agent_skill_conflict_replace},
          conflict_target: [:agent_uid, :skill_name]
        )

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp agent_skill_entry(%AgentSkill{} = skill, now) do
    %{
      id: UUIDv7.autogenerate(),
      agent_uid: skill.agent_uid,
      skill_name: skill.skill_name,
      source_kind: skill.source_kind,
      agent_plugin_id: skill.agent_plugin_id,
      relative_path: skill.relative_path,
      enabled_override: skill.enabled_override,
      default_enabled: skill.default_enabled,
      description: skill.description,
      metadata: skill.metadata,
      content_hash: skill.content_hash,
      synced_at: skill.synced_at,
      inserted_at: now,
      updated_at: now
    }
  end

  defp agent_skill_hash(rows) do
    rows
    |> Enum.flat_map(&[&1.skill_name, &1.source_kind, &1.relative_path, &1.content_hash])
    |> Enum.join(<<0>>)
    |> SourceReader.hash()
  end

  defp upsert_sync_state(repo, content_hash, result, now) do
    attrs = %{
      name: @sync_name,
      content_hash: content_hash,
      synced_at: now,
      metadata: %{"skills" => result.skills, "files" => result.files}
    }

    %LibraryBuiltinSyncState{}
    |> LibraryBuiltinSyncState.changeset(attrs)
    |> repo.insert(
      on_conflict: {:replace, [:content_hash, :synced_at, :metadata, :updated_at]},
      conflict_target: :name
    )
  end

  defp seed_agent_document_in_tx(repo, agent_uid, kind) do
    with {:ok, spec} <- agent_document_spec(kind) do
      upsert_agent_document_in_tx(
        repo,
        agent_uid,
        spec,
        spec.fallback,
        %{"source" => "app_template"}
      )
    end
  end

  defp upsert_agent_document_in_tx(repo, agent_uid, spec, content, metadata) do
    upsert_agent_text_entry_in_tx(repo, %{
      agent_uid: agent_uid,
      path: spec.path,
      source_kind: spec.kind,
      content: content,
      metadata: metadata
    })
  end

  defp upsert_agent_text_entry_in_tx(repo, attrs) do
    attrs =
      attrs
      |> Map.put(:path, SourceReader.normalize_virtual_path!(attrs.path))
      |> Map.put(:content_hash, SourceReader.hash(attrs.content || ""))
      |> Map.put_new(:metadata, %{})

    %AgentLibraryContainerEntry{}
    |> AgentLibraryContainerEntry.changeset(attrs)
    |> repo.insert(
      on_conflict: [
        set: [
          source_kind: attrs.source_kind,
          content: attrs.content,
          content_hash: attrs.content_hash,
          metadata: attrs.metadata,
          deleted_at: nil,
          updated_at: DateTime.utc_now(:microsecond)
        ]
      ],
      conflict_target: {:unsafe_fragment, "(agent_uid, path) WHERE deleted_at IS NULL"},
      returning: true
    )
  end

  defp get_agent_document_text(agent_uid, kind, opts) do
    with {:ok, spec} <- agent_document_spec(kind) do
      get_agent_text(agent_uid, spec.path, spec.fallback, opts)
    end
  end

  defp get_agent_text(agent_uid, path, fallback, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      case active_agent_entry(repo, agent_uid, path) do
        %AgentLibraryContainerEntry{content: content} when is_binary(content) -> {:ok, content}
        _entry -> {:ok, fallback}
      end
    end
  end

  defp agent_document_spec("mission") do
    {:ok,
     %{
       kind: "mission",
       path: @mission_file,
       fallback: SourceReader.load_default_mission_template()
     }}
  end

  defp agent_document_spec("soul") do
    {:ok,
     %{
       kind: "soul",
       path: @soul_file,
       fallback: SourceReader.load_default_soul_template()
     }}
  end

  defp agent_document_spec("design") do
    {:ok,
     %{
       kind: "design",
       path: @design_file,
       fallback: SourceReader.load_default_design_template()
     }}
  end

  defp agent_document_spec(_kind), do: {:error, :invalid_document_kind}

  defp agent_document_payload(repo, agent_uid, spec) do
    repo
    |> active_agent_entry(agent_uid, spec.path)
    |> agent_document_payload(spec)
  end

  defp agent_document_payload(
         %AgentLibraryContainerEntry{content: content},
         spec
       )
       when is_binary(content) do
    build_agent_document_payload(content, spec)
  end

  defp agent_document_payload(_entry, spec),
    do: build_agent_document_payload(spec.fallback, spec)

  defp build_agent_document_payload(content, spec) when is_binary(content) do
    %{
      "kind" => spec.kind,
      "content" => content,
      "content_hash" => SourceReader.hash(content)
    }
  end

  defp ensure_agent(repo, agent_uid) do
    case repo.get(Agent, agent_uid) do
      %Agent{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  defp lock_agent_document(repo, agent_uid, kind) do
    Ecto.Adapters.SQL.query!(
      repo,
      "SELECT pg_advisory_xact_lock(hashtext($1))",
      ["agent-library-document:#{agent_uid}:#{kind}"]
    )

    :ok
  end

  defp verify_agent_document_hash(%{"content_hash" => hash}, hash), do: :ok

  defp verify_agent_document_hash(_document, _expected_hash),
    do: {:error, :agent_library_document_conflict}

  defp reject_agent_append_file("AGENT_APPEND.md"), do: {:error, :skill_file_not_found}
  defp reject_agent_append_file(_file_path), do: :ok

  defp enabled_skill(repo, agent_uid, skill_name, opts) do
    case repo.get_by(AgentSkill, agent_uid: agent_uid, skill_name: skill_name) do
      %AgentSkill{} = skill ->
        with {:ok, defaults} <- library_defaults(opts),
             {:ok, parent_enabled} <- parent_enablement(agent_uid, opts) do
          if effective_skill_enabled?(skill, defaults, parent_enabled),
            do: {:ok, skill},
            else: {:error, :skill_not_enabled}
        end

      nil ->
        {:error, :skill_not_found}
    end
  end

  defp enabled_skills(repo, agent_uid, skill_names, defaults, parent_enabled) do
    skills =
      AgentSkill
      |> where([skill], skill.agent_uid == ^agent_uid)
      |> where([skill], skill.skill_name in ^skill_names)
      |> repo.all()
      |> Map.new(&{&1.skill_name, &1})

    Enum.reduce_while(skill_names, {:ok, []}, fn skill_name, {:ok, acc} ->
      case Map.get(skills, skill_name) do
        %AgentSkill{} = skill ->
          if effective_skill_enabled?(skill, defaults, parent_enabled) do
            {:cont, {:ok, [skill | acc]}}
          else
            {:halt, {:error, :skill_not_enabled}}
          end

        nil ->
          {:halt, {:error, :skill_not_found}}
      end
    end)
  end

  defp normalize_skill_names(skill_names) do
    skill_names
    |> Enum.reduce_while({:ok, []}, fn skill_name, {:ok, acc} ->
      case SourceReader.normalize_skill_name(skill_name) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.reverse(normalized)

        if Enum.uniq(normalized) == normalized,
          do: {:ok, normalized},
          else: {:error, :duplicate_skill_name}

      {:error, _reason} = error ->
        error
    end
  end

  defp do_skill_view(repo, agent_uid, %AgentSkill{} = skill, file_path, opts) do
    case read_skill_file(skill, file_path, opts) do
      {:ok, raw_content} when file_path == @skill_file ->
        base_content = SourceReader.skill_body(raw_content)
        overlay = active_skill_overlay(repo, agent_uid, skill.skill_name)
        overlay_text = skill_overlay_text(overlay)

        content =
          case overlay_text do
            nil ->
              base_content

            append ->
              base_content <>
                "\n\n---\nAgent-specific additions for #{agent_uid}:\n\n" <> String.trim(append)
          end

        {:ok,
         %{
           "skill_name" => skill.skill_name,
           "source_kind" => skill.source_kind,
           "relative_path" => skill.relative_path,
           "skill_uri" => skill_uri(skill.skill_name, file_path),
           "content" => content,
           "base_content" => base_content,
           "overlay_json" => overlay_json(overlay),
           "has_agent_overlay" => is_binary(overlay_text)
         }}

      {:ok, content} ->
        {:ok,
         %{
           "skill_name" => skill.skill_name,
           "source_kind" => skill.source_kind,
           "relative_path" => skill.relative_path,
           "skill_uri" => skill_uri(skill.skill_name, file_path),
           "content" => content,
           "has_agent_overlay" =>
             is_binary(
               skill_overlay_text(active_skill_overlay(repo, agent_uid, skill.skill_name))
             )
         }}

      {:error, _reason} ->
        {:error, :skill_file_not_found}
    end
  end

  defp read_skill_file(%AgentSkill{source_kind: "builtin"} = skill, file_path, _opts) do
    SourceReader.read_builtin_skill_file(skill.relative_path, file_path)
  end

  defp read_skill_file(%AgentSkill{source_kind: "installed"} = skill, file_path, opts) do
    _skill = skill
    _file_path = file_path
    _opts = opts

    {:error, :skill_file_not_available_in_control_plane}
  end

  defp installed_sources_from_observations(observations) do
    observations
    |> Enum.map(&installed_source_from_observation/1)
    |> Ankole.Attrs.collect_results()
    |> case do
      {:ok, sources} -> reject_duplicate_observations(sources)
      {:error, _reason} = error -> error
    end
  end

  defp installed_source_from_observation(observation) when is_map(observation) do
    with {:ok, name} <- SourceReader.normalize_skill_name(map_text(observation, :skill_name)),
         {:ok, description} <- observation_description(observation),
         {:ok, default_enabled} <- observation_boolean(observation, :default_enabled, true),
         {:ok, tags} <- observation_tags(observation),
         {:ok, category} <- observation_optional_text(observation, :category),
         {:ok, disable_model_invocation} <-
           observation_boolean(observation, :disable_model_invocation, false),
         {:ok, ankole_runtime} <-
           SourceReader.normalize_ankole_runtime(map_text(observation, :ankole_runtime)) do
      metadata =
        %{
          "tags" => tags,
          "disable_model_invocation" => disable_model_invocation
        }
        |> put_optional_metadata("category", category)
        |> put_optional_metadata("ankole-runtime", ankole_runtime)

      source_hash =
        installed_source_hash(
          name,
          description,
          default_enabled,
          tags,
          category,
          disable_model_invocation,
          ankole_runtime
        )

      {:ok,
       %{
         name: name,
         description: description,
         default_enabled: default_enabled,
         metadata: metadata,
         source_hash: source_hash,
         relative_path: name,
         files: []
       }}
    end
  end

  defp installed_source_from_observation(_observation), do: {:error, :invalid_skill_observation}

  defp observation_description(observation) do
    case map_text(observation, :description) do
      description when is_binary(description) and byte_size(description) > 0 ->
        {:ok, String.slice(description, 0, 1024)}

      _value ->
        {:error, :skill_description_missing}
    end
  end

  defp observation_boolean(observation, key, default) do
    case map_value(observation, key) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, default}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  defp observation_tags(observation) do
    case map_value(observation, :tags) do
      nil ->
        {:ok, []}

      tags when is_list(tags) ->
        tags
        |> Enum.reduce_while({:ok, []}, fn
          tag, {:ok, acc} when is_binary(tag) ->
            case String.trim(tag) do
              "" -> {:halt, {:error, :invalid_skill_tags}}
              normalized -> {:cont, {:ok, [normalized | acc]}}
            end

          _tag, _acc ->
            {:halt, {:error, :invalid_skill_tags}}
        end)
        |> case do
          {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
          {:error, _reason} = error -> error
        end

      _value ->
        {:error, :invalid_skill_tags}
    end
  end

  defp observation_optional_text(observation, key) do
    case map_value(observation, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_text, key}}
          normalized -> {:ok, normalized}
        end

      _value ->
        {:error, {:invalid_text, key}}
    end
  end

  defp installed_source_hash(
         name,
         description,
         default_enabled,
         tags,
         category,
         disable_model_invocation,
         ankole_runtime
       ) do
    [
      name,
      description,
      to_string(default_enabled),
      category || "",
      to_string(disable_model_invocation),
      ankole_runtime || ""
      | tags
    ]
    |> Enum.join(<<0>>)
    |> SourceReader.hash()
  end

  defp reject_duplicate_observations(sources) do
    duplicates =
      for {name, count} <- Enum.frequencies_by(sources, & &1.name),
          count > 1,
          do: name

    case duplicates do
      [] -> {:ok, sources}
      _duplicates -> {:error, {:duplicate_skill_name, duplicates}}
    end
  end

  defp reject_skill_source_conflicts(sources) do
    conflicts =
      sources
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case conflicts do
      [] -> {:ok, sources}
      _names -> {:error, {:skill_source_name_conflicts, conflicts}}
    end
  end

  defp reject_skill_row_conflicts(rows) do
    conflicts =
      rows
      |> Enum.frequencies_by(& &1.skill_name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case conflicts do
      [] -> :ok
      names -> {:error, {:skill_source_name_conflicts, names}}
    end
  end

  defp map_text(map, key) do
    case map_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  defp map_value(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp put_optional_metadata(metadata, _key, nil), do: metadata
  defp put_optional_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp active_agent_entry(repo, agent_uid, path) do
    AgentLibraryContainerEntry
    |> where([entry], entry.agent_uid == ^agent_uid)
    |> where([entry], entry.path == ^SourceReader.normalize_virtual_path!(path))
    |> where([entry], is_nil(entry.deleted_at))
    |> repo.one()
  end

  defp active_skill_overlay(repo, agent_uid, skill_name) do
    AgentSkillOverlay
    |> where([overlay], overlay.agent_uid == ^agent_uid)
    |> where([overlay], overlay.skill_name == ^skill_name)
    |> where([overlay], is_nil(overlay.deleted_at))
    |> repo.one()
  end

  defp lock_skill_overlay(repo, agent_uid, skill_name) do
    Ecto.Adapters.SQL.query!(
      repo,
      "SELECT pg_advisory_xact_lock(hashtext($1))",
      ["skill-overlay:#{agent_uid}:#{skill_name}"]
    )

    :ok
  end

  defp verify_overlay_hash(nil, ""), do: :ok

  defp verify_overlay_hash(%AgentSkillOverlay{content_hash: content_hash}, content_hash),
    do: :ok

  defp verify_overlay_hash(_overlay, _expected), do: {:error, :skill_overlay_conflict}

  defp replace_skill_overlay_in_tx(repo, agent_uid, skill_name, overlay_json) do
    attrs = %{
      agent_uid: agent_uid,
      skill_name: skill_name,
      overlay_json: overlay_json,
      content_hash: SourceReader.hash(Torque.encode!(overlay_json))
    }

    %AgentSkillOverlay{}
    |> AgentSkillOverlay.changeset(attrs)
    |> repo.insert(
      on_conflict: [
        set: [
          overlay_json: attrs.overlay_json,
          content_hash: attrs.content_hash,
          deleted_at: nil,
          updated_at: DateTime.utc_now(:microsecond)
        ]
      ],
      conflict_target: {:unsafe_fragment, "(agent_uid, skill_name) WHERE deleted_at IS NULL"},
      returning: true
    )
  end

  defp delete_skill_overlay_in_tx(_repo, nil), do: {:error, :skill_overlay_not_found}

  defp delete_skill_overlay_in_tx(repo, %AgentSkillOverlay{} = overlay) do
    overlay
    |> AgentSkillOverlay.changeset(%{deleted_at: DateTime.utc_now(:microsecond)})
    |> repo.update()
  end

  defp skill_overlay_summary(%AgentSkillOverlay{} = overlay, skill, defaults, parent_enabled) do
    %{
      "skill_name" => overlay.skill_name,
      "skill_id" => skill && skill_stable_id(skill),
      "agent_plugin_id" => skill && skill.agent_plugin_id,
      "description" => skill && skill.description,
      "effective_enabled" =>
        not is_nil(skill) and effective_skill_enabled?(skill, defaults, parent_enabled),
      "text" => skill_overlay_text(overlay) || "",
      "content_hash" => overlay.content_hash,
      "updated_at" => DateTime.to_iso8601(overlay.updated_at)
    }
  end

  defp skill_overlay_text(%AgentSkillOverlay{overlay_json: %{"text" => text}})
       when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp skill_overlay_text(_overlay), do: nil

  defp append_skill_overlay_text(nil, addition), do: String.trim(addition)

  defp append_skill_overlay_text(existing, addition) when is_binary(existing) do
    note = String.trim(addition)

    cond do
      existing == "" -> note
      note == "" -> existing
      true -> existing <> "\n\n" <> note
    end
  end

  defp notify_skill_content_change(
         {:ok, %AgentSkillOverlay{skill_name: skill_name}} = result,
         agent_uid,
         repo
       ) do
    RuntimeCapabilityChanges.notify_skill_content(agent_uid, skill_name, repo: repo)
    result
  end

  defp notify_skill_content_change(result, _agent_uid, _repo), do: result

  defp overlay_json(%AgentSkillOverlay{overlay_json: overlay_json}) when is_map(overlay_json),
    do: overlay_json

  defp overlay_json(_overlay), do: %{}

  defp skill_summary(%AgentSkill{} = skill, overlay_skills, effective, defaults) do
    metadata = skill.metadata || %{}
    global_default = skill_global_default(skill, defaults)

    %{
      "id" => skill_stable_id(skill),
      "skill_name" => skill.skill_name,
      "description" => skill.description,
      "source_kind" => skill.source_kind,
      "agent_plugin_id" => skill.agent_plugin_id,
      "relative_path" => skill.relative_path,
      "default_enabled" => skill.default_enabled,
      "global_default_enabled" => global_default,
      "override_enabled" => skill.enabled_override,
      "effective_enabled" => effective,
      "enabled" => effective,
      "metadata" => metadata,
      "category" => metadata["category"],
      "tags" => metadata["tags"] || [],
      "skill_uri" => skill_uri(skill.skill_name, @skill_file),
      "has_agent_overlay" => MapSet.member?(overlay_skills, skill.skill_name)
    }
  end

  defp standalone_skill_capability(%AgentSkill{} = skill, defaults) do
    global_default = skill_global_default(skill, defaults)
    effective = effective_override(skill.enabled_override, global_default)

    %{
      "id" => skill.skill_name,
      "name" => skill.skill_name,
      "description" => skill.description,
      "source_kind" => skill.source_kind,
      "agent_plugin_id" => nil,
      "global_default_enabled" => global_default,
      "override_enabled" => skill.enabled_override,
      "effective_enabled" => effective
    }
  end

  defp effective_skill_enabled?(%AgentSkill{} = skill, defaults, parent_enabled) do
    enabled = effective_override(skill.enabled_override, skill_global_default(skill, defaults))

    if is_binary(skill.agent_plugin_id),
      do: enabled and Map.get(parent_enabled, skill.agent_plugin_id, false),
      else: enabled
  end

  defp skill_global_default(%AgentSkill{source_kind: "installed"} = skill, _defaults),
    do: skill.default_enabled

  defp skill_global_default(%AgentSkill{agent_plugin_id: id} = skill, defaults)
       when is_binary(id) do
    Map.get(defaults.skills, skill_stable_id(skill), true)
  end

  defp skill_global_default(%AgentSkill{} = skill, defaults) do
    Map.get(defaults.skills, skill.skill_name, skill.default_enabled)
  end

  defp skill_stable_id(%AgentSkill{agent_plugin_id: id} = skill) when is_binary(id),
    do: AgentPlugins.stable_skill_id(skill.agent_plugin_id, skill.skill_name)

  defp skill_stable_id(%AgentSkill{} = skill), do: skill.skill_name

  defp effective_override(value, _default) when is_boolean(value), do: value
  defp effective_override(nil, default), do: default

  defp parent_enablement(agent_uid, opts) do
    with {:ok, agent_plugins} <- AgentPlugins.capabilities_for_agent(agent_uid, opts) do
      {:ok, Map.new(agent_plugins, &{&1["id"], &1["effective_enabled"]})}
    end
  end

  defp library_defaults(opts) do
    case Keyword.get(opts, :agent_library_defaults) do
      %{agent_plugins: agent_plugins, skills: skills}
      when is_map(agent_plugins) and is_map(skills) ->
        {:ok, %{agent_plugins: agent_plugins, skills: skills}}

      _value ->
        AgentPluginConfig.defaults(opts)
    end
  end

  defp normalize_skill_id(skill_id) when is_binary(skill_id) do
    case String.split(skill_id, ":", parts: 2) do
      [skill_name] ->
        with {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name) do
          {:ok, skill_name, nil}
        end

      [agent_plugin_id, skill_name] ->
        with {:ok, agent_plugin_id} <- SourceReader.normalize_skill_name(agent_plugin_id),
             {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name) do
          {:ok, skill_name, agent_plugin_id}
        end
    end
  end

  defp normalize_skill_id(_skill_id), do: {:error, :invalid_skill_id}

  defp validate_skill_owner(%AgentSkill{agent_plugin_id: id}, id) when is_binary(id),
    do: :ok

  defp validate_skill_owner(%AgentSkill{agent_plugin_id: nil}, nil),
    do: :ok

  defp validate_skill_owner(%AgentSkill{}, _expected_agent_plugin_id),
    do: {:error, :skill_not_found}

  defp skill_uri(skill_name, file_path), do: "skill://enabled/#{skill_name}/#{file_path}"
end
