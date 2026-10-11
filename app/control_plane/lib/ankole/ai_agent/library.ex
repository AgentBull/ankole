defmodule Ankole.AIAgent.Library do
  @moduledoc """
  Agent library state for AI agents.

  Persona docs and overlays are PG semantic state. Skills themselves are file
  bundles: builtin skills ship with the app image, and agent-installed skills
  live in the Agent's drive under `skills/<name>/`, which each Worker
  materializes into its Agent Home. `agent_skills` records enablement,
  registry semantics, and manifest hashes; it is not a file content table.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library.AgentPlugins.Config, as: AgentPluginConfig
  alias Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.Schemas.AgentSkillLesson
  alias Ankole.AIAgent.Library.SkillLessons
  alias Ankole.AIAgent.Library.SourceReader
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Files
  alias Ankole.Principals
  alias Ankole.Principals.Agent
  alias Ankole.Repo

  @skill_file "SKILL.md"
  @soul_file "SOUL.md"
  @mission_file "MISSION.md"
  @design_file "DESIGN.md"
  @confidentiality_policy_file "ConfidentialityPolicy.md"
  @agent_document_kinds ~w(mission soul design confidentiality_policy)

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

  @doc "Returns the globally unique union of every shipped standalone and Agent Plugin Skill."
  @spec shipped_skill_sources(keyword()) :: {:ok, [map()]} | {:error, term()}
  def shipped_skill_sources(opts \\ []) do
    with {:ok, builtin_sources} <- SourceReader.read_builtin_skill_sources(),
         {:ok, agent_plugin_sources} <- AgentPlugins.skill_sources(opts) do
      reject_skill_source_conflicts(builtin_sources ++ agent_plugin_sources)
    end
  end

  @doc """
  Synchronizes the Skill catalog from shipped bundles and the Agent's drive.

  Installed manifests are read while the Agent's drive is locked, like drive
  mutations. A missing Worker cache cannot change this catalog.
  """
  @spec sync_agent_skills(String.t(), keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync_agent_skills(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, sources} <- shipped_skill_sources(opts) do
      repo.transact(fn repo -> sync_agent_skills_in_tx(repo, agent_uid, sources, now) end)
    end
  end

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
         {:ok, shipped_sources} <- shipped_skill_sources(opts),
         {:ok, defaults} <- library_defaults(opts) do
      builtin_sources =
        Enum.reject(shipped_sources, &is_binary(&1.metadata["agent_plugin_id"]))

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
         {:ok, sources} <- shipped_skill_sources(),
         {:ok, _soul} <- seed_agent_document_in_tx(repo, agent_uid, "soul"),
         {:ok, _mission} <- seed_agent_document_in_tx(repo, agent_uid, "mission"),
         {:ok, _design} <- seed_agent_document_in_tx(repo, agent_uid, "design"),
         {:ok, _policy} <- seed_agent_document_in_tx(repo, agent_uid, "confidentiality_policy"),
         {:ok, _result} <- sync_agent_skills_in_tx(repo, agent_uid, sources, now) do
      :ok
    end
  end

  @doc """
  Lists the skills currently enabled for an agent.
  """
  @spec enabled_skills_for_agent(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def enabled_skills_for_agent(agent_uid, opts \\ []) do
    with {:ok, runtime_state} <- enabled_runtime_state(agent_uid, opts) do
      {:ok, runtime_state.skills}
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
         {:ok, opts} <- skill_catalog_options(agent_uid, opts),
         {:ok, _result} <- sync_agent_skills(agent_uid, opts),
         {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
         {:ok, file_path} <- SourceReader.normalize_virtual_path(file_path || @skill_file),
         :ok <- reject_agent_append_file(file_path),
         {:ok, skill} <- enabled_skill(repo, agent_uid, skill_name, opts) do
      do_skill_view(repo, agent_uid, skill, file_path, opts)
    end
  end

  @doc """
  Returns the rendered skill-lesson block for an enabled Skill set.

  Validation is all-or-nothing: an invalid, missing, or disabled Skill rejects
  the whole set instead of returning a partial materialization. With
  `brain.skill_learning_enabled = false` every Skill renders empty while the
  stored rows stay unchanged.
  """
  @spec rendered_skill_lessons(String.t(), [String.t()], keyword()) ::
          {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def rendered_skill_lessons(agent_uid, skill_names, opts \\ [])

  def rendered_skill_lessons(agent_uid, skill_names, opts) when is_list(skill_names) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, opts} <- skill_catalog_options(agent_uid, opts),
         {:ok, skill_names} <- normalize_skill_names(skill_names),
         {:ok, _result} <- sync_agent_skills(agent_uid, opts),
         {:ok, defaults} <- library_defaults(opts),
         {:ok, parent_enabled} <- parent_enablement(agent_uid, opts),
         {:ok, _skills} <-
           enabled_skills(repo, agent_uid, skill_names, defaults, parent_enabled) do
      {:ok, SkillLessons.rendered(repo, agent_uid, skill_names)}
    end
  end

  def rendered_skill_lessons(_agent_uid, _skill_names, _opts), do: {:error, :invalid_skill_names}

  @doc """
  Applies reflection-produced lesson adds through the mechanical gates.

  `context` carries `:evidence_job_ids` (the evidence-bundle job id set),
  `:human_input_job_ids` (its subset with mid-run human input), and
  `:checked_release`. Rejected adds are reported with a reason; accepted adds
  are inserted in one transaction.
  """
  @spec apply_skill_lesson_adds(String.t(), [map()], map(), keyword()) ::
          {:ok, %{accepted: [AgentSkillLesson.t()], rejected: [map()]}} | {:error, term()}
  def apply_skill_lesson_adds(agent_uid, adds, context, opts \\ []) when is_list(adds) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, agent_uid, sources, opts} <- prepare_skill_lesson_write(agent_uid, opts) do
      repo.transact(fn repo ->
        with {:ok, _result} <- sync_agent_skills_in_tx(repo, agent_uid, sources, now) do
          catalog = skill_lesson_catalog(repo, agent_uid, opts)

          SkillLessons.apply_adds_in_tx(repo, agent_uid, adds, context, now, catalog)
        end
      end)
    end
  end

  @doc """
  Applies review verdicts to leased lessons.

  `docket_ids` is the set of lesson ids due for review; `renew` and `lapse`
  are valid only inside it, `obsolete` retires any active dreaming lesson.
  `context` carries `:index_job_ids` (the review evidence index) and
  `:checked_release`.
  """
  @spec apply_skill_lesson_reviews(String.t(), [map()], MapSet.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate apply_skill_lesson_reviews(agent_uid, reviews, docket_ids, context, opts \\ []),
    to: SkillLessons

  @doc """
  Returns the leased lessons due for review for one agent.

  Due = lease expiring inside the horizon, or a fingerprint (release or skill
  content hash) that no longer matches the current environment.
  """
  @spec skill_lesson_review_docket(String.t(), DateTime.t(), String.t(), keyword()) ::
          {:ok, [AgentSkillLesson.t()]} | {:error, term()}
  defdelegate skill_lesson_review_docket(agent_uid, horizon, current_release, opts \\ []),
    to: SkillLessons

  @doc """
  Lists all skill lessons of one agent for the Console, retired rows included.

  A lesson outlives its skill enablement, so rows are listed even when the
  skill is disabled or no longer installed.
  """
  @spec list_skill_lessons(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_skill_lessons(agent_uid, opts \\ []) do
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

      lessons =
        AgentSkillLesson
        |> where([lesson], lesson.agent_uid == ^agent_uid)
        |> order_by([lesson], asc: lesson.skill_name, desc: lesson.inserted_at)
        |> repo.all()
        |> Enum.map(
          &skill_lesson_summary(&1, Map.get(skills, &1.skill_name), defaults, parent_enabled)
        )

      {:ok, lessons}
    end
  end

  @doc """
  Creates one operator-authored lesson for an enabled skill.

  Human lessons carry no lease and are never touched by Dreaming.
  """
  @spec create_skill_lesson(String.t(), String.t(), String.t(), Ankole.ActorRef.t(), keyword()) ::
          {:ok, AgentSkillLesson.t()} | {:error, term()}
  def create_skill_lesson(agent_uid, skill_name, content, author, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid, sources, opts} <- prepare_skill_lesson_write(agent_uid, opts) do
      repo.transact(fn repo ->
        with {:ok, _result} <-
               sync_agent_skills_in_tx(repo, agent_uid, sources, DateTime.utc_now(:microsecond)),
             {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
             {:ok, _skill} <- enabled_skill(repo, agent_uid, skill_name, opts) do
          SkillLessons.create_in_tx(repo, agent_uid, skill_name, content, author)
        end
      end)
    end
  end

  @doc """
  Retires one lesson on operator request.

  A human retirement of a dreaming lesson is permanent: the row joins the
  immunity list and Dreaming never re-adds equivalent content.
  """
  @spec retire_skill_lesson(String.t(), String.t(), keyword()) ::
          {:ok, AgentSkillLesson.t()} | {:error, term()}
  defdelegate retire_skill_lesson(agent_uid, lesson_id, opts \\ []), to: SkillLessons

  @doc """
  Returns the active lessons of one agent for reflection prompt assembly.
  """
  @spec active_skill_lessons(String.t(), keyword()) ::
          {:ok, [AgentSkillLesson.t()]} | {:error, term()}
  defdelegate active_skill_lessons(agent_uid, opts \\ []), to: SkillLessons

  @doc """
  Returns the human-revoked lessons of one agent: the never-relearn list.
  """
  @spec revoked_skill_lessons(String.t(), keyword()) ::
          {:ok, [AgentSkillLesson.t()]} | {:error, term()}
  defdelegate revoked_skill_lessons(agent_uid, opts \\ []), to: SkillLessons

  @doc """
  Returns the operator-visible agent documents (MISSION, SOUL, DESIGN, and
  the confidentiality policy) for one agent.

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
  Replaces one agent document (MISSION, SOUL, DESIGN, or the
  confidentiality policy) when its current hash matches.

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
          {:ok, agent_document_payload(entry, spec)}
        end
      end)
    end
  end

  def replace_agent_document(_agent_uid, _kind, _content, _expected_content_hash, _opts),
    do: {:error, :invalid_agent_document}

  @doc "Returns one coherent Agent Plugin and Skill catalog for an Agent runtime."
  @spec runtime_catalog_for_agent(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def runtime_catalog_for_agent(agent_uid, opts \\ []) do
    with {:ok, runtime_state} <- enabled_runtime_state(agent_uid, opts) do
      {:ok,
       %{
         "agent_plugins" => AgentPlugins.enabled_catalog(runtime_state.agent_plugins),
         "skills" => Enum.map(runtime_state.skills, &runtime_skill_summary/1)
       }}
    end
  end

  @doc """
  Returns the compact effective Skill set sent to an Agent runtime.

  The runtime keeps this complete set for `skill_view` and applies discovery
  policy when it renders a model-visible Skill catalog.
  """
  @spec runtime_skills_for_agent(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def runtime_skills_for_agent(agent_uid, opts \\ []) do
    with {:ok, runtime_catalog} <- runtime_catalog_for_agent(agent_uid, opts) do
      {:ok, runtime_catalog["skills"]}
    end
  end

  defp enabled_runtime_state(agent_uid, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, defaults} <- library_defaults(opts),
         runtime_opts = Keyword.put(opts, :agent_library_defaults, defaults),
         {:ok, agent_plugins} <- AgentPlugins.capabilities_for_agent(agent_uid, runtime_opts) do
      lesson_skills = SkillLessons.delivered_skill_names(repo, agent_uid)

      plugin_member_enabled =
        Map.new(
          for agent_plugin <- agent_plugins,
              skill <- agent_plugin["skills"],
              do: {skill["id"], skill["effective_enabled"]}
        )

      skills =
        AgentSkill
        |> where([skill], skill.agent_uid == ^agent_uid)
        |> order_by([skill], asc: skill.skill_name)
        |> repo.all()
        |> Enum.map(fn skill ->
          effective = runtime_skill_enabled?(skill, defaults, plugin_member_enabled)
          {skill, effective}
        end)
        |> Enum.filter(&elem(&1, 1))
        |> Enum.map(fn {skill, effective} ->
          skill_summary(skill, lesson_skills, effective, defaults)
        end)

      {:ok, %{agent_plugins: agent_plugins, skills: skills}}
    end
  end

  defp runtime_skill_summary(skill) do
    metadata = skill["metadata"] || %{}

    %{
      "skill_name" => skill["skill_name"],
      "description" => skill["description"],
      "category" => skill["category"],
      "source_kind" => skill["source_kind"],
      "agent_plugin_id" => skill["agent_plugin_id"],
      "relative_path" => skill["relative_path"],
      "skill_root" => metadata["skill_root"],
      "metadata" => metadata
    }
  end

  defp prepare_skill_lesson_write(agent_uid, opts) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, opts} <- skill_catalog_options(agent_uid, opts),
         {:ok, sources} <- shipped_skill_sources(opts) do
      {:ok, agent_uid, sources, opts}
    end
  end

  defp skill_catalog_options(agent_uid, opts) do
    with {:ok, plugin_sources} <- AgentPlugins.sources(opts),
         {:ok, defaults} <- library_defaults(opts),
         opts =
           Keyword.merge(opts,
             agent_plugin_sources: plugin_sources,
             agent_library_defaults: defaults
           ),
         {:ok, plugins} <- AgentPlugins.capabilities_from_sources(agent_uid, plugin_sources, opts) do
      {:ok,
       Keyword.put(
         opts,
         :parent_enablement,
         Map.new(plugins, &{&1["id"], &1["effective_enabled"]})
       )}
    end
  end

  defp sync_agent_skills_in_tx(repo, agent_uid, sources, now) do
    with :ok <- Files.lock_drive(repo, agent_uid),
         {:ok, installed} <- SourceReader.read_installed_skill_sources(agent_uid, repo: repo) do
      source_rows =
        Enum.map(sources, &source_attrs(&1, "builtin", now)) ++
          Enum.map(installed, &source_attrs(&1, "installed", now))

      source_names = Enum.map(source_rows, & &1.skill_name)

      existing_by_name =
        AgentSkill
        |> where([skill], skill.agent_uid == ^agent_uid)
        |> repo.all()
        |> Map.new(&{&1.skill_name, &1})

      changed_rows =
        Enum.reject(source_rows, &source_row_current?(existing_by_name[&1.skill_name], &1))

      with :ok <- reject_skill_row_conflicts(source_rows),
           :ok <- upsert_agent_skill_rows(repo, agent_uid, changed_rows, now),
           {stale_count, _rows} <-
             AgentSkill
             |> where(
               [skill],
               skill.agent_uid == ^agent_uid and skill.skill_name not in ^source_names
             )
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
      tenant_id: Repo.tenant_id!(),
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

  defp agent_document_spec("confidentiality_policy") do
    {:ok,
     %{
       kind: "confidentiality_policy",
       path: @confidentiality_policy_file,
       fallback: SourceReader.load_default_confidentiality_policy_template()
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
        lessons_text = SkillLessons.delivered_text(repo, agent_uid, skill.skill_name)

        content =
          case lessons_text do
            nil ->
              base_content

            text ->
              base_content <>
                "\n\n---\nAgent-specific additions for #{agent_uid}:\n\n" <> text
          end

        {:ok,
         %{
           "skill_name" => skill.skill_name,
           "source_kind" => skill.source_kind,
           "relative_path" => skill.relative_path,
           "skill_uri" => skill_uri(skill.skill_name, file_path),
           "content" => content,
           "base_content" => base_content,
           "has_agent_overlay" => is_binary(lessons_text)
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
             is_binary(SkillLessons.delivered_text(repo, agent_uid, skill.skill_name))
         }}

      {:error, _reason} ->
        {:error, :skill_file_not_found}
    end
  end

  defp read_skill_file(%AgentSkill{source_kind: "builtin"} = skill, file_path, _opts) do
    SourceReader.read_builtin_skill_file(skill.relative_path, file_path)
  end

  # An installed Skill lives in the Agent's drive under `skills/<name>/`.
  defp read_skill_file(%AgentSkill{source_kind: "installed"} = skill, file_path, _opts) do
    with {:ok, _file, content} <-
           Ankole.Files.read(skill.agent_uid, "skills/#{skill.relative_path}/#{file_path}") do
      {:ok, content}
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

  defp active_agent_entry(repo, agent_uid, path) do
    AgentLibraryContainerEntry
    |> where([entry], entry.agent_uid == ^agent_uid)
    |> where([entry], entry.path == ^SourceReader.normalize_virtual_path!(path))
    |> where([entry], is_nil(entry.deleted_at))
    |> repo.one()
  end

  defp skill_lesson_summary(%AgentSkillLesson{} = lesson, skill, defaults, parent_enabled) do
    %{
      "id" => lesson.id,
      "skill_name" => lesson.skill_name,
      "agent_plugin_id" => skill && skill.agent_plugin_id,
      "description" => skill && skill.description,
      "effective_enabled" =>
        not is_nil(skill) and effective_skill_enabled?(skill, defaults, parent_enabled),
      "content" => lesson.content,
      "author_kind" => lesson.author_kind,
      "author" => lesson.author && Map.from_struct(lesson.author),
      "evidence_job_ids" => lesson.evidence_job_ids,
      "checked_release" => lesson.checked_release,
      "review_after" => lesson.review_after && DateTime.to_iso8601(lesson.review_after),
      "retired_at" => lesson.retired_at && DateTime.to_iso8601(lesson.retired_at),
      "retire_reason" => lesson.retire_reason,
      "created_at" => DateTime.to_iso8601(lesson.inserted_at)
    }
  end

  defp skill_summary(%AgentSkill{} = skill, lesson_skills, effective, defaults) do
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
      "has_agent_overlay" => MapSet.member?(lesson_skills, skill.skill_name)
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

  defp skill_lesson_catalog(repo, agent_uid, opts) do
    defaults = Keyword.fetch!(opts, :agent_library_defaults)
    parent_enabled = Keyword.fetch!(opts, :parent_enablement)

    AgentSkill
    |> where([skill], skill.agent_uid == ^agent_uid)
    |> repo.all()
    |> Map.new(fn skill ->
      result =
        if effective_skill_enabled?(skill, defaults, parent_enabled),
          do: {:ok, skill},
          else: {:error, :skill_not_enabled}

      {skill.skill_name, result}
    end)
  end

  defp effective_skill_enabled?(%AgentSkill{} = skill, defaults, parent_enabled) do
    enabled = effective_override(skill.enabled_override, skill_global_default(skill, defaults))

    if is_binary(skill.agent_plugin_id),
      do: enabled and Map.get(parent_enabled, skill.agent_plugin_id, false),
      else: enabled
  end

  defp runtime_skill_enabled?(%AgentSkill{agent_plugin_id: id} = skill, _defaults, enabled)
       when is_binary(id) do
    Map.get(enabled, skill_stable_id(skill), false)
  end

  defp runtime_skill_enabled?(%AgentSkill{} = skill, defaults, _enabled) do
    effective_override(skill.enabled_override, skill_global_default(skill, defaults))
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
    case Keyword.fetch(opts, :parent_enablement) do
      {:ok, enabled} ->
        {:ok, enabled}

      :error ->
        with {:ok, plugins} <- AgentPlugins.capabilities_for_agent(agent_uid, opts) do
          {:ok, Map.new(plugins, &{&1["id"], &1["effective_enabled"]})}
        end
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
