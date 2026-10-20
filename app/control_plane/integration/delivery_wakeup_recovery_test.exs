defmodule Ankole.Conversations.DeliveryWakeupRecoveryIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures, only: [binding_fixture: 4]

  alias Ankole.AppConfigure
  alias Ankole.Sessions.Reconciler
  alias Ankole.Plugins.LarkAdapter.Config

  alias Ankole.Conversations.{Conversation, External}
  alias Ankole.Conversations.Delivery
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.Jobs.Dispatch

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

        Repo.delete_all(
          from c in Conversation, where: c.provider_conversation_id == ^"lark:#{chat_id}"
        )

        Repo.delete!(tenant)
      end)
    end)

    binding = binding_fixture(agent.uid, "bot", :ignore, adapter: "temporarily-missing-adapter")
    now = DateTime.utc_now(:microsecond)

    assert {:ok, conversation} =
             Repo.transact(fn repo ->
               External.observe_conversation_in_tx(
                 repo,
                 binding,
                 %{
                   provider_conversation_id: "lark:#{chat_id}",
                   external_kind: :im_group,
                   reply_mode: :entry,
                   metadata: %{"chat_id" => chat_id}
                 },
                 now
               )
             end)

    assert {:ok, intent} =
             Ankole.SignalsFixtures.commit_delivery(%{
               agent_uid: agent.uid,
               binding_name: "bot",
               outbound_key: "recover-final-reply",
               delivery_class: :durable_ai_reply,
               operation: :post,
               conversation_id: conversation.id,
               fallback_visible_text: "Recovered final reply",
               idempotency_key: "recovery-#{agent.uid}"
             })

    job = Repo.one!(dispatch_jobs(agent.uid))

    failures =
      Task.async(
        Repo.bind_tenant(fn ->
          for _attempt <- 1..5, do: Oban.drain_queue(queue: :outbox, with_scheduled: true)
        end)
      )
      |> Task.await()

    assert Enum.map(failures, &{&1.failure, &1.discard, &1.success}) ==
             List.duplicate({1, 0, 0}, 4) ++ [{0, 1, 0}]

    assert %{state: "discarded", attempt: 5} = Repo.get!(Oban.Job, job.id)
    assert %{status: :pending, attempt_count: 0} = stored_intent(intent)
    refute_received {:provider_post, _}

    Repo.update_all(where(Oban.Job, id: ^job.id),
      set: [discarded_at: DateTime.add(DateTime.utc_now(), -61)]
    )

    job_id = job.id
    discarded_job = from candidate in Oban.Job, where: candidate.id == ^job_id

    assert {:ok, [%{id: ^job_id}]} =
             Oban.Engines.Basic.prune_jobs(Oban.config(), from(j in subquery(discarded_job)),
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
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "bot",
               adapter: "lark",
               config_ref: "app-config://#{config_key}",
               unaddressed_group_message_policy: :ignore
             })

    refute_enqueued(worker: Dispatch, args: %{agent_uid: agent.uid})

    assert :ok =
             Task.async(Repo.bind_tenant(fn -> Reconciler.perform(%Oban.Job{args: %{}}) end))
             |> Task.await()

    assert :ok = perform_job(Reconciler, %{})
    assert Repo.aggregate(dispatch_jobs(agent.uid), :count) == 1

    assert %{failure: 0, success: 1} =
             Task.async(Repo.bind_tenant(fn -> Oban.drain_queue(queue: :outbox) end))
             |> Task.await()

    assert %{status: :sent, attempt_count: 1, created_provider_message_id: "om_recovered"} =
             stored_intent(intent)

    assert_receive {:provider_post, request}
    assert request.body["receive_id"] == chat_id
    assert request.body["msg_type"] == "text"
    assert Ankole.JSON.decode!(request.body["content"]) == %{"text" => "Recovered final reply"}

    assert %{message: message} = External.get_message(Repo, conversation.id, "om_recovered")
    assert message.text == "Recovered final reply"

    assert :ok = perform_job(Reconciler, %{})
    assert %{failure: 0, success: 0} = Oban.drain_queue(queue: :outbox)
    refute_received {:provider_post, _}
  end

  defp dispatch_jobs(agent_uid) do
    from job in Oban.Job,
      where: job.worker == ^Oban.Worker.to_string(Dispatch),
      where: job.args["agent_uid"] == ^agent_uid
  end

  defp stored_intent(row) do
    Repo.get_by!(Intent,
      agent_uid: row.agent_uid,
      binding_name: row.binding_name,
      outbound_key: row.outbound_key
    )
  end
end
