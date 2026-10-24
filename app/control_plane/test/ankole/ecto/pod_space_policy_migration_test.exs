defmodule Ankole.Ecto.PodSpacePolicyMigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.AuthZ.Grant
  alias Ankole.Pod.{Access, Pages}

  @migration Ankole.Repo.Migrations.InitializePodSpacePolicy

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20261019120000_initialize_pod_space_policy.exs",
        __DIR__
      )
    )
  end

  test "upgrade initializes only tenants with neither Pages nor Page policy", %{tenant: content} do
    empty = create_tenant()
    policy = create_tenant()
    owner = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, _} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{})

    for tenant <- [content, empty, policy] do
      Repo.with_tenant(tenant.id, fn ->
        Repo.delete_all(from g in Grant, where: g.action in ^Access.page_actions())

        Repo.update_all(
          from(g in Ankole.AuthZ.Group, where: g.name == "all_humans"),
          set: [computed_condition: ~s(principal.type == "human" && principal.status == "active")]
        )
      end)
    end

    existing =
      Repo.with_tenant(policy.id, fn ->
        {:ok, group} = Access.space_group()

        {:ok, grant} =
          Ankole.AuthZ.create_permission_grant(%{
            group_id: group.id,
            resource_pattern: "pod:space:**",
            action: "page_view",
            condition: "false"
          })

        grant
      end)

    assert {:ok, :migrated} =
             Repo.transact(fn _repo ->
               Ecto.Migration.Runner.run(
                 Repo,
                 Repo.config(),
                 20_261_019_120_000,
                 @migration,
                 :forward,
                 :up,
                 :up,
                 log: false
               )

               {:ok, :migrated}
             end)

    assert Repo.all(Grant) == []

    Ankole.DataCase.assert_persisted_equal(
      Repo.with_tenant(policy.id, fn -> Repo.all(Grant) end),
      [existing]
    )

    assert Repo.with_tenant(empty.id, fn ->
             Repo.all(from g in Grant, order_by: g.action, select: {g.action, g.condition})
           end) == [{"page_edit", "true"}, {"page_manage", "true"}, {"page_view", "true"}]
  end
end
