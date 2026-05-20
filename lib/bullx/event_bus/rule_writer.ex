defmodule BullX.EventBus.RuleWriter do
  @moduledoc """
  Supported writer path for Event Routing Rules.
  """

  import Ecto.Query
  import Ecto.Changeset, only: [get_field: 2]

  alias Ecto.Multi
  alias BullX.EventBus.{EventRoutingRule, RoutingTable}
  alias BullX.Repo

  @upsert_update_fields [
    :active,
    :priority,
    :match_expr,
    :target_type,
    :target_ref,
    :scope_fields
  ]

  @type refresh_error :: {:routing_table_refresh_failed, EventRoutingRule.t(), term()}

  @spec create_rule(map()) ::
          {:ok, EventRoutingRule.t()} | {:error, Ecto.Changeset.t() | refresh_error()}
  def create_rule(attrs) do
    %EventRoutingRule{}
    |> EventRoutingRule.changeset(attrs)
    |> Repo.insert()
    |> refresh_after_write()
  end

  @spec upsert_by_name(String.t(), map()) ::
          {:ok, EventRoutingRule.t()} | {:error, Ecto.Changeset.t() | refresh_error()}
  def upsert_by_name(name, attrs) when is_binary(name) and is_map(attrs) do
    changeset =
      %EventRoutingRule{}
      |> EventRoutingRule.changeset(put_name(attrs, name))

    changeset
    |> Repo.insert(
      on_conflict: [set: upsert_update_set(changeset)],
      conflict_target: :name,
      returning: true
    )
    |> refresh_after_write()
  end

  @spec update_rule(EventRoutingRule.t(), map()) ::
          {:ok, EventRoutingRule.t()} | {:error, Ecto.Changeset.t() | refresh_error()}
  def update_rule(%EventRoutingRule{} = rule, attrs) do
    rule
    |> EventRoutingRule.changeset(attrs)
    |> Repo.update()
    |> refresh_after_write()
  end

  @spec refresh_routing_table() :: :ok | {:error, term()}
  def refresh_routing_table, do: RoutingTable.refresh()

  @spec reorder_priorities([String.t()], pos_integer()) ::
          {:ok, [EventRoutingRule.t()]} | {:error, term()}
  def reorder_priorities(rule_ids, start_priority \\ 1)
      when is_list(rule_ids) and is_integer(start_priority) and start_priority > 0 do
    now = DateTime.utc_now(:microsecond)

    indexed = Enum.with_index(rule_ids)
    temporary_base = next_temporary_priority(length(indexed), start_priority)

    multi =
      indexed
      |> Enum.reduce(Multi.new(), fn {id, index}, acc ->
        temporary = temporary_base + index

        Multi.update_all(acc, {:temporary, id}, by_id(id),
          set: [priority: temporary, updated_at: now]
        )
      end)
      |> then(fn acc ->
        Enum.reduce(indexed, acc, fn {id, index}, inner ->
          final = start_priority + index

          Multi.update_all(inner, {:final, id}, by_id(id),
            set: [priority: final, updated_at: now]
          )
        end)
      end)

    Repo.transaction(multi)
    |> case do
      {:ok, _changes} ->
        case RoutingTable.refresh() do
          :ok ->
            {:ok,
             Repo.all(
               from r in EventRoutingRule, where: r.id in ^rule_ids, order_by: [asc: r.priority]
             )}

          {:error, reason} ->
            {:error, {:routing_table_refresh_failed, reason}}
        end

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp refresh_after_write({:ok, rule}) do
    case RoutingTable.refresh() do
      :ok -> {:ok, rule}
      {:error, reason} -> {:error, {:routing_table_refresh_failed, rule, reason}}
    end
  end

  defp refresh_after_write({:error, changeset}), do: {:error, changeset}

  defp put_name(attrs, name) do
    attrs = attrs |> Map.delete(:name) |> Map.delete("name")

    case Enum.any?(Map.keys(attrs), &is_binary/1) do
      true -> Map.put(attrs, "name", name)
      false -> Map.put(attrs, :name, name)
    end
  end

  defp upsert_update_set(changeset) do
    values =
      Enum.map(@upsert_update_fields, fn field ->
        {field, get_field(changeset, field)}
      end)

    [{:updated_at, DateTime.utc_now(:microsecond)} | values]
  end

  defp next_temporary_priority(count, start_priority) do
    max_priority = Repo.one(from r in EventRoutingRule, select: max(r.priority)) || 0
    max_priority + start_priority + count
  end

  defp by_id(id), do: from(r in EventRoutingRule, where: r.id == ^id)
end
