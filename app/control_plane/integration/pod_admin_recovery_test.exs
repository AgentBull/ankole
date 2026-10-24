defmodule Ankole.PodAdminRecoveryIntegrationTest do
  use Ankole.DataCase, async: false

  @moduletag sandbox: false
  @moduletag timeout: 120_000

  test "the cold operator command recovers a Pod administrator through its configured enterprise login",
       %{tenant: tenant} do
    {:ok, previous_plugins} = Ankole.Plugins.enabled_ids()
    {:ok, previous_setup} = Ankole.Setup.Config.completed?()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.with_tenant(tenant.id, fn -> cleanup_tenant!(tenant) end)
        {:ok, _} = Ankole.Plugins.put_enabled_ids(previous_plugins)
        {:ok, _} = Ankole.AppConfigure.put_global_by_key("setup.completed", previous_setup)
      end)
    end)

    assert {:ok, _} = Ankole.Plugins.put_configured_enabled("lark-adapter", true)
    assert {:ok, _} = Ankole.AppConfigure.put_global_by_key("setup.completed", true)

    assert {:ok, _} =
             Ankole.IdentityProviders.save_provider(
               "lark-recovery",
               "lark",
               %{"appID" => "cli_recovery_" <> tenant.id, "appSecret" => "secret"},
               true
             )

    assert {:ok, %{principal: member}} =
             Ankole.Plugins.LarkAdapter.IdentityProvider.upsert_user("lark-recovery", %{
               "user_id" => "verified-operator-target"
             })

    refute Ankole.AuthZ.pod_admin?(member.uid)

    args = [
      member.uid,
      "operator",
      "verified with enterprise",
      "--identity-verified",
      "--tenant",
      tenant.slug
    ]

    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "--no-compile",
          "-e",
          "Mix.Tasks.Ankole.Admin.Recover.run(" <> inspect(args) <> ")"
        ],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Administrator access restored for #{member.uid}"
    assert Ankole.AuthZ.pod_admin?(member.uid)

    assert [%{action: "operator_admin_recovery", details: details}] =
             Ankole.Principals.HumanAccess.history(member.uid)

    assert details["identity_verified"]
    assert details["operator"] == "operator"
    assert details["group"] == "pod_admin"
  end
end
