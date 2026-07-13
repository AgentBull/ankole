defmodule Ankole.Config.Bootstrap do
  @moduledoc """
  Shared bootstrap helpers for Ankole config scripts.

  This module runs before the application starts, so it only depends on files,
  system environment, and runtime-safe helper calls.
  """

  @phoenix_secret_key_base "phoenix.secret_key_base"

  @doc """
  Loads Ankole dotenv files for the given Mix environment.

  Existing OS environment variables have final precedence. Dotenv files are
  optional and are loaded in order, so later local files override earlier files.
  """
  def load_dotenv!(opts) do
    root = Keyword.fetch!(opts, :root)
    env = Keyword.fetch!(opts, :env)

    root
    |> dotenv_files(env)
    |> read_env_files()
    |> System.put_env()
  end

  @doc "Returns the string value of an OS environment variable, or `default`."
  def env_string(name, default \\ nil), do: System.get_env(name) || default

  @doc """
  Parses a colon-separated OS path list, returning absolute paths.

  Empty segments are ignored so Docker/Kubernetes templates can build the value
  from optional pieces without changing the parser contract.
  """
  def env_path_list(name, default \\ nil) do
    case System.get_env(name) do
      nil ->
        default

      raw ->
        raw
        |> String.split(":")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&Path.expand/1)
    end
  end

  @doc "Reads a required OS environment variable."
  def env!(name) do
    case System.get_env(name) do
      nil ->
        raise "Ankole.Config.Bootstrap: required environment variable #{name} is not set"

      value ->
        value
    end
  end

  @doc "Parses an OS environment variable as an integer, or returns `default`."
  def env_integer(name, default \\ nil) do
    case System.get_env(name) do
      nil ->
        default

      raw ->
        case Integer.parse(raw) do
          {integer, ""} ->
            integer

          _ ->
            raise "Ankole.Config.Bootstrap: invalid integer for #{name}: #{inspect(raw)}"
        end
    end
  end

  @doc "Parses an OS environment variable as a boolean, or returns `default`."
  def env_boolean(name, default \\ nil) do
    case System.get_env(name) do
      nil -> default
      raw when raw in ~w(true 1 yes) -> true
      raw when raw in ~w(false 0 no) -> false
      raw -> raise "Ankole.Config.Bootstrap: invalid boolean for #{name}: #{inspect(raw)}"
    end
  end

  @doc "Validates a TCP port integer at bootstrap time. Raises on failure."
  def validate_port!(port, name \\ "PORT")

  def validate_port!(port, _name) when is_integer(port) and port in 1..65_535, do: port

  def validate_port!(port, name) do
    raise "Ankole.Config.Bootstrap: invalid port for #{name}: #{inspect(port)}"
  end

  @doc "Derives Phoenix's endpoint secret from ANKOLE_SECRET_BASE."
  def endpoint_secret_key_base! do
    secret_base = env!("ANKOLE_SECRET_BASE")

    case apply(Ankole.Kernel, :derive_key, [secret_base, @phoenix_secret_key_base]) do
      secret_key_base when is_binary(secret_key_base) ->
        secret_key_base

      {:error, reason} ->
        raise "Ankole.Config.Bootstrap: failed to derive Phoenix secret_key_base: #{inspect(reason)}"

      other ->
        raise "Ankole.Config.Bootstrap: failed to derive Phoenix secret_key_base: #{inspect(other)}"
    end
  end

  defp dotenv_files(root, :dev) do
    [
      Path.join(root, ".env.dev"),
      Path.join(root, ".env.dev.local"),
      Path.join(root, ".env.local")
    ]
  end

  defp dotenv_files(root, :test) do
    [
      Path.join(root, ".env.test"),
      Path.join(root, ".env.test.local"),
      Path.join(root, ".env.local")
    ]
  end

  defp dotenv_files(root, _env), do: [Path.join(root, ".env.local")]

  defp read_env_files(files) do
    # Include the OS env before dotenv files for interpolation and after dotenv
    # files for final precedence.
    apply(Dotenvy, :source!, [
      [System.get_env() | files] ++ [System.get_env()],
      [require_files: false, side_effect: false]
    ])
  rescue
    UndefinedFunctionError ->
      files
      |> Enum.reduce(%{}, fn path, acc -> Map.merge(acc, read_env_file(path)) end)
      |> Map.merge(System.get_env())
  end

  defp read_env_file(path) do
    case File.read(path) do
      {:ok, content} -> parse_env(content)
      {:error, _reason} -> %{}
    end
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
end
