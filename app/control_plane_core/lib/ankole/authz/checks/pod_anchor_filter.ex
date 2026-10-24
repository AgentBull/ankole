defmodule Ankole.AuthZ.Checks.PodAnchorFilter do
  @moduledoc false
  @behaviour Ankole.AuthZ.Check
  import Ash.Expr

  def check(actor, _query) do
    with :ok <- Ankole.Repo.require_transaction(),
         {:ok, reachable} <- Ankole.Pod.Access.Graph.reachable_anchors(actor) do
      {containers, pages} = Ankole.Pod.Access.Graph.visibility_ids(reachable)

      {:ok,
       %{
         filter:
           expr(
             is_nil(deleted_at) and
               (acl_anchor_id in ^containers or id in ^pages)
           ),
         reachable: reachable
       }}
    end
  end

  def project(pages, reachable) do
    Enum.map(pages, fn page ->
      # The anchor is the page itself exactly when their IDs are equal.
      page = %{page | is_acl_anchor: page.id == page.acl_anchor_id}

      %{
        page
        | role:
            Ankole.Pod.Access.Graph.role_for_actions(
              Ankole.Pod.Access.Graph.page_bits(page, reachable)
            )
      }
    end)
  end
end
