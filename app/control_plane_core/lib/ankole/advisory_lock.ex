defmodule Ankole.AdvisoryLock do
  @moduledoc "Transaction-scoped PostgreSQL advisory locks."

  alias Ecto.Adapters.SQL

  @doc "Locks a key without changing its existing PostgreSQL hash representation."
  def lock(repo, key, opts \\ []) do
    Ankole.LockOrder.check_advisory(key)
    {statement, params} = statement(key, opts)
    SQL.query(repo, statement, params)
  end

  @doc "Locks a key and raises on a database error."
  def lock!(repo, key, opts \\ []) do
    Ankole.LockOrder.check_advisory(key)
    {statement, params} = statement(key, opts)
    SQL.query!(repo, statement, params)
  end

  defp statement({left, right}, []) when is_binary(left) and is_binary(right),
    do: {"SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))", [left, right]}

  defp statement(key, opts) when is_binary(key) do
    function =
      if Keyword.get(opts, :shared, false),
        do: "pg_advisory_xact_lock_shared",
        else: "pg_advisory_xact_lock"

    hash =
      if Keyword.get(opts, :hash, :text) == :extended,
        do: "hashtextextended($1, 0)",
        else: "hashtext($1::text)"

    {"SELECT #{function}(#{hash})", [key]}
  end
end
