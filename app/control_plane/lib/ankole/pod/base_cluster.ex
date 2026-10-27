defmodule Ankole.Pod.BaseCluster do
  @moduledoc "Starts the configured Base pools and checks their durable identities."
  use Supervisor
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :site

  alias Ankole.Pod.BaseRepo
  alias Ankole.Repo

  def databases, do: Application.fetch_env!(:ankole, __MODULE__) |> Keyword.fetch!(:databases)

  def allocate(id, requested \\ nil) do
    available = Enum.reject(databases(), & &1.stock_only)

    cond do
      requested && Enum.any?(databases(), &(&1.id == requested)) -> {:ok, requested}
      requested -> {:error, :unknown_base_db}
      available == [] -> {:error, :no_allocatable_base_db}
      true -> {:ok, Enum.at(available, :erlang.phash2(id, length(available))).id}
    end
  end

  # These atoms come only from the bounded startup configuration.
  def pool_name(id), do: String.to_atom("ankole_base_pool_" <> id)

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    collation = Repo.query!(collation_sql(), []).rows
    [[version]] = Repo.query!("SELECT current_setting('server_version_num')::integer", []).rows
    if version < 180_000, do: raise("Ankole requires PostgreSQL 18 or later")

    configured = Enum.map(databases(), & &1.id)
    assigned = Ankole.Tenants.assigned_base_db_ids()
    missing = assigned -- configured
    if missing != [], do: raise("BASE_DB_URLS omits assigned shards: #{inspect(missing)}")

    children =
      for shard <- databases() do
        initialize!(shard, collation)

        Supervisor.child_spec(
          {BaseRepo,
           [
             name: pool_name(shard.id),
             url: shard.url,
             pool_size: shard.pool_size,
             prepare: :unnamed,
             after_connect: {__MODULE__, :initialize_connection!, [shard.id, collation]}
           ]},
          id: shard.id
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  def check_identity!(connection, expected) do
    result =
      Postgrex.query!(
        connection,
        "SELECT shard_id FROM public._ankole_shard WHERE singleton = true",
        []
      )

    unless result.rows == [[expected]], do: raise("Base shard identity mismatch for #{expected}")
    :ok
  end

  defp initialize!(shard, collation) do
    opts = Ecto.Repo.Supervisor.parse_url(shard.url) ++ [prepare: :unnamed]
    ensure_database!(opts, collation)
    {:ok, connection} = Postgrex.start_link(opts)

    try do
      initialize_connection!(connection, shard.id, collation)
    after
      GenServer.stop(connection)
    end
  rescue
    _error in DBConnection.ConnectionError ->
      Ankole.Logging.warning("pod.base.shard_unavailable", "Base pool will reconnect", %{
        shard_id: shard.id
      })
  end

  def initialize_connection!(connection, id, collation) do
    unless Postgrex.query!(connection, collation_sql(), []).rows == collation,
      do: raise("Base shard #{id} has a different collation from the control plane")

    [[version, identity]] =
      Postgrex.query!(
        connection,
        "SELECT current_setting('server_version_num')::integer,to_regclass('public._ankole_shard')::text",
        []
      ).rows

    if version < 180_000, do: raise("Base shards require PostgreSQL 18 or later")

    if is_nil(identity) do
      {:ok, :ok} =
        Postgrex.transaction(connection, fn connection ->
          Postgrex.query!(
            connection,
            "SELECT pg_advisory_xact_lock(hashtext('_ankole_shard'))",
            []
          )

          Postgrex.query!(
            connection,
            """
            CREATE TABLE IF NOT EXISTS public._ankole_shard (
              singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton), shard_id text NOT NULL
            )
            """,
            []
          )

          Postgrex.query!(
            connection,
            "INSERT INTO public._ankole_shard(singleton,shard_id) VALUES(true,$1) ON CONFLICT(singleton) DO NOTHING",
            [id]
          )

          :ok
        end)
    end

    check_identity!(connection, id)
  end

  defp ensure_database!(opts, [[provider, collate, ctype, locale]]) do
    if Application.fetch_env!(:ankole, __MODULE__)[:create_databases] do
      {:ok, connection} = Postgrex.start_link(Keyword.put(opts, :database, "postgres"))

      try do
        name = Keyword.fetch!(opts, :database)

        if Postgrex.query!(connection, "SELECT 1 FROM pg_database WHERE datname=$1", [name]).rows ==
             [] do
          provider = %{"c" => "libc", "i" => "icu", "b" => "builtin"}[provider]
          locale_sql = if locale, do: " LOCALE #{literal(locale)}", else: ""

          sql =
            "CREATE DATABASE #{quote_name(name)} TEMPLATE template0 LOCALE_PROVIDER #{provider} LC_COLLATE #{literal(collate)} LC_CTYPE #{literal(ctype)}#{locale_sql}"

          case Postgrex.query(connection, sql, []) do
            {:ok, _} -> :ok
            {:error, %Postgrex.Error{postgres: %{code: :duplicate_database}}} -> :ok
            {:error, error} -> raise error
          end
        end
      after
        GenServer.stop(connection)
      end
    end
  end

  defp collation_sql,
    do:
      "SELECT datlocprovider::text,datcollate,datctype,datlocale FROM pg_database WHERE datname=current_database()"

  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
  defp quote_name(value), do: "\"" <> String.replace(value, "\"", "\"\"") <> "\""
end
