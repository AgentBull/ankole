defmodule Ankole.E2E.AuthnComposeTest do
  use ExUnit.Case, async: false
  alias Ankole.E2E.ComposeDeployment, as: Compose
  @moduletag timeout: 600_000
  @moduletag :authn_compose
  @moduletag :compose_upgrade

  test "a fresh release completes real SMTP setup and keeps the same two administrator roles after restart" do
    {deployment, uid} = Compose.start!(:source) |> Compose.setup_admin!()
    groups = Compose.api!(deployment, :get, "/api/v2/principal-groups")["data"]

    for name <- ["siteadmin", "pod_admin"] do
      assert Enum.any?(
               groups,
               &(&1["attributes"]["name"] == name and &1["attributes"]["built_in"])
             )
    end

    assert %{"data" => %{"id" => ^uid}} =
             Compose.api!(deployment, :get, "/api/v2/principals/#{uid}")

    assert [mail] =
             query(
               deployment,
               "SELECT value->>'type' FROM site_app_configurations WHERE key='authn.email.mail'"
             )

    assert mail == "cipher"

    assert query(
             deployment,
             "SELECT identifier FROM principal_site_credentials WHERE principal_uid='#{uid}'"
           ) == ["compose-e2e@example.test"]

    Compose.compose!(deployment, ["restart", "control-plane"])
    deployment = Compose.wait_http!(deployment)

    assert %{"data" => %{"id" => ^uid}} =
             Compose.api!(deployment, :get, "/api/v2/principals/#{uid}")
  end

  test "a pinned password release upgrades to the shared email proof without changing the Human UID" do
    {deployment, uid} = Compose.start!(:pooled) |> Compose.setup_admin!()
    deployment = Compose.upgrade!(deployment)

    assert %{"data" => %{"id" => ^uid}} =
             Compose.api!(deployment, :get, "/api/v2/principals/#{uid}")

    assert query(
             deployment,
             "SELECT identifier FROM principal_site_credentials WHERE principal_uid='#{uid}'"
           ) == ["compose-e2e@example.test"]

    assert query(deployment, "SELECT to_regclass('public.human_user_local_credentials') IS NULL") ==
             ["t"]

    assert query(
             deployment,
             "SELECT count(*) FROM principal_group_memberships m JOIN principal_groups g ON g.id=m.group_id WHERE m.principal_uid='#{uid}' AND g.name IN ('siteadmin','pod_admin')"
           ) == ["2"]
  end

  defp query(deployment, sql) do
    Compose.compose!(deployment, [
      "exec",
      "-T",
      "postgresql",
      "psql",
      "-U",
      "ankole",
      "-d",
      "ankole",
      "-Atc",
      sql
    ])
    |> String.split("\n", trim: true)
  end
end
