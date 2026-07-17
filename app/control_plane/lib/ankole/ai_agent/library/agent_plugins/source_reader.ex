defmodule Ankole.AIAgent.Library.AgentPlugins.SourceReader do
  @moduledoc false

  alias Ankole.AIAgent.Library.AgentPlugins.Contract
  alias Ankole.AIAgent.Library.SourceReader, as: SkillSourceReader
  alias Ankole.Kernel, as: NativeKernel

  @default_library_root Path.expand("../../../../../../library", __DIR__)
  @manifest_path ".codex-plugin/plugin.json"
  @manifest_required ~w(name version description skills)
  @semver ~r/\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z/
  @hash_header "ankole-agent-plugin-v1\0"
  @max_files 2_048
  @max_file_bytes 8 * 1_024 * 1_024
  @max_total_bytes 64 * 1_024 * 1_024
  @max_relative_path_bytes 4_096

  @type agent_plugin_source :: %{
          required(:id) => String.t(),
          required(:version) => String.t(),
          required(:description) => String.t(),
          required(:content_hash) => String.t(),
          required(:root) => String.t(),
          required(:manifest) => map(),
          required(:skills) => [map()],
          required(:files) => [map()]
        }

  @spec read_trusted_agent_plugins(keyword()) :: {:ok, [agent_plugin_source()]} | {:error, term()}
  def read_trusted_agent_plugins(opts \\ []) do
    opts
    |> library_roots()
    |> Enum.reduce_while({:ok, []}, fn root, {:ok, acc} ->
      case read_root(root) do
        {:ok, plugins} -> {:cont, {:ok, plugins ++ acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, plugins} -> reject_agent_plugin_conflicts(plugins)
      {:error, _reason} = error -> error
    end
  end

  @spec read_trusted_agent_plugin(String.t(), keyword()) ::
          {:ok, agent_plugin_source()} | {:error, term()}
  def read_trusted_agent_plugin(agent_plugin_id, opts \\ []) when is_binary(agent_plugin_id) do
    with :ok <- Contract.validate_identifier(agent_plugin_id),
         {:ok, agent_plugins} <- read_trusted_agent_plugins(opts) do
      case Enum.find(agent_plugins, &(&1.id == agent_plugin_id)) do
        nil -> {:error, :agent_plugin_not_found}
        plugin -> {:ok, plugin}
      end
    end
  end

  @spec package_hash(String.t()) :: {:ok, String.t()} | {:error, term()}
  def package_hash(package_root) when is_binary(package_root) do
    root = Path.expand(package_root)

    with :ok <- real_directory(root, {:invalid_agent_plugin_root, root}),
         {:ok, files} <- collect_package_files(root) do
      bytes =
        [@hash_header | Enum.map(files, &canonical_file_bytes/1)]
        |> IO.iodata_to_binary()

      {:ok, NativeKernel.generic_hash(bytes)}
    end
  end

  defp read_root(library_root) do
    library_root = Path.expand(library_root)
    root = Path.join(library_root, "agent-plugins")

    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
          package_root = Path.join(root, entry)

          case File.lstat(package_root) do
            {:ok, %File.Stat{type: :directory}} ->
              case File.regular?(Path.join(package_root, @manifest_path)) do
                true ->
                  case read_package(library_root, package_root, entry) do
                    {:ok, plugin} -> {:cont, {:ok, [plugin | acc]}}
                    {:error, _reason} = error -> {:halt, error}
                  end

                false ->
                  {:cont, {:ok, acc}}
              end

            {:ok, %File.Stat{type: :symlink}} ->
              {:halt, {:error, {:agent_plugin_symlink_rejected, entry}}}

            {:ok, _stat} ->
              {:cont, {:ok, acc}}

            {:error, reason} ->
              {:halt, {:error, {:agent_plugin_root_entry_unreadable, entry, reason}}}
          end
        end)
        |> case do
          {:ok, plugins} -> {:ok, Enum.reverse(plugins)}
          {:error, _reason} = error -> error
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:agent_plugin_root_unreadable, root, reason}}
    end
  end

  defp read_package(library_root, root, directory_name) do
    with {:ok, files} <- collect_package_files(root),
         {:ok, manifest} <- read_json_file(root, @manifest_path),
         :ok <- validate_manifest(manifest, directory_name, root),
         {:ok, skills} <- read_skills(library_root, root, manifest),
         {:ok, content_hash} <- package_hash_from_files(files) do
      {:ok,
       %{
         id: Map.fetch!(manifest, "name"),
         version: Map.fetch!(manifest, "version"),
         description: Map.fetch!(manifest, "description"),
         content_hash: content_hash,
         root: root,
         manifest: manifest,
         skills: skills,
         files:
           Enum.map(files, fn file ->
             %{path: file.path, byte_size: byte_size(file.content)}
           end)
       }}
    end
  end

  defp read_json_file(root, relative_path) do
    path = Path.join(root, relative_path)

    with {:ok, raw} <- File.read(path),
         {:ok, value} <- Ankole.JSON.decode(raw),
         true <- is_map(value) do
      {:ok, value}
    else
      {:error, reason} -> {:error, {:invalid_agent_plugin_json, relative_path, reason}}
      false -> {:error, {:invalid_agent_plugin_json, relative_path, :not_an_object}}
    end
  end

  defp validate_manifest(manifest, directory_name, root) do
    keys = Map.keys(manifest)
    missing = @manifest_required -- keys
    name = Map.get(manifest, "name")
    version = Map.get(manifest, "version")
    description = Map.get(manifest, "description")

    cond do
      missing != [] ->
        {:error, {:agent_plugin_manifest_missing_keys, Enum.sort(missing)}}

      Contract.validate_identifier(name) != :ok ->
        {:error, {:invalid_agent_plugin_name, name}}

      name != directory_name ->
        {:error, {:agent_plugin_name_directory_mismatch, name, directory_name}}

      not is_binary(version) or not Regex.match?(@semver, version) ->
        {:error, {:invalid_agent_plugin_version, version}}

      not is_binary(description) or String.trim(description) == "" or
          String.length(description) > 1_024 ->
        {:error, :invalid_agent_plugin_description}

      true ->
        with {:ok, skills_dir} <-
               manifest_relative_path(root, Map.get(manifest, "skills"), :directory),
             :ok <- real_directory(skills_dir, :invalid_agent_plugin_skills_path) do
          :ok
        end
    end
  end

  defp read_skills(library_root, root, manifest) do
    with {:ok, skills_root} <-
           manifest_relative_path(root, Map.fetch!(manifest, "skills"), :directory),
         {:ok, entries} <- File.ls(skills_root) do
      entries
      |> Enum.sort()
      |> Enum.filter(&File.regular?(Path.join([skills_root, &1, "SKILL.md"])))
      |> Enum.map(fn relative_path ->
        library_relative_path =
          Path.join([
            "agent-plugins",
            Map.fetch!(manifest, "name"),
            trim_manifest_path(Map.fetch!(manifest, "skills")),
            relative_path
          ])

        SkillSourceReader.read_skill_source(
          library_root,
          "library",
          library_relative_path
        )
      end)
      |> collect_results()
      |> case do
        {:ok, []} ->
          {:error, :agent_plugin_has_no_skills}

        {:ok, skills} ->
          agent_plugin_id = Map.fetch!(manifest, "name")
          version = Map.fetch!(manifest, "version")

          {:ok,
           Enum.map(skills, fn skill ->
             %{
               skill
               | default_enabled: true,
                 metadata:
                   skill.metadata
                   |> Map.put("agent_plugin_id", agent_plugin_id)
                   |> Map.put("agent_plugin_version", version)
                   |> Map.put("skill_root", "library")
             }
           end)}

        {:error, _reason} = error ->
          error
      end
    else
      {:error, reason} -> {:error, {:agent_plugin_skills_unreadable, reason}}
    end
  end

  defp collect_package_files(root) do
    walk_package(root, "", [], 0, 0)
    |> case do
      {:ok, files, _count, _total_bytes} -> {:ok, Enum.sort_by(files, & &1.path)}
      {:error, _reason} = error -> error
    end
  end

  defp walk_package(root, relative_dir, acc, count, total_bytes) do
    dir = if relative_dir == "", do: root, else: Path.join(root, relative_dir)

    with {:ok, entries} <- File.ls(dir) do
      Enum.reduce_while(
        Enum.sort(entries),
        {:ok, acc, count, total_bytes},
        fn entry, {:ok, files, file_count, byte_count} ->
          relative_path = if relative_dir == "", do: entry, else: relative_dir <> "/" <> entry
          path = Path.join(root, relative_path)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :regular, size: size}} ->
              cond do
                byte_size(relative_path) > @max_relative_path_bytes ->
                  {:halt, {:error, {:agent_plugin_path_too_long, relative_path}}}

                file_count + 1 > @max_files ->
                  {:halt, {:error, {:agent_plugin_file_limit_exceeded, @max_files}}}

                size > @max_file_bytes ->
                  {:halt,
                   {:error, {:agent_plugin_file_too_large, relative_path, @max_file_bytes}}}

                byte_count + size > @max_total_bytes ->
                  {:halt, {:error, {:agent_plugin_size_limit_exceeded, @max_total_bytes}}}

                true ->
                  case File.read(path) do
                    {:ok, content} ->
                      {:cont,
                       {:ok, [%{path: relative_path, content: content} | files], file_count + 1,
                        byte_count + size}}

                    {:error, reason} ->
                      {:halt, {:error, {:agent_plugin_file_unreadable, relative_path, reason}}}
                  end
              end

            {:ok, %File.Stat{type: :directory}} ->
              case walk_package(root, relative_path, files, file_count, byte_count) do
                {:ok, nested, nested_count, nested_bytes} ->
                  {:cont, {:ok, nested, nested_count, nested_bytes}}

                {:error, _reason} = error ->
                  {:halt, error}
              end

            {:ok, %File.Stat{type: :symlink}} ->
              {:halt, {:error, {:agent_plugin_symlink_rejected, relative_path}}}

            {:ok, %File.Stat{type: type}} ->
              {:halt, {:error, {:agent_plugin_non_regular_file_rejected, relative_path, type}}}

            {:error, reason} ->
              {:halt, {:error, {:agent_plugin_file_unreadable, relative_path, reason}}}
          end
        end
      )
    else
      {:error, reason} -> {:error, {:agent_plugin_directory_unreadable, relative_dir, reason}}
    end
  end

  defp package_hash_from_files(files) do
    bytes =
      [@hash_header | Enum.map(files, &canonical_file_bytes/1)]
      |> IO.iodata_to_binary()

    {:ok, NativeKernel.generic_hash(bytes)}
  end

  defp canonical_file_bytes(file) do
    path = file.path
    content = file.content

    [
      <<byte_size(path)::unsigned-big-integer-size(32)>>,
      path,
      <<byte_size(content)::unsigned-big-integer-size(64)>>,
      content
    ]
  end

  defp manifest_relative_path(root, "./" <> relative, expected_type) do
    relative = String.trim_trailing(relative, "/")
    path = Path.expand(relative, root)

    cond do
      relative == "" ->
        {:error, :invalid_agent_plugin_relative_path}

      path == root or not String.starts_with?(path, root <> "/") ->
        {:error, :agent_plugin_path_escapes_root}

      expected_type == :file and File.regular?(path) ->
        {:ok, path}

      expected_type == :directory and File.dir?(path) ->
        {:ok, path}

      true ->
        {:error, :invalid_agent_plugin_relative_path}
    end
  end

  defp manifest_relative_path(_root, _relative, _expected_type),
    do: {:error, :invalid_agent_plugin_relative_path}

  defp real_directory(path, reason) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:agent_plugin_symlink_rejected, path}}
      _value -> {:error, reason}
    end
  end

  defp reject_agent_plugin_conflicts(plugins) do
    conflicts =
      plugins
      |> Enum.group_by(& &1.id)
      |> Enum.flat_map(fn
        {_id, [_single]} ->
          []

        {id, duplicates} ->
          [
            %{
              id: id,
              versions: duplicates |> Enum.map(& &1.version) |> Enum.uniq() |> Enum.sort(),
              content_hashes:
                duplicates |> Enum.map(& &1.content_hash) |> Enum.uniq() |> Enum.sort(),
              roots: duplicates |> Enum.map(& &1.root) |> Enum.sort()
            }
          ]
      end)

    case conflicts do
      [] -> {:ok, Enum.sort_by(plugins, & &1.id)}
      _conflicts -> {:error, {:agent_plugin_conflicts, conflicts}}
    end
  end

  defp library_roots(opts) do
    case Keyword.get(opts, :roots) do
      roots when is_list(roots) -> Enum.map(roots, &Path.expand/1)
      nil -> configured_roots()
    end
  end

  defp configured_roots do
    config = Application.get_env(:ankole, Ankole.AIAgent.Library, [])

    case Keyword.get(config, :library_root) do
      root when is_binary(root) and root != "" -> [Path.expand(root)]
      _value -> [@default_library_root]
    end
  end

  defp trim_manifest_path("./" <> relative), do: String.trim(relative, "/")

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
