defmodule Ankole.Pod.Documents.PrincipalMentions do
  @moduledoc "Updates canonical mentions when a tenant Principal changes its name."
  require Ash.Query
  alias Ankole.{AuthZ, Repo}
  alias Ankole.Pod.{Documents, PageComment, PageContent, PageSnapshot, Pages}

  def rename_in_tx(old_uid, new_uid) do
    unless Repo.in_transaction?(),
      do:
        raise(Ankole.Errors.Framework.TransactionRequired, operation: {__MODULE__, :rename_in_tx})

    {:ok, system} = Ankole.Principals.system_principal()
    actor = AuthZ.Actor.new(system)

    contents =
      PageContent |> Ash.Query.filter(contains(content, "<mention")) |> Ankole.Ash.read!()

    with {:ok, pages} <- rename_documents(contents, old_uid, new_uid, actor),
         {:ok, snapshots} <- rename_snapshots(old_uid, new_uid),
         {:ok, comments} <- rename_comments(old_uid, new_uid) do
      {:ok, Enum.uniq(pages ++ snapshots ++ comments)}
    end
  end

  def publish(page_ids) do
    Enum.each(page_ids, fn id ->
      Pages.broadcast(id)
      Pages.broadcast_comments(id)
    end)
  end

  defp rename_documents(contents, old, new, actor) do
    Enum.reduce_while(contents, {:ok, []}, fn before, {:ok, ids} ->
      with {:ok, page} <- Pages.lock(before.page_id),
           content <-
             PageContent |> Ash.Query.filter(page_id == ^page.id) |> Ankole.Ash.read_one!(),
           {:ok, parsed} <- Ankole.Kernel.page_rename_principal(content.content, old, new),
           true <- parsed.xml != content.content,
           {:ok, %{page: page}} <-
             Documents.commit_parsed_in_tx(page, content, actor, parsed, attribution: false) do
        {:cont, {:ok, [page.id | ids]}}
      else
        false -> {:cont, {:ok, ids}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp rename_snapshots(old, new) do
    PageSnapshot
    |> Ash.Query.filter(contains(content, "<mention"))
    |> Ankole.Ash.read!()
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, ids} ->
      with {:ok, parsed} <- Ankole.Kernel.page_rename_principal(row.content, old, new),
           true <- parsed.xml != row.content,
           {:ok, _row} <- Ankole.Ash.update(row, :rename_mentions, %{content: parsed.xml}) do
        {:cont, {:ok, [row.page_id | ids]}}
      else
        {:error, _} = error -> {:halt, error}
        _unchanged -> {:cont, {:ok, ids}}
      end
    end)
  end

  defp rename_comments(old, new) do
    PageComment
    |> Ash.Query.filter(contains(body, "<mention") or contains(body, "(principal:"))
    |> Ankole.Ash.read!()
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, ids} ->
      with {:ok, _page} <- Pages.lock(row.page_id) do
        row =
          PageComment
          |> Ash.Query.filter(id == ^row.id)
          |> Ash.Query.lock(:for_update)
          |> Ankole.Ash.read_one!()

        body = rewrite_comment(row.body, old, new)

        if body == row.body do
          {:cont, {:ok, ids}}
        else
          with {:ok, _row} <- Ankole.Ash.update(row, :change_in_tx, %{body: body}) do
            {:cont, {:ok, [row.page_id | ids]}}
          else
            {:error, _} = error -> {:halt, error}
          end
        end
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Comments contain Markdown. Only canonical mention fragments enter the XML
  # codec; the surrounding prose and formatting keep their original bytes.
  defp rewrite_comment(body, old, new) do
    Ankole.Plugins.MarkdownChunks.rewrite_prose(body, fn prose, _marker ->
      prose = Ankole.Pod.Comments.rename_markdown_mentions(prose, old, new)

      Regex.replace(~r/<mention\s[^<>]*\/>/, prose, fn mention ->
        xml = "<page><p>#{mention}</p></page>"

        case Ankole.Kernel.page_rename_principal(xml, old, new) do
          {:ok, %{xml: ^xml}} -> mention
          {:ok, %{xml: "<page><p>" <> updated}} -> String.trim_trailing(updated, "</p></page>")
          {:error, _invalid_fragment} -> mention
        end
      end)
    end)
  end
end
