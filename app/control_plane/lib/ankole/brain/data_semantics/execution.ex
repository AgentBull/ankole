defmodule Ankole.Brain.DataSemantics.Execution do
  @moduledoc """
  Executes a published metric revision without a model.

  The caller names a metric object and a revision (or the latest one). The
  executor never substitutes a column or another revision: a missing,
  unpublished, or unreadable metric returns a structured error code, and
  the data source applies the caller's own permissions.
  """
  require Ash.Query
  alias Ankole.Brain.{DataSemantics, Objects}
  alias Ankole.Brain.DataSemantics.Definitions
  alias Ankole.Brain.Schemas.MetricRevision

  @doc "See `Ankole.Brain.execute_metric/4`."
  def execute(%Ankole.Principals.Principal{} = principal, reference, revision, params),
    do: execute(Ankole.AuthZ.Actor.new(principal), reference, revision, params)

  def execute(%Ankole.AuthZ.Actor{} = actor, reference, revision, params) do
    with {:ok, object} <- metric_object(actor, reference),
         {:ok, chosen, latest} <- choose(object, revision),
         {:ok, values, dimensions} <- Definitions.execution_params(chosen, params || %{}),
         {:ok, executed} <- run(actor, chosen, values, dimensions) do
      {:ok,
       Map.merge(executed, %{
         metric: %{id: object.id, slug: object.slug, title: object.title},
         revision: %{
           id: chosen.id,
           revision: chosen.revision,
           latest: chosen.revision == latest.revision,
           status: chosen.status,
           approved_by: chosen.approved_by,
           created_at: chosen.created_at
         },
         definition:
           Map.take(chosen, [
             :grain,
             :unit,
             :numerator,
             :denominator,
             :time_field,
             :addible_dimensions
           ]),
         source: Map.put(chosen.source, "kind", Atom.to_string(chosen.source_kind)),
         params: values,
         dimensions: Enum.map(dimensions, & &1["name"]),
         executed_at: DateTime.utc_now(:microsecond)
       })}
    end
  end

  # A reader who cannot view the metric object learns nothing about it.
  defp metric_object(actor, reference) do
    with true <- is_binary(reference),
         {:ok, %{kind: :knowledge, deleted_at: nil} = object} <- Objects.resolve_slug(reference),
         "metrics" <- DataSemantics.category(object.id),
         {:ok, _page} <- Ankole.Pod.Pages.authorize(actor, object.id, "node_view") do
      {:ok, object}
    else
      _ -> {:error, {:metric_not_found, %{metric: reference}}}
    end
  end

  defp choose(object, requested) do
    revisions =
      MetricRevision
      |> Ash.Query.filter(metric_page_id == ^object.id)
      |> Ash.Query.sort(revision: :desc)
      |> Ankole.Ash.read!()

    case revisions do
      [] ->
        {:error, {:metric_not_found, %{metric: object.slug}}}

      [%{status: :retired} | _] ->
        {:error, {:metric_not_found, %{metric: object.slug, status: :retired}}}

      [latest | _] ->
        with {:ok, chosen} <- pick(revisions, latest, requested) do
          case chosen.status do
            :published ->
              {:ok, chosen, latest}

            :needs_review ->
              {:error,
               {:metric_needs_review,
                %{metric: object.slug, revision: chosen.revision, reason: chosen.review_reason}}}

            :retired ->
              {:error, {:metric_not_found, %{metric: object.slug, status: :retired}}}
          end
        end
    end
  end

  defp pick(_revisions, latest, requested) when requested in [nil, :latest, "latest"],
    do: {:ok, latest}

  defp pick(revisions, _latest, requested) when is_integer(requested) do
    case Enum.find(revisions, &(&1.revision == requested)) do
      nil -> {:error, {:metric_revision_not_found, %{revision: requested}}}
      revision -> {:ok, revision}
    end
  end

  defp pick(_revisions, _latest, requested),
    do: {:error, {:metric_revision_not_found, %{revision: requested}}}

  defp run(actor, %{source_kind: :base} = revision, values, dimensions) do
    spec = Definitions.substitute(revision.spec, values)

    spec =
      if dimensions == [] do
        spec
      else
        groups = Enum.map(dimensions, &Map.take(&1, ["field_id", "bucket"]))
        Map.put(spec, "group_by", Map.get(spec, "group_by", []) ++ groups)
      end

    with {:ok, result} <- Ankole.Pod.Bases.aggregate(actor, revision.source["table_id"], spec),
         do: {:ok, %{executed_spec: spec, result: result, data_versions: result.data_versions}}
  end

  # The connector SQL fixes its own grouping and returns every declared
  # dimension column, so requested dimensions only pass the allowlist check.
  # SQL placeholders bind the parameters in their declared order.
  defp run(actor, %{source_kind: :connector} = revision, values, _dimensions) do
    sql = revision.spec["sql"]
    connection = revision.source["connection"]
    ordered = Enum.map(revision.parameters, &values[&1["name"]])
    bound = Enum.zip_with(revision.parameters, ordered, &bind(&1["type"], &2))

    with {:ok, evidence} <- Ankole.Connectors.run_read_query(actor, connection, sql, bound, []) do
      {:ok,
       %{
         executed_spec: %{"sql" => sql, "params" => ordered, "connection" => connection},
         result: evidence,
         data_versions: %{}
       }}
    end
  end

  defp bind("date", value), do: Date.from_iso8601!(value)

  defp bind("datetime", value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp bind(_type, value), do: value
end
