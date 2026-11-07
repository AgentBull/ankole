defmodule Ankole.Plugins.ConnectionLifecycleClusterTest do
  use Ankole.DataCase, async: false

  @moduletag :cluster
  @moduletag sandbox: false
  @moduletag timeout: 120_000

  import Ankole.PrincipalsFixtures

  alias Ankole.Plugins.ConnectionClusterProbe
  alias Ankole.Plugins.ConnectionLifecycle.Cluster

  setup do
    ensure_distributed_node!()
    :ok
  end

  test "keeps one owner across two BEAM nodes, refuses split-brain on RPC timeout, and propagates updates and disables" do
    {_peer, remote} = start_peer!()
    %{principal: agent} = agent_fixture()

    assert {:ok, binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "main",
               adapter: "connection_lifecycle_cluster_test",
               config_ref: "app",
               filters: %{"cel" => "v1"}
             })

    {:ok, remote_sup} =
      :erpc.call(remote, ConnectionClusterProbe, :start_runtime_link, [
        [interval_ms: nil, observer: self(), peer_rpc_timeout_ms: 80]
      ])

    on_exit(fn -> stop_remote_supervisor(remote, remote_sup) end)

    assert_receive {:cluster_owner_started, ^remote, "app", first_owner, %{"secret" => "v1"}},
                   5_000

    assert node(first_owner) == remote

    start_supervised!(
      ConnectionClusterProbe.runtime_spec(
        interval_ms: nil,
        observer: self(),
        peer_rpc_timeout_ms: 80
      )
    )

    refute_receive {:cluster_owner_started, _, "app", _, _}, 150
    assert %{started: 1, errors: []} = ConnectionClusterProbe.reconcile()
    assert :erpc.call(remote, ConnectionClusterProbe, :registered_keys, []) == ["app"]
    assert ConnectionClusterProbe.registered_keys() == []

    # Rotating configuration from the local node replaces the owner on the remote node in place.
    assert {:ok, binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(binding, %{filters: %{"cel" => "v2"}})

    assert %{started: 1, errors: []} = ConnectionClusterProbe.reconcile()

    assert_receive {:cluster_owner_started, ^remote, "app", rotated_owner, %{"secret" => "v2"}},
                   5_000

    refute rotated_owner == first_owner
    refute :erpc.call(remote, Process, :alive?, [first_owner])
    assert :erpc.call(remote, ConnectionClusterProbe, :registered_keys, []) == ["app"]
    assert ConnectionClusterProbe.registered_keys() == []

    # Regression for Finding #2: when the peer reconcile RPC times out while the remote
    # owner is still alive, the caller must report an error and NEVER preempt or start a second owner.
    locker = :erpc.call(remote, ConnectionClusterProbe, :hold_registry_lock, ["app", self()])
    assert_receive {:registry_lock_held, ^locker}, 2_000

    assert %{started: 0, errors: [%{reason: {:peer_reconcile_failed, :timeout}}]} =
             ConnectionClusterProbe.reconcile()

    refute_receive {:cluster_owner_started, _, "app", _, _}, 150
    assert ConnectionClusterProbe.registered_keys() == []
    assert :erpc.call(remote, Process, :alive?, [rotated_owner])

    assert :global.whereis_name({Cluster, :owner, ConnectionClusterProbe, "app"}) ==
             rotated_owner

    send(locker, :release_registry_lock)
    assert %{started: 1, errors: []} = ConnectionClusterProbe.reconcile()
    assert :erpc.call(remote, ConnectionClusterProbe, :registered_keys, []) == ["app"]
    assert ConnectionClusterProbe.registered_keys() == []

    # Disabling the binding from the local node stops the remote owner across the cluster.
    binding |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    assert %{started: 0, stopped: 1, errors: []} = ConnectionClusterProbe.reconcile()
    refute :erpc.call(remote, Process, :alive?, [rotated_owner])
    assert :erpc.call(remote, ConnectionClusterProbe, :registered_keys, []) == []
    assert ConnectionClusterProbe.registered_keys() == []
    assert :global.whereis_name({Cluster, :owner, ConnectionClusterProbe, "app"}) == :undefined
  end

  test "hands over blocked connections during EndpointDrain and fails over immediately on peer crash" do
    {peer, remote} = start_peer!()
    %{principal: agent} = agent_fixture()

    assert {:ok, binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "handover",
               adapter: "connection_lifecycle_cluster_test",
               config_ref: "handover"
             })

    {:ok, remote_sup} =
      :erpc.call(remote, ConnectionClusterProbe, :start_runtime_link, [
        [interval_ms: nil, observer: self()]
      ])

    on_exit(fn -> stop_remote_supervisor(remote, remote_sup) end)

    assert_receive {:cluster_owner_started, ^remote, "handover", remote_owner, _}, 5_000

    start_supervised!(ConnectionClusterProbe.runtime_spec(interval_ms: nil, observer: self()))
    assert %{started: 1, errors: []} = ConnectionClusterProbe.reconcile()
    assert :erpc.call(remote, ConnectionClusterProbe, :registered_keys, []) == ["handover"]
    assert ConnectionClusterProbe.registered_keys() == []

    # Once the binding becomes blocked, both nodes surface the blocked error while preserving
    # the single live owner on `remote` and caching its start arguments on `node()`.
    binding |> Ecto.Changeset.change(config_ref: "blocked") |> Repo.update!()

    assert %{started: 0, errors: [%{reason: :runtime_bot_identity_unavailable}]} =
             :erpc.call(remote, ConnectionClusterProbe, :reconcile, [])

    assert %{started: 0, errors: [%{reason: :runtime_bot_identity_unavailable}]} =
             ConnectionClusterProbe.reconcile()

    refute_receive {:cluster_owner_started, _, "handover", _, _}, 100

    # Entering graceful EndpointDrain on `remote` (`Supervisor.terminate_child/2`, matching
    # `Ankole.Supervisor` shutdown order on SIGTERM) broadcasts over distributed PubSub,
    # stops `remote_owner`, and hands the blocked connection over to `node()`.
    assert :ok =
             :erpc.call(remote, Supervisor, :terminate_child, [
               Ankole.Supervisor,
               AnkoleWeb.EndpointDrain
             ])

    local_node = node()
    assert_receive {:cluster_owner_started, ^local_node, "handover", local_owner, _}, 5_000
    assert :erpc.call(remote, AnkoleWeb.EndpointDrain, :draining?, [])
    refute :erpc.call(remote, Process, :alive?, [remote_owner])
    assert :erpc.call(remote, ConnectionClusterProbe, :registered_keys, []) == []
    assert ConnectionClusterProbe.registered_keys() == ["handover"]

    assert :global.whereis_name({Cluster, :owner, ConnectionClusterProbe, "handover"}) ==
             local_owner

    # Now launch a fresh second peer, transfer ownership to it by stopping the local runtime,
    # and then kill that peer abruptly (`:peer.stop/1`) to verify `:noconnection` crash failover.
    {second_peer, second_remote} = start_peer!()

    {:ok, second_sup} =
      :erpc.call(second_remote, ConnectionClusterProbe, :start_runtime_link, [
        [interval_ms: nil, observer: self()]
      ])

    on_exit(fn -> stop_remote_supervisor(second_remote, second_sup) end)

    assert %{started: 0, errors: [%{reason: :runtime_bot_identity_unavailable}]} =
             :erpc.call(second_remote, ConnectionClusterProbe, :reconcile, [])

    stop_supervised!(ConnectionClusterProbe)

    assert_receive {:cluster_owner_started, ^second_remote, "handover", second_owner, _}, 5_000
    refute Process.alive?(local_owner)
    assert :erpc.call(second_remote, ConnectionClusterProbe, :registered_keys, []) == ["handover"]

    # Restart local runtime so it monitors `second_owner`, then abruptly stop `second_peer`.
    start_supervised!(ConnectionClusterProbe.runtime_spec(interval_ms: nil, observer: self()))

    assert %{started: 0, errors: [%{reason: :runtime_bot_identity_unavailable}]} =
             ConnectionClusterProbe.reconcile()

    :ok = :peer.stop(second_peer)
    :ok = :peer.stop(peer)

    assert_receive {:cluster_owner_started, ^local_node, "handover", crash_recovered_owner, _},
                   5_000

    refute crash_recovered_owner == second_owner
    assert ConnectionClusterProbe.registered_keys() == ["handover"]
  end

  defp ensure_distributed_node! do
    if not Node.alive?() do
      _ = System.cmd("epmd", ["-daemon"])
      name = :"ankole_conn_primary_#{System.unique_integer([:positive])}"
      {:ok, _} = Node.start(name, :shortnames)
    end
  end

  defp stop_remote_supervisor(remote, sup_pid) do
    if remote in Node.list() do
      try do
        :erpc.call(remote, Supervisor, :stop, [sup_pid, :normal, 5_000], 5_000)
      catch
        _, _ -> :ok
      end
    end
  end

  defp start_peer! do
    name = String.to_atom("ankole_conn_peer_#{System.unique_integer([:positive])}")

    {:ok, peer, remote} =
      :peer.start(%{
        name: name,
        longnames: :net_kernel.longnames(),
        host:
          node() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist(),
        connection: :standard_io,
        args:
          [~c"+S", ~c"2:2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie()), ~c"-pa"] ++
            :code.get_path(),
        wait_boot: 30_000
      })

    on_exit(fn ->
      if Process.alive?(peer) do
        :peer.stop(peer)
      end
    end)

    config =
      Enum.map(Application.loaded_applications(), fn {app, _, _} ->
        {app, Application.get_all_env(app)}
      end)

    :ok = :peer.call(peer, Application, :put_all_env, [config, [persistent: true]])

    repo =
      Application.get_env(:ankole, Repo)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 4)

    :ok = :peer.call(peer, Application, :put_env, [:ankole, Repo, repo, [persistent: true]])
    assert {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ankole], 30_000)
    assert true == :peer.call(peer, Node, :connect, [node()])
    :ok = :global.sync()
    :ok = :erpc.call(remote, :global, :sync, [])
    {peer, remote}
  end
end
