defmodule Ankole.Sessions.GeneratedImageRecoveryTest do
  use Ankole.DataCase, async: false

  import Ankole.SessionsCase, only: [agent_fixture: 0]
  import Ankole.SignalsFixtures, only: [external_session_signal_fixture: 2]
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Files
  alias Ankole.Files.Jobs.CollectUnreferenced
  alias Ankole.Files.Schemas.Blob
  alias Ankole.Sessions.{Admission, Model, Presentation, Receipts, Run, SessionWorkspace, Tools}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  test "finalization projects pending receipt attachments and follow-up text after its journal" do
    ctx = admitted()
    {:ok, stored} = Files.store("pending receipt attachment")
    path = "chats/#{ctx.signal.conversation_id}/notes.txt"

    assert {:ok, _} =
             Repo.transact(fn ->
               Files.commit_in_tx(
                 ctx.agent.uid,
                 [%{path: path, sha256: stored.sha256, source: "generated"}],
                 []
               )
             end)

    attachment = %{
      "path" => path,
      "blob_ref" => stored.sha256,
      "name" => "notes.txt",
      "mime_type" => "text/plain",
      "size" => stored.size
    }

    call = call("reply_attachment")
    prior_id = image_id()
    {run, artifact, payload} = completed_image(ctx, [call], [image_item(prior_id)])

    assert {:ok, _} =
             Receipts.execute(
               run,
               Run.response_id(run.model_response),
               call["call_id"],
               prepare_operation(fn _ ->
                 {:ok,
                  Tools.result(%{"tool" => "reply_attachment", "attachments" => [attachment]}),
                  []}
               end)
             )

    text = "The completed image and the receipt attachment are ready."

    follow_up = %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }

    run = %{run | calls: [call], round_calls: [call], follow_ups: [follow_up]}

    assert {:ok, result} = Run.finalize(run)
    assert result.final_text == text
    assert result.journal.message.id != run.model_response.id

    assert {:error, :receipt_not_found} =
             Receipts.fetch(Run.response_id(run.model_response), call["call_id"])

    attachments = Enum.flat_map(result.posted.intents, &(&1.payload["attachments"] || []))
    assert length(attachments) == 2
    assert Enum.any?(attachments, &(&1["path"] == path))
    image = Enum.find(attachments, &(&1["name"] == Artifacts.public_id(artifact) <> ".png"))
    assert {:ok, _, ^payload} = Files.read(ctx.agent.uid, image["path"])
    refute Enum.any?(attachments, &String.contains?(&1["name"], prior_id))
    assert Repo.reload!(ctx.signal).completed_at
  end

  test "a pending ending receipt supplies clarification after image preparation" do
    ctx = admitted()
    call = call("clarify")
    {run, _artifact, _payload} = completed_image(ctx, [call])
    question = "Which image variant should I keep?"

    assert {:ok, _} =
             Receipts.execute(
               run,
               Run.response_id(run.model_response),
               call["call_id"],
               prepare_operation(fn _ ->
                 {:ok,
                  Tools.result(
                    %{
                      "tool" => "clarify",
                      "question" => question,
                      "choices" => [%{"label" => "First"}]
                    },
                    terminate: true
                  ), []}
               end)
             )

    assert {:ok, result} = Run.finalize(%{run | calls: [call], round_calls: [call]})
    assert result.journal.message.metadata["tool_result_journal"]

    assert Enum.any?(
             result.posted.intents,
             &(&1.payload["interactive_output"]["body"] == question)
           )

    assert {:error, :receipt_not_found} =
             Receipts.fetch(Run.response_id(run.model_response), call["call_id"])

    assert Repo.reload!(ctx.signal).completed_at
  end

  test "GC-marked prepared bytes retry through admission without losing the completed response" do
    ctx = admitted()
    {run, _artifact, payload} = completed_image(ctx)
    digest = :crypto.hash(:sha256, payload)

    hook =
      after_blob_row(fn ->
        age_blob(digest)
        CollectUnreferenced.mark_unreferenced()
      end)

    assert {:error, %{"retryable" => true} = error} = Run.finalize(run)
    assert_receive {^hook, {:ok, 1}}
    assert Repo.get!(Blob, digest).deleting
    refute Repo.reload!(ctx.signal).completed_at
    assert {:ok, %{files: []}} = Files.list(ctx.agent.uid)
    assert Repo.aggregate(Intent, :count) == 0
    assert CollectUnreferenced.remove_marked(0) == 1
    assert Repo.get(Blob, digest) == nil
    assert {:error, _} = Ankole.ObjectStore.read(Files.object_key(digest))

    assert {:ok, deferred} = Run.defer_retry(run, error)
    assert {:ok, recovered} = Admission.admit(ctx.key, deferred, now: deferred.available_at)
    assert {:ok, {:boundary, recovered}} = Run.restore(recovered)
    assert {:ok, result} = Run.finalize(recovered)
    [attachment] = Enum.flat_map(result.posted.intents, &(&1.payload["attachments"] || []))
    assert {:ok, _, ^payload} = Files.read(ctx.agent.uid, attachment["path"])
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.reload!(ctx.signal).completed_at
  end

  test "a current run preserves the preparation error for a missing generated image" do
    ctx = admitted()
    {run, error} = completed_image_without_artifact(ctx)

    assert_rejected_without_reply_or_retry(ctx, run, error)
  end

  test "a stale run rejects finalization before reporting its missing generated image" do
    ctx = admitted()
    {run, _error} = completed_image_without_artifact(ctx)

    assert {1, nil} =
             Repo.update_all(from(w in SessionWorkspace, where: w.id == ^run.workspace_id),
               inc: [epoch: 1]
             )

    assert_rejected_without_reply_or_retry(ctx, run, :stale_driver)
  end

  test "a closed run rejects finalization before reporting its missing generated image" do
    ctx = admitted()
    {run, _error} = completed_image_without_artifact(ctx)

    Repo.update!(
      Ecto.Changeset.change(ctx.signal,
        status: :completed,
        completed_at: DateTime.utc_now(:microsecond)
      )
    )

    assert Repo.get!(SessionWorkspace, run.workspace_id).epoch == run.epoch

    assert_rejected_without_reply_or_retry(ctx, run, :run_closed)
  end

  test "superseded finalization leaves no references and its prepared bytes remain collectable" do
    ctx = admitted()
    {run, _artifact, payload} = completed_image(ctx)
    digest = :crypto.hash(:sha256, payload)

    hook =
      after_blob_row(fn ->
        Repo.update_all(from(w in SessionWorkspace, where: w.id == ^run.workspace_id),
          inc: [epoch: 1]
        )
      end)

    assert {:error, :stale_driver} = Run.finalize(run)
    assert_receive {^hook, {1, nil}}
    refute Repo.reload!(ctx.signal).completed_at
    assert {:ok, %{files: []}} = Files.list(ctx.agent.uid)
    assert Repo.aggregate(Intent, :count) == 0
    assert Repo.get!(Blob, digest)
    assert {:ok, ^payload} = Ankole.ObjectStore.read(Files.object_key(digest))
    age_blob(digest)
    assert {:ok, 1} = CollectUnreferenced.mark_unreferenced()
    assert CollectUnreferenced.remove_marked(0) == 1
    assert Repo.get(Blob, digest) == nil
    assert {:error, _} = Ankole.ObjectStore.read(Files.object_key(digest))
  end

  test "an image retry at the admission budget ends explicitly without another upload or reply" do
    ctx = admitted()
    {run, _artifact, payload} = completed_image(ctx)
    digest = :crypto.hash(:sha256, payload)
    Repo.update!(Ecto.Changeset.change(ctx.signal, attempt_count: 5))

    hook =
      after_blob_row(fn ->
        age_blob(digest)
        CollectUnreferenced.mark_unreferenced()
      end)

    assert {:error, %{"retryable" => true} = error} = Run.finalize(run)
    assert_receive {^hook, {:ok, 1}}
    assert {:ok, deferred} = Run.defer_retry(run, error)
    reject_upload = after_blob_row(fn -> :unexpected_second_upload end)

    assert {:ok, %{status: :dead_letter, signal: ended}} =
             Admission.admit(ctx.key, deferred, now: deferred.available_at)

    assert ended.status == :dead_letter
    assert ended.attempt_count == 6
    assert %DateTime{} = ended.dead_letter_at
    assert ended.dead_letter_reason["code"] == "conversation_attempts_exhausted"
    refute ended.completed_at
    assert {:ok, :idle} = Run.rebuild(ctx.key, deferred.available_at)
    assert Repo.get!(Blob, digest).deleting
    refute_received {^reject_upload, _}
    assert {:ok, %{files: []}} = Files.list(ctx.agent.uid)
    assert Enum.all?(Repo.all(Intent), &((&1.payload["attachments"] || []) == []))
    assert Repo.aggregate(Message, :count) == 1
  end

  defp admitted do
    %{principal: agent} = agent_fixture()
    signal = external_session_signal_fixture(agent.uid, type: "conversation.message.addressed")
    key = %{agent_uid: agent.uid, session_id: signal.session_id}
    assert {:ok, run} = Admission.admit(key, signal)
    assert {:ok, {:preparing, run}} = Model.prepare(run)
    %{agent: agent, signal: signal, key: key, run: run}
  end

  defp completed_image(ctx, calls \\ [], request_items \\ []) do
    assert {:ok, response} =
             start_response_run(%{
               subject_uid: ctx.agent.uid,
               conversation_id: ctx.run.conversation.id,
               round_state: ctx.run,
               request_items: request_items,
               metadata: %{"request_metadata" => Run.metadata(ctx.run)}
             })

    id = image_id()
    payload = @png <> id

    assert {:ok, artifact} =
             Artifacts.persist_generated_image(
               ctx.agent.uid,
               id,
               Base.encode64(payload),
               "image/png",
               message_id: response.id
             )

    assert {:ok, response} = ResponseCommit.commit_complete(response, [image_item(id) | calls])
    {%{ctx.run | model_response: response, anchor: response.id}, artifact, payload}
  end

  defp completed_image_without_artifact(ctx) do
    {run, artifact, _payload} = completed_image(ctx)
    Repo.delete!(artifact)

    assert {:error, _} =
             Artifacts.get_generated_image(ctx.agent.uid, Artifacts.public_id(artifact),
               payload?: true
             )

    assert {:error,
            %{"code" => "generated_image_materialization_failed", "retryable" => true} = error} =
             Presentation.prepare_generated_images(run, Run.response_id(run.model_response))

    {run, error}
  end

  defp assert_rejected_without_reply_or_retry(ctx, run, reason) do
    signal = Repo.reload!(ctx.signal)
    assert Repo.aggregate(Message, :count) == 1
    assert {:error, ^reason} = Run.finalize(run)
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(Intent, :count) == 0
    assert {:ok, %{files: []}} = Files.list(ctx.agent.uid)
    assert Repo.reload!(signal).attempt_count == signal.attempt_count
    assert Repo.reload!(signal).completed_at == signal.completed_at
  end

  defp age_blob(digest) do
    Repo.update_all(from(b in Blob, where: b.sha256 == ^digest),
      set: [last_referenced_at: DateTime.add(DateTime.utc_now(:microsecond), -172_800)]
    )
  end

  defp after_blob_row(operation) do
    owner = self()
    hook = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        hook,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner and String.starts_with?(metadata.query, "INSERT INTO files ") do
            :telemetry.detach(hook)
            send(owner, {hook, operation.()})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(hook) end)
    hook
  end

  defp call(name),
    do: %{
      "type" => "function_call",
      "name" => name,
      "call_id" => "#{name}-pending",
      "arguments" => "{}",
      "status" => "completed"
    }

  defp image_id, do: "ig_#{Ankole.Ecto.UUIDv7.autogenerate()}"

  defp image_item(id),
    do: %{"id" => id, "type" => "image_generation_call", "status" => "completed", "result" => nil}

  defp prepare_operation(operation) do
    fn -> {:ok, [], fn -> operation.(Repo) end} end
  end
end
