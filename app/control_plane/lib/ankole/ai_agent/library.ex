defmodule Ankole.AIAgent.Library do
  @moduledoc """
  Agent library state for AI agents.

  Persona docs and overlays are PG semantic state. Skills themselves are
  filesystem bundles: builtin skills ship with the app image, and agent-installed
  skills live under worker-visible storage. `agent_skills` records enablement,
  registry semantics, and file observations; it is not a file content table.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.AIAgent.Library.Schemas.LibraryBuiltinSyncState
  alias Ankole.AIAgent.Library.SourceReader
  alias Ankole.Principals
  alias Ankole.Repo

  @sync_name "app/library/skills"
  @skill_file "SKILL.md"
  @soul_file "SOUL.md"
  @mission_file "MISSION.md"

  @type sync_result :: %{
          changed: boolean(),
          content_hash: String.t(),
          skills: non_neg_integer(),
          files: non_neg_integer()
        }

  @type installed_skill_observation :: %{
          required(:skill_name) => String.t(),
          optional(:relative_path) => String.t(),
          optional(:description) => String.t(),
          optional(:default_enabled) => boolean(),
          optional(:metadata) => map(),
          optional(:content_hash) => String.t(),
          optional(:xxh3_128) => String.t(),
          optional(:file_count) => non_neg_integer()
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

    with {:ok, sources} <- SourceReader.read_builtin_skill_sources() do
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

  The caller is expected to obtain these observations through RuntimeFabric File
  Lane LIST/GET/STAT work. This function deliberately accepts data, not a
  filesystem root, so the control plane cannot silently become an NFS scanner.
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
         {:ok, installed_sources} <- installed_sources_from_observations(observations) do
      repo.transact(fn repo ->
        sync_agent_skills_in_tx(
          repo,
          agent_uid,
          %{
            builtin: builtin_sources,
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
         {:ok, _soul} <-
           upsert_agent_text_entry_in_tx(repo, %{
             agent_uid: agent_uid,
             path: @soul_file,
             source_kind: "soul",
             content: SourceReader.load_default_soul_template(),
             metadata: %{"source" => "app_template"}
           }),
         {:ok, _mission} <-
           upsert_agent_text_entry_in_tx(repo, %{
             agent_uid: agent_uid,
             path: @mission_file,
             source_kind: "mission",
             content: SourceReader.load_default_mission_template(),
             metadata: %{"source" => "app_template"}
           }),
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
         {:ok, _result} <- sync_agent_skills(agent_uid, opts) do
      overlay_skills =
        AgentSkillOverlay
        |> where([overlay], overlay.agent_uid == ^agent_uid)
        |> where([overlay], is_nil(overlay.deleted_at))
        |> select([overlay], overlay.skill_name)
        |> repo.all()
        |> MapSet.new()

      skills =
        AgentSkill
        |> where([skill], skill.agent_uid == ^agent_uid)
        |> where([skill], skill.enabled == true)
        |> order_by([skill], asc: skill.skill_name)
        |> repo.all()
        |> Enum.map(&skill_summary(&1, overlay_skills))

      {:ok, skills}
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
         {:ok, skill} <- enabled_skill(repo, agent_uid, skill_name) do
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

    repo.transact(fn repo ->
      with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
           {:ok, sources} <- agent_skill_sources(agent_uid, opts),
           {:ok, _result} <-
             sync_agent_skills_in_tx(repo, agent_uid, sources, DateTime.utc_now(:microsecond)),
           {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
           {:ok, _skill} <- enabled_skill(repo, agent_uid, skill_name) do
        replace_skill_overlay_in_tx(repo, agent_uid, skill_name, overlay_json)
      end
    end)
  end

  def replace_skill_overlay(_agent_uid, _skill_name, _overlay_json, _opts),
    do: {:error, :invalid_overlay}

  @doc """
  Backward-compatible tool entry: replaces the DB overlay text.
  """
  @spec skill_append(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, AgentSkillOverlay.t()} | {:error, term()}
  def skill_append(agent_uid, skill_name, content, opts \\ [])

  def skill_append(agent_uid, skill_name, content, opts) when is_binary(content),
    do: replace_skill_overlay(agent_uid, skill_name, %{"text" => content}, opts)

  def skill_append(_agent_uid, _skill_name, _content, _opts), do: {:error, :invalid_content}

  @doc """
  Returns the active DB overlay for an enabled skill.
  """
  @spec skill_overlay(String.t(), String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def skill_overlay(agent_uid, skill_name, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, _result} <- sync_agent_skills(agent_uid, opts),
         {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
         {:ok, _skill} <- enabled_skill(repo, agent_uid, skill_name) do
      {:ok, active_skill_overlay(repo, agent_uid, skill_name)}
    end
  end

  @doc """
  Clears the active DB overlay for an enabled skill.
  """
  @spec clear_skill_overlay(String.t(), String.t(), keyword()) ::
          {:ok, AgentSkillOverlay.t() | nil} | {:error, term()}
  def clear_skill_overlay(agent_uid, skill_name, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    repo.transact(fn repo ->
      with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
           {:ok, sources} <- agent_skill_sources(agent_uid, opts),
           {:ok, _result} <- sync_agent_skills_in_tx(repo, agent_uid, sources, now),
           {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
           {:ok, _skill} <- enabled_skill(repo, agent_uid, skill_name) do
        case active_skill_overlay(repo, agent_uid, skill_name) do
          %AgentSkillOverlay{} = overlay ->
            overlay
            |> AgentSkillOverlay.changeset(%{deleted_at: now})
            |> repo.update()

          nil ->
            {:ok, nil}
        end
      end
    end)
  end

  @doc """
  Returns the current agent soul text, falling back to the bundled template.
  """
  @spec get_soul(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_soul(agent_uid, opts \\ []),
    do: get_agent_text(agent_uid, @soul_file, SourceReader.load_default_soul_template(), opts)

  @doc """
  Returns the current agent mission text, falling back to the bundled template.
  """
  @spec get_mission(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_mission(agent_uid, opts \\ []),
    do:
      get_agent_text(agent_uid, @mission_file, SourceReader.load_default_mission_template(), opts)

  @doc """
  Returns the compact skill index used by prompt builders.
  """
  @spec skills_for_system_prompt(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def skills_for_system_prompt(agent_uid, opts \\ []) do
    with {:ok, skills} <- enabled_skills_for_agent(agent_uid, opts) do
      {:ok,
       Enum.map(skills, fn skill ->
         %{
           "skill_name" => skill["skill_name"],
           "name" => skill["skill_name"],
           "description" => skill["description"],
           "category" => skill["category"],
           "source_kind" => skill["source_kind"],
           "relative_path" => skill["relative_path"],
           "skill_uri" => skill_uri(skill["skill_name"], @skill_file),
           "disable_model_invocation" =>
             get_in(skill, ["metadata", "disable_model_invocation"]) == true
         }
       end)}
    end
  end

  defp agent_skill_sources(_agent_uid, _opts) do
    with {:ok, builtin_sources} <- SourceReader.read_builtin_skill_sources() do
      {:ok, %{builtin: builtin_sources, installed: [], installed_authoritative?: false}}
    end
  end

  defp sync_agent_skills_in_tx(repo, agent_uid, sources, now) do
    source_rows =
      Enum.map(sources.builtin, &source_attrs(&1, "builtin", now)) ++
        Enum.map(sources.installed, &source_attrs(&1, "installed", now))

    source_names = MapSet.new(source_rows, & &1.skill_name)

    existing =
      AgentSkill
      |> where([skill], skill.agent_uid == ^agent_uid)
      |> repo.all()
      |> Map.new(&{&1.skill_name, &1})

    with :ok <- upsert_agent_skill_rows(repo, agent_uid, source_rows, existing),
         {_count, _rows} <-
           stale_agent_skills_query(agent_uid, source_names, sources.installed_authoritative?)
           |> repo.delete_all() do
      {:ok,
       %{
         changed: true,
         content_hash: agent_skill_hash(source_rows),
         skills: length(source_rows),
         files: Enum.reduce(source_rows, 0, fn row, count -> count + row.file_count end)
       }}
    end
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
      relative_path: source.relative_path,
      enabled: source.default_enabled,
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

  defp upsert_agent_skill_rows(repo, agent_uid, source_rows, existing) do
    Enum.reduce_while(source_rows, :ok, fn row, :ok ->
      enabled =
        case Map.get(existing, row.skill_name) do
          %AgentSkill{enabled: enabled?} -> enabled?
          nil -> row.enabled
        end

      attrs =
        row
        |> Map.take([
          :skill_name,
          :source_kind,
          :relative_path,
          :default_enabled,
          :description,
          :metadata,
          :content_hash,
          :synced_at
        ])
        |> Map.put(:agent_uid, agent_uid)
        |> Map.put(:enabled, enabled)

      %AgentSkill{}
      |> AgentSkill.changeset(attrs)
      |> repo.insert(
        on_conflict:
          {:replace,
           [
             :source_kind,
             :relative_path,
             :enabled,
             :default_enabled,
             :description,
             :metadata,
             :content_hash,
             :synced_at,
             :updated_at
           ]},
        conflict_target: [:agent_uid, :skill_name]
      )
      |> case do
        {:ok, _skill} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
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

  defp reject_agent_append_file("AGENT_APPEND.md"), do: {:error, :skill_file_not_found}
  defp reject_agent_append_file(_file_path), do: :ok

  defp enabled_skill(repo, agent_uid, skill_name) do
    case repo.get_by(AgentSkill, agent_uid: agent_uid, skill_name: skill_name) do
      %AgentSkill{enabled: true} = skill -> {:ok, skill}
      %AgentSkill{} -> {:error, :skill_not_enabled}
      nil -> {:error, :skill_not_found}
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
    |> collect_results()
    |> case do
      {:ok, sources} -> sources |> Enum.reverse() |> reject_duplicate_observations()
      {:error, _reason} = error -> error
    end
  end

  defp installed_source_from_observation(observation) when is_map(observation) do
    with {:ok, name} <- SourceReader.normalize_skill_name(map_text(observation, :skill_name)),
         {:ok, relative_path} <-
           SourceReader.normalize_virtual_path(map_text(observation, :relative_path) || name),
         {:ok, content_hash} <- observation_hash(observation),
         {:ok, description} <- observation_description(observation),
         {:ok, default_enabled} <- observation_boolean(observation, :default_enabled, true),
         {:ok, file_count} <- observation_file_count(observation) do
      metadata =
        observation
        |> map_value(:metadata)
        |> case do
          metadata when is_map(metadata) -> metadata
          _value -> %{}
        end
        |> Map.put("name", name)
        |> Map.put("description", description)
        |> Map.put("default_enabled", default_enabled)
        |> Map.put("relative_path", relative_path)
        |> Map.put("fingerprint_algorithm", "xxh3_128")

      {:ok,
       %{
         name: name,
         description: description,
         default_enabled: default_enabled,
         metadata: metadata,
         source_hash: content_hash,
         relative_path: relative_path,
         files: List.duplicate(%{path: "SKILL.md", content_hash: content_hash}, file_count)
       }}
    end
  end

  defp installed_source_from_observation(_observation), do: {:error, :invalid_skill_observation}

  defp observation_hash(observation) do
    case map_text(observation, :xxh3_128) || map_text(observation, :content_hash) do
      hash when is_binary(hash) ->
        if Regex.match?(~r/\A[a-f0-9]{32}\z/, hash) do
          {:ok, hash}
        else
          {:error, :invalid_skill_fingerprint}
        end

      _value ->
        {:error, :missing_skill_fingerprint}
    end
  end

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

  defp observation_file_count(observation) do
    case map_value(observation, :file_count) do
      nil -> {:ok, 1}
      count when is_integer(count) and count >= 1 -> {:ok, count}
      _value -> {:error, :invalid_file_count}
    end
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
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
  end

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
      conflict_target: {:unsafe_fragment, "(agent_uid, skill_name) WHERE deleted_at IS NULL"}
    )
  end

  defp skill_overlay_text(%AgentSkillOverlay{overlay_json: %{"text" => text}})
       when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp skill_overlay_text(_overlay), do: nil

  defp overlay_json(%AgentSkillOverlay{overlay_json: overlay_json}) when is_map(overlay_json),
    do: overlay_json

  defp overlay_json(_overlay), do: %{}

  defp skill_summary(%AgentSkill{} = skill, overlay_skills) do
    metadata = skill.metadata || %{}

    %{
      "skill_name" => skill.skill_name,
      "description" => skill.description,
      "source_kind" => skill.source_kind,
      "relative_path" => skill.relative_path,
      "default_enabled" => skill.default_enabled,
      "enabled" => skill.enabled,
      "metadata" => metadata,
      "category" => metadata["category"],
      "tags" => metadata["tags"] || [],
      "skill_uri" => skill_uri(skill.skill_name, @skill_file),
      "has_agent_overlay" => MapSet.member?(overlay_skills, skill.skill_name)
    }
  end

  defp skill_uri(skill_name, file_path), do: "skill://enabled/#{skill_name}/#{file_path}"
end
