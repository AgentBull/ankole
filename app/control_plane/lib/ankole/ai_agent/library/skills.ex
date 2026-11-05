defmodule Ankole.AIAgent.Library.Skills do
  @moduledoc "Owns Skill manifests, package files, positive bindings and upstream reconciliation."
  require Ash.Query
  alias Ankole.AIAgent.Library.{Management, RuntimeCapabilityChanges, SourceReader}
  alias Ankole.AIAgent.Library.Schemas.{Skill, SkillFile, AgentSkill}
  alias Ankole.{Files, Repo}

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
    ids = Enum.map(skills, & &1.id)
    agents = Ankole.Principals.list_agents(status: :active)

    colleagues =
      agents |> Enum.filter(&(&1.agent.type == :ai_colleague)) |> MapSet.new(& &1.principal.uid)

    assistant =
      Enum.find(
        agents,
        &(&1.agent.type == :personal_assistant and
            &1.agent.owner_principal_uid == actor.principal.uid)
      )

    bindings =
      AgentSkill
      |> Ash.Query.filter(skill_id in ^ids)
      |> Ankole.Ash.read!()
      |> Enum.group_by(& &1.skill_id, & &1.agent_uid)

    Map.new(skills, fn skill ->
      uids = Map.get(bindings, skill.id, [])

      {skill.id,
       %{
         colleague_count: Enum.count(uids, &MapSet.member?(colleagues, &1)),
         assistant_enabled: not is_nil(assistant) and assistant.principal.uid in uids
       }}
    end)
  end

  def enabled?(skill, bindings), do: skill.enabled_for_all or MapSet.member?(bindings, skill.id)

  def list(actor) do
    with :ok <- Management.member(actor), {:ok, _} <- synchronize(), do: {:ok, list()}
  end

  def detail(actor, slug) do
    with :ok <- Management.member(actor),
         {:ok, _} <- synchronize(),
         {:ok, skill} <- get(slug),
         do:
           {:ok,
            %{
              skill: skill,
              files: files(skill.id),
              agent_uids:
                Enum.filter(bound_agents(skill.id), &(Management.agent(actor, &1, "read") == :ok))
            }}
  end

  def create(actor, attrs) do
    with :ok <- Management.authorize(actor, "tenant_console:custom_skills"),
         {:ok, content} <- manifest(attrs) do
      Repo.transact_top_level(
        fn ->
          Ankole.Ash.create(
            Skill,
            :create,
            Map.merge(content, %{
              slug: attrs.slug,
              source_kind: :custom,
              enabled_for_all: false,
              created_by: actor.principal.uid
            })
          )
        end,
        after_commit: &Management.committed/1
      )
    end
  end

  def import(actor, slug, archive) do
    with :ok <- Management.authorize(actor, "tenant_console:custom_skills"),
         {:ok, entries} <- archive_files(archive),
         {manifest_path, bytes, _mode} <-
           entries
           |> Enum.filter(fn {path, _, _} -> Path.basename(path) == "SKILL.md" end)
           |> Enum.min_by(fn {path, _, _} -> length(Path.split(path)) end, fn ->
             {nil, nil, nil}
           end),
         true <- is_binary(manifest_path),
         {:ok, manifest} <- parse(bytes),
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
          with {:ok, skill} <-
                 Ankole.Ash.create(
                   Skill,
                   :create,
                   Map.merge(
                     manifest,
                     %{
                       slug: slug,
                       source_kind: :custom,
                       enabled_for_all: false,
                       created_by: actor.principal.uid
                     }
                   )
                 ),
               {:ok, _} <-
                 Enum.map(prepared, &import_file_in_tx(skill.id, &1))
                 |> Ankole.Attrs.collect_results(),
               do: {:ok, skill}
        end,
        after_commit: &Management.committed/1
      )
    else
      false -> {:error, :invalid_skill_package}
      error -> error
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
    with {:ok, skill} <- get(slug),
         :ok <- Management.skill(actor, skill, "update"),
         :ok <- rename_allowed(skill, Map.get(attrs, :slug, slug)),
         {:ok, content} <- manifest(attrs) do
      Repo.transact_top_level(
        fn ->
          with {:ok, saved} <-
                 Ankole.Ash.update(
                   skill,
                   :save,
                   Map.merge(content, %{
                     slug: Map.get(attrs, :slug, slug),
                     base_revision: attrs.base_revision
                   })
                 ),
               :ok <- Ankole.AIAgent.Library.SkillLessons.rename_skill_in_tx(slug, saved.slug),
               do: {:ok, saved}
        end,
        after_commit: fn result ->
          if Map.get(attrs, :slug, slug) != slug,
            do: RuntimeCapabilityChanges.notify_global({:skill, slug}),
            else: Management.committed(result)

          result
        end
      )
    end
  end

  def delete(actor, slug, revision) do
    with {:ok, %{source_kind: :custom} = skill} <- get(slug),
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
      {:ok, _} -> {:error, :official_skill}
      error -> error
    end
  end

  def set_all(actor, slug, enabled, revision) do
    with :ok <- Management.authorize(actor, "tenant_console:skill_bindings"),
         {:ok, skill} <- get(slug) do
      Repo.transact_top_level(
        fn ->
          Ankole.Ash.update(skill, :save, %{enabled_for_all: enabled, base_revision: revision})
        end,
        after_commit: fn result ->
          RuntimeCapabilityChanges.notify_global({:skill, slug})
          result
        end
      )
    end
  end

  def set_binding(actor, slug, uid, enabled) do
    with :ok <- Management.binding(actor, uid), {:ok, skill} <- get(slug) do
      Repo.transact_top_level(
        fn ->
          with {:ok, skill} <- lock(skill.id),
               false <- skill.enabled_for_all,
               {:ok, _} <- bind_in_tx(skill.id, uid, enabled),
               do: {:ok, skill},
               else: (
                 true -> {:error, :skill_enabled_for_all}
                 error -> error
               )
        end,
        after_commit: fn result ->
          RuntimeCapabilityChanges.notify_agent(uid, {:skill, slug})
          result
        end
      )
    end
  end

  def bind_in_tx(id, uid, true),
    do: Ankole.Ash.create(AgentSkill, :enable, %{skill_id: id, agent_uid: uid})

  def bind_in_tx(id, uid, false),
    do:
      AgentSkill
      |> Ash.Query.filter(skill_id == ^id and agent_uid == ^uid)
      |> Ankole.Ash.destroy_where(:disable)

  def put_file(actor, slug, path, content, attrs) do
    with {:ok, skill} <- get(slug),
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
    end
  end

  def change_file(actor, slug, path, attrs) do
    with {:ok, skill} <- get(slug),
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
