defmodule Ankole.Config.Bootstrap do
  @moduledoc """
  Shared bootstrap helpers for Ankole config scripts.

  This module runs before the application starts, so it only depends on files,
  system environment, and runtime-safe helper calls.
  """

  @phoenix_secret_key_base "phoenix.secret_key_base"

  @doc "Parses the fixed Base shard topology before storage starts."
  def base_databases(raw, database_url, env, partition \\ nil, edition \\ :foss) do
    raw = if is_binary(raw) and String.trim(raw) == "", do: nil, else: raw

    urls =
      case raw do
        nil when env in [:dev, :test] or edition == :saas ->
          count = if env in [:dev, :test], do: 4, else: 8

          for index <- 0..(count - 1) do
            id = "base_" <> String.pad_leading(to_string(index), 2, "0")
            suffix = if env == :test, do: "_test_#{partition || "default"}", else: ""
            uri = URI.parse(database_url)
            URI.to_string(%{uri | path: "/ankole_#{id}#{suffix}", query: "ankole_sharding=#{id}"})
          end

        nil ->
          [database_url]

        value ->
          value |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end

    if urls == [], do: raise("BASE_DB_URLS must contain at least one URL")

    default_pool =
      cond do
        env in [:dev, :test] -> 2
        edition == :saas -> 5
        true -> 10
      end

    shards = Enum.map(urls, &base_database(&1, length(urls), default_pool))
    ids = Enum.map(shards, & &1.id)
    if Enum.uniq(ids) != ids, do: raise("BASE_DB_URLS has duplicate shard IDs")
    shards
  end

  defp base_database(url, count, default_pool) do
    uri = URI.parse(url)

    unless uri.scheme in ["postgres", "postgresql", "ecto"] and is_binary(uri.host) and
             is_binary(uri.path) and uri.path != "/",
           do: raise("BASE_DB_URLS requires PostgreSQL database URLs")

    pairs = if uri.query, do: Enum.to_list(URI.query_decoder(uri.query)), else: []

    {custom, driver} =
      Enum.split_with(pairs, fn {key, _} -> String.starts_with?(key, "ankole_") end)

    keys = Enum.map(custom, &elem(&1, 0))

    unless Enum.uniq(keys) == keys and
             Enum.all?(keys, &(&1 in ~w(ankole_sharding ankole_stock_only ankole_pool_size))),
           do: raise("BASE_DB_URLS has duplicate or unknown ankole_* parameters")

    if Enum.any?(driver, fn {key, _} -> key == "sslmode" end),
      do: raise("BASE_DB_URLS does not support sslmode; use the internal PostgreSQL network")

    custom = Map.new(custom)
    id = custom["ankole_sharding"] || if(count == 1, do: "base_default")

    unless is_binary(id) and Regex.match?(~r/\A[a-z0-9_]{1,32}\z/, id),
      do: raise("Each BASE_DB_URLS entry requires a unique ankole_sharding ID")

    stock_only =
      case custom["ankole_stock_only"] do
        value when value in [nil, "false"] -> false
        "true" -> true
        _ -> raise "ankole_stock_only must be true or false"
      end

    pool =
      case custom["ankole_pool_size"] do
        nil ->
          default_pool

        value ->
          case Integer.parse(value) do
            {size, ""} when size > 0 -> size
            _ -> raise "ankole_pool_size must be a positive integer"
          end
      end

    %{
      id: id,
      stock_only: stock_only,
      pool_size: pool,
      url:
        URI.to_string(%{
          uri
          | scheme: "ecto",
            query: if(driver == [], do: nil, else: URI.encode_query(driver))
        })
    }
  end

  @files_store_fields %{
    "fs" => {~w(root)a, []},
    "s3" => {~w(bucket region)a, ~w(endpoint root access_key_id secret_access_key)a},
    "azblob" => {~w(container endpoint)a, ~w(root account_name account_key sas_token)a},
    "d1" => {~w(account_id database_id token table key_field value_field)a, ~w(root)a},
    "cos" => {~w(bucket endpoint)a, ~w(root secret_id secret_key security_token)a},
    "postgresql" => {~w(connection_string table key_field value_field)a, ~w(root)a},
    "oss" => {~w(bucket endpoint)a, ~w(root access_key_id access_key_secret security_token)a},
    "tos" =>
      {~w(bucket endpoint region)a, ~w(root access_key_id secret_access_key security_token)a},
    "gcs" => {~w(bucket)a, ~w(root endpoint credential credential_path)a},
    "sftp" => {~w(endpoint)a, ~w(root user key known_hosts_strategy)a},
    "webdav" => {~w(endpoint)a, ~w(root username password token)a}
  }

  @doc "Builds the file-service store spec from its bootstrap environment."
  def files_store_spec do
    case env_string("ANKOLE_FILES_STORE") do
      nil ->
        nil

      scheme ->
        case Map.fetch(@files_store_fields, scheme) do
          {:ok, {required, optional}} ->
            files_store_fields(scheme, required, optional)

          :error ->
            supported = @files_store_fields |> Map.keys() |> Enum.sort() |> Enum.join(", ")
            raise "invalid ANKOLE_FILES_STORE=#{inspect(scheme)}; expected one of #{supported}"
        end
    end
  end

  defp files_store_fields(scheme, required, optional) do
    Enum.reduce(required ++ optional, %{scheme: scheme}, fn field, spec ->
      name = "ANKOLE_FILES_#{String.upcase(scheme)}_#{field |> to_string() |> String.upcase()}"

      case env_string(name) do
        value when is_binary(value) and value != "" ->
          Map.put(spec, field, value)

        _missing ->
          if field in required, do: raise("#{name} is required for ANKOLE_FILES_STORE=#{scheme}")
          spec
      end
    end)
  end

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
    Dotenvy.source!(
      [System.get_env() | files] ++ [System.get_env()],
      require_files: false,
      side_effect: false
    )
  end
end
