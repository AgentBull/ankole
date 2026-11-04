defmodule Ankole.Connectors.WorkerDiscoveryTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Connectors.{Accounts, Store, Tokens}

  test "live Turns discover active application slots without personal accounts or credentials" do
    human = human_fixture().principal
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(human.uid) end)

    {:ok, config} =
      Store.create_auth_config(human, %{
        "plugin_id" => "github",
        "slug" => "engineering",
        "display_name" => "Engineering",
        "auth_scheme" => "oauth2",
        "secret" => %{"clientID" => "discovery", "clientSecret" => "root-secret"}
      })

    {:ok, _} =
      Repo.transact_top_level(fn ->
        for key <- ["42", "org.two"] do
          {:ok, _} =
            Accounts.put_tokens_in_tx(config, "app", key, %{"access_token" => "app-secret"}, %{})
        end

        {:ok, revoked} =
          Accounts.put_tokens_in_tx(config, "app", "revoked", %{"access_token" => "old"}, %{})

        Accounts.revoke(revoked)
      end)

    {:ok, _} =
      Accounts.put_human_tokens(config.id, human.uid, %{"access_token" => "personal-secret"})

    agent = agent_fixture().principal
    signal = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)

    ref = %Ankole.Sessions.RunRef{
      agent_uid: agent.uid,
      session_id: signal.session_id,
      signal_id: signal.id
    }

    assert {:ok, env} = Tokens.worker(agent.uid, ref)
    metadata = env["ANKOLE_MCP_CONNECTIONS"]

    assert Torque.decode!(metadata)["github"] == [
             %{
               "connection" => "engineering",
               "label" => "Engineering",
               "accounts" => ["42", "org.two"]
             }
           ]

    for hidden <- [human.uid, "secret", "revoked"], do: refute(String.contains?(metadata, hidden))

    {:ok, _} = Store.update_auth_config(human, config.id, %{"status" => "disabled"})
    assert {:ok, env} = Tokens.worker(agent.uid, ref)
    assert Torque.decode!(env["ANKOLE_MCP_CONNECTIONS"])["github"] == []
  end
end
