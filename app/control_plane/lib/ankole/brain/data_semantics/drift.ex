defmodule Ankole.Brain.DataSemantics.Drift do
  @moduledoc """
  Marks published metric revisions `needs_review` when a source they depend
  on changes underneath them.

  Each revision snapshots its whole dependency set at publish time: a Base
  revision records the type of every field it or its binding references and
  an entry for every table its link paths reach, and a connector revision
  records its resolved source table and every column it or its binding
  reads. Drift detection compares only that snapshot, never the current
  dataset binding, so rebinding a dataset leaves earlier revisions on their
  own source. After a Base schema change, a deleted table, a deleted field,
  or a changed type marks each affected revision. A connector catalog
  refresh reports the columns it no longer finds, and Brain marks the
  revisions that read them.
  """
  require Ash.Query
  alias Ankole.Brain.Schemas.MetricRevision
  alias Ankole.Repo

  @doc "Rechecks the published Base revisions that reference the given tables."
  def base_tables_changed_in_tx(table_ids) do
    Repo.require_transaction!({__MODULE__, :base_tables_changed_in_tx})
    table_ids = Enum.uniq(table_ids)

    current =
      Map.new(table_ids, fn id ->
        case Ankole.Pod.Bases.fetch_table(id) do
          {:ok, _table} ->
            {id, Map.new(Ankole.Pod.Bases.fields(id), &{&1.id, to_string(&1.type)})}

          {:error, :not_found} ->
            {id, :deleted}
        end
      end)

    MetricRevision
    |> Ash.Query.filter(status == :published and source_kind == :base)
    |> Ankole.Ash.read!()
    |> Enum.flat_map(fn revision ->
      case drift(revision.field_types, current) do
        nil -> []
        reason -> [{revision, reason}]
      end
    end)
    |> mark()
  end

  @doc """
  Marks connector revisions whose source columns a catalog refresh no longer
  finds. Each missing entry names `table` and optionally `catalog`, `schema`,
  and `column`; an entry without `column` reports the whole table missing.
  """
  def connector_columns_missing_in_tx(connection_slug, missing) when is_list(missing) do
    Repo.require_transaction!({__MODULE__, :connector_columns_missing_in_tx})
    missing = Enum.map(missing, &Map.new(&1, fn {key, value} -> {to_string(key), value} end))

    MetricRevision
    |> Ash.Query.filter(status == :published and source_kind == :connector)
    |> Ankole.Ash.read!()
    |> Enum.filter(&(&1.source["connection"] == connection_slug))
    |> Enum.flat_map(fn revision ->
      case Enum.filter(
             missing,
             &(same_table?(&1, revision.source) and missing_column?(&1, revision.source_columns))
           ) do
        [] -> []
        found -> [{revision, %{"connection" => connection_slug, "missing" => found}}]
      end
    end)
    |> mark()
  end

  # Returns nil when every recorded field of a changed table still exists
  # with its recorded type.
  defp drift(field_types, current) do
    Enum.find_value(field_types, fn {table_id, expected} ->
      case Map.get(current, table_id) do
        nil ->
          nil

        :deleted ->
          %{
            "table_id" => table_id,
            "table_deleted" => true,
            "missing_field_ids" => Map.keys(expected)
          }

        fields ->
          missing = Enum.reject(Map.keys(expected), &Map.has_key?(fields, &1))

          changed =
            Enum.filter(expected, fn {id, type} ->
              Map.has_key?(fields, id) and fields[id] != type
            end)

          if missing == [] and changed == [],
            do: nil,
            else: %{
              "table_id" => table_id,
              "missing_field_ids" => missing,
              "changed_field_ids" => Enum.map(changed, &elem(&1, 0))
            }
      end
    end)
  end

  defp same_table?(missing, source) do
    missing["table"] == source["table"] and
      missing["schema"] in [nil, source["schema"]] and
      missing["catalog"] in [nil, source["catalog"]]
  end

  defp missing_column?(%{"column" => column}, columns) when is_binary(column),
    do: column in columns

  defp missing_column?(_missing, _columns), do: true

  defp mark(revisions) do
    Enum.reduce_while(revisions, :ok, fn {revision, reason}, :ok ->
      case Ankole.Ash.update(revision, :mark_needs_review, %{review_reason: reason}) do
        {:ok, _revision} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
