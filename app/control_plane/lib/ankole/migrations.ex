defmodule Ankole.Migrations do
  @moduledoc "The selected build's schema migrations, shared by Mix and releases."

  def paths do
    public = Ecto.Migrator.migrations_path(Ankole.Repo)

    paths =
      case Application.fetch_env!(:ankole, :edition) do
        :foss -> [public]
        :saas -> [public, Application.fetch_env!(:ankole, :internal_migrations_path)]
      end

    Enum.each(paths, fn path ->
      unless File.dir?(path), do: raise(ArgumentError, "Missing migration directory: #{path}")
    end)

    paths
  end

  def migrate(repo, requested_paths, direction, opts) do
    paths = selected_paths(requested_paths, opts)
    validate!(paths)

    case direction do
      :up ->
        Ankole.CredentialUpgrade.preflight!(repo)
        Ankole.Upgrade202610.migrate(repo, paths, :up, opts)

      :down ->
        Ecto.Migrator.run(repo, paths, :down, opts)
    end
  end

  def status(repo, requested_paths, opts) do
    paths = selected_paths(requested_paths, opts)
    validate!(paths)
    Ecto.Migrator.migrations(repo, paths, opts)
  end

  # Keep explicit migration paths for upgrade tools and migration fixtures.
  defp selected_paths(requested, opts) do
    if Keyword.has_key?(opts, :migrations_path), do: requested, else: paths()
  end

  def validate!(paths \\ paths()) do
    files = Enum.flat_map(paths, &Path.wildcard(Path.join(&1, "*.exs"))) |> Enum.sort()

    identities =
      Enum.map(files, fn path ->
        case Regex.run(~r/\A(\d+)_(.+)\.exs\z/, Path.basename(path)) do
          [_, version, name] -> {String.to_integer(version), name, path}
          _ -> raise ArgumentError, "Invalid migration filename: #{path}"
        end
      end)

    reject_duplicates!(
      Enum.map(identities, fn {version, _, path} -> {version, path} end),
      "version"
    )

    reject_duplicates!(Enum.map(identities, fn {_, name, path} -> {name, path} end), "name")

    modules =
      Enum.flat_map(files, fn path ->
        {_, modules} =
          path
          |> File.read!()
          |> Code.string_to_quoted!(file: path)
          |> Macro.prewalk([], fn
            {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, acc ->
              {node, [{Module.concat(parts), path} | acc]}

            {:defmodule, _, _}, _ ->
              raise ArgumentError, "Migration modules must use literal names: #{path}"

            node, acc ->
              {node, acc}
          end)

        modules
      end)

    reject_duplicates!(modules, "module")
    :ok
  end

  defp reject_duplicates!(entries, kind) do
    entries
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {identity, files} ->
      if length(files) > 1 do
        raise ArgumentError,
              "Duplicate migration #{kind} #{inspect(identity)}: #{Enum.join(files, ", ")}"
      end
    end)
  end
end
