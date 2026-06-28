defmodule Ankole.AIAgent.Library.SourceReader do
  @moduledoc """
  Reads first-party on-disk library skill bundles.

  Agent-installed skills are worker filesystem facts. The control plane records
  observations received through RuntimeFabric, but this module does not scan or
  read worker-visible skill roots.
  """

  alias Ankole.Kernel, as: NativeKernel

  @library_root Path.expand("../../../../../library", __DIR__)
  @skills_root Path.join(@library_root, "skills")
  @templates_root Path.join(@library_root, "templates")
  @skill_file "SKILL.md"
  @soul_file "SOUL.md"
  @mission_file "MISSION.md"
  # Used only if the bundled SOUL/MISSION templates are unreadable, so a fresh
  # agent still gets a usable (if minimal) persona rather than failing to seed.
  @fallback_soul "You are an Ankole AI colleague. Reply in plain text."
  @fallback_mission ""
  @yaml_block_item_regex ~r/^\s+-\s+(.+)\s*$/
  @yaml_block_end_regex ~r/^\S/

  @doc """
  Reads every allowlisted builtin skill bundle from disk.
  """
  @spec read_builtin_skill_sources() :: {:ok, [map()]} | {:error, term()}
  def read_builtin_skill_sources do
    read_skill_sources(@skills_root, missing: :error)
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
    @templates_root
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
    @templates_root
    |> Path.join(@mission_file)
    |> File.read()
    |> case do
      {:ok, content} -> content
      {:error, _reason} -> @fallback_mission
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
    read_skill_file(@skills_root, skill_name, file_path)
  end

  @doc """
  Hashes the full builtin catalog source set.
  """
  @spec catalog_hash([map()]) :: String.t()
  def catalog_hash(sources) do
    sources
    |> Enum.flat_map(fn source ->
      [source.name, source.source_hash | Enum.flat_map(source.files, &[&1.path, &1.content_hash])]
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

  defp read_skill_sources(root, opts) do
    root = Path.expand(root)

    with {:ok, entries} <- list_skill_root(root, Keyword.fetch!(opts, :missing)) do
      entries
      |> Enum.map(&read_skill_source(root, &1))
      |> collect_results()
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

  defp read_skill_source(parent_root, relative_path) do
    root = Path.join(parent_root, relative_path)
    skill_path = Path.join(root, @skill_file)

    with {:ok, normalized_relative_path} <- normalize_virtual_path(relative_path),
         true <- File.dir?(root) || {:error, {:missing_skill_dir, relative_path}},
         {:ok, raw_skill} <- File.read(skill_path),
         {:ok, files} <- read_text_files_recursive(root),
         {:ok, metadata} <-
           parse_skill_metadata(raw_skill, Path.basename(normalized_relative_path)) do
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
             "relative_path" => normalized_relative_path,
             "tags" => metadata.tags,
             "disable_model_invocation" => metadata.disable_model_invocation
           }
           |> maybe_put("category", metadata.category),
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

  defp read_text_files_recursive(root, relative \\ "") do
    dir = Path.join(root, relative)

    with {:ok, entries} <- File.ls(dir) do
      entries
      |> Enum.sort()
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        child_relative = Path.join(relative, entry)
        child = Path.join(root, child_relative)

        cond do
          File.dir?(child) ->
            case read_text_files_recursive(root, child_relative) do
              {:ok, files} -> {:cont, {:ok, Enum.reverse(files, acc)}}
              {:error, _reason} = error -> {:halt, error}
            end

          File.regular?(child) ->
            with {:ok, content} <- File.read(child),
                 {:ok, path} <- normalize_virtual_path(child_relative) do
              {:cont, {:ok, [%{path: path, content: content, content_hash: hash(content)} | acc]}}
            else
              {:error, _reason} = error -> {:halt, error}
            end

          true ->
            {:cont, {:ok, acc}}
        end
      end)
      |> case do
        {:ok, files} -> {:ok, Enum.reverse(files)}
        {:error, _reason} = error -> error
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stable_hash(parts) when is_list(parts), do: hash(Enum.join(parts, <<0>>))

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
  end
end
