defmodule Ankole.AuthZ.Checks.DriveAnchorFilter do
  @moduledoc false
  @behaviour Ankole.AuthZ.Check
  import Ash.Expr
  import Bitwise

  def apply_policy(query, actor, policy) do
    query
    |> Ash.Query.ensure_selected([:id, :acl_anchor_id])
    |> Ash.Query.set_context(%{private: %{drive_authorization: {actor, policy}}})
    |> Ash.Query.after_action(fn _query, pages -> {:ok, project(pages, policy.reachable)} end)
  end

  def check(actor, query) do
    with :ok <- Ankole.Repo.require_transaction(),
         {:ok, reachable} <- Ankole.Files.Access.Graph.reachable_anchors(actor) do
      required_action = Ash.Query.get_argument(query, :required_action) || :node_view
      {:ok, policy(reachable, required_action)}
    end
  end

  def policy(reachable, required_action \\ :node_view) do
    required_bits = bor(1, Ankole.Files.Access.Graph.action_bit(to_string(required_action)))
    {containers, pages} = Ankole.Files.Access.Graph.visibility_ids(reachable, required_bits)

    %{
      filter:
        expr(
          is_nil(deleted_at) and
            ((not is_acl_anchor and acl_anchor_id in ^containers) or
               (is_acl_anchor and id in ^pages))
        ),
      reachable: reachable
    }
  end

  def project(pages, reachable) do
    Enum.map(pages, fn page ->
      # The anchor is the page itself exactly when their IDs are equal.
      page = %{page | is_acl_anchor: page.id == page.acl_anchor_id}

      Ankole.Files.Access.Graph.project_permissions(
        page,
        Ankole.Files.Access.Graph.page_bits(page, reachable)
      )
    end)
  end
end
