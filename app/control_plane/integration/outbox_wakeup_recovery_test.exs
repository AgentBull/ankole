defmodule Ankole.SignalsGateway.OutboxWakeupRecoveryIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures, only: [binding_fixture: 4]

  alias Ankole.AppConfigure
  alias Ankole.Conversations.Reconciler
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{Channel, Entry, Outbox, OutboxEntry}
  alias Ankole.SignalsGateway.Jobs.OutboxDispatch

  test "a committed reply survives five failed attempts and pruning, then reaches the Lark HTTP API",
       %{tenant: tenant} do
    parent = self()
    chat_id = "oc_#{Ecto.UUID.generate()}"

    url =
      start_upstream_server(fn request ->
        case {request.method, request.request_path} do
          {:post, "/open-apis/auth/v3/tenant_access_token/internal"} ->
            {:json, 200, %{"code" => 0, "tenant_access_token" => "test-token", "expire" => 7_200}}

          {:post, "/open-apis/im/v1/messages"} ->
            send(parent, {:provider_post, request})
            {:json, 200, %{"code" => 0, "data" => %{"message_id" => "om_recovered"}}}

          request ->
            flunk("Unexpected Lark request: #{inspect(request)}")
        end
      end)

    previous = Application.fetch_env!(:ankole, Config)

    Application.put_env(:ankole, Config,
      client_opts: [base_url: url, req_options: [retry: false]]
    )

    on_exit(fn -> Application.put_env(:ankole, Config, previous) end)

    %{principal: agent} = agent_fixture()
    config_key = Config.binding_config_key(agent.uid, "bot")

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        Repo.delete_all(from job in Oban.Job, where: job.args["agent_uid"] == ^agent.uid)
        :ok = AppConfigure.delete_global_by_key(config_key)
        delete_agent_fixture_rows(agent.uid)
        Repo.delete_all(where(Channel, id: ^"lark:#{chat_id}"))
        Repo.delete!(tenant)
      end)
    end)

    binding_fixture(agent.uid, "bot", :ignore, adapter: "temporarily-missing-adapter")

    Repo.insert!(
      Channel.changeset(%Channel{}, %{
        id: "lark:#{chat_id}",
        kind: :im_group,
        reply_mode: :entry,
        metadata: %{"chat_id" => chat_id},
        first_seen_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      })
    )

    assert {:ok, outbox} =
             Outbox.commit_outbox(%{
               agent_uid: agent.uid,
               binding_name: "bot",
               outbound_key: "recover-final-reply",
               delivery_class: :durable_ai_reply,
               operation: :post,
               signal_channel_id: "lark:#{chat_id}",
               fallback_visible_text: "Recovered final reply",
               idempotency_key: "recovery-#{agent.uid}"
             })

    job = Repo.one!(dispatch_jobs(agent.uid))

    failures =
      Task.async(fn ->
        for _attempt <- 1..5, do: Oban.drain_queue(queue: :outbox, with_scheduled: true)
      end)
      |> Task.await()

    assert Enum.map(failures, &{&1.failure, &1.discard, &1.success}) ==
             List.duplicate({1, 0, 0}, 4) ++ [{0, 1, 0}]

    assert %{state: "discarded", attempt: 5} = Repo.get!(Oban.Job, job.id)
    assert %{status: :created, attempt_count: 0} = stored_outbox(outbox)
    refute_received {:provider_post, _}

    Repo.update_all(where(Oban.Job, id: ^job.id),
      set: [discarded_at: DateTime.add(DateTime.utc_now(), -61)]
    )

    assert {:ok, [_]} =
             Oban.Engines.Basic.prune_jobs(Oban.config(), where(Oban.Job, id: ^job.id),
               max_age: 60,
               limit: 1
             )

    refute Repo.get(Oban.Job, job.id)

    assert {:ok, _config} =
             AppConfigure.put_global_by_key(config_key, %{
               "appID" => "cli_#{agent.uid}",
               "appSecret" => "test-secret"
             })

    assert {:ok, _binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: "bot",
               adapter: "lark",
               config_ref: "app-config://#{config_key}",
               unaddressed_group_message_policy: :ignore
             })

    refute_enqueued(worker: OutboxDispatch, args: %{agent_uid: agent.uid})

    assert :ok =
             Task.async(fn -> Reconciler.perform(%Oban.Job{args: %{}}) end)
             |> Task.await()

    assert :ok = perform_job(Reconciler, %{})
    assert Repo.aggregate(dispatch_jobs(agent.uid), :count) == 1

    assert %{failure: 0, success: 1} =
             Task.async(fn -> Oban.drain_queue(queue: :outbox) end) |> Task.await()

    assert %{status: :succeeded, attempt_count: 1, created_source_entry_id: "om_recovered"} =
             stored_outbox(outbox)

    assert_receive {:provider_post, request}
    assert request.body["receive_id"] == chat_id
    assert request.body["msg_type"] == "text"
    assert Ankole.JSON.decode!(request.body["content"]) == %{"text" => "Recovered final reply"}

    assert Repo.get_by!(Entry,
             signal_channel_id: "lark:#{chat_id}",
             source_entry_id: "om_recovered"
           ).text ==
             "Recovered final reply"

    assert :ok = perform_job(Reconciler, %{})
    assert %{failure: 0, success: 0} = Oban.drain_queue(queue: :outbox)
    refute_received {:provider_post, _}
  end

  defp dispatch_jobs(agent_uid) do
    from job in Oban.Job,
      where: job.worker == ^Oban.Worker.to_string(OutboxDispatch),
      where: job.args["agent_uid"] == ^agent_uid
  end

  defp stored_outbox(row) do
    Repo.get_by!(OutboxEntry,
      agent_uid: row.agent_uid,
      binding_name: row.binding_name,
      outbound_key: row.outbound_key
    )
  end
end
