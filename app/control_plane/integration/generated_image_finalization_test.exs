defmodule Ankole.Sessions.GeneratedImageFinalizationIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  alias Ankole.AIGateway.{Artifacts, ResponseCommit}
  alias Ankole.Sessions.{Admission, Fence, Model, Queue, Run}
  alias Ankole.Signals.Signal
  alias Ankole.Files

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  test "byte preparation holds no Session lock and a lost writer can recover without another model request",
       %{tenant: tenant} do
    %{principal: agent} = Ankole.SessionsCase.agent_fixture()
    {:ok, profile} = Ankole.AIGateway.ModelProfiles.get_model_profile(agent.uid, "primary")

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        Repo.delete_all(from job in Oban.Job, where: job.args["tenant_id"] == ^tenant.id)
        Repo.delete_all(Ankole.Conversations.Conversation)
        Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)

        # The provider owner first disables an active row, then deletes it.
        {:ok, _} = Ankole.AIGateway.ProviderConfigs.delete_provider(profile["provider_id"])
        {:ok, _} = Ankole.AIGateway.ProviderConfigs.delete_provider(profile["provider_id"])
        cleanup_tenant!(tenant)
      end)
    end)

    event =
      Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid,
        type: "conversation.message.addressed"
      )

    key = %{agent_uid: agent.uid, session_id: event.session_id}
    assert {:ok, run} = Admission.admit(key, event)
    assert {:ok, {:preparing, run}} = Model.prepare(run)

    assert {:ok, response} =
             Ankole.AIGatewayCase.start_response_run(%{
               subject_uid: agent.uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Run.metadata(run)}
             })

    image_id = "ig_#{Ankole.Ecto.UUIDv7.autogenerate()}"
    bytes = @png <> :crypto.strong_rand_bytes(16)

    assert {:ok, _} =
             Artifacts.persist_generated_image(
               agent.uid,
               image_id,
               Base.encode64(bytes),
               "image/png",
               message_id: response.id
             )

    assert {:ok, response} =
             ResponseCommit.commit_complete(response, [
               %{"id" => image_id, "type" => "image_generation_call", "status" => "completed"}
             ])

    run = %{run | model_response: response, anchor: response.id}
    parent = self()
    hook = {__MODULE__, make_ref()}
    tenant = Repo.tenant_id!()

    :telemetry.attach(
      hook,
      [:ankole, :repo, :query],
      fn _, _, metadata, _ ->
        if Repo.tenant_id() == tenant and
             String.starts_with?(metadata.query, "INSERT INTO files ") do
          :telemetry.detach(hook)
          send(parent, {:before_object_write, self(), Repo.in_transaction?()})

          receive do
            :write -> :ok
          after
            10_000 -> raise "image writer was not released"
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(hook) end)
    supervisor = start_supervised!(Task.Supervisor)

    writer =
      Task.Supervisor.async_nolink(supervisor, Repo.bind_tenant(fn -> Run.finalize(run) end))

    assert_receive {:before_object_write, writer_pid, false}, 10_000

    assert {:ok, :locks_available} =
             Repo.transact(fn repo ->
               repo.query!("SET LOCAL lock_timeout = '1s'")
               :ok = Queue.lock_session_in_tx(agent.uid, event.session_id)
               assert Fence.lock_workspace_in_tx(key)
               assert Ankole.Signals.lock_signal_in_tx(event.id)
               {:ok, :locks_available}
             end)

    assert {:ok, %{files: []}} = Files.list(agent.uid)
    refute Repo.reload!(event).completed_at
    assert Repo.aggregate(Ankole.Conversations.Delivery.Intent, :count) == 0

    # Losing the writer after the durable blob row but before its object and
    # final transaction must be recoverable from the same completed model row.
    Process.exit(writer_pid, :kill)
    assert {:exit, :killed} = Task.yield(writer, 5_000)
    assert {:ok, recovered} = Admission.admit(key, Repo.reload!(event))
    assert {:ok, {_, recovered}} = Run.restore(recovered)
    assert {:ok, result} = Run.finalize(recovered)
    [attachment] = Enum.flat_map(result.posted.intents, &(&1.payload["attachments"] || []))
    assert {:ok, _, ^bytes} = Files.read(agent.uid, attachment["path"])
    assert Repo.reload!(event).completed_at
    assert Repo.aggregate(Ankole.AIGateway.Schemas.Message, :count) == 1
    assert Repo.aggregate(Signal, :count) == 1
  end
end
