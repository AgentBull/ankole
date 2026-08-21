defmodule Ankole.AIAgent.Library.SourceReader do
  @moduledoc """
  Reads first-party on-disk library skill bundles.

  Agent-installed skills are worker filesystem facts. The control plane records
  observations received through RuntimeFabric, but this module does not scan or
  read worker-visible skill roots.
  """

  alias Ankole.Kernel, as: NativeKernel

  @default_library_root Path.expand("../../../../../library", __DIR__)
  @cache_key {__MODULE__, :builtin_skill_sources}
  @skill_file "SKILL.md"
  @soul_file "SOUL.md"
  @mission_file "MISSION.md"
  @design_file "DESIGN.md"
  # Used only if the bundled templates are unreadable, so a fresh agent still
  # gets usable runtime documents rather than failing to seed.
  @fallback_soul "You are an Ankole AI colleague. Reply in plain text."
  @fallback_mission ""
  @fallback_design ""
  @yaml_block_item_regex ~r/^\s+-\s+(.+)\s*$/
  @yaml_block_end_regex ~r/^\S/
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

  def normalize_skill_name(_name), do: {:error, :invalid_skill_name}

  @doc "Normalizes the optional Ankole Skill execution surface."
  @spec normalize_ankole_runtime(term()) ::
          {:ok, String.t() | nil} | {:error, {:invalid_ankole_runtime, term()}}
  def normalize_ankole_runtime(nil), do: {:ok, nil}

  def normalize_ankole_runtime(value) when is_binary(value) do
    runtime = String.trim(value)

    if runtime in @ankole_runtimes,
      do: {:ok, runtime},
      else: {:error, {:invalid_ankole_runtime, value}}
  end

  def normalize_ankole_runtime(value), do: {:error, {:invalid_ankole_runtime, value}}

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

  @doc """
  Loads the default SOUL template, falling back to a minimal builtin value.
  """
  @spec load_default_soul_template() :: String.t()
  def load_default_soul_template do
    templates_root()
    |> Path.join(@soul_file)
    |> File.read()
    |> case do
      {:ok, content} -> content
      {:error, _reason} -> @fallback_soul
    end
  end

  @doc """
  Loads the default MISSION template, falling back to an empty document.
  """
  @spec load_default_mission_template() :: String.t()
  def load_default_mission_template do
    templates_root()
    |> Path.join(@mission_file)
    |> File.read()
    |> case do
      {:ok, content} -> content
      {:error, _reason} -> @fallback_mission
    end
  end

  @doc """
  Loads the default DESIGN template, falling back to an empty document.
  """
  @spec load_default_design_template() :: String.t()
  def load_default_design_template do
    templates_root()
    |> Path.join(@design_file)
    |> File.read()
    |> case do
      {:ok, content} -> content
      {:error, _reason} -> @fallback_design
    end
  end

  @doc """
  Returns a simple media type for a library file path.
  """
  @spec media_type_for_path(String.t()) :: String.t()
  def media_type_for_path(path) do
    cond do
      String.ends_with?(path, ".md") -> "text/markdown"
      String.ends_with?(path, ".json") -> "application/json"
      String.ends_with?(path, [".yaml", ".yml"]) -> "application/yaml"
      true -> "text/plain"
    end
  end

  @doc """
  Reads one file from a builtin skill bundle.
  """
  @spec read_builtin_skill_file(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def read_builtin_skill_file(skill_name, file_path) do
    builtin_skill_roots()
    |> Enum.reverse()
    |> Enum.reduce_while({:error, :skill_file_not_found}, fn source_root, _last_error ->
      case read_skill_file(source_root.root, skill_name, file_path) do
        {:ok, _content} = ok -> {:halt, ok}
        {:error, _reason} = error -> {:cont, error}
      end
    end)
  end

  @doc false
  @spec read_skill_source(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def read_skill_source(parent_root, root_label, relative_path)
      when is_binary(parent_root) and is_binary(root_label) and is_binary(relative_path) do
    do_read_skill_source(Path.expand(parent_root), root_label, relative_path)
  end

  @doc false
  @spec read_skill_file_at(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def read_skill_file_at(parent_root, relative_path, file_path)
      when is_binary(parent_root) and is_binary(relative_path) and is_binary(file_path) do
    read_skill_file(Path.expand(parent_root), relative_path, file_path)
  end

  @doc """
  Hashes the builtin catalog metadata source set.
  """
  @spec catalog_hash([map()]) :: String.t()
  def catalog_hash(sources) do
    sources
    |> Enum.flat_map(fn source ->
      [source.name, source.source_hash]
    end)
    |> stable_hash()
  end

  @doc """
  Hashes a text value with XXH3 128-bit.
  """
  @spec hash(String.t()) :: String.t()
  def hash(value) when is_binary(value) do
    NativeKernel.xxh3_128_hex(value)
  end

  defp read_builtin_skill_sources_cached(roots, ttl_ms) do
    now_ms = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      %{expires_at_ms: expires_at_ms, roots: cached_roots, result: {:ok, _sources} = result}
      when cached_roots == roots and now_ms < expires_at_ms ->
        result

      _cache_miss ->
        case read_builtin_skill_sources_uncached(roots) do
          {:ok, _sources} = result ->
            :persistent_term.put(@cache_key, %{
              expires_at_ms: now_ms + ttl_ms,
              roots: roots,
              result: result
            })

            result

          {:error, _reason} = error ->
            error
        end
    end
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

  defp list_skill_root(root, :empty) do
    case File.ls(root) do
      {:ok, entries} -> {:ok, skill_directories(root, entries)}
      {:error, :enoent} -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  defp list_skill_root(root, :error) do
    case File.ls(root) do
      {:ok, entries} -> {:ok, skill_directories(root, entries)}
      {:error, _reason} = error -> error
    end
  end

  defp skill_directories(root, entries) do
    entries
    |> Enum.sort()
    |> Enum.filter(fn entry ->
      File.dir?(Path.join(root, entry)) and File.regular?(Path.join([root, entry, @skill_file]))
    end)
  end

  defp do_read_skill_source(parent_root, root_label, relative_path) do
    root = Path.join(parent_root, relative_path)
    skill_path = Path.join(root, @skill_file)

    with {:ok, normalized_relative_path} <- normalize_virtual_path(relative_path),
         true <- File.dir?(root) || {:error, {:missing_skill_dir, relative_path}},
         {:ok, raw_skill} <- File.read(skill_path),
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
             "tags" => metadata.tags,
             "disable_model_invocation" => metadata.disable_model_invocation
           }
           |> Ankole.Attrs.maybe_put("category", metadata.category)
           |> Ankole.Attrs.maybe_put("ankole-runtime", metadata.ankole_runtime),
         source_hash: source_hash,
         relative_path: normalized_relative_path,
         files: files
       }}
    else
      false -> {:error, {:missing_skill_dir, relative_path}}
      {:error, _reason} = error -> error
    end
  end

  defp read_skill_file(parent_root, relative_path, file_path) do
    with {:ok, relative_path} <- normalize_virtual_path(relative_path),
         {:ok, file_path} <- normalize_virtual_path(file_path) do
      root = Path.expand(Path.join(parent_root, relative_path))
      path = Path.expand(file_path, root)

      cond do
        path != root and String.starts_with?(path, root <> "/") ->
          File.read(path)

        true ->
          {:error, :invalid_library_path}
      end
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
         {:ok, default_enabled} <- yaml_boolean(frontmatter, "default_enabled", true),
         {:ok, disable_model_invocation} <-
           yaml_boolean(frontmatter, "disable-model-invocation", false),
         {:ok, ankole_runtime} <-
           normalize_ankole_runtime(yaml_scalar(frontmatter, "ankole-runtime")) do
      {:ok,
       %{
         name: name,
         description: description,
         default_enabled: default_enabled,
         tags: yaml_tags(frontmatter),
         category: yaml_scalar(frontmatter, "category"),
         disable_model_invocation: disable_model_invocation,
         ankole_runtime: ankole_runtime
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
    key_regex = Regex.compile!("^#{Regex.escape(key)}:\\s*$")

    {_state, values} =
      Enum.reduce(lines, {:before, []}, fn line, {state, acc} ->
        cond do
          state == :before and Regex.match?(key_regex, line) ->
            {:inside, acc}

          state == :inside ->
            collect_yaml_block_line(line, acc)

          true ->
            {state, acc}
        end
      end)

    Enum.reverse(values)
  end

  defp collect_yaml_block_line(line, acc) do
    case Regex.run(@yaml_block_item_regex, line) do
      [_, value] ->
        {:inside, [strip_quotes(String.trim(value)) | acc]}

      nil ->
        case Regex.match?(@yaml_block_end_regex, line) do
          true -> {:after, acc}
          false -> {:inside, acc}
        end
    end
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

  defp library_root do
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

  defp source_cache_ttl_ms do
    case Keyword.get(library_config(), :source_cache_ttl_ms, 30_000) do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _ttl -> 0
    end
  end
end
