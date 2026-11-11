defmodule Ankole.AIAgent.Library do
  @moduledoc "Agent contracts and Skill capabilities, independent of collaboration and knowledge permissions."
  alias Ankole.AIAgent.Library.{AgentPlugins, Contracts, Skills, SkillLessons, SourceReader}
  alias Ankole.AIAgent.Library.Schemas.AgentSkillLesson
  alias Ankole.{Principals, Repo}

  def shipped_skill_sources(opts \\ []) do
    with {:ok, builtins} <- SourceReader.read_builtin_skill_sources(),
         {:ok, plugins} <- AgentPlugins.skill_sources(opts) do
      sources = builtins ++ plugins

      conflicts =
        sources
        |> Enum.frequencies_by(& &1.name)
        |> Enum.filter(&(elem(&1, 1) > 1))
        |> Enum.map(&elem(&1, 0))

      if conflicts == [],
        do: {:ok, sources},
        else: {:error, {:skill_source_name_conflicts, conflicts}}
    end
  end

  def sync_agent_skills(uid, opts \\ []) do
    with {:ok, _} <- Principals.get_agent(uid),
         {:ok, sources} <- shipped_skill_sources(opts),
         {:ok, _} <- if(Repo.in_transaction?(), do: {:ok, []}, else: Skills.sync(sources)),
         do: {:ok, :ok}
  end

  def seed_agent_library_in_tx(uid, type \\ :ai_colleague),
    do: Contracts.seed_agent_in_tx(uid, type)

  defdelegate list_agent_documents(uid), to: Contracts, as: :effective

  def global_capabilities(opts \\ []) do
    with {:ok, sources} <- shipped_skill_sources(opts),
         {:ok, _} <- Skills.sync(sources),
         {:ok, plugins} <- AgentPlugins.global_capabilities(opts) do
      {:ok,
       %{
         "agent_plugins" => plugins,
         "skills" =>
           Skills.list()
           |> Enum.filter(&(is_nil(&1.agent_plugin_id) and is_nil(&1.agent_uid)))
           |> Enum.map(&capability(&1, MapSet.new()))
       }}
    end
  end

  def capabilities_for_agent(uid, opts \\ []) do
    with {:ok, plugins} <- AgentPlugins.capabilities_for_agent(uid, opts) do
      bindings = Skills.bindings(uid)

      {:ok,
       %{
         "agent_plugins" => plugins,
         "skills" =>
           Skills.list()
           |> Enum.filter(
             &(is_nil(&1.agent_plugin_id) and (is_nil(&1.agent_uid) or &1.agent_uid == uid))
           )
           |> Enum.map(&capability(&1, bindings, uid))
       }}
    end
  end

  def capability(skill, bindings, uid \\ nil) do
    personal? = is_binary(uid) and skill.agent_uid == uid

    %{
      "id" => skill.slug,
      "name" => skill.slug,
      "description" => skill.description,
      "source_kind" => to_string(skill.source_kind),
      "agent_plugin_id" => skill.agent_plugin_id,
      "enabled_for_all" => skill.enabled_for_all,
      "bound" => personal? or MapSet.member?(bindings, skill.id),
      "effective_enabled" => Skills.enabled_for_agent?(skill, uid, bindings),
      "revision" => skill.revision
    }
  end

  def enabled_skills_for_agent(uid, opts \\ []) do
    with {:ok, _} <- Principals.get_agent(uid),
         {:ok, plugins} <- AgentPlugins.capabilities_for_agent(uid, opts),
         do: {:ok, enabled_skills(uid, plugins, opts)}
  end

  def runtime_catalog_for_agent(uid, opts \\ []) do
    with {:ok, _} <- Principals.get_agent(uid),
         {:ok, plugins} <- AgentPlugins.capabilities_for_agent(uid, opts) do
      {:ok,
       %{
         "agent_plugins" => AgentPlugins.enabled_catalog(plugins),
         "skills" => enabled_skills(uid, plugins, opts)
       }}
    end
  end

  defp enabled_skills(uid, plugins, opts) do
    parents = Map.new(plugins, &{&1["id"], &1["effective_enabled"]})
    bindings = Skills.bindings(uid)
    lessons = SkillLessons.delivered_skill_names(uid)

    Skills.list()
    |> Enum.filter(
      &(Ankole.BackgroundAgentJobs.RuntimeProjection.allows_skill?(
          opts[:runtime_projection],
          &1
        ) and Skills.enabled_for_agent?(&1, uid, bindings) and
          (is_nil(&1.agent_plugin_id) or parents[&1.agent_plugin_id] == true))
    )
    |> Enum.map(&summary(&1, uid, MapSet.member?(lessons, &1.slug)))
  end

  def runtime_skills_for_agent(uid, opts \\ []), do: enabled_skills_for_agent(uid, opts)

  def enabled_skill(uid, slug, opts \\ []) do
    with {:ok, _} <- Principals.get_agent(uid),
         {:ok, _} <-
           if(Repo.in_transaction?() or not Keyword.get(opts, :sync, true),
             do: {:ok, :not_synced},
             else: sync_agent_skills(uid, opts)
           ),
         {:ok, skill} <- Skills.get(slug),
         true <-
           Ankole.BackgroundAgentJobs.RuntimeProjection.allows_skill?(
             opts[:runtime_projection],
             skill
           ),
         true <- Skills.enabled_for_agent?(skill, uid, Skills.bindings(uid)),
         {:ok, true} <- parent_enabled?(skill.agent_plugin_id, uid, opts),
         do: {:ok, skill},
         else: (
           false -> {:error, :skill_not_enabled}
           {:ok, false} -> {:error, :skill_not_enabled}
           {:error, :agent_plugin_not_found} -> {:error, :skill_not_enabled}
           {:error, :not_found} -> {:error, :skill_not_found}
           error -> error
         )
  end

  defp parent_enabled?(nil, _, _), do: {:ok, true}

  defp parent_enabled?(plugin, uid, opts),
    do: AgentPlugins.effective_enabled?(uid, plugin, opts)

  def skill_view(uid, slug, path \\ nil, opts \\ []) do
    with {:ok, path} <- SourceReader.normalize_virtual_path(path || "SKILL.md"),
         {:ok, skill} <- enabled_skill(uid, slug, opts),
         {:ok, raw} <- Skills.read(skill, path) do
      base = if path == "SKILL.md", do: SourceReader.skill_body(raw), else: raw
      lessons = if path == "SKILL.md", do: SkillLessons.delivered_text(uid, slug)

      content =
        if is_binary(lessons),
          do: base <> "\n\n---\nAgent-specific additions for #{uid}:\n\n" <> lessons,
          else: base

      {:ok,
       %{
         "skill_name" => slug,
         "source_kind" => to_string(skill.source_kind),
         "relative_path" => slug,
         "skill_uri" => "/drive/Skills/#{slug}/#{path}",
         "content" => content,
         "base_content" => base,
         "has_agent_overlay" => is_binary(lessons)
       }}
    end
  end

  def skill_bundle(uid, slug, opts \\ []) do
    with {:ok, skill} <- enabled_skill(uid, slug, opts),
         {:ok, files} <-
           Skills.files(skill.id)
           |> Enum.map(fn file ->
             with {:ok, bytes} <- Ankole.Files.read_object(file.object_id),
                  do:
                    {:ok,
                     %{
                       "path" => file.relative_path,
                       "content" => Base.encode64(bytes),
                       "mode" => file.mode
                     }}
           end)
           |> Ankole.Attrs.collect_results() do
      {:ok,
       [
         %{
           "path" => "SKILL.md",
           "content" => Base.encode64(skill.manifest_markdown),
           "mode" => 0o444
         }
         | files
       ]}
    end
  end

  def apply_skill_lesson_adds(uid, adds, context, opts \\ []) do
    with {:ok, skills} <- enabled_skills_for_agent(uid, opts) do
      names = MapSet.new(skills, & &1["skill_name"])

      catalog =
        Map.new(Skills.list(), fn skill ->
          value =
            if MapSet.member?(names, skill.slug),
              do: {:ok, %{content_hash: SourceReader.hash(skill.manifest_markdown)}},
              else: {:error, :skill_not_enabled}

          {skill.slug, value}
        end)

      Repo.transact_top_level(fn ->
        SkillLessons.apply_adds_in_tx(
          uid,
          adds,
          context,
          Keyword.get(opts, :now, DateTime.utc_now(:microsecond)),
          catalog
        )
      end)
    end
  end

  def create_skill_lesson(uid, slug, content, author, opts \\ []) do
    with {:ok, _} <- enabled_skill(uid, slug, opts) do
      Repo.transact_top_level(fn ->
        Ankole.Ash.create(AgentSkillLesson, :teach_human, %{
          agent_uid: uid,
          skill_name: slug,
          content: content,
          author: author
        })
      end)
    end
  end

  defdelegate apply_skill_lesson_reviews(uid, reviews, docket_ids, context, opts \\ []),
    to: SkillLessons

  defdelegate skill_lesson_review_docket(uid, horizon, release), to: SkillLessons
  defdelegate retire_skill_lesson(uid, id), to: SkillLessons
  defdelegate active_skill_lessons(uid), to: SkillLessons
  defdelegate revoked_skill_lessons(uid), to: SkillLessons

  defp summary(skill, uid, lessons),
    do: %{
      "id" => skill.slug,
      "skill_name" => skill.slug,
      "name" => skill.name,
      "agent_uid" => uid,
      "personal" => skill.agent_uid == uid,
      "description" => skill.description,
      "source_kind" => to_string(skill.source_kind),
      "agent_plugin_id" => skill.agent_plugin_id,
      "relative_path" => skill.slug,
      "skill_root" => "drive",
      "metadata" => skill.metadata,
      "enabled_for_all" => skill.enabled_for_all,
      "effective_enabled" => true,
      "enabled" => true,
      "category" => skill.metadata["category"],
      "tags" => skill.metadata["tags"] || [],
      "skill_uri" => "/drive/Skills/#{skill.slug}/SKILL.md",
      "has_agent_overlay" => lessons
    }
end
