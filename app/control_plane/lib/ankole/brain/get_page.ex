defmodule Ankole.Brain.GetPage do
  @moduledoc "L0 summaries, L1 outlines and complete OKF pages under Drive visibility."
  require Ash.Query
  alias Ankole.Brain.{Access, Knowledge, Objects}
  alias Ankole.Brain.Schemas.Page
  alias Ankole.Pod.Knowledge, as: PageKnowledge

  def get_page(uid, reference, opts \\ []) do
    context = %{
      querier_uid: uid,
      disclosure: Keyword.get(opts, :disclosure, Access.open_disclosure())
    }

    with {:ok, access} <- Access.for_context(context),
         {:ok, page} <- Objects.resolve_reference(reference, access: access),
         {:ok, projection} <- render(page, Keyword.get(opts, :level, :l2)) do
      result = summary(page) |> Map.put(:revision, page.revision) |> Map.merge(projection)

      if projection.level == "L0",
        do: {:ok, result},
        else: enrich(context, page, access, result)
    end
  end

  defp enrich(context, page, access, result) do
    with {:ok, panel} <- Knowledge.panel(context, page.id) do
      children =
        Page
        |> Ash.Query.filter(parent_id == ^page.id)
        |> Access.filter_objects(access)
        |> Ash.Query.sort(title: :asc)
        |> Ankole.Ash.read!()
        |> Enum.map(&summary/1)

      {:ok,
       Map.merge(result, %{
         children: children,
         facts: Enum.filter(panel.claims, &(&1.claim_type == :fact)),
         takes: Enum.filter(panel.claims, &(&1.claim_type == :take)),
         timelines: panel.timelines,
         links: panel.backlinks,
         scorecard: panel.scorecard
       })}
    end
  end

  def get_page_admin(reference) do
    with {:ok, page} <- Objects.resolve_reference(reference),
         {:ok, projection} <- render(page, :l2),
         do: {:ok, summary(page) |> Map.put(:revision, page.revision) |> Map.merge(projection)}
  end

  def summary(page),
    do: %{
      id: page.id,
      page_id: page.id,
      slug: page.slug,
      title: page.title,
      type: page.type,
      summary: PageKnowledge.summary(page.meta)
    }

  defp render(page, level) when level in [:l0, "l0"],
    do: PageKnowledge.project(nil, page.meta, level)

  defp render(%{kind: kind, body: body, meta: metadata}, _level) when kind != :knowledge,
    do: {:ok, %{level: "L2", content: body, metadata: metadata}}

  defp render(page, level), do: PageKnowledge.project(page.xml, page.meta, level)
end
