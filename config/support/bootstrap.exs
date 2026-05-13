defmodule BullX.Config.Bootstrap do
  @moduledoc """
  Shared bootstrap helpers for BullX config scripts.

  This module exists for the pre-Repo bootstrap phase, where BullX still needs
  typed environment parsing but cannot rely on the runtime config cache. It
  owns the project-wide dotenv convention used by `config/*.exs`: load `.env`
  plus `.env.<profile>`, include `.env.local` in `:dev`, and never override a
  value already present in the OS environment.
  """

  @doc """
  Loads the appropriate `.env*` files for the given Mix environment and merges
  them into the process environment. Existing OS environment variables are not
  overwritten; file-based values only fill gaps.
  """
  def load_dotenv!(opts) do
    root = Keyword.fetch!(opts, :root)
    env = Keyword.fetch!(opts, :env)
    profile = profile_name(env)
    files = dotenv_files(root, profile, env)

    files
    |> Enum.reduce(%{}, fn path, acc ->
      Map.merge(acc, read_env_file(path))
    end)
    |> put_missing_envs()
  end

  # Reads a KEY=value file into a map.
  # Falls back to Dotenvy when available (supports quoted values, comments, etc.);
  # uses a minimal built-in parser otherwise (covers the plain KEY=value case).
  defp read_env_file(path) do
    case apply(Dotenvy, :source!, [[path], [require_files: false]]) do
      loaded when is_map(loaded) -> loaded
    end
  rescue
    UndefinedFunctionError ->
      case File.read(path) do
        {:ok, content} -> parse_env(content)
        {:error, _} -> %{}
      end
  end

  defp put_missing_envs(values) when is_map(values) do
    Enum.each(values, fn {key, value} ->
      if is_nil(System.get_env(key)), do: System.put_env(key, value)
    end)
  end

  defp parse_env(content) do
    content
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      with false <- line == "" or String.starts_with?(line, "#"),
           [key, value] <- String.split(line, "=", parts: 2),
           key = String.trim(key),
           true <- key != "" do
        Map.put(acc, key, String.trim(value))
      else
        _ -> acc
      end
    end)
  end

  @doc "Returns the string value of an OS environment variable, or `default`."
  def env_string(name, default \\ nil), do: System.get_env(name) || default

  @doc "Parses an OS environment variable as an integer, or returns `default`."
  def env_integer(name, default \\ nil) do
    case System.get_env(name) do
      nil ->
        default

      raw ->
        case Integer.parse(raw) do
          {n, ""} ->
            n

          _ ->
            raise "BullX.Config.Bootstrap: invalid integer for #{name}: #{inspect(raw)}"
        end
    end
  end

  @doc "Parses an OS environment variable as a boolean, or returns `default`."
  def env_boolean(name, default \\ nil) do
    case System.get_env(name) do
      nil -> default
      raw when raw in ~w(true 1 yes) -> true
      raw when raw in ~w(false 0 no) -> false
      raw -> raise "BullX.Config.Bootstrap: invalid boolean for #{name}: #{inspect(raw)}"
    end
  end

  @doc """
  Reads a required OS environment variable and applies `parser/1`.
  Raises if the variable is absent.
  """
  def env!(name, parser) when is_function(parser, 1) do
    case System.get_env(name) do
      nil ->
        raise "BullX.Config.Bootstrap: required environment variable #{name} is not set"

      raw ->
        parser.(raw)
    end
  end

  @doc "Validates `value` against a Zoi schema supplied via the `zoi:` option. Raises on failure."
  def validate!(value, opts) when is_list(opts) do
    apply(BullX.Config.Validation, :validate_bootstrap!, [value, opts])
  end

  @doc "Validates a TCP port integer at bootstrap time. Raises on failure."
  def validate_port!(port, name \\ "PORT")

  def validate_port!(port, _name) when is_integer(port) and port in 1..65_535 do
    port
  end

  def validate_port!(port, name) do
    raise "BullX.Config.Bootstrap: invalid port for #{name}: #{inspect(port)}"
  end

  @doc "Maps a Mix config env atom to a BullX dotenv profile name."
  def profile_name(config_env), do: Atom.to_string(config_env)

  defp dotenv_files(root, profile, env) do
    base = [
      Path.join(root, ".env"),
      Path.join(root, ".env.#{profile}")
    ]

    if env == :dev do
      base ++ [Path.join(root, ".env.local")]
    else
      base
    end
  end
end
