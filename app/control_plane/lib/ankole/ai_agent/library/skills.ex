defmodule Ankole.AIAgent.Library.Skills do
  @moduledoc "Owns Skill manifests, package files, positive bindings and upstream reconciliation."
  require Ash.Query
  alias Ankole.AIAgent.Library.{Management, RuntimeCapabilityChanges, SourceReader}
  alias Ankole.AIAgent.Library.Schemas.{Skill, SkillFile, AgentSkill}
  alias Ankole.{Files, Principals, Repo}

  @reserved_custom_slugs ~w(new compress retry steer stop llm learn invite rename page model)
  @slug_regex ~r/\A[a-z0-9][a-z0-9._-]{0,95}\z/

  def reserved_custom_slugs, do: @reserved_custom_slugs
  def reserved_custom_slug?(slug) when is_binary(slug), do: slug in @reserved_custom_slugs
  def reserved_custom_slug?(_), do: false

  def validate_custom_slug(slug) when is_binary(slug) do
    trimmed = String.trim(slug)

    cond do
      not Regex.match?(@slug_regex, trimmed) -> {:error, :invalid_skill_manifest}
      trimmed in @reserved_custom_slugs -> {:error, :reserved_skill_slug}
      true -> {:ok, trimmed}
    end
  end

  def validate_custom_slug(_), do: {:error, :invalid_skill_manifest}

  def slugify_name(name) when is_binary(name) do
    candidate =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 64)
      |> String.trim_trailing("-")

    cond do
      candidate == "" -> "custom-skill"
      candidate in @reserved_custom_slugs -> candidate <> "-skill"
      true -> candidate
    end
  end

  def slugify_name(_), do: "custom-skill"

  def resolve_custom_slug(raw_slug, fallback_name) do
    trimmed = if is_binary(raw_slug), do: String.trim(raw_slug), else: ""

    if trimmed != "" do
      validate_custom_slug(trimmed)
    else
      with {:ok, current} <- stored_by_slug() do
        {:ok, unique_slug(slugify_name(fallback_name), current)}
      end
    end
  end

  defp unique_slug(base, current) do
    if not Map.has_key?(current, base) do
      base
    else
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{base}-#{n}"
        unless Map.has_key?(current, candidate), do: candidate
      end)
    end
  end

  def list, do: Skill |> Ash.Query.sort(slug: :asc) |> Ankole.Ash.read!()
  def get(slug), do: Skill |> Ash.Query.filter(slug == ^slug) |> Ankole.Ash.read_one() |> found()

  def files(id),
    do:
      SkillFile
      |> Ash.Query.filter(skill_id == ^id)
      |> Ash.Query.sort(relative_path: :asc)
      |> Ankole.Ash.read!()

  def mcp_metadata_files do
    SkillFile
    |> Ash.Query.filter(relative_path == "agents/openai.yaml")
    |> Ankole.Ash.read()
  end

  def bindings(uid),
    do:
      AgentSkill
      |> Ash.Query.filter(agent_uid == ^uid)
      |> Ankole.Ash.read!()
      |> MapSet.new(& &1.skill_id)

  def bound_agents(id),
    do:
      AgentSkill
      |> Ash.Query.filter(skill_id == ^id)
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.agent_uid)

  def binding_summaries(actor, skills) do
    alias Ankole.AIAgent.Library.AgentPlugins

    ids = Enum.map(skills, & &1.id)
    agents = Ankole.Principals.list_agents(status: :active)

    colleagues =
      agents |> Enum.filter(&(&1.agent.type == :ai_colleague)) |> MapSet.new(& &1.principal.uid)

    readable =
      agents
      |> Enum.map(& &1.principal.uid)
      |> Enum.filter(&(Management.agent(actor, &1, "read") == :ok))
      |> MapSet.new()

    readable_sorted = Enum.sort(readable)

    assistant =
      Enum.find(
        agents,
        &(&1.agent.type == :personal_assistant and
            &1.agent.owner_principal_uid == actor.principal.uid)
      )

    {global_plugins, plugins_by_agent} =
      if Enum.any?(skills, &(not is_nil(&1.agent_plugin_id))),
        do: AgentPlugins.plugin_enablement(readable_sorted),
        else: {%{}, %{}}

    bindings =
      AgentSkill
      |> Ash.Query.filter(skill_id in ^ids)
      |> Ankole.Ash.read!()
      |> Enum.group_by(& &1.skill_id, & &1.agent_uid)

    Map.new(skills, fn skill ->
      if is_binary(skill.agent_uid) do
        assistant_enabled =
          not is_nil(assistant) and assistant.principal.uid == skill.agent_uid

        agent_uids =
          if(MapSet.member?(readable, skill.agent_uid), do: [skill.agent_uid], else: [])

        {skill.id,
         %{
           colleague_count: 0,
           assistant_enabled: assistant_enabled,
           agent_uids: agent_uids,
           runtime_assistant_enabled: assistant_enabled,
           runtime_agent_uids: agent_uids
         }}
      else
        uids = Map.get(bindings, skill.id, [])
        visible_bound_uids = uids |> Enum.filter(&MapSet.member?(readable, &1)) |> Enum.sort()
        assistant_enabled = not is_nil(assistant) and assistant.principal.uid in uids

        candidate_runtime_uids =
          if skill.enabled_for_all, do: readable_sorted, else: visible_bound_uids

        runtime_agent_uids =
          Enum.filter(candidate_runtime_uids, fn uid ->
            parent_plugin_enabled?(skill.agent_plugin_id, uid, global_plugins, plugins_by_agent)
          end)

        runtime_assistant_enabled =
          if assistant do
            (skill.enabled_for_all or assistant_enabled) and
              parent_plugin_enabled?(
                skill.agent_plugin_id,
                assistant.principal.uid,
                global_plugins,
                plugins_by_agent
              )
          else
            skill.enabled_for_all and
              parent_plugin_enabled?(skill.agent_plugin_id, nil, global_plugins, plugins_by_agent)
          end

        {skill.id,
         %{
           colleague_count: Enum.count(uids, &MapSet.member?(colleagues, &1)),
           assistant_enabled: assistant_enabled,
           agent_uids: visible_bound_uids,
           runtime_assistant_enabled: runtime_assistant_enabled,
           runtime_agent_uids: runtime_agent_uids
         }}
      end
    end)
  end

  defp parent_plugin_enabled?(nil, _agent_uid, _global_plugins, _plugins_by_agent), do: true

  defp parent_plugin_enabled?(plugin_id, nil, global_plugins, _plugins_by_agent),
    do: Map.get(global_plugins, plugin_id, false) == true

  defp parent_plugin_enabled?(plugin_id, agent_uid, _global_plugins, plugins_by_agent),
    do: get_in(plugins_by_agent, [agent_uid, plugin_id]) == true

  def enabled?(skill, bindings), do: skill.enabled_for_all or MapSet.member?(bindings, skill.id)

  def enabled_for_agent?(%{agent_uid: agent_uid}, uid, _bindings) when is_binary(agent_uid),
    do: agent_uid == uid

  def enabled_for_agent?(skill, _uid, bindings),
    do: enabled?(skill, bindings)

  def visible_to?(_actor, %{agent_uid: nil}), do: true

  def visible_to?(actor, %{agent_uid: uid}) when is_binary(uid),
    do: Management.agent(actor, uid, "read") == :ok

  def list(actor) do
    with :ok <- Management.member(actor),
         {:ok, _} <- synchronize() do
      {:ok, Enum.filter(list(), &visible_to?(actor, &1))}
    end
  end

  def detail(actor, slug) do
    with :ok <- Management.member(actor),
         {:ok, _} <- synchronize(),
         {:ok, skill} <- get(slug),
         true <- visible_to?(actor, skill) do
      agent_uids =
        if is_binary(skill.agent_uid) do
          [skill.agent_uid]
        else
          Enum.filter(bound_agents(skill.id), &(Management.agent(actor, &1, "read") == :ok))
        end

      {:ok,
       %{
         skill: skill,
         files: files(skill.id),
         agent_uids: agent_uids
       }}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def create(actor, attrs) do
    with {:ok, target_agent_uid} <- resolve_target_agent_uid(actor, attrs),
         {:ok, content} <- manifest(attrs),
         {:ok, slug} <- resolve_custom_slug(Map.get(attrs, :slug), content.name) do
      Repo.transact_top_level(
        fn ->
          case get(slug) do
            {:ok, _} ->
              {:error, :skill_slug_taken}

            {:error, :not_found} ->
              Ankole.Ash.create(
                Skill,
                :create,
                Map.merge(content, %{
                  slug: slug,
                  source_kind: :custom,
                  enabled_for_all: false,
                  agent_uid: target_agent_uid,
                  created_by: actor.principal.uid
                })
              )
          end
        end,
        after_commit: fn result ->
          Management.committed(result)

          if is_binary(target_agent_uid) do
            RuntimeCapabilityChanges.notify_agent(target_agent_uid, {:skill, slug})
          end

          result
        end
      )
    end
  end

  def import(actor, slug, archive, opts \\ %{}) do
    with {:ok, target_agent_uid} <- resolve_target_agent_uid(actor, opts),
         {:ok, entries} <- archive_files(archive),
         {manifest_path, bytes, _mode} <-
           entries
           |> Enum.filter(fn {path, _, _} -> Path.basename(path) == "SKILL.md" end)
           |> Enum.min_by(fn {path, _, _} -> length(Path.split(path)) end, fn ->
             {nil, nil, nil}
           end),
         true <- is_binary(manifest_path),
         {:ok, manifest} <- parse(bytes),
         {:ok, resolved_slug} <- resolve_custom_slug(slug, manifest.name),
         prefix = String.replace_suffix(manifest_path, "SKILL.md", ""),
         {:ok, prepared} <-
           entries
           |> Enum.reject(fn {path, _, _} -> path == manifest_path end)
           |> Enum.map(fn {path, bytes, mode} ->
             with true <- String.starts_with?(path, prefix),
                  {:ok, path} <- file_path(String.replace_prefix(path, prefix, "")),
                  {:ok, stored} <- Files.store(bytes),
                  do: {:ok, {path, stored, mode}},
                  else: (
                    false -> {:error, :invalid_skill_package}
                    error -> error
                  )
           end)
           |> Ankole.Attrs.collect_results(),
         :ok <- validate_paths(Enum.map(prepared, &elem(&1, 0))) do
      Repo.transact_top_level(
        fn ->
          case get(resolved_slug) do
            {:ok, _} ->
              {:error, :skill_slug_taken}

            {:error, :not_found} ->
              with {:ok, skill} <-
                     Ankole.Ash.create(
                       Skill,
                       :create,
                       Map.merge(
                         manifest,
                         %{
                           slug: resolved_slug,
                           source_kind: :custom,
                           enabled_for_all: false,
                           agent_uid: target_agent_uid,
                           created_by: actor.principal.uid
                         }
                       )
                     ),
                   {:ok, _} <-
                     Enum.map(prepared, &import_file_in_tx(skill.id, &1))
                     |> Ankole.Attrs.collect_results(),
                   do: {:ok, skill}
          end
        end,
        after_commit: fn result ->
          Management.committed(result)

          if is_binary(target_agent_uid) do
            RuntimeCapabilityChanges.notify_agent(target_agent_uid, {:skill, resolved_slug})
          end

          result
        end
      )
    else
      false -> {:error, :invalid_skill_package}
      error -> error
    end
  end

  defp resolve_target_agent_uid(actor, attrs) when is_map(attrs) do
    personal? = Map.get(attrs, :personal, false) == true

    explicit_uid =
      case Map.get(attrs, :agent_uid) do
        uid when is_binary(uid) -> String.trim(uid)
        _ -> ""
      end

    cond do
      explicit_uid != "" ->
        with {:ok, %{agent: %{type: :personal_assistant}}} <- Principals.get_agent(explicit_uid),
             :ok <- Management.agent(actor, explicit_uid, "update") do
          {:ok, explicit_uid}
        else
          {:ok, _} -> {:error, :personal_skill_requires_assistant}
          error -> error
        end

      personal? ->
        with :ok <- Management.member(actor),
             {:ok, %{principal: assistant}} <-
               Principals.ensure_personal_assistant(actor.principal.uid) do
          {:ok, assistant.uid}
        end

      true ->
        with :ok <- Management.authorize(actor, "tenant_console:custom_skills"), do: {:ok, nil}
    end
  end

  defp import_file_in_tx(id, {path, stored, mode}) do
    with {:ok, object} <- Files.complete_object_in_tx(stored),
         do: put_file_in_tx(id, path, object.id, %{mode: mode})
  end

  defp archive_files(archive) do
    :zip.foldl(
      fn path, info, content, files ->
        stat = File.Stat.from_record(info.())

        name = to_string(path)

        if stat.type == :directory or "__MACOSX" in Path.split(name) or
             Path.basename(name) == ".DS_Store" do
          files
        else
          mode = if Bitwise.band(stat.mode, 0o111) == 0, do: 0o444, else: 0o555
          [{name, content.(), mode} | files]
        end
      end,
      [],
      archive
    )
  end

  def save(actor, slug, attrs) do
    next_slug = Map.get(attrs, :slug, slug)

    with {:ok, skill} <- get(slug),
         true <- visible_to?(actor, skill),
         :ok <- Management.skill(actor, skill, "update"),
         :ok <- rename_allowed(skill, next_slug),
         {:ok, next_slug} <-
           if(next_slug != slug, do: validate_custom_slug(next_slug), else: {:ok, slug}),
         {:ok, content} <- manifest(attrs) do
      Repo.transact_top_level(
        fn ->
          if next_slug != slug and match?({:ok, _}, get(next_slug)) do
            {:error, :skill_slug_taken}
          else
            with {:ok, saved} <-
                   Ankole.Ash.update(
                     skill,
                     :save,
                     Map.merge(content, %{
                       slug: next_slug,
                       base_revision: attrs.base_revision
                     })
                   ),
                 :ok <- Ankole.AIAgent.Library.SkillLessons.rename_skill_in_tx(slug, saved.slug),
                 do: {:ok, saved}
          end
        end,
        after_commit: fn result ->
          if next_slug != slug,
            do: RuntimeCapabilityChanges.notify_global({:skill, slug}),
            else: Management.committed(result)

          result
        end
      )
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def delete(actor, slug, revision) do
    with {:ok, skill} <- get(slug),
         true <- visible_to?(actor, skill),
         %{source_kind: :custom} <- skill,
         :ok <- Management.skill(actor, skill, "delete") do
      Repo.transact_top_level(
        fn ->
          with {:ok, skill} <- Ankole.Ash.update(skill, :save, %{base_revision: revision}),
               :ok <- Ankole.AIAgent.Library.SkillLessons.retire_skill_in_tx(slug),
               do: Ankole.Ash.destroy(skill, :remove)
        end,
        after_commit: fn result ->
          RuntimeCapabilityChanges.notify_global({:skill, slug})
          result
        end
      )
    else
      false -> {:error, :not_found}
      %{source_kind: _} -> {:error, :official_skill}
      error -> error
    end
  end

  def set_all(actor, slug, enabled, revision) do
    with :ok <- Management.authorize(actor, "tenant_console:skill_bindings"),
         {:ok, skill} <- get(slug),
         true <- visible_to?(actor, skill),
         true <- is_nil(skill.agent_uid) do
      Repo.transact_top_level(
        fn ->
          Ankole.Ash.update(skill, :save, %{enabled_for_all: enabled, base_revision: revision})
        end,
        after_commit: fn result ->
          RuntimeCapabilityChanges.notify_global({:skill, slug})
          result
        end
      )
    else
      false ->
        case get(slug) do
          {:ok, %{agent_uid: uid} = skill} when is_binary(uid) ->
            if visible_to?(actor, skill), do: {:error, :private_skill}, else: {:error, :not_found}

          _ ->
            {:error, :not_found}
        end

      error ->
        error
    end
  end

  def set_binding(actor, slug, uid, enabled) do
    with :ok <- Management.binding(actor, uid),
         {:ok, skill} <- get(slug),
         true <- visible_to?(actor, skill) do
      if is_binary(skill.agent_uid) do
        {:error, :private_skill}
      else
        Repo.transact_top_level(
          fn -> bind_shared_skill(skill.id, uid, enabled) end,
          after_commit: fn result ->
            RuntimeCapabilityChanges.notify_agent(uid, {:skill, slug})
            result
          end
        )
      end
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp bind_shared_skill(skill_id, uid, enabled) do
    with {:ok, locked} <- lock(skill_id) do
      cond do
        is_binary(locked.agent_uid) ->
          {:error, :private_skill}

        locked.enabled_for_all ->
          {:error, :skill_enabled_for_all}

        true ->
          with {:ok, _} <- bind_in_tx(locked.id, uid, enabled), do: {:ok, locked}
      end
    end
  end

  def publish_to_workspace(actor, slug, base_revision) do
    with {:ok, skill} <- get(slug),
         true <- visible_to?(actor, skill),
         owner_agent_uid when is_binary(owner_agent_uid) <- skill.agent_uid,
         :ok <- Management.skill(actor, skill, "update"),
         :ok <- Management.authorize(actor, "tenant_console:custom_skills") do
      Repo.transact_top_level(
        fn ->
          with {:ok, locked} <- lock(skill.id),
               true <- locked.agent_uid == owner_agent_uid,
               {:ok, saved} <-
                 Ankole.Ash.update(locked, :save, %{
                   agent_uid: nil,
                   base_revision: base_revision
                 }),
               {:ok, _} <-
                 Ankole.Ash.create(AgentSkill, :enable, %{
                   skill_id: saved.id,
                   agent_uid: owner_agent_uid
                 }) do
            {:ok, saved}
          else
            false -> {:error, :already_workspace_skill}
            error -> error
          end
        end,
        after_commit: fn result ->
          Management.committed(result)
          RuntimeCapabilityChanges.notify_global({:skill, slug})
          result
        end
      )
    else
      false -> {:error, :not_found}
      nil -> {:error, :already_workspace_skill}
      error -> error
    end
  end

  def upsert_from_action_card_in_tx(actor, payload, preconditions)
      when is_map(payload) and is_map(preconditions) do
    :ok = Repo.require_transaction()
    slug = payload["slug"]
    target_agent_uid = payload["agent_uid"]
    bind_agent_uid = payload["bind_agent_uid"]

    if preconditions["expected_missing"] == true do
      create_from_action_card(actor, payload, slug, target_agent_uid, bind_agent_uid)
    else
      update_from_action_card(actor, payload, preconditions, target_agent_uid, bind_agent_uid)
    end
  end

  defp create_from_action_card(actor, payload, slug, target_agent_uid, bind_agent_uid) do
    with :ok <- authorize_card_create(actor, target_agent_uid, bind_agent_uid),
         {:ok, slug} <- validate_custom_slug(slug),
         {:ok, content} <- parse(payload["markdown"]) do
      case get(slug) do
        {:ok, _existing} ->
          {:stale, "A Skill with slug \"#{slug}\" was created after this card was drafted."}

        {:error, :not_found} ->
          with {:ok, created} <-
                 Ankole.Ash.create(
                   Skill,
                   :create,
                   Map.merge(content, %{
                     slug: slug,
                     source_kind: :custom,
                     enabled_for_all: false,
                     agent_uid: target_agent_uid,
                     created_by: actor.principal.uid
                   })
                 ),
               {:ok, _} <-
                 if(is_nil(target_agent_uid) and is_binary(bind_agent_uid),
                   do: bind_in_tx(created.id, bind_agent_uid, true),
                   else: {:ok, :skipped}
                 ) do
            {:ok, created, skill_commit_effects(created, target_agent_uid || bind_agent_uid)}
          end
      end
    end
  end

  defp update_from_action_card(actor, payload, preconditions, target_agent_uid, bind_agent_uid) do
    skill_id = preconditions["skill_id"]
    expected_revision = preconditions["expected_revision"]

    with {:ok, locked} <- lock(skill_id),
         :ok <- Management.skill(actor, locked, "update"),
         :ok <-
           if(is_nil(locked.agent_uid) and is_binary(bind_agent_uid),
             do: Management.binding(actor, bind_agent_uid),
             else: :ok
           ) do
      if locked.source_kind == :custom and locked.revision == expected_revision and
           locked.agent_uid == target_agent_uid do
        with {:ok, content} <- parse(payload["markdown"]),
             {:ok, saved} <-
               Ankole.Ash.update(
                 locked,
                 :save,
                 Map.merge(content, %{slug: locked.slug, base_revision: locked.revision})
               ),
             {:ok, _} <-
               if(is_nil(saved.agent_uid) and is_binary(bind_agent_uid),
                 do: bind_in_tx(saved.id, bind_agent_uid, true),
                 else: {:ok, :skipped}
               ) do
          {:ok, saved, skill_commit_effects(saved, target_agent_uid || bind_agent_uid)}
        end
      else
        {:stale, "Skill \"#{locked.slug}\" changed after this card was drafted."}
      end
    else
      {:error, :not_found} ->
        {:stale, "Target Skill was deleted after this card was drafted."}

      error ->
        error
    end
  end

  defp authorize_card_create(actor, target_agent_uid, _bind_agent_uid)
       when is_binary(target_agent_uid) do
    with {:ok, %{agent: %{type: :personal_assistant}}} <- Principals.get_agent(target_agent_uid),
         :ok <- Management.agent(actor, target_agent_uid, "update") do
      :ok
    else
      {:ok, _} -> {:error, :personal_skill_requires_assistant}
      error -> error
    end
  end

  defp authorize_card_create(actor, nil, bind_agent_uid) do
    with :ok <- Management.authorize(actor, "tenant_console:custom_skills"),
         :ok <-
           if(is_binary(bind_agent_uid), do: Management.binding(actor, bind_agent_uid), else: :ok) do
      :ok
    end
  end

  defp skill_commit_effects(skill, notified_agent_uid) do
    [
      fn ->
        Management.committed({:ok, skill})

        if is_binary(notified_agent_uid) do
          RuntimeCapabilityChanges.notify_agent(notified_agent_uid, {:skill, skill.slug})
        else
          RuntimeCapabilityChanges.notify_global({:skill, skill.slug})
        end
      end
    ]
  end

  def bind_in_tx(id, uid, true) do
    case Skill |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one() do
      {:ok, %{agent_uid: owner}} when is_binary(owner) ->
        {:error, :private_skill}

      {:ok, %{}} ->
        Ankole.Ash.create(AgentSkill, :enable, %{skill_id: id, agent_uid: uid})

      {:ok, nil} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  def bind_in_tx(id, uid, false),
    do:
      AgentSkill
      |> Ash.Query.filter(skill_id == ^id and agent_uid == ^uid)
      |> Ankole.Ash.destroy_where(:disable)

  def put_file(actor, slug, path, content, attrs) do
    with {:ok, skill} <- get(slug),
         true <- visible_to?(actor, skill),
         :ok <- Management.skill(actor, skill, "update"),
         {:ok, path} <- file_path(path),
         {:ok, stored} <- Files.store(content) do
      Repo.transact_top_level(
        fn ->
          with {:ok, skill} <-
                 Ankole.Ash.update(skill, :save, %{base_revision: attrs.base_revision}),
               :ok <- validate_paths([path | Enum.map(files(skill.id), & &1.relative_path)]),
               {:ok, object} <- Files.complete_object_in_tx(stored),
               {:ok, _} <- put_file_in_tx(skill.id, path, object.id, attrs),
               do: {:ok, skill}
        end,
        after_commit: &Management.committed/1
      )
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def change_file(actor, slug, path, attrs) do
    with {:ok, skill} <- get(slug),
         true <- visible_to?(actor, skill),
         :ok <- Management.skill(actor, skill, "update"),
         {:ok, path} <- file_path(path) do
      Repo.transact_top_level(
        fn ->
          with {:ok, skill} <-
                 Ankole.Ash.update(skill, :save, %{base_revision: attrs.base_revision}),
               {:ok, file} <- file(skill.id, path),
               {:ok, _} <- change_file_in_tx(file, attrs[:new_path]),
               do: {:ok, skill}
        end,
        after_commit: &Management.committed/1
      )
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp change_file_in_tx(file, nil), do: Ankole.Ash.destroy(file, :remove)

  defp change_file_in_tx(file, path) do
    with {:ok, path} <- file_path(path),
         :ok <-
           validate_paths([
             path | Enum.map(files(file.skill_id), & &1.relative_path) -- [file.relative_path]
           ]),
         do: Ankole.Ash.update(file, :rename, %{relative_path: path})
  end

  defp validate_paths(paths) do
    paths = MapSet.new(["SKILL.md" | paths])

    collision? =
      Enum.any?(paths, fn path ->
        path
        |> Path.split()
        |> Enum.scan(&Path.join(&2, &1))
        |> Enum.drop(-1)
        |> Enum.any?(&MapSet.member?(paths, &1))
      end)

    if collision?, do: {:error, :skill_path_conflict}, else: :ok
  end

  def read(skill, "SKILL.md"), do: {:ok, skill.manifest_markdown}

  def read(skill, path) do
    with {:ok, file} <- file(skill.id, path), do: Files.read_object(file.object_id)
  end

  def file(id, path),
    do:
      SkillFile
      |> Ash.Query.filter(skill_id == ^id and relative_path == ^path)
      |> Ankole.Ash.read_one()
      |> found()

  def manifest(%{manifest_xml: xml, metadata: metadata}) do
    with true <- is_binary(metadata["name"]) and String.trim(metadata["name"]) != "",
         true <- is_binary(metadata["description"]) and String.trim(metadata["description"]) != "",
         true <- metadata["ankole-runtime"] in [nil, "any", "main", "background_job"],
         {:ok, _} <- Ankole.Kernel.knowledge_validate(xml),
         {:ok, markdown} <- Ankole.Kernel.knowledge_export(xml, metadata) do
      {:ok,
       %{
         manifest_xml: xml,
         manifest_markdown: markdown,
         metadata: metadata,
         name: metadata["name"],
         description: metadata["description"]
       }}
    else
      false -> {:error, :invalid_skill_manifest}
      error -> error
    end
  end

  def parse(markdown) do
    with {:ok, parsed} <- Ankole.Kernel.knowledge_parse(markdown),
         do: manifest(%{manifest_xml: parsed.xml, metadata: parsed.metadata})
  end

  def file_path(path) do
    with {:ok, path} <- SourceReader.normalize_virtual_path(path),
         true <- path != "SKILL.md",
         do: {:ok, path},
         else: (
           false -> {:error, :required_manifest}
           error -> error
         )
  end

  def synchronize do
    with {:ok, sources} <- Ankole.AIAgent.Library.shipped_skill_sources(), do: sync(sources)
  end

  # Concurrent first Turns of a tenant would each install every shipped
  # package, so installation runs one at a time per tenant and the later Turns
  # find the packages current. A sync that finds every package current takes
  # no lock.
  def sync(sources) do
    with {:ok, current} <- stored_by_slug() do
      if Enum.any?(sources, &install?(&1, current[&1.name])) do
        :global.trans({{__MODULE__, :sync, Repo.tenant_id!()}, self()}, fn -> install(sources) end)
      else
        {:ok, Enum.map(sources, &current[&1.name])}
      end
    end
  end

  defp install(sources) do
    with {:ok, current} <- stored_by_slug() do
      sources
      |> Enum.map(fn source ->
        skill = current[source.name]
        if install?(source, skill), do: prepare_source(source), else: {:ok, skill}
      end)
      |> Ankole.Attrs.collect_results()
    end
  end

  defp stored_by_slug do
    with {:ok, skills} <- Ankole.Ash.read(Skill), do: {:ok, Map.new(skills, &{&1.slug, &1})}
  end

  # A shipped addition must leave an existing custom package manageable.
  # Renaming the custom package lets the next sync install the shipped one.
  defp install?(_source, %{source_kind: :custom}), do: false

  defp install?(source, %{} = skill),
    do:
      source.source_hash not in [
        skill.upstream_state["upstream_base_hash"],
        skill.upstream_state["pending_upstream_hash"]
      ]

  defp install?(_source, nil), do: true

  defp prepare_source(source) do
    manifest = Enum.find(source.files, &(&1.path == "SKILL.md"))

    with {:ok, content} <- parse(manifest.content),
         {:ok, files} <-
           source.files
           |> Enum.reject(&(&1.path == "SKILL.md"))
           |> store_files(),
         :ok <- validate_paths(Enum.map(files, & &1.path)) do
      Repo.transact_top_level(fn -> reconcile(source, content, files) end,
        after_commit: &Management.committed/1
      )
    end
  end

  # A shipped package can carry more than a hundred files, and each store waits
  # on the object store, so the files of one package upload in parallel.
  defp store_files(files) do
    tenant_id = Repo.tenant_id!()

    files
    |> Task.async_stream(
      fn file -> Repo.with_tenant(tenant_id, fn -> store_file(file) end) end,
      max_concurrency: 8,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Ankole.Attrs.collect_results()
  end

  defp store_file(file) do
    with {:ok, path} <- file_path(file.path),
         {:ok, stored} <- Files.store(file.content),
         do: {:ok, Map.merge(file, %{path: path, stored: stored})}
  end

  defp reconcile(source, content, prepared) do
    Ankole.AdvisoryLock.lock!(Repo, "skill:#{Repo.tenant_id!()}:#{source.name}")
    existing = get(source.name)

    with {:ok, skill} <- source_row(existing, source, content),
         true <- package_current?(skill, prepared) do
      with {:ok, managed} <-
             prepared
             |> Enum.map(fn file ->
               with {:ok, object} <- Files.complete_object_in_tx(file.stored),
                    {:ok, _} <- put_file_in_tx(skill.id, file.path, object.id, file),
                    do:
                      {:ok,
                       {file.path,
                        %{
                          "sha256" => Base.encode16(object.sha256, case: :lower),
                          "mode" => file.mode
                        }}}
             end)
             |> Ankole.Attrs.collect_results(),
           :ok <- remove_obsolete(skill, Map.new(managed)) do
        state = %{
          "upstream_base_hash" => source.source_hash,
          "content_hash" => SourceReader.hash(content.manifest_markdown),
          "files" => Map.new(managed)
        }

        Ankole.Ash.update(
          skill,
          :save,
          Map.merge(content, %{base_revision: skill.revision, upstream_state: state})
        )
      end
    else
      false ->
        {:ok, skill} = get(source.name)

        Ankole.Ash.update(skill, :save, %{
          base_revision: skill.revision,
          upstream_state:
            Map.put(skill.upstream_state, "pending_upstream_hash", source.source_hash)
        })

      error ->
        error
    end
  end

  defp source_row({:ok, skill}, _source, _content), do: lock(skill.id)

  defp source_row({:error, :not_found}, source, content) do
    plugin = source.metadata["agent_plugin_id"]

    Ankole.Ash.create(
      Skill,
      :create,
      Map.merge(content, %{
        slug: source.name,
        source_kind: if(plugin, do: :agent_plugin, else: :builtin),
        agent_plugin_id: plugin,
        enabled_for_all: source.default_enabled
      })
    )
  end

  defp package_current?(%{upstream_state: state} = skill, prepared) do
    managed = state["files"] || %{}
    current = Map.new(files(skill.id), &{&1.relative_path, &1})
    next_paths = (Map.keys(current) -- Map.keys(managed)) ++ Enum.map(prepared, & &1.path)

    (is_nil(state["content_hash"]) or
       state["content_hash"] == SourceReader.hash(skill.manifest_markdown)) and
      Enum.all?(managed, fn {path, recorded} ->
        with %{} = file <- current[path],
             {:ok, object} <- Files.fetch_object(file.object_id) do
          recorded["sha256"] == Base.encode16(object.sha256, case: :lower) and
            Bitwise.band(recorded["mode"], 0o555) == Bitwise.band(file.mode, 0o555)
        else
          _ -> false
        end
      end) and
      Enum.all?(prepared, &(Map.has_key?(managed, &1.path) or not Map.has_key?(current, &1.path))) and
      validate_paths(next_paths) == :ok
  end

  defp remove_obsolete(skill, managed) do
    paths = Map.keys(skill.upstream_state["files"] || %{}) -- Map.keys(managed)

    with {:ok, _} <-
           SkillFile
           |> Ash.Query.filter(skill_id == ^skill.id and relative_path in ^paths)
           |> Ankole.Ash.destroy_where(:remove),
         do: :ok
  end

  defp put_file_in_tx(id, path, object, attrs),
    do:
      Ankole.Ash.create(SkillFile, :put, %{
        skill_id: id,
        relative_path: path,
        object_id: object,
        mode: Map.get(attrs, :mode, 0o444),
        content_type: Map.get(attrs, :content_type, MIME.from_path(path))
      })

  defp lock(id),
    do:
      Skill
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one(lock_identity: {"skills", [id]})
      |> found()

  defp rename_allowed(%{source_kind: :custom}, _), do: :ok
  defp rename_allowed(%{slug: slug}, slug), do: :ok
  defp rename_allowed(_, _), do: {:error, :official_skill}
  defp found({:ok, nil}), do: {:error, :not_found}
  defp found(result), do: result
end
