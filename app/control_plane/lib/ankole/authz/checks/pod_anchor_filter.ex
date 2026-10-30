defmodule Ankole.AuthZ.Checks.PodAnchorFilter do
  @moduledoc false
  @behaviour Ankole.AuthZ.Check
  import Ash.Expr
  import Bitwise

  def apply_policy(query, actor, policy) do
    query
    |> Ash.Query.ensure_selected([:id, :acl_anchor_id])
    |> Ash.Query.set_context(%{private: %{pod_authorization: {actor, policy}}})
    |> Ash.Query.after_action(fn _query, pages -> {:ok, project(pages, policy.reachable)} end)
  end

  def check(actor, query) do
    with :ok <- Ankole.Repo.require_transaction(),
         {:ok, reachable} <- Ankole.Pod.Access.Graph.reachable_anchors(actor) do
      required_action = Ash.Query.get_argument(query, :required_action) || :page_view
      {:ok, policy(reachable, required_action)}
    end
  end

  def policy(reachable, required_action \\ :page_view) do
    required_bits = bor(1, Ankole.Pod.Access.Graph.action_bit(to_string(required_action)))
    {containers, pages} = Ankole.Pod.Access.Graph.visibility_ids(reachable, required_bits)

    %{
      filter:
        expr(
          is_nil(deleted_at) and
            (acl_anchor_id in ^containers or id in ^pages)
        ),
      reachable: reachable
    }
  end

  def project(pages, reachable) do
    Enum.map(pages, fn page ->
      # The anchor is the page itself exactly when their IDs are equal.
      page = %{page | is_acl_anchor: page.id == page.acl_anchor_id}

      Ankole.Pod.Access.Graph.project_permissions(
        page,
        Ankole.Pod.Access.Graph.page_bits(page, reachable)
      )
    end)
  end
end
