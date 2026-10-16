defmodule Ankole.BrowserAuthenticationsIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  alias Ankole.BrowserSessions
  import Ankole.PrincipalsFixtures

  setup %{tenant: tenant} do
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    %{principal: first} = human_fixture()
    %{principal: second} = human_fixture()
    {:ok, browser} = BrowserSessions.create()

    on_exit(fn ->
      Repo.delete!(browser)
      {:ok, _} = Ankole.Tenants.delete(tenant)
      job = %Oban.Job{args: %{"tenant_id" => tenant.id}}

      result =
        Enum.reduce_while(1..20, nil, fn _, _ ->
          case Ankole.Tenants.Jobs.Delete.run(job) do
            {:snooze, _} -> {:cont, nil}
            result -> {:halt, result}
          end
        end)

      assert result == :ok

      Repo.delete_all(
        from j in Oban.Job, where: fragment("?->>'tenant_id'", j.args) == ^tenant.id
      )
    end)

    {:ok, browser: BrowserSessions.reference(browser), first: first, second: second}
  end

  test "independent callbacks wait on the browser row, then both commit", context do
    %{browser: browser, first: a, second: b} = context
    [flow_a, flow_b] = for _ <- 1..2, do: flow(browser)
    {first, second} = race(browser, flow_a, a, flow_b, b)
    assert {:ok, a_login} = first
    assert {:ok, b_login} = second

    for {login, human} <- [{a_login, a}, {b_login, b}] do
      reference = BrowserSessions.reference(login.authentication)
      assert BrowserSessions.authentication(reference, :pod)["principal_uid"] == human.uid
    end
  end

  test "two callbacks for one subject cannot replace each other's committed proof", context do
    %{browser: browser, first: human} = context
    [first_flow, second_flow] = for _ <- 1..2, do: flow(browser)
    {first, second} = race(browser, first_flow, human, second_flow, human)
    assert {:ok, login} = first
    assert {:error, :login_expired} = second
    assert BrowserSessions.authentication(BrowserSessions.reference(login.authentication), :pod)
  end

  test "logout confirmation cannot include authentication added while it waits for the lock",
       context do
    %{browser: browser, first: a, second: b} = context
    {:ok, a_login} = BrowserSessions.complete_login(browser, flow(browser).id, auth(a))
    {:ok, request} = Ankole.OIDC.RPLogout.prepare(browser, %{})
    new_login = flow(browser)

    {first, second} =
      race(
        fn wait -> BrowserSessions.complete_login(browser, new_login.id, auth(b), wait) end,
        fn -> Ankole.OIDC.RPLogout.confirm(browser, request.id) end
      )

    assert {:ok, b_login} = first
    assert {:error, :logout_request_expired} = second
    assert BrowserSessions.authentication(BrowserSessions.reference(a_login.authentication), :pod)
    assert BrowserSessions.authentication(BrowserSessions.reference(b_login.authentication), :pod)
  end

  defp race(browser, first_flow, first_human, second_flow, second_human) do
    race(
      fn wait ->
        BrowserSessions.complete_login(browser, first_flow.id, auth(first_human), wait)
      end,
      fn -> BrowserSessions.complete_login(browser, second_flow.id, auth(second_human)) end
    )
  end

  defp race(first_operation, second_operation) do
    owner = self()

    first =
      Task.async(
        Repo.bind_tenant(fn ->
          first_operation.(fn ->
            send(owner, :first_locked)
            receive do: (:commit -> :ok), after: (5_000 -> {:error, :barrier_timeout})
          end)
        end)
      )

    assert_receive :first_locked, 5_000

    second =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact(fn repo ->
            %{rows: [[pid]]} = repo.query!("SELECT pg_backend_pid()")
            send(owner, {:second_backend, pid})
            second_operation.()
          end)
        end)
      )

    assert_receive {:second_backend, pid}, 5_000
    assert_waiting(pid)
    send(first.pid, :commit)
    {Task.await(first), Task.await(second)}
  end

  defp assert_waiting(pid, remaining \\ 200) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [pid])

    unless blocked do
      assert remaining > 0, "the second callback never waited on the browser row"
      receive after: (5 -> :ok)
      assert_waiting(pid, remaining - 1)
    end
  end

  defp flow(browser) do
    {:ok, transaction} = BrowserSessions.begin_login(browser, :pod, %{}, mode: :add)
    {:ok, transaction} = BrowserSessions.bind_provider(browser, transaction.id, "local")
    transaction
  end

  defp auth(human),
    do: %{
      "principal_uid" => human.uid,
      "access_version" => human.access_version,
      "provider_id" => "local",
      "external_id" => human.uid,
      "auth_time" => System.system_time(:second)
    }
end
