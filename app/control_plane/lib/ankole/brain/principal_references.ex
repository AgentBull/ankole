defmodule Ankole.Brain.PrincipalReferences do
  @moduledoc "Moves structured body references with a renamed Principal."
  require Ash.Query

  alias Ankole.Brain.{Chunks, Objects, Scope}
  alias Ankole.Brain.Schemas.{Object, ObjectVersion}
  alias Ankole.Repo

  def rename_in_tx(old_uid, new_uid, principal_type) do
    replacements = %{
      Scope.principal(old_uid) => Scope.principal(new_uid),
      Scope.principal_page_slug(principal_type, old_uid) =>
        Scope.principal_page_slug(principal_type, new_uid)
    }

    with :ok <- Repo.require_transaction(),
         :ok <- rewrite_rows(Object, replacements),
         :ok <- rewrite_rows(ObjectVersion, replacements),
         do: :ok
  end

  defp rewrite_rows(resource, replacements) do
    resource
    |> Ash.Query.filter(contains(body, "{%") or contains(body, "[["))
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!()
    |> Enum.reduce_while(:ok, fn row, :ok ->
      with {:ok, body} <- Ankole.Kernel.brain_markdoc_rewrite_references(row.body, replacements),
           :ok <- save_body(row, body) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp save_body(%{body: body}, body), do: :ok

  defp save_body(%Object{} = object, body) do
    with {:ok, object} <- Ankole.Ash.update(object, :rename_references, %{body: body}),
         {:ok, object} <- Objects.refresh_content_hash_in_tx(object),
         {:ok, _object} <- Chunks.reconcile_in_tx(object),
         do: :ok
  end

  defp save_body(%ObjectVersion{} = version, body) do
    with {:ok, _version} <- Ankole.Ash.update(version, :rename_references, %{body: body}),
         do: :ok
  end
end
