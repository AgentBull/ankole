defmodule Ankole.AIAgent.Library do
  @moduledoc """
  DB-backed library-containers surface for AI agents.

  Builtin skills are first-party files under `app/library/skills`. They sync
  into a canonical catalog, while `SOUL.md`, `MISSION.md`, and
  `skills/<name>/AGENT_APPEND.md` remain agent-owned writable entries.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry
  alias Ankole.AIAgent.Library.Schemas.AgentSkillAssignment
  alias Ankole.AIAgent.Library.Schemas.LibraryBuiltinSyncState
  alias Ankole.AIAgent.Library.Schemas.LibrarySkill
  alias Ankole.AIAgent.Library.Schemas.LibrarySkillFile
  alias Ankole.Principals
  alias Ankole.Repo

  @library_root Path.expand("../../../../library", __DIR__)
  @skills_root Path.join(@library_root, "skills")
  @templates_root Path.join(@library_root, "templates")
  @sync_name "app/library/skills"
  @skill_file "SKILL.md"
  @agent_append_file "AGENT_APPEND.md"
  @soul_file "SOUL.md"
  @mission_file "MISSION.md"
  @builtin_skill_names ~w(jupyter-live-kernel nano-pdf powerpoint)
  @fallback_soul "You are an Ankole AI colleague. Reply in plain text."
  @fallback_mission ""

  @type sync_result :: %{
          changed: boolean(),
          content_hash: String.t(),
          skills: non_neg_integer(),
          files: non_neg_integer()
        }

  @doc """
  Syncs the first-party builtin skills into Postgres.
  """
  @spec sync_builtin_skills(keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync_builtin_skills(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    force? = Keyword.get(opts, :force, false)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, sources} <- read_builtin_skill_sources() do
      content_hash = catalog_hash(sources)
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
          Repo.transact(fn repo ->
            with :ok <- upsert_builtin_sources(repo, sources, now),
                 {:ok, _state} <-
                   upsert_sync_state(repo, content_hash, result, now) do
              {:ok, result}
            end
          end)
      end
    end
  end

  @doc """
  Seeds writable library files for a newly-created agent.
  """
  @spec seed_agent_library(String.t()) :: :ok | {:error, term()}
  def seed_agent_library(agent_uid) do
    Repo.transact(fn repo -> seed_agent_library_in_tx(repo, agent_uid) end)
  end

  @doc false
  @spec seed_agent_library_in_tx(module(), String.t()) :: :ok | {:error, term()}
  def seed_agent_library_in_tx(repo, agent_uid) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, _soul} <-
           upsert_agent_text_entry_in_tx(repo, %{
             agent_uid: agent_uid,
             path: @soul_file,
             source_kind: "soul",
             content: load_default_soul_template(),
             metadata: %{"source" => "app_template"}
           }),
         {:ok, _mission} <-
           upsert_agent_text_entry_in_tx(repo, %{
             agent_uid: agent_uid,
             path: @mission_file,
             source_kind: "mission",
             content: load_default_mission_template(),
             metadata: %{"source" => "app_template"}
           }),
         :ok <- seed_default_skill_assignments_in_tx(repo, agent_uid) do
      :ok
    end
  end

  @doc """
  Lists the skills currently enabled for an agent after assignment overrides.
  """
  @spec enabled_skills_for_agent(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def enabled_skills_for_agent(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      skills =
        LibrarySkill
        |> order_by([skill], asc: skill.skill_name)
        |> repo.all()

      assignments =
        AgentSkillAssignment
        |> where([assignment], assignment.agent_uid == ^agent_uid)
        |> repo.all()
        |> Map.new(&{&1.skill_name, &1})

      append_paths =
        AgentLibraryContainerEntry
        |> where([entry], entry.agent_uid == ^agent_uid)
        |> where([entry], entry.source_kind == "skill_append")
        |> where([entry], is_nil(entry.deleted_at))
        |> select([entry], entry.path)
        |> repo.all()
        |> MapSet.new()

      enabled =
        skills
        |> Enum.filter(fn skill ->
          case Map.get(assignments, skill.skill_name) do
            %AgentSkillAssignment{enabled: enabled?} -> enabled?
            nil -> skill.default_enabled
          end
        end)
        |> Enum.map(&skill_summary(&1, append_paths))

      {:ok, enabled}
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
         {:ok, skill_name} <- normalize_skill_name(skill_name),
         {:ok, file_path} <- normalize_virtual_path(file_path || @skill_file),
         {:ok, skill} <- enabled_skill(repo, agent_uid, skill_name) do
      do_skill_view(repo, agent_uid, skill, file_path)
    end
  end

  @doc """
  Replaces an agent-specific `AGENT_APPEND.md` for an enabled skill.
  """
  @spec skill_append(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, AgentLibraryContainerEntry.t()} | {:error, term()}
  def skill_append(agent_uid, skill_name, content, opts \\ [])

  def skill_append(agent_uid, skill_name, content, _opts)
      when is_binary(content) do
    Repo.transact(fn repo ->
      with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
           {:ok, skill_name} <- normalize_skill_name(skill_name),
           {:ok, _skill} <- enabled_skill(repo, agent_uid, skill_name) do
        upsert_agent_text_entry_in_tx(repo, %{
          agent_uid: agent_uid,
          path: agent_append_path(skill_name),
          source_kind: "skill_append",
          content: content,
          metadata: %{"skill_name" => skill_name}
        })
      end
    end)
  end

  def skill_append(_agent_uid, _skill_name, _content, _opts), do: {:error, :invalid_content}

  @doc """
  Returns the current agent soul text, falling back to the bundled template.
  """
  @spec get_soul(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_soul(agent_uid, opts \\ []),
    do: get_agent_text(agent_uid, @soul_file, load_default_soul_template(), opts)

  @doc """
  Returns the current agent mission text, falling back to the bundled template.
  """
  @spec get_mission(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_mission(agent_uid, opts \\ []),
    do: get_agent_text(agent_uid, @mission_file, load_default_mission_template(), opts)

  @doc """
  Projects all files that should appear under `/workspace/library-containers`.
  """
  @spec list_effective_library_container_files(String.t(), keyword()) ::
          {:ok, [%{path: String.t(), content: String.t()}]} | {:error, term()}
  def list_effective_library_container_files(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, summaries} <- enabled_skills_for_agent(agent_uid, repo: repo) do
      agent_files =
        AgentLibraryContainerEntry
        |> where([entry], entry.agent_uid == ^agent_uid)
        |> where([entry], is_nil(entry.deleted_at))
        |> where(
          [entry],
          entry.path in [@soul_file, @mission_file] or
            like(entry.path, "skills/%/AGENT_APPEND.md")
        )
        |> order_by([entry], asc: entry.path)
        |> repo.all()
        |> Enum.flat_map(fn
          %AgentLibraryContainerEntry{content: content, path: path} when is_binary(content) ->
            [%{path: path, content: content}]

          _entry ->
            []
        end)

      skill_files =
        summaries
        |> Enum.flat_map(fn %{"skill_name" => skill_name} ->
          LibrarySkillFile
          |> where([file], file.skill_name == ^skill_name)
          |> order_by([file], asc: file.path)
          |> repo.all()
          |> Enum.map(fn file ->
            %{path: "skills/#{skill_name}/#{file.path}", content: file.content}
          end)
        end)

      {:ok, agent_files ++ skill_files}
    end
  end

  @doc """
  Writes the effective library tree to a host directory.
  """
  @spec materialize_effective_library(String.t(), Path.t(), keyword()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def materialize_effective_library(agent_uid, mount_root, opts \\ []) do
    with {:ok, files} <- list_effective_library_container_files(agent_uid, opts) do
      paths =
        Enum.map(files, fn %{path: path, content: content} ->
          full_path = safe_join!(mount_root, path)
          File.mkdir_p!(Path.dirname(full_path))
          File.write!(full_path, content)
          full_path
        end)

      {:ok, paths}
    end
  end

  @doc """
  Returns the compact skill index used by prompt builders.
  """
  @spec skills_for_system_prompt(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def skills_for_system_prompt(agent_uid, opts \\ []) do
    with {:ok, skills} <- enabled_skills_for_agent(agent_uid, opts) do
      {:ok,
       Enum.map(skills, fn skill ->
         %{
           "name" => skill["skill_name"],
           "description" => skill["description"],
           "category" => skill["category"],
           "file_path" => "/workspace/library-containers/skills/#{skill["skill_name"]}/SKILL.md",
           "disable_model_invocation" =>
             get_in(skill, ["metadata", "disable_model_invocation"]) == true
         }
       end)}
    end
  end

  defp upsert_builtin_sources(repo, sources, now) do
    Enum.reduce_while(sources, :ok, fn source, :ok ->
      attrs = %{
        skill_name: source.name,
        description: source.description,
        default_enabled: source.default_enabled,
        metadata: source.metadata,
        content_hash: source.source_hash,
        synced_at: now
      }

      case upsert_skill(repo, attrs) do
        {:ok, _skill} ->
          repo.delete_all(from(file in LibrarySkillFile, where: file.skill_name == ^source.name))

          case insert_skill_files(repo, source) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp upsert_skill(repo, attrs) do
    %LibrarySkill{}
    |> LibrarySkill.changeset(attrs)
    |> repo.insert(
      on_conflict:
        {:replace,
         [:description, :default_enabled, :metadata, :content_hash, :synced_at, :updated_at]},
      conflict_target: :skill_name
    )
  end

  defp insert_skill_files(repo, source) do
    Enum.reduce_while(source.files, :ok, fn file, :ok ->
      attrs = %{
        skill_name: source.name,
        path: file.path,
        content: file.content,
        content_hash: file.content_hash,
        metadata: %{"media_type" => media_type_for_path(file.path)}
      }

      %LibrarySkillFile{}
      |> LibrarySkillFile.changeset(attrs)
      |> repo.insert()
      |> case do
        {:ok, _file} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
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

  defp seed_default_skill_assignments_in_tx(repo, agent_uid) do
    LibrarySkill
    |> repo.all()
    |> Enum.reduce_while(:ok, fn skill, :ok ->
      attrs = %{
        agent_uid: agent_uid,
        skill_name: skill.skill_name,
        enabled: skill.default_enabled,
        metadata: %{"source" => "agent_seed"}
      }

      %AgentSkillAssignment{}
      |> AgentSkillAssignment.changeset(attrs)
      |> repo.insert(
        on_conflict: {:replace, [:enabled, :metadata, :updated_at]},
        conflict_target: [:agent_uid, :skill_name]
      )
      |> case do
        {:ok, _assignment} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp upsert_agent_text_entry_in_tx(repo, attrs) do
    attrs =
      attrs
      |> Map.put(:path, normalize_virtual_path!(attrs.path))
      |> Map.put(:content_hash, hash(attrs.content || ""))
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
      conflict_target: {:unsafe_fragment, "(agent_uid, path) WHERE deleted_at IS NULL"}
    )
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

  defp enabled_skill(repo, agent_uid, skill_name) do
    case repo.get(LibrarySkill, skill_name) do
      %LibrarySkill{} = skill ->
        assignment =
          repo.get_by(AgentSkillAssignment, agent_uid: agent_uid, skill_name: skill_name)

        cond do
          match?(%AgentSkillAssignment{enabled: false}, assignment) ->
            {:error, :skill_not_enabled}

          skill.default_enabled or match?(%AgentSkillAssignment{enabled: true}, assignment) ->
            {:ok, skill}

          true ->
            {:error, :skill_not_enabled}
        end

      nil ->
        {:error, :skill_not_found}
    end
  end

  defp do_skill_view(repo, agent_uid, %LibrarySkill{} = skill, @agent_append_file) do
    case active_agent_entry(repo, agent_uid, agent_append_path(skill.skill_name)) do
      %AgentLibraryContainerEntry{content: content} when is_binary(content) ->
        {:ok,
         %{
           "skill_name" => skill.skill_name,
           "file_path" =>
             "/workspace/library-containers/skills/#{skill.skill_name}/#{@agent_append_file}",
           "content" => content,
           "has_agent_append" => true
         }}

      _entry ->
        {:error, :skill_file_not_found}
    end
  end

  defp do_skill_view(repo, agent_uid, %LibrarySkill{} = skill, file_path) do
    case repo.get_by(LibrarySkillFile, skill_name: skill.skill_name, path: file_path) do
      %LibrarySkillFile{} = file when file_path == @skill_file ->
        base_content = skill_body(file.content)
        append_content = agent_append_content(repo, agent_uid, skill.skill_name)

        content =
          case append_content do
            nil ->
              base_content

            append ->
              base_content <>
                "\n\n---\nAgent-specific additions for #{agent_uid}:\n\n" <> String.trim(append)
          end

        {:ok,
         %{
           "skill_name" => skill.skill_name,
           "file_path" => "/workspace/library-containers/skills/#{skill.skill_name}/#{file_path}",
           "content" => content,
           "base_content" => base_content,
           "append_content" => append_content,
           "has_agent_append" => is_binary(append_content)
         }}

      %LibrarySkillFile{} = file ->
        {:ok,
         %{
           "skill_name" => skill.skill_name,
           "file_path" => "/workspace/library-containers/skills/#{skill.skill_name}/#{file_path}",
           "content" => file.content,
           "has_agent_append" =>
             is_binary(agent_append_content(repo, agent_uid, skill.skill_name))
         }}

      nil ->
        {:error, :skill_file_not_found}
    end
  end

  defp agent_append_content(repo, agent_uid, skill_name) do
    case active_agent_entry(repo, agent_uid, agent_append_path(skill_name)) do
      %AgentLibraryContainerEntry{content: content} when is_binary(content) ->
        case String.trim(content) do
          "" -> nil
          content -> content
        end

      _entry ->
        nil
    end
  end

  defp active_agent_entry(repo, agent_uid, path) do
    AgentLibraryContainerEntry
    |> where([entry], entry.agent_uid == ^agent_uid)
    |> where([entry], entry.path == ^normalize_virtual_path!(path))
    |> where([entry], is_nil(entry.deleted_at))
    |> repo.one()
  end

  defp skill_summary(%LibrarySkill{} = skill, append_paths) do
    metadata = skill.metadata || %{}

    %{
      "skill_name" => skill.skill_name,
      "description" => skill.description,
      "default_enabled" => skill.default_enabled,
      "metadata" => metadata,
      "category" => metadata["category"],
      "tags" => metadata["tags"] || [],
      "file_path" => "/workspace/library-containers/skills/#{skill.skill_name}/#{@skill_file}",
      "has_agent_append" => MapSet.member?(append_paths, agent_append_path(skill.skill_name))
    }
  end

  defp read_builtin_skill_sources do
    sources =
      @builtin_skill_names
      |> Enum.map(&read_builtin_skill_source/1)
      |> collect_results()

    case sources do
      {:ok, sources} -> {:ok, Enum.sort_by(sources, & &1.name)}
      {:error, _reason} = error -> error
    end
  end

  defp read_builtin_skill_source(skill_name) do
    root = Path.join(@skills_root, skill_name)
    skill_path = Path.join(root, @skill_file)

    with true <- File.dir?(root) || {:error, {:missing_skill_dir, skill_name}},
         {:ok, raw_skill} <- File.read(skill_path),
         {:ok, files} <- read_text_files_recursive(root),
         {:ok, metadata} <- parse_skill_metadata(raw_skill, skill_name) do
      source_hash =
        files
        |> Enum.flat_map(fn file -> [file.path, file.content_hash] end)
        |> stable_hash()

      {:ok,
       %{
         name: metadata.name,
         description: metadata.description,
         default_enabled: metadata.default_enabled,
         metadata:
           %{
             "name" => metadata.name,
             "description" => metadata.description,
             "default_enabled" => metadata.default_enabled,
             "tags" => metadata.tags,
             "disable_model_invocation" => metadata.disable_model_invocation
           }
           |> maybe_put("category", metadata.category),
         source_hash: source_hash,
         files: files
       }}
    else
      false -> {:error, {:missing_skill_dir, skill_name}}
      {:error, _reason} = error -> error
    end
  end

  defp read_text_files_recursive(root, relative \\ "") do
    dir = Path.join(root, relative)

    with {:ok, entries} <- File.ls(dir) do
      entries
      |> Enum.sort()
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        child_relative = if relative == "", do: entry, else: relative <> "/" <> entry
        child = Path.join(root, child_relative)

        cond do
          File.dir?(child) ->
            case read_text_files_recursive(root, child_relative) do
              {:ok, files} -> {:cont, {:ok, acc ++ files}}
              {:error, _reason} = error -> {:halt, error}
            end

          File.regular?(child) ->
            with {:ok, content} <- File.read(child),
                 {:ok, path} <- normalize_virtual_path(child_relative) do
              {:cont,
               {:ok, acc ++ [%{path: path, content: content, content_hash: hash(content)}]}}
            else
              {:error, _reason} = error -> {:halt, error}
            end

          true ->
            {:cont, {:ok, acc}}
        end
      end)
    end
  end

  defp parse_skill_metadata(raw_skill, directory_name) do
    frontmatter = skill_frontmatter(raw_skill)

    name =
      frontmatter
      |> yaml_scalar("name")
      |> Kernel.||(directory_name)

    with {:ok, name} <- normalize_skill_name(name),
         true <-
           name == directory_name ||
             {:error, {:skill_name_directory_mismatch, name, directory_name}},
         {:ok, description} <- skill_description(frontmatter),
         {:ok, default_enabled} <- yaml_boolean(frontmatter, "default_enabled", true) do
      {:ok,
       %{
         name: name,
         description: description,
         default_enabled: default_enabled,
         tags: yaml_tags(frontmatter),
         category: yaml_scalar(frontmatter, "category"),
         disable_model_invocation:
           yaml_boolean(frontmatter, "disable-model-invocation", false) |> elem(1)
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp skill_frontmatter(raw_skill) do
    case Regex.run(~r/\A---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)\z/, raw_skill) do
      [_, frontmatter, _body] -> frontmatter
      _no_frontmatter -> ""
    end
  end

  defp skill_body(raw_skill) do
    case Regex.run(~r/\A---\r?\n[\s\S]*?\r?\n---\r?\n?([\s\S]*)\z/, raw_skill) do
      [_, body] ->
        body
        |> String.trim()
        |> case do
          "" -> String.trim(raw_skill)
          body -> body
        end

      _no_frontmatter ->
        String.trim(raw_skill)
    end
  end

  defp skill_description(frontmatter) do
    case yaml_scalar(frontmatter, "description") do
      value when is_binary(value) and value != "" -> {:ok, String.slice(value, 0, 1024)}
      _value -> {:error, :skill_description_missing}
    end
  end

  defp yaml_scalar(frontmatter, key) do
    pattern = Regex.compile!("^#{Regex.escape(key)}:\\s*(.*?)\\s*$", "m")

    case Regex.run(pattern, frontmatter) do
      [_, value] ->
        value
        |> String.trim()
        |> strip_quotes()
        |> case do
          "" -> nil
          value -> value
        end

      _no_match ->
        nil
    end
  end

  defp yaml_boolean(frontmatter, key, default) do
    case yaml_scalar(frontmatter, key) do
      nil -> {:ok, default}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      "TRUE" -> {:ok, true}
      "FALSE" -> {:ok, false}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  defp yaml_tags(frontmatter) do
    case yaml_scalar(frontmatter, "tags") do
      "[" <> _rest = inline ->
        inline
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.split(",", trim: true)
        |> Enum.map(&strip_quotes(String.trim(&1)))

      _value ->
        frontmatter
        |> String.split(~r/\r?\n/)
        |> collect_yaml_block_list("tags")
    end
  end

  defp collect_yaml_block_list(lines, key) do
    {_state, values} =
      Enum.reduce(lines, {:before, []}, fn line, {state, acc} ->
        cond do
          state == :before and String.match?(line, ~r/^#{Regex.escape(key)}:\s*$/) ->
            {:inside, acc}

          state == :inside and String.match?(line, ~r/^\s+-\s+(.+)\s*$/) ->
            [_, value] = Regex.run(~r/^\s+-\s+(.+)\s*$/, line)
            {:inside, acc ++ [strip_quotes(String.trim(value))]}

          state == :inside and String.match?(line, ~r/^\S/) ->
            {:after, acc}

          true ->
            {state, acc}
        end
      end)

    values
  end

  defp strip_quotes(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        value
    end
  end

  defp normalize_skill_name(name) when is_binary(name) do
    name =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")

    case Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, name) do
      true -> {:ok, name}
      false -> {:error, :invalid_skill_name}
    end
  end

  defp normalize_skill_name(_name), do: {:error, :invalid_skill_name}

  defp normalize_virtual_path(value) when is_binary(value) do
    normalized =
      value
      |> String.replace("\\", "/")
      |> String.replace(~r/\A\/+/, "")
      |> String.replace(~r/\/+/, "/")

    parts = String.split(normalized, "/", trim: false)

    cond do
      normalized == "" -> {:error, :invalid_library_path}
      Enum.any?(parts, &(&1 in ["", ".", ".."])) -> {:error, :invalid_library_path}
      true -> {:ok, normalized}
    end
  end

  defp normalize_virtual_path(_value), do: {:error, :invalid_library_path}

  defp normalize_virtual_path!(value) do
    case normalize_virtual_path(value) do
      {:ok, normalized} ->
        normalized

      {:error, reason} ->
        raise ArgumentError, "invalid library path #{inspect(value)}: #{inspect(reason)}"
    end
  end

  defp safe_join!(root, virtual_path) do
    root = Path.expand(root)
    path = Path.expand(normalize_virtual_path!(virtual_path), root)

    if path == root or String.starts_with?(path, root <> "/") do
      path
    else
      raise ArgumentError, "library path escapes mount root"
    end
  end

  defp agent_append_path(skill_name), do: "skills/#{skill_name}/#{@agent_append_file}"

  defp load_default_soul_template do
    @templates_root
    |> Path.join(@soul_file)
    |> File.read()
    |> case do
      {:ok, content} -> content
      {:error, _reason} -> @fallback_soul
    end
  end

  defp load_default_mission_template do
    @templates_root
    |> Path.join(@mission_file)
    |> File.read()
    |> case do
      {:ok, content} -> content
      {:error, _reason} -> @fallback_mission
    end
  end

  defp media_type_for_path(path) do
    cond do
      String.ends_with?(path, ".md") -> "text/markdown"
      String.ends_with?(path, ".json") -> "application/json"
      String.ends_with?(path, [".yaml", ".yml"]) -> "application/yaml"
      true -> "text/plain"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp catalog_hash(sources) do
    sources
    |> Enum.flat_map(fn source ->
      [source.name, source.source_hash | Enum.flat_map(source.files, &[&1.path, &1.content_hash])]
    end)
    |> stable_hash()
  end

  defp stable_hash(parts) when is_list(parts), do: hash(Enum.join(parts, <<0>>))

  defp hash(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
