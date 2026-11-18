defmodule AnkoleWeb.PodAgentUIChannelTest do
  use AnkoleWeb.ChannelCase, async: false
  import Ankole.PrincipalsFixtures
  require Ash.Query
  alias Ankole.{BrowserSessions, Repo}
  alias Ankole.Pod.AgentUIRequest
  alias AnkoleWeb.{PodAgentUIChannel, PodSocket}

  setup do
    alice = human_fixture(%{display_name: "Alice"}).principal
    bob = human_fixture().principal
    agent = Ankole.SessionsCase.agent_fixture(%{display_name: "Helper"}).principal
    %{alice: alice, bob: bob, agent: agent}
  end

  test "a request reaches only its Human's tabs, one tab claims it, and the answer is stored",
       ctx do
    {:ok, _, alice_tab} = subscribe_and_join(socket_for(ctx.alice), PodAgentUIChannel, "agent_ui")
    {:ok, _, bob_tab} = subscribe_and_join(socket_for(ctx.bob), PodAgentUIChannel, "agent_ui")

    request = open!(ctx.agent.uid, ctx.alice.uid)
    Ankole.Pod.AgentUI.publish(request)
    id = request.id
    agent_uid = ctx.agent.uid

    assert_push "request",
                %{id: ^id, operation: "act", agent: %{uid: ^agent_uid, name: "Helper"}},
                1_000

    refute_push "request", _, 100

    # Bob cannot claim or answer Alice's request.
    ref = push(bob_tab, "claim", %{"id" => id})
    assert_reply ref, :error, %{reason: "not_found"}

    ref = push(alice_tab, "claim", %{"id" => id})
    assert_reply ref, :ok
    ref = push(alice_tab, "claim", %{"id" => id})
    assert_reply ref, :error, %{reason: "taken"}

    ref = push(alice_tab, "result", %{"id" => id, "result" => %{"ok" => true}})
    assert_reply ref, :ok

    assert %{status: :done, result: %{"ok" => true}} = read!(id)

    ref = push(alice_tab, "result", %{"id" => id, "error" => "late"})
    assert_reply ref, :error, %{reason: "not_found"}
  end

  test "a tab that opens late receives the requests that still wait for a tab", ctx do
    request = open!(ctx.agent.uid, ctx.alice.uid)
    id = request.id
    {:ok, _, _tab} = subscribe_and_join(socket_for(ctx.alice), PodAgentUIChannel, "agent_ui")
    assert_push "request", %{id: ^id}, 1_000
  end

  test "a failed run on the page is stored as the request's error", ctx do
    {:ok, _, tab} = subscribe_and_join(socket_for(ctx.alice), PodAgentUIChannel, "agent_ui")
    request = open!(ctx.agent.uid, ctx.alice.uid)
    Ankole.Pod.AgentUI.publish(request)
    assert_push "request", _, 1_000

    ref = push(tab, "result", %{"id" => request.id, "error" => "too early"})
    assert_reply ref, :error, %{reason: "not_found"}

    ref = push(tab, "claim", %{"id" => request.id})
    assert_reply ref, :ok
    ref = push(tab, "result", %{"id" => request.id, "error" => "Nothing is named Region."})
    assert_reply ref, :ok
    assert %{status: :failed, error: "Nothing is named Region."} = read!(request.id)
  end

  defp open!(agent_uid, principal_uid) do
    Ankole.Ash.create!(AgentUIRequest, :open_in_tx, %{
      agent_uid: agent_uid,
      principal_uid: principal_uid,
      operation: :act,
      arguments: %{"steps" => []}
    })
  end

  defp read!(id), do: Ankole.Ash.read_one!(Ash.Query.filter(AgentUIRequest, id == ^id))

  defp socket_for(principal) do
    {:ok, browser} = BrowserSessions.create()

    {:ok, %{authentication: auth}} =
      BrowserSessions.authenticate(BrowserSessions.reference(browser), %{
        "principal_uid" => principal.uid,
        "access_version" => principal.access_version,
        "provider_id" => "lark-main",
        "external_id" => principal.uid
      })

    token =
      Phoenix.Token.sign(AnkoleWeb.Endpoint, "pod-socket", %{
        tenant_id: Repo.tenant_id!(),
        uid: principal.uid,
        authentication: BrowserSessions.reference(auth)
      })

    {:ok, tenant} = Ankole.Tenants.get(Repo.tenant_id!())
    origin = AnkoleWeb.PodURL.origin(%{scheme: :http, port: 80}, tenant)

    {:ok, socket} =
      connect(PodSocket, %{"token" => token},
        connect_info: %{uri: URI.parse(origin), peer_data: %{address: {127, 0, 0, 1}}}
      )

    socket
  end
end
