defmodule Ankole.AdvisoryLock do
  @moduledoc "Transaction-scoped PostgreSQL advisory locks."

  alias Ecto.Adapters.SQL

  # The statements read no table: each locks one key of the database.
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :site

  @doc "Locks a key without changing its existing PostgreSQL hash representation."
  def lock(repo, key, opts \\ []) do
    Ankole.LockOrder.check_advisory(key)
    {statement, params} = statement(key, opts)
    SQL.query(repo, statement, params)
  end

  @doc """
  Locks a key and raises on a database error.

  A list of `{left, right}` keys locks each key in the list order.
  """
  def lock!(repo, key, opts \\ []) do
    Ankole.LockOrder.check_advisory(key)
    {statement, params} = statement(key, opts)
    SQL.query!(repo, statement, params)
  end

  defp statement({left, right}, []) when is_binary(left) and is_binary(right),
    do: {"SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))", [left, right]}

  # One statement locks a list of pair keys in the list order.
  defp statement([_ | _] = pairs, []) do
    {"""
     SELECT count(pg_advisory_xact_lock(hashtext(key.left_part), hashtext(key.right_part)))
     FROM unnest($1::text[], $2::text[]) AS key(left_part, right_part)
     """, [Enum.map(pairs, &elem(&1, 0)), Enum.map(pairs, &elem(&1, 1))]}
  end

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
