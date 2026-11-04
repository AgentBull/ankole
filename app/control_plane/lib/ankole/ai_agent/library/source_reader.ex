defmodule Ankole.AIAgent.Library.SourceReader do
  @moduledoc """
  Reads shipped Skill bundles and default Agent contracts from the installation library.
  """

  alias Ankole.Kernel, as: NativeKernel

  @default_library_root Path.expand("../../../../../library", __DIR__)
  @cache_key {__MODULE__, :builtin_skill_sources}
  @skill_file "SKILL.md"
  @soul_file "SOUL.md"
  @mission_file "MISSION.md"
  @design_file "DESIGN.md"
  @confidentiality_policy_file "ConfidentialityPolicy.md"
  # Used only if the bundled templates are unreadable, so a fresh agent still
  # gets usable runtime documents rather than failing to seed.
  @fallback_soul "You are an Ankole AI colleague. Reply in plain text."
  @fallback_mission ""
  @fallback_design ""
  @fallback_confidentiality_policy ""
  @ankole_runtimes ~w(any main background_job)

  @doc """
  Reads every allowlisted builtin skill bundle from disk.
  """
  @spec read_builtin_skill_sources() :: {:ok, [map()]} | {:error, term()}
  def read_builtin_skill_sources do
    roots = builtin_skill_roots()
    ttl_ms = source_cache_ttl_ms()

    if ttl_ms > 0 do
      read_builtin_skill_sources_cached(roots, ttl_ms)
    else
      read_builtin_skill_sources_uncached(roots)
    end
  end

  @doc "Lists Skill directories without treating unreadable entries as absent."
  @spec list_skill_directories(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_skill_directories(root) do
    with {:ok, entries} <- File.ls(root), do: skill_directories(root, entries)
  end

  @doc """
  Strips YAML frontmatter from a skill body.
  """
  @spec skill_body(String.t()) :: String.t()
  def skill_body(raw_skill) do
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

  @doc """
  Normalizes a skill catalog name.
  """
  @spec normalize_skill_name(term()) :: {:ok, String.t()} | {:error, :invalid_skill_name}
  def normalize_skill_name(name) when is_binary(name) do
    case Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,95}\z/, name) do
      true -> {:ok, name}
      false -> {:error, :invalid_skill_name}
    end
  end

  def normalize_skill_name(_name), do: {:error, :invalid_skill_name}

  # Normalizes the optional Ankole Skill execution surface.
  @spec normalize_ankole_runtime(term()) ::
          {:ok, String.t() | nil} | {:error, {:invalid_ankole_runtime, term()}}
  defp normalize_ankole_runtime(nil), do: {:ok, nil}

  defp normalize_ankole_runtime(value) when is_binary(value) do
    runtime = String.trim(value)

    if runtime in @ankole_runtimes,
      do: {:ok, runtime},
      else: {:error, {:invalid_ankole_runtime, value}}
  end

  defp normalize_ankole_runtime(value), do: {:error, {:invalid_ankole_runtime, value}}

  @doc """
  Normalizes a library-container virtual path.
  """
  @spec normalize_virtual_path(term()) :: {:ok, String.t()} | {:error, :invalid_library_path}
  def normalize_virtual_path(value) when is_binary(value) do
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

  def normalize_virtual_path(_value), do: {:error, :invalid_library_path}

  @doc """
  Normalizes a library path or raises for trusted internal callers.
  """
  @spec normalize_virtual_path!(term()) :: String.t()
  def normalize_virtual_path!(value) do
    case normalize_virtual_path(value) do
      {:ok, normalized} ->
        normalized

      {:error, reason} ->
        raise ArgumentError, "invalid library path #{inspect(value)}: #{inspect(reason)}"
    end
  end

  def load_personal_assistant_template(path) do
    File.read!(Path.join([@default_library_root, "templates", "personal-assistant", path]))
  end

  @doc """
  Loads the default SOUL template, falling back to a minimal builtin value.
  """
  @spec load_default_soul_template() :: String.t()
  def load_default_soul_template, do: load_default_template(@soul_file, @fallback_soul)

  @doc """
  Loads the default MISSION template, falling back to an empty document.
  """
  @spec load_default_mission_template() :: String.t()
  def load_default_mission_template, do: load_default_template(@mission_file, @fallback_mission)

  @doc """
  Loads the default DESIGN template, falling back to an empty document.
  """
  @spec load_default_design_template() :: String.t()
  def load_default_design_template, do: load_default_template(@design_file, @fallback_design)

  @doc """
  Loads the default confidentiality policy template, falling back to an empty document.
  """
  @spec load_default_confidentiality_policy_template() :: String.t()
  def load_default_confidentiality_policy_template do
    load_default_template(@confidentiality_policy_file, @fallback_confidentiality_policy)
  end

  defp load_default_template(filename, fallback) do
    root = templates_root()
    ttl_ms = source_cache_ttl_ms()

    if ttl_ms > 0 do
      load_default_template_cached(root, filename, fallback, ttl_ms)
    else
      read_default_template(root, filename, fallback)
    end
  end

  defp load_default_template_cached(root, filename, fallback, ttl_ms) do
    key = {__MODULE__, :default_template, filename}

    case Ankole.AIAgent.Library.SourceCache.fetch(key, root, ttl_ms, fn ->
           File.read(Path.join(root, filename))
         end) do
      {:ok, content} -> content
      {:error, _reason} -> fallback
    end
  end

  defp read_default_template(root, filename, fallback) do
    case File.read(Path.join(root, filename)) do
      {:ok, content} -> content
      {:error, _reason} -> fallback
    end
  end

  @doc false
  @spec read_skill_source(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def read_skill_source(parent_root, root_label, relative_path)
      when is_binary(parent_root) and is_binary(root_label) and is_binary(relative_path) do
    do_read_skill_source(Path.expand(parent_root), root_label, relative_path)
  end

  @doc """
  Hashes a text value with XXH3 128-bit.
  """
  @spec hash(String.t()) :: String.t()
  def hash(value) when is_binary(value) do
    NativeKernel.xxh3_128_hex(value)
  end

  defp read_builtin_skill_sources_cached(roots, ttl_ms) do
    Ankole.AIAgent.Library.SourceCache.fetch(@cache_key, roots, ttl_ms, fn ->
      read_builtin_skill_sources_uncached(roots)
    end)
  end

  defp read_builtin_skill_sources_uncached(roots) do
    roots
    |> Enum.reduce_while({:ok, %{}}, fn source_root, {:ok, by_name} ->
      case read_skill_sources(source_root) do
        {:ok, sources} ->
          merged =
            Enum.reduce(sources, by_name, fn source, acc ->
              Map.put(acc, source.name, source)
            end)

          {:cont, {:ok, merged}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, by_name} -> {:ok, by_name |> Map.values() |> Enum.sort_by(& &1.name)}
      {:error, _reason} = error -> error
    end
  end

  defp read_skill_sources(%{
         root: root,
         scan_root: scan_root,
         relative_prefix: relative_prefix,
         missing: missing,
         label: label
       }) do
    root = Path.expand(root)
    scan_root = Path.expand(scan_root)

    with {:ok, entries} <- list_skill_root(scan_root, missing) do
      entries
      |> Enum.map(fn entry ->
        relative_path =
          case relative_prefix do
            "" -> entry
            prefix -> Path.join(prefix, entry)
          end

        do_read_skill_source(root, label, relative_path)
      end)
      |> Ankole.Attrs.collect_results()
      |> case do
        {:ok, sources} -> {:ok, Enum.sort_by(sources, & &1.name)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp list_skill_root(root, missing) do
    case list_skill_directories(root) do
      {:error, :enoent} when missing == :empty ->
        case File.lstat(root) do
          {:error, :enoent} -> {:ok, []}
          _result -> {:error, :enoent}
        end

      result ->
        result
    end
  end

  defp skill_directories(root, entries) do
    entries
    |> Enum.sort()
    |> Enum.map(&skill_directory(root, &1))
    |> Ankole.Attrs.collect_results()
    |> case do
      {:ok, directories} -> {:ok, Enum.reject(directories, &is_nil/1)}
      {:error, _reason} = error -> error
    end
  end

  defp skill_directory(root, entry) do
    case File.stat(Path.join(root, entry)) do
      {:ok, %File.Stat{type: :directory}} ->
        skill_file_directory(root, entry)

      {:ok, _stat} ->
        {:ok, nil}

      {:error, _reason} = error ->
        error
    end
  end

  defp skill_file_directory(root, entry) do
    path = Path.join([root, entry, @skill_file])

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        {:ok, entry}

      {:ok, _stat} ->
        {:ok, nil}

      {:error, :enoent} ->
        case File.lstat(path) do
          {:error, :enoent} -> {:ok, nil}
          _result -> {:error, :enoent}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp do_read_skill_source(parent_root, root_label, relative_path) do
    root = Path.join(parent_root, relative_path)
    skill_path = Path.join(root, @skill_file)

    with {:ok, normalized_relative_path} <- normalize_virtual_path(relative_path),
         true <- File.dir?(root) || {:error, {:missing_skill_dir, relative_path}},
         {:ok, raw_skill} <- File.read(skill_path) do
      with {:ok, source} <- skill_source(raw_skill, root_label, normalized_relative_path),
           {:ok, files} <- read_bundle_files(root, "") do
        {:ok,
         %{
           source
           | files: files,
             source_hash:
               stable_hash(
                 Enum.flat_map(files, &[&1.path, &1.content_hash, Integer.to_string(&1.mode)])
               )
         }}
      end
    else
      false -> {:error, {:missing_skill_dir, relative_path}}
      {:error, _reason} = error -> error
    end
  end

  defp read_bundle_files(root, relative) do
    path = Path.join(root, relative)

    with {:ok, entries} <- File.ls(path) do
      entries
      |> Enum.reject(&(&1 in ~w(.git node_modules target __pycache__ .DS_Store)))
      |> Enum.sort()
      |> Enum.map(fn name ->
        file = Path.join(relative, name)

        case File.stat(Path.join(root, file)) do
          {:ok, %{type: :directory}} ->
            read_bundle_files(root, file)

          {:ok, %{type: :regular, mode: mode}} ->
            with {:ok, content} <- File.read(Path.join(root, file)),
                 do:
                   {:ok,
                    [
                      %{
                        path: file,
                        content: content,
                        content_hash: hash(content),
                        mode: Bitwise.band(mode, 0o777)
                      }
                    ]}

          {:ok, _} ->
            {:ok, []}

          error ->
            error
        end
      end)
      |> Ankole.Attrs.collect_results()
      |> case do
        {:ok, files} -> {:ok, List.flatten(files)}
        error -> error
      end
    end
  end

  defp skill_source(raw_skill, root_label, normalized_relative_path) do
    with true <- String.valid?(raw_skill) || {:error, :invalid_skill_content},
         {:ok, metadata} <-
           parse_skill_metadata(raw_skill, Path.basename(normalized_relative_path)) do
      skill_hash = hash(raw_skill)
      files = [%{path: @skill_file, content: raw_skill, content_hash: skill_hash}]

      source_hash =
        stable_hash([root_label, normalized_relative_path, @skill_file, skill_hash])

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
             "relative_path" => normalized_relative_path,
             "skill_root" => root_label,
             "tags" => metadata.tags
           }
           |> Ankole.Attrs.maybe_put("category", metadata.category)
           |> Ankole.Attrs.maybe_put("ankole-runtime", metadata.ankole_runtime),
         source_hash: source_hash,
         relative_path: normalized_relative_path,
         files: files
       }}
    end
  end

  defp parse_skill_metadata(raw_skill, directory_name) do
    with {:ok, frontmatter} <- skill_frontmatter(raw_skill),
         {:ok, name} <- normalize_skill_name(Map.get(frontmatter, "name", directory_name)),
         true <-
           name == directory_name ||
             {:error, {:skill_name_directory_mismatch, name, directory_name}},
         {:ok, description} <- skill_description(frontmatter),
         {:ok, default_enabled} <- yaml_boolean(frontmatter, "default_enabled", true),
         {:ok, ankole_runtime} <-
           normalize_ankole_runtime(Map.get(frontmatter, "ankole-runtime")) do
      {:ok,
       %{
         name: name,
         description: description,
         default_enabled: default_enabled,
         tags: frontmatter |> Map.get("tags", []) |> List.wrap() |> Enum.filter(&is_binary/1),
         category: Ankole.Attrs.optional_text(Map.get(frontmatter, "category")),
         ankole_runtime: ankole_runtime
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp skill_frontmatter(raw_skill) do
    case Regex.run(~r/\A---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)\z/, raw_skill) do
      [_, frontmatter, _body] ->
        case YamlElixir.read_from_string(frontmatter) do
          {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
          _invalid -> {:error, :invalid_skill_frontmatter}
        end

      _no_frontmatter ->
        {:ok, %{}}
    end
  end

  defp skill_description(frontmatter) do
    case Ankole.Attrs.optional_text(Map.get(frontmatter, "description")) do
      value when is_binary(value) and value != "" -> {:ok, String.slice(value, 0, 1024)}
      _value -> {:error, :skill_description_missing}
    end
  end

  defp yaml_boolean(frontmatter, key, default) do
    case Map.get(frontmatter, key) do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      value when value in ["true", "TRUE"] -> {:ok, true}
      value when value in ["false", "FALSE"] -> {:ok, false}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  defp stable_hash(parts) when is_list(parts), do: hash(Enum.join(parts, <<0>>))

  defp builtin_skill_roots do
    roots = [
      %{
        label: "library",
        root: library_root(),
        scan_root: skills_root(),
        relative_prefix: "skills",
        missing: :error
      }
    ]

    case internal_skills_root() do
      root when is_binary(root) and root != "" ->
        roots ++
          [
            %{
              label: "internal",
              root: root,
              scan_root: root,
              relative_prefix: "",
              missing: :empty
            }
          ]

      _root ->
        roots
    end
  end

  defp library_config do
    Application.get_env(:ankole, Ankole.AIAgent.Library, [])
  end

  @doc """
  The configured product library root. Every reader of shipped library
  content — Skills and templates — resolves paths from this one owner, so the `ANKOLE_LIBRARY_ROOT`
  release override applies to all of them.
  """
  @spec library_root() :: String.t()
  def library_root do
    library_config()
    |> Keyword.get(:library_root, @default_library_root)
    |> Path.expand()
  end

  defp skills_root, do: Path.join(library_root(), "skills")
  defp templates_root, do: Path.join(library_root(), "templates")

  defp internal_skills_root do
    case Keyword.get(library_config(), :internal_skills_root) do
      root when is_binary(root) and root != "" -> Path.expand(root)
      _root -> nil
    end
  end

  @doc false
  @spec source_cache_ttl_ms() :: non_neg_integer()
  def source_cache_ttl_ms do
    case Keyword.get(library_config(), :source_cache_ttl_ms, 30_000) do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _ttl -> 0
    end
  end
end
