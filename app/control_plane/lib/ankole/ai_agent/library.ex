defmodule Ankole.AIAgent.Library do
  @moduledoc """
  Agent contracts and Skill capabilities backed by Pod knowledge pages.

  Shared contracts and Skills live in the tenant's AnkoleBrain tree. Private
  installed packages live in the Agent's Drive. The registry records enablement
  and discovery metadata; the owning pages and files provide runtime content.
  """

  require Ash.Query

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library.AgentPlugins.Config, as: AgentPluginConfig
  alias Ankole.AIAgent.Library.{Contracts, SkillPages}
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.Schemas.AgentSkillLesson
  alias Ankole.AIAgent.Library.SkillLessons
  alias Ankole.AIAgent.Library.SourceReader
  alias Ankole.Files
  alias Ankole.Principals
  alias Ankole.Repo

  @skill_file "SKILL.md"
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
         {:ok, agent_plugin_sources} <- AgentPlugins.skill_sources(opts),
         sources = builtin_sources ++ agent_plugin_sources,
         :ok <- reject_skill_name_conflicts(Enum.map(sources, & &1.name)) do
      {:ok, sources}
    end
  end

  @doc """
  Synchronizes the Skill catalog from shipped bundles and the Agent's drive.

  Installed manifests are read while the Agent's drive is locked, like drive
  mutations. A missing Worker cache cannot change this catalog.
  """
  @spec sync_agent_skills(String.t(), keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync_agent_skills(agent_uid, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, sources} <- shipped_skill_sources(opts) do
      # A Job transition reads the catalog inside its own transaction; the
      # sync then joins that transaction. A top-level read opens its own.
      if Repo.in_transaction?() do
        sync_agent_skills_in_tx(agent_uid, sources, now)
      else
        with {:ok, _} <- SkillPages.sync(sources),
             do:
               Repo.transact_top_level(fn -> sync_agent_skills_in_tx(agent_uid, sources, now) end)
      end
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
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, _result} <- sync_agent_skills(agent_uid, opts),
         {:ok, skill_name, expected_agent_plugin_id} <- normalize_skill_id(skill_id),
         %AgentSkill{} = skill <-
           AgentSkill
           |> Ash.Query.filter(agent_uid == ^agent_uid and skill_name == ^skill_name)
           |> Ankole.Ash.read_one!(),
         :ok <- validate_skill_owner(skill, expected_agent_plugin_id) do
      Ankole.Ash.update(skill, :set_override, %{enabled_override: enabled})
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
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, agent_plugins} <- AgentPlugins.capabilities_for_agent(agent_uid, opts),
         {:ok, defaults} <- library_defaults(opts) do
      skills =
        AgentSkill
        |> Ash.Query.filter(agent_uid == ^agent_uid and is_nil(agent_plugin_id))
        |> Ash.Query.sort(skill_name: :asc)
        |> Ankole.Ash.read!()
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
  Seeds writable library state inside a caller-owned transaction.
  """
  @spec seed_agent_library_in_tx(String.t(), atom()) :: :ok | {:error, term()}
  def seed_agent_library_in_tx(agent_uid, type \\ :ai_colleague) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, sources} <- shipped_skill_sources(),
         :ok <- Files.lock_drive(agent_uid),
         :ok <- Contracts.seed_agent_in_tx(agent_uid, type),
         {:ok, _result} <- sync_agent_skills_in_tx(agent_uid, sources, now) do
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
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, opts} <- skill_catalog_options(agent_uid, opts),
         {:ok, _result} <- sync_agent_skills(agent_uid, opts),
         {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
         {:ok, file_path} <- SourceReader.normalize_virtual_path(file_path || @skill_file),
         :ok <- reject_agent_append_file(file_path),
         {:ok, skill} <- enabled_skill(agent_uid, skill_name, opts) do
      do_skill_view(agent_uid, skill, file_path, opts)
    end
  end

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
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, agent_uid, sources, opts} <- prepare_skill_lesson_write(agent_uid, opts) do
      Repo.transact_top_level(fn ->
        with {:ok, _result} <- sync_agent_skills_in_tx(agent_uid, sources, now) do
          catalog = skill_lesson_catalog(agent_uid, opts)
          SkillLessons.apply_adds_in_tx(agent_uid, adds, context, now, catalog)
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
  @spec skill_lesson_review_docket(String.t(), DateTime.t(), String.t()) ::
          {:ok, [AgentSkillLesson.t()]} | {:error, term()}
  defdelegate skill_lesson_review_docket(agent_uid, horizon, current_release),
    to: SkillLessons

  @doc """
  Creates one operator-authored lesson for an enabled skill.

  Human lessons carry no lease and are never touched by Dreaming.
  """
  @spec create_skill_lesson(String.t(), String.t(), String.t(), Ankole.ActorRef.t(), keyword()) ::
          {:ok, AgentSkillLesson.t()} | {:error, term()}
  def create_skill_lesson(agent_uid, skill_name, content, author, opts \\ []) do
    with {:ok, agent_uid, sources, opts} <- prepare_skill_lesson_write(agent_uid, opts) do
      Repo.transact_top_level(fn ->
        teach_in_tx(agent_uid, skill_name, content, author, sources, opts)
      end)
    end
  end

  defp teach_in_tx(agent_uid, skill_name, content, author, sources, catalog_options) do
    with {:ok, _result} <-
           sync_agent_skills_in_tx(agent_uid, sources, DateTime.utc_now(:microsecond)),
         {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
         {:ok, _skill} <- enabled_skill(agent_uid, skill_name, catalog_options) do
      Ankole.Ash.create(AgentSkillLesson, :teach_human, %{
        agent_uid: agent_uid,
        skill_name: skill_name,
        content: content,
        author: author
      })
    end
  end

  @doc """
  Retires one lesson on operator request.

  A human retirement of a dreaming lesson is permanent: the row joins the
  immunity list and Dreaming never re-adds equivalent content.
  """
  @spec retire_skill_lesson(String.t(), String.t()) ::
          {:ok, AgentSkillLesson.t()} | {:error, term()}
  defdelegate retire_skill_lesson(agent_uid, lesson_id), to: SkillLessons

  @doc """
  Returns the active lessons of one agent for reflection prompt assembly.
  """
  @spec active_skill_lessons(String.t()) ::
          {:ok, [AgentSkillLesson.t()]} | {:error, term()}
  defdelegate active_skill_lessons(agent_uid), to: SkillLessons

  @doc """
  Returns the human-revoked lessons of one agent: the never-relearn list.
  """
  @spec revoked_skill_lessons(String.t()) ::
          {:ok, [AgentSkillLesson.t()]} | {:error, term()}
  defdelegate revoked_skill_lessons(agent_uid), to: SkillLessons

  @doc "Reads the Agent's whole effective contracts using the Agent identity."
  defdelegate list_agent_documents(agent_uid), to: Contracts, as: :effective

  @doc "Returns one coherent Agent Plugin and Skill catalog for an Agent runtime."
  @spec runtime_catalog_for_agent(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def runtime_catalog_for_agent(agent_uid, opts \\ []) do
    with {:ok, runtime_state} <- enabled_runtime_state(agent_uid, opts) do
      names = MapSet.new(runtime_state.skills, & &1["skill_name"])

      plugins =
        runtime_state.agent_plugins
        |> AgentPlugins.enabled_catalog()
        |> Enum.map(fn plugin ->
          Map.update!(plugin, "skills", fn skills ->
            Enum.filter(skills, &MapSet.member?(names, &1["catalog_name"]))
          end)
        end)

      {:ok,
       %{
         "agent_plugins" => plugins,
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
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, _} <- sync_agent_skills(agent_uid, opts),
         {:ok, context} <- request_context(agent_uid, opts),
         {:ok, defaults} <- library_defaults(opts),
         runtime_opts = Keyword.merge(opts, agent_library_defaults: defaults, sync: false),
         {:ok, agent_plugins} <- AgentPlugins.capabilities_for_agent(agent_uid, runtime_opts) do
      lesson_skills = SkillLessons.delivered_skill_names(agent_uid)

      plugin_member_enabled =
        Map.new(
          for agent_plugin <- agent_plugins,
              skill <- agent_plugin["skills"],
              do: {skill["id"], skill["effective_enabled"]}
        )

      skills =
        AgentSkill
        |> Ash.Query.filter(agent_uid == ^agent_uid)
        |> Ash.Query.sort(skill_name: :asc)
        |> Ankole.Ash.read!()
        |> Enum.map(fn skill ->
          effective = runtime_skill_enabled?(skill, defaults, plugin_member_enabled)
          {skill, effective}
        end)
        |> Enum.filter(&elem(&1, 1))
        |> Enum.map(fn {skill, effective} ->
          skill_summary(skill, lesson_skills, effective, defaults)
        end)
        |> Enum.filter(&SkillPages.visible?(&1, context))

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
         {:ok, sources} <- shipped_skill_sources(opts),
         {:ok, _} <- sync_agent_skills(agent_uid, opts) do
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

  defp sync_agent_skills_in_tx(agent_uid, _sources, now) do
    with :ok <- Files.lock_drive(agent_uid),
         {:ok, shared} <- SkillPages.catalog(),
         {:ok, installed} <- SourceReader.read_installed_skill_sources(agent_uid) do
      source_rows =
        Enum.map(shared, &source_attrs(&1, &1.source_kind, now)) ++
          Enum.map(installed, &source_attrs(&1, :installed, now))

      source_names = Enum.map(source_rows, & &1.skill_name)

      existing_by_name =
        AgentSkill
        |> Ash.Query.filter(agent_uid == ^agent_uid)
        |> Ankole.Ash.read!()
        |> Map.new(&{&1.skill_name, &1})

      changed_rows =
        Enum.reject(source_rows, &source_row_current?(existing_by_name[&1.skill_name], &1))

      with :ok <- reject_skill_name_conflicts(source_names),
           :ok <- upsert_agent_skill_rows(agent_uid, changed_rows, now),
           {:ok, stale_rows} <-
             AgentSkill
             |> Ash.Query.filter(agent_uid == ^agent_uid and skill_name not in ^source_names)
             |> Ankole.Ash.destroy_where(:remove_stale, %{}, select: [:id]) do
        {:ok,
         %{
           changed: changed_rows != [] or stale_rows != [],
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
        |> Map.put("source_kind", Atom.to_string(source_kind))
        |> Map.put("relative_path", source.relative_path),
      content_hash: source.source_hash,
      synced_at: now,
      file_count: length(source.files)
    }
  end

  # The upsert keeps the operator overrides. Only the changed rows are written.
  defp upsert_agent_skill_rows(_agent_uid, [], _now), do: :ok

  defp upsert_agent_skill_rows(agent_uid, source_rows, now) do
    inputs =
      Enum.map(source_rows, fn row ->
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
        |> Map.merge(%{agent_uid: agent_uid, inserted_at: now, updated_at: now})
      end)

    case Ankole.Ash.create_all(inputs, AgentSkill, :sync) do
      {:ok, _skills} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp agent_skill_hash(rows) do
    rows
    |> Enum.flat_map(&[&1.skill_name, &1.source_kind, &1.relative_path, &1.content_hash])
    |> Enum.join(<<0>>)
    |> SourceReader.hash()
  end

  defp reject_agent_append_file("AGENT_APPEND.md"), do: {:error, :skill_file_not_found}
  defp reject_agent_append_file(_file_path), do: :ok

  defp enabled_skill(agent_uid, skill_name, opts) do
    case AgentSkill
         |> Ash.Query.filter(agent_uid == ^agent_uid and skill_name == ^skill_name)
         |> Ankole.Ash.read_one!() do
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

  defp do_skill_view(agent_uid, %AgentSkill{} = skill, file_path, opts) do
    case read_skill_file(skill, file_path, opts) do
      {:ok, raw_content} when file_path == @skill_file ->
        base_content = SourceReader.skill_body(raw_content)
        lessons_text = SkillLessons.delivered_text(agent_uid, skill.skill_name)

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
           "source_kind" => Atom.to_string(skill.source_kind),
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
           "source_kind" => Atom.to_string(skill.source_kind),
           "relative_path" => skill.relative_path,
           "skill_uri" => skill_uri(skill.skill_name, file_path),
           "content" => content,
           "has_agent_overlay" =>
             is_binary(SkillLessons.delivered_text(agent_uid, skill.skill_name))
         }}

      {:error, _reason} ->
        {:error, :skill_file_not_found}
    end
  end

  defp read_skill_file(%AgentSkill{source_kind: source} = skill, file_path, opts)
       when source in [:builtin, :shared] do
    with {:ok, context} <- request_context(skill.agent_uid, opts),
         do: SkillPages.read(skill, file_path, context)
  end

  defp read_skill_file(%AgentSkill{source_kind: :installed} = skill, file_path, opts) do
    with {:ok, context} <- request_context(skill.agent_uid, opts),
         true <- SkillPages.private_visible?(skill.agent_uid, context),
         {:ok, _file, content} <-
           Ankole.Files.read(skill.agent_uid, "skills/#{skill.relative_path}/#{file_path}") do
      {:ok, content}
    else
      _ -> {:error, :skill_file_not_found}
    end
  end

  def request_context(agent_uid, opts) do
    case Keyword.fetch(opts, :request_context) do
      {:ok, context} -> {:ok, context}
      :error -> Ankole.Brain.RequestContext.build(agent_uid, nil)
    end
  end

  def skill_bundle(agent_uid, name, opts \\ []) do
    with {:ok, opts} <- skill_catalog_options(agent_uid, opts),
         {:ok, skill} <- enabled_skill(agent_uid, name, opts),
         {:ok, context} <- request_context(agent_uid, opts) do
      case skill.source_kind do
        :installed -> private_bundle(skill, context)
        _ -> SkillPages.bundle(skill, context)
      end
    end
  end

  defp private_bundle(skill, context) do
    with true <- SkillPages.private_visible?(skill.agent_uid, context),
         {:ok, access} <- Ankole.Brain.Access.for_context(context) do
      private_bundle_page(skill, access, nil)
    else
      _ -> {:error, :skill_not_found}
    end
  end

  defp private_bundle_page(skill, access, after_path) do
    prefix = "skills/#{skill.relative_path}"

    with {:ok, %{files: files, next_after: next_after}} <-
           Files.list(skill.agent_uid, prefix, limit: 5_000, after: after_path),
         {:ok, contents} <-
           files
           |> Enum.map(&private_bundle_file(&1, access, prefix))
           |> Ankole.Attrs.collect_results(),
         {:ok, rest} <-
           if(next_after, do: private_bundle_page(skill, access, next_after), else: {:ok, []}) do
      {:ok, List.flatten(contents) ++ rest}
    end
  end

  defp private_bundle_file(file, access, prefix) do
    with {:ok, node} <- Files.Nodes.fetch(file.node_id),
         true <- Ankole.Brain.Access.visible_node?(access, node),
         {:ok, bytes} <- Files.read_object(file.object_id) do
      {:ok,
       [
         %{
           "path" => String.replace_prefix(file.path, prefix <> "/", ""),
           "content" => Base.encode64(bytes),
           "mode" => file.mode
         }
       ]}
    else
      false -> {:ok, []}
      error -> error
    end
  end

  defp reject_skill_name_conflicts(names) do
    conflicts =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case conflicts do
      [] -> :ok
      names -> {:error, {:skill_source_name_conflicts, names}}
    end
  end

  defp skill_summary(%AgentSkill{} = skill, lesson_skills, effective, defaults) do
    metadata = skill.metadata || %{}
    global_default = skill_global_default(skill, defaults)

    %{
      "id" => skill_stable_id(skill),
      "skill_name" => skill.skill_name,
      "agent_uid" => skill.agent_uid,
      "description" => skill.description,
      "source_kind" => Atom.to_string(skill.source_kind),
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
      "source_kind" => Atom.to_string(skill.source_kind),
      "agent_plugin_id" => nil,
      "global_default_enabled" => global_default,
      "override_enabled" => skill.enabled_override,
      "effective_enabled" => effective
    }
  end

  defp skill_lesson_catalog(agent_uid, opts) do
    defaults = Keyword.fetch!(opts, :agent_library_defaults)
    parent_enabled = Keyword.fetch!(opts, :parent_enablement)

    AgentSkill
    |> Ash.Query.filter(agent_uid == ^agent_uid)
    |> Ankole.Ash.read!()
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

  defp skill_global_default(%AgentSkill{source_kind: :installed} = skill, _defaults),
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
        AgentPluginConfig.defaults()
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
