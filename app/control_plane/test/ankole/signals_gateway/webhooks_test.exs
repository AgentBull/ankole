defmodule Ankole.SignalsGateway.WebhooksTest do
  # Serial because the one-shot claim test leaves the sandbox with
  # `unboxed_run` to prove real row locking.
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.Jobs.ExecuteRun
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.WebhookEndpoint
  alias Ankole.SignalsGateway.Webhooks

  @now ~U[2026-07-30 01:00:00.000000Z]
  @token "wh_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
  @other_token "wh_ABCDEFGhijklmnopqrstuvwxyz0123456789abcdefg"

  test "one-shot callback appends one durable receipt and then ignores replay" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    expires_at = DateTime.add(@now, 1, :hour)

    assert {:ok, %{status: :created, webhook_endpoint: endpoint}} =
             Webhooks.create_endpoint(endpoint_attrs(source, expires_at), @token, now: @now)

    refute endpoint.token_digest == @token
    assert endpoint.token_digest == Webhooks.token_digest(@token)

    headers = [
      {"content-type", "application/json"},
      {"x-github-event", "issues"},
      {"x-github-delivery", "delivery-1"},
      {"x-hub-signature-256", "sha256=retained"},
      {"x-github-invalid", <<255>>},
      {"authorization", "Bearer must-not-persist"},
      {"x-api-key", "must-not-persist"}
    ]

    assert {:ok,
            %{
              status: :accepted,
              webhook_endpoint: %WebhookEndpoint{status: "fired"},
              actor_event: receipt
            }} = Webhooks.receive(@token, headers, ~s({"action":"opened"}), now: @now)

    assert receipt.type == "webhook.received"
    assert receipt.binding_name == source.binding_name
    assert receipt.session_id == source.session_id
    assert receipt.source_entry_id == source.source_entry_id
    assert get_in(receipt.payload, ["data", "webhook_endpoint", "id"]) == endpoint.id
    assert get_in(receipt.payload, ["data", "webhook_endpoint", "label"]) == "Watch GitHub issues"

    assert get_in(receipt.payload, ["data", "headers"]) == %{
             "content-type" => "application/json",
             "x-github-delivery" => "delivery-1",
             "x-github-event" => "issues",
             "x-hub-signature-256" => "sha256=retained"
           }

    refute inspect(receipt.payload) =~ "must-not-persist"
    refute get_in(receipt.payload, ["data", "headers"])["x-github-invalid"]
    assert get_in(receipt.payload, ["data", "body"]) == ~s({"action":"opened"})
    assert get_in(receipt.payload, ["data", "body_encoding"]) == "utf-8"
    assert get_in(receipt.payload, ["data", "body_size"]) == 19

    assert {:ok, %{status: :ignored, webhook_endpoint: replayed}} =
             Webhooks.receive(@token, headers, ~s({"action":"replayed"}), now: @now)

    assert replayed.status == "fired"

    assert Repo.aggregate(
             from(event in ActorEvent, where: event.type == "webhook.received"),
             :count
           ) == 1
  end

  @tag ownership_timeout: 10_000
  test "concurrent one-shot deliveries claim the endpoint once" do
    token = token("concurrent-#{System.unique_integer([:positive])}")

    {agent_uid, endpoint_id} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        %{principal: agent} = agent_fixture()
        source = source_event!(agent.uid)

        assert {:ok, %{webhook_endpoint: endpoint}} =
                 Webhooks.create_endpoint(
                   endpoint_attrs(source, DateTime.add(@now, 1, :hour)),
                   token,
                   now: @now
                 )

        {agent.uid, endpoint.id}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        delete_agent_fixture_rows(agent_uid)
      end)
    end)

    tasks =
      for body <- ~w(first second) do
        Task.async(fn ->
          receive do
            :start ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                Webhooks.receive(token, [], body, now: @now)
              end)
          end
        end)
      end

    Enum.each(tasks, fn task ->
      send(task.pid, :start)
    end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert 1 == Enum.count(results, &match?({:ok, %{status: :accepted}}, &1))
    assert 1 == Enum.count(results, &match?({:ok, %{status: :ignored}}, &1))

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert %WebhookEndpoint{status: "fired"} = Repo.get!(WebhookEndpoint, endpoint_id)

      assert Repo.aggregate(
               from(
                 event in ActorEvent,
                 where: event.agent_uid == ^agent_uid and event.type == "webhook.received"
               ),
               :count
             ) == 1
    end)
  end

  test "standing callback appends one ActorEvent for every delivery" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    token = token("standing")

    assert {:ok, %{webhook_endpoint: endpoint}} =
             Webhooks.create_endpoint(
               endpoint_attrs(source, DateTime.add(@now, 1, :day), mode: "standing"),
               token,
               now: @now
             )

    assert endpoint.status == "active"

    assert {:ok, %{status: :accepted, actor_event: first}} =
             Webhooks.receive(token, [{"x-github-event", "pull_request"}], "first", now: @now)

    assert {:ok, %{status: :accepted, actor_event: second}} =
             Webhooks.receive(
               token,
               [{"x-github-event", "pull_request"}],
               "second",
               now: DateTime.add(@now, 1, :second)
             )

    assert first.id != second.id
    assert first.source_event_id != second.source_event_id
    assert Repo.get!(WebhookEndpoint, endpoint.id).status == "active"
  end

  test "a bound callback commits one automation run before accepting the delivery" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    job = automation_job!(source)
    token = token("automation-consumer")

    assert {:ok, %{webhook_endpoint: endpoint}} =
             Webhooks.create_endpoint(
               endpoint_attrs(source, DateTime.add(@now, 1, :day), automation_job_id: job.id),
               token,
               now: @now
             )

    assert endpoint.automation_job_id == job.id

    assert {:ok,
            %{
              status: :accepted,
              webhook_endpoint: %WebhookEndpoint{status: "fired"},
              automation_job_run: run
            }} =
             Webhooks.receive(
               token,
               [{"x-github-event", "issues"}],
               ~s({"action":"opened"}),
               now: @now
             )

    assert run.automation_job_id == job.id
    assert run.status == "queued"
    assert run.event["type"] == "webhook.received"
    assert get_in(run.event, ["data", "body"]) == ~s({"action":"opened"})
    assert get_in(run.event, ["data", "headers", "x-github-event"]) == "issues"
    assert_enqueued(worker: ExecuteRun, args: %{"automation_job_run_id" => run.id})

    assert Repo.aggregate(
             from(event in ActorEvent, where: event.type == "webhook.received"),
             :count
           ) == 0

    assert {:ok, %{status: :ignored}} =
             Webhooks.receive(token, [], "replayed", now: DateTime.add(@now, 1, :second))
  end

  test "a webhook cannot bind an automation job owned by another Agent" do
    %{principal: owner} = agent_fixture()
    %{principal: other} = agent_fixture()
    source = source_event!(owner.uid)
    other_source = source_event!(other.uid)
    other_job = automation_job!(other_source)

    assert {:error, :automation_job_not_owned} =
             Webhooks.create_endpoint(
               endpoint_attrs(source, DateTime.add(@now, 1, :day),
                 automation_job_id: other_job.id
               ),
               token("wrong-owner"),
               now: @now
             )
  end

  test "unknown tokens return not found while known terminal tokens stay successful" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    token = token("cancel")

    assert {:ok, %{webhook_endpoint: endpoint}} =
             Webhooks.create_endpoint(
               endpoint_attrs(source, DateTime.add(@now, 1, :day), mode: "standing"),
               token,
               now: @now
             )

    assert {:ok, %{status: :cancelled, webhook_endpoint: cancelled}} =
             Webhooks.cancel_endpoint(agent.uid, source.session_id, endpoint.id, now: @now)

    assert cancelled.status == "cancelled"

    assert {:ok, %{status: :ignored}} =
             Webhooks.receive(token, [], "ignored", now: DateTime.add(@now, 1, :second))

    assert {:error, :webhook_endpoint_not_found} =
             Webhooks.receive(token("missing"), [], "unknown", now: @now)

    assert Repo.aggregate(
             from(event in ActorEvent, where: event.type == "webhook.received"),
             :count
           ) == 0
  end

  test "create is idempotent for one token and list projections never expose it" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    attrs = endpoint_attrs(source, DateTime.add(@now, 1, :day))

    assert {:ok, %{status: :created, webhook_endpoint: endpoint}} =
             Webhooks.create_endpoint(attrs, @token, now: @now)

    assert {:ok, %{status: :already_exists, webhook_endpoint: same}} =
             Webhooks.create_endpoint(attrs, @token, now: @now)

    assert same.id == endpoint.id

    assert [listed] =
             Webhooks.list_endpoints(agent.uid, source.session_id, active_only: true, now: @now)

    assert listed.id == endpoint.id

    model_projection = Webhooks.model_projection(listed)
    console_projection = Webhooks.console_projection(listed)

    refute Map.has_key?(model_projection, "token")
    refute Map.has_key?(model_projection, "token_digest")
    refute Map.has_key?(console_projection, :token)
    refute Map.has_key?(console_projection, :token_digest)
  end

  test "a nil session lists and cancels endpoints across every session of one agent" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    first = source_event!(agent.uid)
    second = source_event!(agent.uid)
    expires_at = DateTime.add(@now, 1, :day)

    assert {:ok, %{webhook_endpoint: one}} =
             Webhooks.create_endpoint(endpoint_attrs(first, expires_at), @token, now: @now)

    assert {:ok, %{webhook_endpoint: two}} =
             Webhooks.create_endpoint(endpoint_attrs(second, expires_at), @other_token, now: @now)

    listed = Webhooks.list_endpoints(agent.uid, nil, active_only: true, now: @now)

    assert MapSet.new(listed, & &1.id) == MapSet.new([one.id, two.id])

    assert MapSet.new(listed, & &1.session_id) ==
             MapSet.new([first.session_id, second.session_id])

    assert Webhooks.cancel_endpoint(other_agent.uid, nil, one.id) ==
             {:error, :webhook_endpoint_not_found}

    assert {:ok, %{status: :cancelled, webhook_endpoint: cancelled}} =
             Webhooks.cancel_endpoint(agent.uid, nil, one.id, now: @now)

    assert cancelled.status == "cancelled"
    assert [remaining] = Webhooks.list_endpoints(agent.uid, nil, active_only: true, now: @now)
    assert remaining.id == two.id
  end

  test "expiry sweep marks due credentials and active lists hide unswept expiry" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    expires_at = DateTime.add(@now, 10, :second)

    assert {:ok, %{webhook_endpoint: endpoint}} =
             Webhooks.create_endpoint(endpoint_attrs(source, expires_at), @token, now: @now)

    assert [] =
             Webhooks.list_endpoints(agent.uid, source.session_id,
               active_only: true,
               now: DateTime.add(expires_at, 1, :second)
             )

    assert Webhooks.expire_due(DateTime.add(expires_at, 1, :second)) == 1
    assert Repo.get!(WebhookEndpoint, endpoint.id).status == "expired"

    assert {:ok, %{status: :ignored}} =
             Webhooks.receive(@token, [], "late", now: DateTime.add(expires_at, 2, :second))
  end

  test "binary callback bodies are stored as bounded base64 data" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)

    assert {:ok, %{webhook_endpoint: _endpoint}} =
             Webhooks.create_endpoint(
               endpoint_attrs(source, DateTime.add(@now, 1, :hour), mode: "standing"),
               @token,
               now: @now
             )

    for body <- [<<"valid utf-8", 0>>, <<255, 1>>] do
      assert {:ok, %{actor_event: receipt}} =
               Webhooks.receive(@token, [], body, now: @now)

      assert get_in(receipt.payload, ["data", "body"]) == Base.encode64(body)
      assert get_in(receipt.payload, ["data", "body_encoding"]) == "base64"
      assert get_in(receipt.payload, ["data", "body_size"]) == byte_size(body)
    end
  end

  defp source_event!(agent_uid) do
    unique = System.unique_integer([:positive])

    assert {:ok, event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: agent_uid,
               binding_name: "github",
               session_id: "conversation-#{unique}",
               source_event_id: "source-#{unique}",
               signal_channel_id: "lark:chat:#{unique}",
               provider_thread_id: "thread-#{unique}",
               source_entry_id: "message-#{unique}",
               type: "im.message.addressed",
               available_at: @now,
               sender_key: nil,
               payload: %{
                 "specversion" => "1.0",
                 "id" => "source-#{unique}",
                 "source" => "test://webhooks",
                 "type" => "im.message.addressed",
                 "data" => %{}
               }
             })

    event
  end

  defp endpoint_attrs(source, expires_at, opts \\ []) do
    %{
      agent_uid: source.agent_uid,
      binding_name: source.binding_name,
      session_id: source.session_id,
      signal_channel_id: source.signal_channel_id,
      provider_thread_id: source.provider_thread_id,
      source_actor_event_id: source.id,
      source_entry_id: source.source_entry_id,
      source_provenance: %{"kind" => "test"},
      label: "Watch GitHub issues",
      mode: Keyword.get(opts, :mode, "one_shot"),
      automation_job_id: Keyword.get(opts, :automation_job_id),
      expires_at: expires_at
    }
  end

  defp automation_job!(source) do
    assert {:ok, job} =
             AutomationJobs.create_job(%{
               agent_uid: source.agent_uid,
               owner_session_id: source.session_id,
               source_actor_event_id: source.id,
               source_entry_id: source.source_entry_id,
               source_provenance: %{"kind" => "test"},
               reply_route: %{
                 "binding_name" => source.binding_name,
                 "signal_channel_id" => source.signal_channel_id,
                 "provider_thread_id" => source.provider_thread_id,
                 "source_entry_id" => source.source_entry_id
               },
               directory_path: "/agents/#{source.agent_uid}/automation/webhook-test",
               label: "Webhook deterministic consumer",
               wake_on_failure: false
             })

    job
  end

  defp token(seed) do
    digest = :crypto.hash(:sha256, seed) |> Base.url_encode64(padding: false)
    "wh_" <> digest
  end
end
