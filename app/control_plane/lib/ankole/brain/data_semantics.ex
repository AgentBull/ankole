defmodule Ankole.Brain.DataSemantics do
  @moduledoc """
  Keeps the executable side of Brain's data objects in step with their pages.

  A knowledge save of a Brain object runs `sync_in_tx/1` inside the save
  transaction. A `datasets/` object replaces its `DatasetBinding`, a
  `metrics/` object appends a `MetricRevision` when its definition changes,
  and any Brain object replaces its `EntityIdentifier` rows. Invalid
  frontmatter returns an error, which rolls the save back.
  """
  require Ash.Query
  alias Ankole.Brain.DataSemantics.Definitions
  alias Ankole.Brain.Schemas.{DatasetBinding, EntityIdentifier, Link, MetricRevision}
  alias Ankole.Pod.Pages.Tree, as: Nodes

  @link_source "data_semantics"
  # Revision fields that define what a revision executes and means.
  @definition [
    :dataset_binding_id,
    :source_kind,
    :source,
    :spec,
    :parameters,
    :field_types,
    :source_columns,
    :grain,
    :unit,
    :addible_dimensions,
    :time_field,
    :numerator,
    :denominator,
    :status
  ]

  @doc "Synchronizes one saved knowledge object's bindings, revisions, and identifiers."
  def sync_in_tx(%{kind: :knowledge, deleted_at: nil} = object) do
    case category(object.id) do
      nil ->
        :ok

      category ->
        with :ok <- sync_identifiers(object), do: sync_category(category, object)
    end
  end

  def sync_in_tx(_object), do: :ok

  @doc """
  Returns the Brain category of a page (`"metrics"`, `"datasets"`, ...), or
  nil for a page outside the Brain root.
  """
  def category(page_id) do
    with {:ok, node} <- Nodes.fetch(page_id),
         {:ok, path} <- Nodes.path(node),
         true <- Enum.any?(path, &(&1.system_key == "ankole_brain")) do
      Enum.find_value(path, "", fn
        %{system_key: "ankole_brain_category:" <> name} -> name
        _ -> nil
      end)
    else
      _ -> nil
    end
  end

  defp sync_category(category, object) when category in ["datasets", "metrics"] do
    with {:ok, _} <-
           Link
           |> Ash.Query.filter(origin_page_id == ^object.id and link_source == @link_source)
           |> Ankole.Ash.destroy_where(:remove),
         do: sync_definition(category, object)
  end

  defp sync_category(_category, _object), do: :ok

  defp sync_definition("datasets", object) do
    current = Definitions.dataset_binding(object.id)

    case Definitions.dataset(object.meta, object.id) do
      {:ok, :draft} ->
        if current, do: destroy(current), else: :ok

      {:ok, attrs, targets} ->
        result =
          if current,
            do: Ankole.Ash.update(current, :rebind, attrs),
            else:
              Ankole.Ash.create(
                DatasetBinding,
                :bind,
                Map.put(attrs, :dataset_page_id, object.id)
              )

        with {:ok, _binding} <- result,
             do: link_all(object.id, targets, "joins_to")

      error ->
        error
    end
  end

  defp sync_definition("metrics", object) do
    latest = latest_revision(object.id)

    case Definitions.metric(object.meta) do
      {:ok, :draft} when is_nil(latest) or latest.status == :retired ->
        :ok

      {:ok, :draft} ->
        {:error,
         {:invalid_metric_definition,
          %{
            key: "dataset",
            message:
              "a metric with revisions keeps its definition; set status: retired to withdraw it"
          }}}

      {:ok, :retired} when is_nil(latest) or latest.status == :retired ->
        :ok

      {:ok, :retired} ->
        latest
        |> Map.take(@definition)
        |> Map.put(:status, :retired)
        |> append(object, latest)

      {:ok, attrs, dataset_id} ->
        with :ok <- if(same?(latest, attrs), do: :ok, else: append(attrs, object, latest)),
             do: link_all(object.id, [dataset_id], "measures")

      error ->
        error
    end
  end

  defp same?(nil, _attrs), do: false
  defp same?(latest, attrs), do: Map.take(latest, @definition) == Map.take(attrs, @definition)

  defp append(attrs, object, latest) do
    with {:ok, %{content: content}} <- Ankole.Pod.Knowledge.read_in_tx(object.id),
         {:ok, _revision} <-
           Ankole.Ash.create(
             MetricRevision,
             :append,
             Map.merge(attrs, %{
               metric_page_id: object.id,
               revision: if(latest, do: latest.revision + 1, else: 1),
               page_revision: object.revision,
               approved_by: content.updated_by
             })
           ),
         do: :ok
  end

  @doc "Returns the newest revision of one metric object, or nil."
  def latest_revision(page_id),
    do:
      MetricRevision
      |> Ash.Query.filter(metric_page_id == ^page_id)
      |> Ash.Query.sort(revision: :desc)
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()

  defp link_all(from, targets, type) do
    targets
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn target, :ok ->
      case Ankole.Ash.create(Link, :add, %{
             from_page_id: from,
             to_page_id: target,
             origin_page_id: from,
             link_source: @link_source,
             link_type: type,
             origin_field: "metadata"
           }) do
        {:ok, _link} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp sync_identifiers(object) do
    with {:ok, pairs} <- Definitions.identifiers(object.meta["identifiers"]) do
      current =
        EntityIdentifier
        |> Ash.Query.filter(entity_page_id == ^object.id)
        |> Ankole.Ash.read!()

      with :ok <-
             current
             |> Enum.reject(&({&1.namespace, &1.value} in pairs))
             |> Enum.reduce_while(:ok, fn row, :ok ->
               case destroy(row) do
                 :ok -> {:cont, :ok}
                 error -> {:halt, error}
               end
             end) do
        held = MapSet.new(current, &{&1.namespace, &1.value})

        pairs
        |> Enum.reject(&MapSet.member?(held, &1))
        |> Enum.reduce_while(:ok, fn pair, :ok ->
          case add_identifier(object.id, pair) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      end
    end
  end

  defp add_identifier(page_id, {namespace, value}) do
    holder =
      EntityIdentifier
      |> Ash.Query.filter(namespace == ^namespace and value == ^value)
      |> Ankole.Ash.read_one!()

    if holder do
      {:error, {:entity_identifier_conflict, %{namespace: namespace, value: value}}}
    else
      with {:ok, _row} <-
             Ankole.Ash.create(EntityIdentifier, :add, %{
               entity_page_id: page_id,
               namespace: namespace,
               value: value
             }),
           do: :ok
    end
  end

  defp destroy(record) do
    with {:ok, _destroyed} <- Ankole.Ash.destroy(record, :remove), do: :ok
  end
end
