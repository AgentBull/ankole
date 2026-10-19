defmodule Ankole.ConversationsQueueTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures, only: [human_fixture: 0]
  import Ankole.SessionsCase, only: [agent_fixture: 1]

  alias Ankole.Conversations
  alias Ankole.Conversations.Message
  alias Ankole.Sessions.{Admission, Commands, Model, Queue, Run}
  alias Ankole.Signals.Signal
  import Ankole.AIGatewayCase, only: [start_response_run: 1]
  alias Ankole.AIGateway.ResponseCommit

  setup do
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal
    id = Ecto.UUID.generate()

    assert {:ok, detail} =
             Conversations.create(human.uid, %{
               conversation_id: id,
               agent_uid: agent.uid,
               message_id: Ecto.UUID.generate(),
               text: "Original work"
             })

    input = Repo.get_by!(Signal, conversation_id: id)
    key = %{agent_uid: agent.uid, session_id: detail.session_id}
    assert {:ok, run} = Admission.admit(key, input)
    assert {:ok, {:preparing, run}} = Model.prepare(run)
    %{human: human, agent: agent, id: id, key: key, input: input, run: run}
  end

  test "queued input does not leak into the current request and each queued item starts its own turn",
       ctx do
    first = post!(ctx, "Wait for the next turn", "queue")
    second = post!(ctx, "Wait for another turn", "queue")
    steer = post!(ctx, "Change the current direction", "steer")
    run = %{ctx.run | pending_event_ids: [first.id, second.id, steer.id]}

    assert {:ok, [injected], run} = Run.inject_pending(run, fn _ -> true end)
    assert injected.id == steer.id
    request = Ankole.JSON.encode!(Model.request(run)["input"])
    assert request =~ "Change the current direction"
    refute request =~ "Wait for the next turn"
    refute request =~ "Wait for another turn"
    assert is_nil(Repo.reload!(first).last_attempt_at)
    assert Repo.reload!(steer).last_attempt_at
    assert {:error, :input_already_started} = change(ctx, "edit", steer, text: "Too late")

    assert {:ok, _} = Run.finalize(run, :silent)
    assert Queue.next_ready_event(ctx.agent.uid, ctx.key.session_id).id == first.id
    assert {:ok, next} = Admission.admit(ctx.key, first)
    assert {:ok, {:preparing, next}} = Model.prepare(next)

    assert {:ok, [], next} =
             Run.inject_pending(%{next | pending_event_ids: [second.id]}, fn _ -> true end)

    next_request = Ankole.JSON.encode!(Model.request(next)["input"])
    assert next_request =~ "Wait for the next turn"
    refute next_request =~ "Wait for another turn"
  end

  test "edits retain message identity and removal survives a late POST retry", ctx do
    input = post!(ctx, "A queued draft", "queue")
    assert {:ok, _} = change(ctx, "edit", input, text: "The edited draft")
    assert Repo.get_by!(Message, id: input.message_id).text == "The edited draft"
    assert Repo.reload!(input).data["text"] == "The edited draft"
    assert {:ok, reopened} = Conversations.get(ctx.human.uid, ctx.id)
    assert Enum.find(reopened.pending_inputs, &(&1.id == input.id)).message_id == input.message_id
    assert {:ok, _} = change(ctx, "remove", input)

    assert {:ok, replay} =
             Conversations.post(ctx.human.uid, ctx.id, %{
               message_id: input.message_id,
               text: "The edited draft",
               delivery_mode: "queue"
             })

    refute Enum.any?(replay.pending_inputs, &(&1.message_id == input.message_id))
    refute Enum.any?(replay.messages, &(&1.id == input.message_id))
    assert Repo.reload!(input).completed_at
    refute Ankole.JSON.encode!(Model.request(ctx.run)["input"]) =~ "The edited draft"
  end

  test "reordering rejects a stale admission and preserves the new order after reading it again",
       ctx do
    first = post!(ctx, "First queued", "queue")
    second = post!(ctx, "Second queued", "queue")

    assert {:ok, _} =
             queue_command(ctx, %{
               action: "reorder",
               message_ids: [second.message_id, first.message_id]
             })

    assert {:ok, reopened} = Conversations.get(ctx.human.uid, ctx.id)

    assert Enum.map(reopened.pending_inputs, & &1.message_id) == [
             second.message_id,
             first.message_id
           ]

    assert {:ok, _} = Run.finalize(ctx.run, :silent)
    assert {:error, :input_unavailable} = Admission.admit(ctx.key, first)
    assert Queue.next_ready_event(ctx.agent.uid, ctx.key.session_id).id == second.id
    assert {:ok, _} = Admission.admit(ctx.key, Repo.reload!(second))

    assert {:error, :queue_changed} =
             queue_command(ctx, %{
               action: "reorder",
               message_ids: [first.message_id, second.message_id]
             })
  end

  test "an injection that read before an edit uses the saved text and latest queue order", ctx do
    first = post!(ctx, "Old first steer", "steer")
    second = post!(ctx, "Second steer", "steer")
    assert {:ok, _} = change(ctx, "edit", first, text: "Updated steer")

    assert {:ok, _} =
             queue_command(ctx, %{
               action: "reorder",
               message_ids: [second.message_id, first.message_id]
             })

    assert {:ok, injected} = Run.inject(ctx.run, [first, second])
    assert Enum.map(injected, & &1.id) == [second.id, first.id]
    assert List.last(injected).data["text"] == "Updated steer"
    assert {:error, :input_already_started} = change(ctx, "remove", first)
  end

  test "Stop cancels the current run and persists a paused queue until explicit resume", ctx do
    first = post!(ctx, "Paused first", "queue")
    second = post!(ctx, "Paused second", "queue")
    pending_steer = post!(ctx, "Do not restart this pending steer after Stop", "steer")
    command_id = Ecto.UUID.generate()

    assert {:ok, stopped} =
             queue_command(ctx, %{
               action: "stop",
               command_id: command_id
             })

    assert stopped.conversation.metadata["queue_paused"] == true
    stop = Repo.get_by!(Signal, source_event_id: command_id)
    assert stop.type == "command.stop"
    assert {:ok, _} = Commands.interrupt(ctx.run, stop)
    assert Repo.reload!(ctx.input).completed_at
    assert {:ok, reopened} = Conversations.get(ctx.human.uid, ctx.id)
    assert reopened.conversation.metadata["queue_paused"] == true
    assert Enum.map(reopened.pending_inputs, & &1.id) == [first.id, second.id, pending_steer.id]
    assert Repo.reload!(pending_steer).data["delivery_mode"] == "queue"
    assert is_nil(Queue.next_ready_event(ctx.agent.uid, ctx.key.session_id))
    assert Ankole.Sessions.status(ctx.key) == %{state: :idle, retry_at: nil}

    assert {:ok, resumed} = queue_command(ctx, %{action: "resume"})
    assert resumed.conversation.metadata["queue_paused"] == false
    assert Queue.next_ready_event(ctx.agent.uid, ctx.key.session_id).id == first.id

    assert {:ok, duplicate_stop} =
             queue_command(ctx, %{
               action: "stop",
               command_id: command_id
             })

    assert duplicate_stop.conversation.metadata["queue_paused"] == false
  end

  test "send now releases only the selected message while the rest remain paused", ctx do
    first = post!(ctx, "Keep waiting", "queue")
    second = post!(ctx, "Send only this one", "queue")
    command_id = Ecto.UUID.generate()

    assert {:ok, _} =
             queue_command(ctx, %{
               action: "stop",
               command_id: command_id
             })

    assert {:ok, _} =
             Commands.interrupt(ctx.run, Repo.get_by!(Signal, source_event_id: command_id))

    assert {:ok, now} = change(ctx, "send_now", second)
    assert now.conversation.metadata["queue_paused"] == true
    assert Queue.next_ready_event(ctx.agent.uid, ctx.key.session_id).id == second.id
    assert Repo.reload!(first).data["delivery_mode"] == "queue"
    assert Repo.reload!(second).data["delivery_mode"] == "steer"
    assert Ankole.Sessions.status(ctx.key) == %{state: :queued, retry_at: nil}
    assert {:ok, selected_run} = Admission.admit(ctx.key, Repo.reload!(second))
    assert Ankole.Sessions.status(ctx.key) == %{state: :running, retry_at: nil}
    assert is_nil(Repo.reload!(first).last_attempt_at)
    assert {:ok, still_paused} = Conversations.get(ctx.human.uid, ctx.id)
    assert still_paused.conversation.metadata["queue_paused"] == true
    assert {:ok, _} = Run.finalize(selected_run, :silent)
    assert Ankole.Sessions.status(ctx.key) == %{state: :idle, retry_at: nil}
  end

  test "pending edits are scoped to the requesting Human and conversation", ctx do
    input = post!(ctx, "Private follow-up", "queue")
    other = human_fixture().principal

    assert {:error, :conversation_not_found} =
             Conversations.update_queue(other.uid, ctx.id, %{
               action: "edit",
               message_id: input.message_id,
               text: "Overwrite"
             })

    assert Repo.reload!(input).data["text"] == "Private follow-up"
  end

  test "unadmitted steering is withheld from background context until the real injection", ctx do
    input = post!(ctx, "An update that has not reached the active boundary", "steer")
    refute Ankole.JSON.encode!(Model.request(ctx.run)["input"]) =~ input.data["text"]
    assert is_nil(Repo.reload!(input).last_attempt_at)

    assert {:ok, [injected], _} =
             Run.inject_pending(%{ctx.run | pending_event_ids: [input.id]}, fn _ -> true end)

    assert injected.last_attempt_at
  end

  test "a stale editor or reorder cannot replace a newer saved queue", ctx do
    first = post!(ctx, "First draft", "queue")
    second = post!(ctx, "Second draft", "queue")
    {:ok, baseline} = Conversations.get(ctx.human.uid, ctx.id)
    assert {:ok, _} = change(ctx, "edit", first, text: "Saved in another tab")

    assert {:error, :queue_changed} =
             queue_command(ctx, %{
               action: "edit",
               message_id: first.message_id,
               text: "Stale overwrite",
               expected_version: baseline.queue_version
             })

    assert Repo.reload!(first).data["text"] == "Saved in another tab"

    assert {:error, :queue_changed} =
             queue_command(ctx, %{
               action: "reorder",
               message_ids: [second.message_id, first.message_id],
               expected_version: baseline.queue_version
             })

    assert {:ok, current} = Conversations.get(ctx.human.uid, ctx.id)
    assert Enum.map(current.pending_inputs, & &1.id) == [first.id, second.id]
  end

  test "a delayed Resume cannot release a queue paused by a later Stop", ctx do
    _input = post!(ctx, "Keep this paused", "queue")

    assert {:ok, first_stop} =
             queue_command(ctx, %{action: "stop", command_id: Ecto.UUID.generate()})

    assert {:ok, _} = queue_command(ctx, %{action: "resume"})
    assert {:ok, _} = queue_command(ctx, %{action: "stop", command_id: Ecto.UUID.generate()})

    assert {:error, :queue_changed} =
             queue_command(ctx, %{action: "resume", expected_version: first_stop.queue_version})

    assert {:ok, current} = Conversations.get(ctx.human.uid, ctx.id)
    assert current.conversation.metadata["queue_paused"] == true
  end

  test "editing the latest completed Human input retries the saved text through the real history owner",
       ctx do
    assert {:ok, %{job: job}} =
             Ankole.BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => ctx.key.session_id,
               "source_signal_id" => ctx.input.id,
               "source_tool_call_id" => Ecto.UUID.generate(),
               "reply_route" => %{"conversation_id" => ctx.id},
               "title" => "In-flight original work",
               "task" => "Prepare the original report."
             })

    assert {:ok, _} =
             Ankole.BackgroundAgentJobs.commit_status_with_wakeup(job.id, ctx.agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "original-edit-version"
             })

    reply = complete_reply(ctx, "Original answer")
    command_id = Ecto.UUID.generate()

    assert {:ok, changed} =
             queue_command(ctx, %{
               action: "edit_last",
               message_id: ctx.input.message_id,
               text: "Corrected request",
               expected_text: "Original work",
               command_id: command_id
             })

    assert Repo.get_by!(Message, id: ctx.input.message_id).text == "Corrected request"
    refute Enum.any?(changed.messages, &(&1.id == reply.id))
    assert Repo.reload!(ctx.input).data["text"] == "Original work"

    assert Ankole.Conversations.Route.human_request(%{job_id: job.id, agent_uid: ctx.agent.uid})[
             "text"
           ] == "Original work"

    retry = Queue.next_ready_event(ctx.agent.uid, ctx.key.session_id)
    assert retry.message_id == ctx.input.message_id
    assert retry.data["text"] == "Corrected request"

    assert Ankole.Conversations.Route.human_request(%{
             signal_id: retry.id,
             agent_uid: ctx.agent.uid
           })["text"] == "Corrected request"

    assert {:ok, run} = Admission.admit(ctx.key, retry)
    assert {:ok, {:preparing, run}} = Model.prepare(run)
    request = Ankole.JSON.encode!(Model.request(run)["input"])
    assert request =~ "Corrected request"
    refute request =~ "Original answer"
    count = Repo.aggregate(Signal, :count)

    assert {:ok, _} =
             queue_command(ctx, %{
               action: "edit_last",
               message_id: ctx.input.message_id,
               text: "Corrected request",
               expected_text: "Original work",
               command_id: command_id
             })

    assert Repo.aggregate(Signal, :count) == count
  end

  test "an attachment edit can clear text without changing the consumed input version", ctx do
    for text <- [nil, ""] do
      path = Path.join(System.tmp_dir!(), "native-edit-#{Ecto.UUID.generate()}.txt")
      File.write!(path, "Retained attachment")

      upload =
        try do
          assert {:ok, upload} =
                   Ankole.Conversations.Attachments.Native.upload(
                     ctx.human.uid,
                     Ecto.UUID.generate(),
                     "note.txt",
                     {:file, path},
                     "text/plain"
                   )

          upload
        after
          File.rm(path)
        end

      id = Ecto.UUID.generate()

      assert {:ok, detail} =
               Conversations.create(ctx.human.uid, %{
                 conversation_id: id,
                 agent_uid: ctx.agent.uid,
                 message_id: Ecto.UUID.generate(),
                 text: "Original attachment request",
                 attachments: [upload.receipt]
               })

      input = Repo.get_by!(Signal, conversation_id: id)
      key = %{agent_uid: ctx.agent.uid, session_id: detail.session_id}
      assert {:ok, run} = Admission.admit(key, input)
      assert {:ok, {:preparing, run}} = Model.prepare(run)
      current = %{ctx | id: id, input: input, key: key, run: run}
      _reply = complete_reply(current, "Attachment read")

      assert {:ok, _} =
               queue_command(current, %{
                 action: "edit_last",
                 message_id: input.message_id,
                 expected_text: "Original attachment request",
                 text: text,
                 command_id: Ecto.UUID.generate()
               })

      retry = Queue.next_ready_event(ctx.agent.uid, key.session_id)
      assert Repo.reload!(input).data["text"] == "Original attachment request"
      assert Repo.get_by!(Message, id: input.message_id).text == nil
      assert retry.data["text"] == nil
      assert retry.data["entry"]["text"] == nil
      assert length(retry.data["entry"]["attachments"]) == 1
    end
  end

  test "regenerate preserves the Human request and starts an actual new response turn", ctx do
    reply = complete_reply(ctx, "Replace this answer")
    assert {:ok, available} = Conversations.get(ctx.human.uid, ctx.id)
    assert available.retryable_message_id == reply.id

    assert {:ok, changed} =
             queue_command(ctx, %{
               action: "regenerate",
               message_id: reply.id,
               command_id: Ecto.UUID.generate()
             })

    assert Repo.get_by!(Message, id: ctx.input.message_id).text == "Original work"
    refute Enum.any?(changed.messages, &(&1.id == reply.id))
    retry = Queue.next_ready_event(ctx.agent.uid, ctx.key.session_id)
    assert retry.message_id == ctx.input.message_id
    assert {:ok, run} = Admission.admit(ctx.key, retry)
    assert {:ok, {:preparing, run}} = Model.prepare(run)
    assert Ankole.JSON.encode!(Model.request(run)["input"]) =~ "Original work"
  end

  test "a dead-letter reply exposes Retry and reaches a new real model request", ctx do
    assert {:ok, %{posted: %{messages: [notice]}}} =
             Run.finalize(ctx.run, :dead_letter, %{"code" => "test_failure"})

    assert notice.kind == :notice
    assert Repo.reload!(ctx.input).input_state == "dead_letter"
    assert {:ok, detail} = Conversations.get(ctx.human.uid, ctx.id)
    assert detail.retryable_message_id == notice.id

    assert {:ok, changed} =
             queue_command(ctx, %{
               action: "regenerate",
               message_id: notice.id,
               command_id: Ecto.UUID.generate()
             })

    assert is_nil(changed.retryable_message_id)
    refute Enum.any?(changed.messages, &(&1.id == notice.id))
    retry = Queue.next_ready_event(ctx.agent.uid, ctx.key.session_id)
    assert retry.message_id == ctx.input.message_id
    assert {:ok, run} = Admission.admit(ctx.key, retry)
    assert {:ok, {:preparing, run}} = Model.prepare(run)
    request = Ankole.JSON.encode!(Model.request(run)["input"])
    assert request =~ "Original work"
    refute request =~ notice.text
  end

  test "Stop and a model-configuration rejection are not retryable replies", ctx do
    command_id = Ecto.UUID.generate()
    assert {:ok, _} = queue_command(ctx, %{action: "stop", command_id: command_id})

    assert {:ok, _} =
             Commands.interrupt(ctx.run, Repo.get_by!(Signal, source_event_id: command_id))

    assert {:ok, stopped} = Conversations.get(ctx.human.uid, ctx.id)
    assert is_nil(stopped.retryable_message_id)

    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.create(ctx.human.uid, %{
               conversation_id: id,
               agent_uid: ctx.agent.uid,
               message_id: Ecto.UUID.generate(),
               text: "A request rejected before a model turn"
             })

    input = Repo.get_by!(Signal, conversation_id: id)

    assert {:ok, _} =
             Ankole.Sessions.Notices.finalize(
               {:error, {:model_profile_unavailable, "unavailable", %{}}},
               input,
               DateTime.utc_now(:microsecond)
             )

    assert {:ok, rejected} = Conversations.get(ctx.human.uid, id)
    notice = List.last(rejected.messages)
    assert notice.kind == :notice
    assert is_nil(rejected.retryable_message_id)

    assert {:error, :reply_unavailable} =
             Conversations.update_queue(ctx.human.uid, id, %{
               action: "regenerate",
               message_id: notice.id,
               command_id: Ecto.UUID.generate(),
               expected_version: rejected.queue_version
             })
  end

  test "an explicit retry captures the currently selected usable model instead of the failed profile",
       ctx do
    alias Ankole.AIAgent.ModelProfiles
    {:ok, heavy} = ModelProfiles.get_model_profile(ctx.agent.uid, "heavy")

    assert {:ok, _} =
             ModelProfiles.put_model_profile(
               ctx.agent.uid,
               "careful",
               Map.put(heavy, "description", "Careful")
             )

    id = Ecto.UUID.generate()

    assert {:ok, detail} =
             Conversations.create(ctx.human.uid, %{
               conversation_id: id,
               agent_uid: ctx.agent.uid,
               message_id: Ecto.UUID.generate(),
               text: "Use the selected model",
               model_profile: "careful"
             })

    input = Repo.get_by!(Signal, conversation_id: id)
    key = %{agent_uid: ctx.agent.uid, session_id: detail.session_id}
    assert {:ok, run} = Admission.admit(key, input)
    assert {:ok, {:preparing, run}} = Model.prepare(run)

    assert {:ok, %{posted: %{messages: [notice]}}} =
             Run.finalize(run, :dead_letter, %{"code" => "test_failure"})

    assert {:ok, _} = ModelProfiles.put_model_profile(ctx.agent.uid, "careful", nil)
    assert {:ok, _} = Conversations.set_model_profile(ctx.human.uid, id, nil)
    assert {:ok, failed} = Conversations.get(ctx.human.uid, id)

    command = %{
      action: "regenerate",
      message_id: notice.id,
      command_id: Ecto.UUID.generate(),
      expected_version: failed.queue_version
    }

    assert {:ok, _} = Conversations.update_queue(ctx.human.uid, id, command)
    retry = Queue.next_ready_event(ctx.agent.uid, key.session_id)
    assert Repo.reload!(input).data["model_profile"] == "careful"
    assert retry.data["model_profile"] == "primary"
    assert {:ok, _} = Conversations.set_model_profile(ctx.human.uid, id, nil)
    assert {:ok, _} = Conversations.update_queue(ctx.human.uid, id, command)
    assert Repo.reload!(retry).data["model_profile"] == "primary"
    assert {:ok, next} = Admission.admit(key, retry)
    assert next.spec.model_ref["profile"] == "primary"
  end

  test "executing or superseded inputs cannot be edited, and rejection changes no statements or commands",
       ctx do
    request = %{
      action: "edit_last",
      message_id: ctx.input.message_id,
      text: "Do not save",
      expected_text: "Original work",
      command_id: Ecto.UUID.generate()
    }

    assert {:error, :reply_unavailable} = queue_command(ctx, request)
    assert Repo.get_by!(Message, id: ctx.input.message_id).text == "Original work"
    assert is_nil(Repo.get_by(Signal, source_event_id: request.command_id))
    _reply = complete_reply(ctx, "Completed answer")
    _newer = post!(ctx, "A newer Human request", "queue")
    assert {:error, :reply_unavailable} = queue_command(ctx, request)
    assert Repo.get_by!(Message, id: ctx.input.message_id).text == "Original work"
    assert is_nil(Repo.get_by(Signal, source_event_id: request.command_id))
  end

  test "an expired completed-message editor cannot overwrite text saved elsewhere", ctx do
    _reply = complete_reply(ctx, "Completed answer")

    assert {:error, :queue_changed} =
             queue_command(ctx, %{
               action: "edit_last",
               message_id: ctx.input.message_id,
               text: "Stale replacement",
               expected_text: "Earlier unsaved text",
               command_id: Ecto.UUID.generate()
             })

    assert Repo.get_by!(Message, id: ctx.input.message_id).text == "Original work"
    assert Queue.next_ready_event(ctx.agent.uid, ctx.key.session_id) == nil
  end

  test "an exact retry after a lost edit response is accepted before queue CAS without repeating the edit",
       ctx do
    _reply = complete_reply(ctx, "Completed answer")
    {:ok, baseline} = Conversations.get(ctx.human.uid, ctx.id)

    command = %{
      action: "edit_last",
      message_id: ctx.input.message_id,
      text: "Committed correction",
      expected_text: "Original work",
      command_id: Ecto.UUID.generate(),
      expected_version: baseline.queue_version
    }

    assert {:ok, saved} = Conversations.update_queue(ctx.human.uid, ctx.id, command)
    refute saved.queue_version == baseline.queue_version
    count = Repo.aggregate(Signal, :count)
    assert {:ok, replayed} = Conversations.update_queue(ctx.human.uid, ctx.id, command)
    assert replayed.queue_version == saved.queue_version
    assert Repo.aggregate(Signal, :count) == count
    assert Repo.get_by!(Message, id: ctx.input.message_id).text == "Committed correction"

    assert {:error, :conversation_conflict} =
             Conversations.update_queue(ctx.human.uid, ctx.id, %{
               command
               | text: "Different operation under the same identity"
             })

    assert {:error, :queue_changed} =
             Conversations.update_queue(ctx.human.uid, ctx.id, %{
               command
               | command_id: Ecto.UUID.generate()
             })

    assert Repo.aggregate(Signal, :count) == count
  end

  defp complete_reply(ctx, text) do
    assert {:ok, response} =
             start_response_run(%{
               subject_uid: ctx.run.agent_uid,
               conversation_id: ctx.run.conversation.id,
               round_state: ctx.run,
               metadata: %{"request_metadata" => Run.metadata(ctx.run)}
             })

    assert {:ok, final} =
             ResponseCommit.commit_complete(response, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => text}]
               }
             ])

    assert {:ok, _} = Run.finalize(%{ctx.run | anchor: final.id})
    Repo.get_by!(Message, conversation_id: ctx.id, signal_id: ctx.input.id)
  end

  defp post!(ctx, text, mode) do
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.post(ctx.human.uid, ctx.id, %{
               message_id: message_id,
               text: text,
               delivery_mode: mode
             })

    Repo.get_by!(Signal, message_id: message_id)
  end

  defp change(ctx, action, input, attrs \\ []) do
    queue_command(ctx, Map.merge(Map.new(attrs), %{action: action, message_id: input.message_id}))
  end

  defp queue_command(ctx, attrs) do
    {:ok, detail} = Conversations.get(ctx.human.uid, ctx.id)

    Conversations.update_queue(
      ctx.human.uid,
      ctx.id,
      Map.put_new(attrs, :expected_version, detail.queue_version)
    )
  end
end
