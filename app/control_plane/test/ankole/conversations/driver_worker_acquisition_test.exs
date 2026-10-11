defmodule Ankole.Conversations.DriverWorkerAcquisitionTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Conversations.{Driver, Run, Tool, Worker}
  alias Ankole.Conversations.Driver.{PendingCall, State}
  alias Ankole.RuntimeFabric.V1, as: Proto
  alias Ankole.SignalsGateway.{ActorEvent, AIReplyPreview}
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker

  setup do
    %{principal: agent} = agent_fixture()
    key = %{agent_uid: agent.uid, session_id: "acquisition:#{Ecto.UUID.generate()}"}
    event = struct!(ActorEvent, Map.merge(key, %{id: Ecto.UUID.generate()}))
    {:global, preview_name} = AIReplyPreview.via_tuple(event)
    :yes = :global.register_name(preview_name, self())
    on_exit(fn -> :global.unregister_name(preview_name) end)

    tool = Tool.new(%{"name" => "command", "parameters" => %{"type" => "object"}}, :worker)
    call = %{"call_id" => "fresh", "name" => "command", "arguments" => "{}"}

    run = %Run{
      agent_uid: agent.uid,
      session_id: key.session_id,
      actor_event_id: event.id,
      epoch: 1,
      event: event,
      tools: [tool],
      calls: [call]
    }

    pending = %PendingCall{call: call, tool: tool, status: :worker_wait}
    %{data: %State{key: key, run: run, worker: :opening, pending: %{"fresh" => pending}}}
  end

  for {phase, label} <- [
        starting: "starting_computer",
        resuming: "resuming_computer",
        retrying: "computer_retrying",
        replacing: "computer_replacing",
        preparing: "computer_preparing"
      ] do
    test "#{phase} gives immediate feedback, renews demand, and starts one 60 second deadline", %{
      data: data
    } do
      phase = unquote(phase)
      label = "signals_gateway.reply.activity." <> unquote(label)
      set_demand(data, nil)
      before = System.monotonic_time(:millisecond)

      assert {:keep_state, waiting, [{{:timeout, :worker_acquire}, 60_000, :expired}]} =
               opened(data, {:wait, phase})

      assert System.monotonic_time(:millisecond) - before < 1_000
      assert_phase(label)
      assert waiting.worker == :waiting
      assert waiting.worker_wait_phase == phase
      assert Repo.get!(AgentWorker, data.key.agent_uid).wanted_until != nil

      assert {:keep_state, again, []} = opened(waiting, {:wait, :retrying})
      assert again.worker_wait_since == waiting.worker_wait_since
    end
  end

  for {reason, phase, label} <- [
        {:CAPACITY, :capacity, "computer_busy"},
        {:DRAINING, :replacing, "computer_replacing"}
      ] do
    test "#{reason} feedback and deadline do not depend on lifecycle readiness", %{data: data} do
      payload = %Proto.WorkspaceReady{run: Worker.ref(data.run), reason: unquote(reason)}

      assert {:keep_state, waiting, [{{:timeout, :worker_acquire}, 60_000, :expired}]} =
               Driver.handle_event(
                 :info,
                 {:worker, :workspace_ready, payload},
                 :executing_tools,
                 data
               )

      assert waiting.worker_wait_phase == unquote(phase)
      assert_phase("signals_gateway.reply.activity." <> unquote(label))
    end
  end

  test "readiness clears acquisition time and cancels its generic timeout", %{data: data} do
    data = %{
      data
      | worker: %{row: %{}, ready?: false},
        worker_wait_since: 1,
        worker_wait_phase: :capacity
    }

    payload = %Proto.WorkspaceReady{run: Worker.ref(data.run)}

    assert {:keep_state, ready, actions} =
             Driver.handle_event(
               :info,
               {:worker, :workspace_ready, payload},
               :executing_tools,
               data
             )

    assert ready.worker.ready?
    assert ready.worker_wait_since == nil
    assert {{:timeout, :worker_acquire}, :cancel} in actions
    assert ready.pending["fresh"].status == :queued

    assert :keep_state_and_data =
             Driver.handle_event({:timeout, :worker_acquire}, :expired, :executing_tools, ready)
  end

  for {phase, text} <- [
        {:preparing, "being prepared for a new version"},
        {:capacity, "busy with other tasks"},
        {:resuming, "did not become ready in time"},
        {:retrying, "did not become ready in time"}
      ] do
    test "#{phase} expiry returns an error, interrupts adoption, and keeps local work", %{
      data: data
    } do
      adopted = %{
        data.pending["fresh"]
        | call: %{"call_id" => "adopted", "name" => "command"},
          probe?: true
      }

      local = %{data.pending["fresh"] | status: :waiting}

      data = %{
        data
        | pending: Map.merge(data.pending, %{"adopted" => adopted, "local" => local}),
          worker_wait_since: System.monotonic_time(:millisecond),
          worker_wait_phase: unquote(phase)
      }

      assert {:keep_state, expired, [{:next_event, :internal, :tools}]} =
               Driver.handle_event({:timeout, :worker_acquire}, :expired, :executing_tools, data)

      assert expired.run.results["fresh"].is_error
      assert expired.run.results["fresh"].output =~ unquote(text)
      assert expired.run.results["adopted"] == Ankole.Conversations.Tools.interrupted()
      assert expired.pending == %{"local" => local}
    end
  end

  test "a generic acquisition timeout cannot affect another state", %{data: data} do
    for state <- [:requesting_model, :boundary, :finalizing, :idle] do
      assert :keep_state_and_data =
               Driver.handle_event({:timeout, :worker_acquire}, :expired, state, data)
    end
  end

  test "a broadcast during open cannot hide a newer rejection behind an old waiting result", %{
    data: data
  } do
    data = %{data | worker_changed?: true, worker_wait_since: 1, worker_wait_phase: :starting}
    assert {:keep_state, rechecking} = opened(data, {:wait, :starting})
    assert rechecking.worker == :opening
    refute rechecking.worker_changed?
    assert rechecking.worker_wait_since == data.worker_wait_since
    [{ref, {:worker_open, _pid}}] = Map.to_list(rechecking.tasks)
    assert_receive {^ref, {:error, :stale_driver}}, 1_000
  end

  test "Worker notices cannot open a workspace for local work or revive a failed acquisition", %{
    data: data
  } do
    for worker <- [nil, {:unavailable, {:timeout, :capacity}}] do
      data = %{data | worker: worker, pending: %{}, tasks: %{}}

      assert {:keep_state, unchanged, [{:next_event, :internal, :tools}]} =
               Driver.handle_event(
                 :info,
                 {:worker_changed, data.key.agent_uid},
                 :executing_tools,
                 data
               )

      assert unchanged == data

      assert {:keep_state, unchanged, _actions} =
               Driver.handle_event({:timeout, :worker_check}, :check, :executing_tools, data)

      assert unchanged == data
    end
  end

  test "terminal errors renew meaningful demand and hide internal reasons", %{data: data} do
    raw = "{:docker_api, 403, secret_platform_log}"
    set_demand(data, nil)

    assert {:keep_state, failed, [{:next_event, :internal, {:worker_unavailable, reason}}]} =
             opened(data, {:error, {:rejected, raw}})

    assert Repo.get!(AgentWorker, data.key.agent_uid).wanted_until != nil

    assert {:keep_state, finished, _} =
             Driver.handle_event(
               :internal,
               {:worker_unavailable, reason},
               :executing_tools,
               failed
             )

    assert finished.run.results["fresh"].output =~ "administrator must fix it in the Console"
    refute finished.run.results["fresh"].output =~ raw

    for reason <- [:agent_not_active, :agent_worker_unavailable] do
      set_demand(data, nil)
      assert {:keep_state, _, _} = opened(data, {:error, reason})
      assert Repo.get!(AgentWorker, data.key.agent_uid).wanted_until == nil
    end
  end

  test "streamed Worker calls use the dispatch catalog and request only once per run", %{
    data: data
  } do
    event = %{
      "type" => "response.output_item.added",
      "item" => %{"type" => "function_call", "name" => "command"}
    }

    set_demand(data, nil)

    for item <- [%{"type" => "message"}, put_in(event["item"]["namespace"], "other")] do
      assert {:keep_state, ignored} = stream(data, [item])
      refute ignored.worker_requested?
      assert Repo.get!(AgentWorker, data.key.agent_uid).wanted_until == nil
    end

    assert {:keep_state, requested} = stream(data, [event])
    assert requested.worker_requested?
    assert requested.worker == data.worker
    refute requested.workspace_opened?
    assert Repo.get!(AgentWorker, data.key.agent_uid).wanted_until != nil
    set_demand(data, nil)
    assert {:keep_state, _} = stream(requested, [event])
    assert Repo.get!(AgentWorker, data.key.agent_uid).wanted_until == nil
  end

  test "a streamed drive attachment or incomplete attachment cannot prewarm a computer", %{
    data: data
  } do
    attachment =
      Ankole.Conversations.Presentation.declarations()
      |> hd()
      |> Tool.new(Ankole.Conversations.Presentation)

    data = %{data | run: %{data.run | tools: [attachment]}}
    set_demand(data, nil)

    for arguments <- [
          nil,
          "{",
          "{}",
          Ankole.JSON.encode!(%{"drive_path" => "reports/answer.txt"})
        ] do
      event = %{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "name" => "reply_attachment",
          "arguments" => arguments
        }
      }

      assert {:keep_state, ignored} = stream(data, [event])
      refute ignored.worker_requested?
      assert Repo.get!(AgentWorker, data.key.agent_uid).wanted_until == nil
    end

    event = %{
      "type" => "response.output_item.added",
      "item" => %{
        "type" => "function_call",
        "name" => "reply_attachment",
        "arguments" => Ankole.JSON.encode!(%{"path" => "answer.txt"})
      }
    }

    assert {:keep_state, ignored} = stream(data, [event])
    refute ignored.worker_requested?
  end

  defp opened(data, result) do
    ref = make_ref()
    data = %{data | tasks: Map.put(data.tasks, ref, {:worker_open, self()})}
    Driver.handle_event(:info, {ref, result}, :executing_tools, data)
  end

  defp stream(data, events),
    do:
      Driver.handle_event(
        :info,
        {:ai_gateway_response_stream, make_ref(), :events, events, :continue},
        :requesting_model,
        data
      )

  defp set_demand(data, until),
    do:
      Repo.update_all(from(w in AgentWorker, where: w.agent_uid == ^data.key.agent_uid),
        set: [wanted_until: until]
      )

  defp assert_phase(label) do
    assert_received {:"$gen_cast",
                     {:for_event, _,
                      {:presentation_event,
                       %{"kind" => "turn.phase", "payload" => %{"label_key" => ^label}}}}}
  end
end
