defmodule Ankole.Pod.GrantConcurrencyTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{AuthZ, Repo}
  alias Ankole.Pod.Pages

  test "an editor move serializes its tenant's revocation without blocking another tenant", %{
    tenant: tenant
  } do
    other = create_tenant()

    on_exit(fn ->
      for item <- [tenant, other] do
        Repo.with_tenant(item.id, fn ->
          for table <-
                (Ankole.Tenants.Jobs.Delete.tenant_tables() -- ["principals"]) ++ ["principals"] do
            Ecto.Adapters.SQL.query!(
              Repo,
              "DELETE FROM #{table} WHERE tenant_id=$1::text::uuid",
              [item.id]
            )
          end

          Repo.delete!(item)
        end)
      end
    end)

    owner = human_fixture().principal
    editor = agent_fixture().principal

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "**",
        action: "update"
      })

    {:ok, grant} =
      AuthZ.create_permission_grant(%{
        principal_uid: editor.uid,
        resource_pattern: "pod:space:**",
        action: "page_edit"
      })

    {:ok, root} = Pages.create(owner.uid, %{title: "Source"})
    {:ok, child} = Pages.create(owner.uid, %{parent_id: root.id, title: "Moving"})
    {:ok, destination} = Pages.create(owner.uid, %{title: "Target"})
    other_actor = Repo.with_tenant(other.id, fn -> human_fixture().principal end)
    parent = self()

    holder =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact(fn _ ->
            assert {:ok, _} = Pages.move(editor.uid, child.id, %{parent_id: destination.id})
            send(parent, :move_holds_tree)

            receive do
              :release_move -> {:ok, :moved}
            after
              5_000 -> {:error, :release_timeout}
            end
          end)
        end)
      )

    try do
      assert_receive :move_holds_tree, 2_000

      revoke =
        Task.async(
          Repo.bind_tenant(fn ->
            result = AuthZ.delete_permission_grant(grant.id)
            send(parent, :revocation_finished)
            result
          end)
        )

      other_write =
        Task.async(fn ->
          Repo.with_tenant(other.id, fn ->
            AuthZ.create_permission_grant(%{
              principal_uid: other_actor.uid,
              resource_pattern: "pod:space:**",
              action: "page_view"
            })
          end)
        end)

      assert {:ok, _} = Task.await(other_write, 2_000)
      refute_receive :revocation_finished, 100
      send(holder.pid, :release_move)
      assert {:ok, :moved} = Task.await(holder)
      assert {:ok, _} = Task.await(revoke)
      assert {:error, :forbidden} = Pages.move(editor.uid, child.id, %{parent_id: root.id})
    after
      send(holder.pid, :release_move)
    end
  end
end
