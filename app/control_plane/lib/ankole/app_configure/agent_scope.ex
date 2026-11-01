defmodule Ankole.AppConfigure.AgentScope do
  @moduledoc "Moves encrypted settings when a tenant Agent changes its name."
  require Ash.Query
  alias Ankole.AppConfigure.{AppConfig, Cache, Codec, Registry}
  alias Ankole.Repo
  @agent_scope_prefix "agent:"

  @doc "Moves one Agent's scoped settings, re-encrypting values under the new scope."
  def rename_agent_in_tx(old_uid, new_uid) do
    unless Repo.in_transaction?(),
      do:
        raise(Ankole.Errors.Framework.TransactionRequired,
          operation: {__MODULE__, :rename_agent_in_tx}
        )

    old_scope = @agent_scope_prefix <> old_uid
    new_scope = @agent_scope_prefix <> new_uid

    AppConfig
    |> Ash.Query.filter(scope == ^old_scope)
    |> Ankole.Ash.read!()
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, keys} ->
      with {:ok, definition} <- Registry.require_key(row.key),
           {:ok, value} <- Codec.load(definition, old_scope, row.key, row.value),
           {:ok, envelope, _value} <- Codec.dump(definition, new_scope, row.key, value),
           {:ok, _new} <-
             Ankole.Ash.create(AppConfig, :import_envelope, %{
               scope: new_scope,
               key: row.key,
               value: Map.merge(row.value, envelope)
             }),
           {:ok, _old} <- Ankole.Ash.destroy(row, :remove) do
        {:cont, {:ok, [{old_scope, new_scope, row.key} | keys]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "Refreshes the old and new Agent scopes after a committed rename."
  def publish_agent_rename(keys) do
    Enum.each(keys, fn {old_scope, new_scope, key} ->
      Cache.refresh(old_scope, key)
      Cache.refresh(new_scope, key)
    end)
  end
end
