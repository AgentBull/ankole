defmodule Ankole.Brain.GetPage do
  @moduledoc "L0 summaries, L1 outlines, complete OKF pages, and extracted file text under Drive visibility."
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

  # A file page has no OKF document: L0 and L1 preview its table summary or
  # leading text, and L2 returns the extracted text. The L2 limit sits above
  # ordinary documents and only cuts a file near the extraction limit, which
  # would otherwise fill a model's context in one read.
  @file_content_tokens 100_000
  @table_guidance "These rows are extracted text. For exact totals, grouping, or filtering, compute over the original file instead of estimating from them."

  defp render(%{kind: :file} = page, level) when level in [:l0, "l0"],
    do: {:ok, %{level: "L0", summary: file_preview(page, 100), file: file_coverage(page)}}

  defp render(%{kind: :file} = page, level) when level in [:l1, "l1"],
    do: {:ok, %{level: "L1", content: file_preview(page, 400), file: file_coverage(page)}}

  defp render(%{kind: :file} = page, _level) do
    content = Ankole.Kernel.truncate_o200k_base_tokens(page.body, @file_content_tokens)

    {:ok,
     %{
       level: "L2",
       content: content,
       metadata: page.meta,
       file: Map.put(file_coverage(page), "content_truncated", content != page.body)
     }}
  end

  defp render(page, level) when level in [:l0, "l0"],
    do: PageKnowledge.project(nil, page.meta, level)

  defp render(%{kind: kind, body: body, meta: metadata}, _level) when kind != :knowledge,
    do: {:ok, %{level: "L2", content: body, metadata: metadata}}

  defp render(page, level), do: PageKnowledge.project(page.xml, page.meta, level)

  defp file_preview(
         %{
           content_hash: version,
           upstream_state: %{"file_summary" => %{"version" => version, "text" => text}}
         },
         tokens
       ),
       do: Ankole.Kernel.truncate_o200k_base_tokens(text, tokens)

  defp file_preview(page, tokens),
    do: Ankole.Kernel.truncate_o200k_base_tokens(page.body, tokens)

  # What the extraction covered: `truncated` marks text cut at the extraction
  # limit, `textless_pages` lists PDF pages that still have no text, and
  # `ocr_pages` lists the scanned pages whose text an OCR model read.
  defp file_coverage(%{file: %{"format" => format, "metadata" => metadata}} = page) do
    coverage =
      metadata
      |> Map.take(
        ~w(truncated page_count extracted_pages textless_pages ocr_pages sheets row_count line_count)
      )
      |> Map.put("format", format)

    if Ankole.Brain.FileText.table?(page),
      do: Map.put(coverage, "guidance", @table_guidance),
      else: coverage
  end

  defp file_coverage(_page), do: %{}
end
