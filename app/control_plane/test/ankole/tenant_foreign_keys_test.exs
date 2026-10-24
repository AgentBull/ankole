defmodule Ankole.TenantForeignKeysTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.AuthZ.{ExternalBinding, Grant, Membership}
  alias Ankole.OIDC
  alias Ankole.OIDC.ClientGroup

  setup do
    local = identities()
    foreign_tenant = create_tenant()
    foreign = Repo.with_tenant(foreign_tenant.id, &identities/0)
    %{local: local, foreign: foreign}
  end

  test "membership admission rejects a foreign Principal or group in the database", ctx do
    assert_rejected(
      Membership,
      :add_in_tx,
      %{
        principal_uid: ctx.foreign.human.uid,
        group_id: ctx.local.group.id
      },
      :principal_uid
    )

    assert_rejected(
      Membership,
      :add_in_tx,
      %{
        principal_uid: ctx.local.human.uid,
        group_id: ctx.foreign.group.id
      },
      :group_id
    )

    assert {:ok, membership} =
             Repo.transact(fn _repo ->
               Ankole.Ash.create(Membership, :add_in_tx, %{
                 principal_uid: ctx.local.human.uid,
                 group_id: ctx.local.group.id
               })
             end)

    assert membership.tenant_id == ctx.tenant.id
  end

  test "permission grants reject either foreign owner in the database", ctx do
    for {field, id} <- [
          principal_uid: ctx.foreign.human.uid,
          group_id: ctx.foreign.group.id
        ] do
      attrs = Map.put(%{resource_pattern: "tenant_console:**", action: "read"}, field, id)
      assert_rejected(Grant, :create_in_tx, attrs, field)
    end

    assert {:ok, grant} =
             Repo.transact(fn _repo ->
               Ankole.Ash.create(Grant, :create_in_tx, %{
                 principal_uid: ctx.local.human.uid,
                 resource_pattern: "tenant_console:**",
                 action: "read"
               })
             end)

    assert grant.tenant_id == ctx.tenant.id
  end

  test "provider bindings cannot assign a foreign group through their upsert action", ctx do
    attrs = %{
      provider: "tenant-boundary",
      external_kind: :directory_department,
      external_id: "department",
      group_id: ctx.foreign.group.id
    }

    assert_rejected(ExternalBinding, :bind_in_tx, attrs, :group_id)

    assert {:ok, binding} =
             Repo.transact(fn _repo ->
               Ankole.Ash.create(
                 ExternalBinding,
                 :bind_in_tx,
                 Map.put(attrs, :group_id, ctx.local.group.id)
               )
             end)

    assert binding.tenant_id == ctx.tenant.id
    before = Repo.get_by!(ExternalBinding, provider: "tenant-boundary", external_id: "department")
    assert_rejected(ExternalBinding, :bind_in_tx, attrs, :group_id)

    assert Repo.get_by!(ExternalBinding, provider: "tenant-boundary", external_id: "department") ==
             before
  end

  test "Client group links reject a foreign Client or group in the database", ctx do
    assert_rejected(
      ClientGroup,
      :link_in_tx,
      %{
        client_id: ctx.foreign.client.id,
        group_id: ctx.local.group.id
      },
      :client_id
    )

    assert_rejected(
      ClientGroup,
      :link_in_tx,
      %{
        client_id: ctx.local.client.id,
        group_id: ctx.foreign.group.id
      },
      :group_id
    )

    assert {:ok, link} =
             Repo.transact(fn _repo ->
               Ankole.Ash.create(ClientGroup, :link_in_tx, %{
                 client_id: ctx.local.client.id,
                 group_id: ctx.local.group.id
               })
             end)

    assert link.tenant_id == ctx.tenant.id
  end

  defp identities do
    %{principal: human} = human_fixture()

    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: unique_uid("tenant-boundary"),
        display_name: "Directory group",
        domain: :directory
      })

    {:ok, %{client: client}} =
      OIDC.create_client(%{
        name: "Tenant Client",
        type: "public",
        enabled: true,
        redirect_uris: ["https://rp.example/callback"],
        scopes: ["openid"]
      })

    %{human: human, group: group, client: client}
  end

  defp assert_rejected(resource, action, attrs, field) do
    count = Repo.aggregate(resource, :count)

    assert {:error, error} =
             Repo.transact(fn _repo -> Ankole.Ash.create(resource, action, attrs) end)

    assert Map.fetch!(errors_on(error), field) == ["does not exist"]
    assert Repo.aggregate(resource, :count) == count
  end
end
