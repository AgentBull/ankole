defmodule Ankole.Pod.Pages.PagePreview do
  @moduledoc """
  Reads a live Page's title, domain, icon, and bounded excerpt for tenant-opted-in
  link previews.
  """

  require Ash.Expr
  require Ash.Query

  alias Ankole.Pod.{Files, Knowledge, Page, PageContent, PageSearchDocument, Pages}
  alias Ankole.Pod.Pages.Tree
  alias Ankole.Repo

  @preview_prefix_chars 600
  @preview_excerpt_graphemes 180

  @spec link_preview(String.t()) :: {:ok, map()} | {:error, :not_found}
  def link_preview(page_id) when is_binary(page_id) do
    case Ecto.UUID.cast(page_id) do
      {:ok, id} -> Repo.transact_repeatable_read_only(fn -> link_preview_in_tx(id) end)
      :error -> {:error, :not_found}
    end
  end

  def link_preview(_page_id), do: {:error, :not_found}

  defp link_preview_in_tx(id) do
    page =
      Page
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.select([
        :id,
        :parent_id,
        :title,
        :name,
        :type,
        :icon,
        :metadata,
        :system_key,
        :is_root,
        :updated_at,
        :deleted_at,
        :purge_started_at
      ])
      |> Ankole.Ash.read_one!()

    with %Page{
           is_root: false,
           parent_id: parent_id,
           system_key: nil,
           deleted_at: nil,
           purge_started_at: nil
         }
         when is_binary(parent_id) <- page,
         {:ok, domain} <- live_domain(page.id) do
      {:ok,
       %{
         id: page.id,
         title: String.trim(page.title || ""),
         name: String.trim(page.name || ""),
         type: page.type,
         domain: domain,
         emoji_icon: if(Pages.emoji_icon?(page.icon), do: page.icon),
         excerpt: preview_excerpt(page),
         file: preview_file(page),
         updated_at: page.updated_at
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp live_domain(page_id) do
    ancestor_ids = Tree.ancestor_ids([page_id])

    ancestors =
      if ancestor_ids == [] do
        []
      else
        Page
        |> Ash.Query.filter(id in ^ancestor_ids)
        |> Ash.Query.select([:id, :parent_id, :system_key, :deleted_at, :purge_started_at])
        |> Ankole.Ash.read!()
      end

    live_chain? =
      length(ancestors) == length(ancestor_ids) and
        Enum.any?(ancestors, &is_nil(&1.parent_id)) and
        Enum.all?(ancestors, fn node ->
          is_nil(node.deleted_at) and is_nil(node.purge_started_at) and
            node.system_key != "ankole_brain_sources"
        end)

    cond do
      not live_chain? -> :error
      Enum.any?(ancestors, &(&1.system_key == "ankole_brain")) -> {:ok, :brain}
      true -> {:ok, :pages}
    end
  end

  defp preview_file(%Page{type: :file, id: id}) do
    case Map.get(Files.primary_files_by_page([id]), id) do
      %{path: path, size: size, content_type: content_type} ->
        %{path: path, size: size, content_type: content_type}

      _ ->
        nil
    end
  end

  defp preview_file(_page), do: nil

  defp preview_excerpt(%Page{type: :doc, id: id}), do: compact_excerpt(content_prefix(id))

  defp preview_excerpt(%Page{type: :knowledge, id: id, metadata: metadata}) do
    case compact_excerpt(Knowledge.summary(metadata)) do
      "" -> compact_excerpt(content_prefix(id))
      summary -> summary
    end
  end

  defp preview_excerpt(%Page{type: :base, id: id}),
    do: compact_excerpt(search_doc_prefix(id, :meta_text))

  defp preview_excerpt(%Page{type: :file, id: id}),
    do: compact_excerpt(search_doc_prefix(id, :body_text))

  defp preview_excerpt(%Page{type: :applet}), do: ""

  defp content_prefix(page_id) do
    row =
      PageContent
      |> Ash.Query.filter(page_id == ^page_id)
      |> Ash.Query.select([:page_id])
      |> Ash.Query.calculate(
        :prefix,
        :string,
        Ash.Expr.expr(fragment("left(?, ?)", plain_text, ^@preview_prefix_chars))
      )
      |> Ankole.Ash.read_one!()

    if row, do: row.calculations.prefix || "", else: ""
  end

  defp search_doc_prefix(page_id, field) when field in [:meta_text, :body_text] do
    expr =
      case field do
        :meta_text -> Ash.Expr.expr(fragment("left(?, ?)", meta_text, ^@preview_prefix_chars))
        :body_text -> Ash.Expr.expr(fragment("left(?, ?)", body_text, ^@preview_prefix_chars))
      end

    row =
      PageSearchDocument
      |> Ash.Query.filter(page_id == ^page_id)
      |> Ash.Query.select([:page_id])
      |> Ash.Query.calculate(:prefix, :string, expr)
      |> Ankole.Ash.read_one!()

    if row, do: row.calculations.prefix || "", else: ""
  end

  defp compact_excerpt(text) when is_binary(text) do
    collapsed =
      text
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if String.length(collapsed) > @preview_excerpt_graphemes do
      String.slice(collapsed, 0, @preview_excerpt_graphemes) <> "…"
    else
      collapsed
    end
  end

  defp compact_excerpt(_text), do: ""
end
