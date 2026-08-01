defmodule Ankole.AIGateway.ResponseStreamTest do
  use ExUnit.Case, async: false

  alias Ankole.AIGateway.MaxToolCalls
  alias Ankole.AIGateway.ProgrammaticToolCalling, as: PTC
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.AIGateway.ResponseStream.State
  alias Ankole.AIGateway.ResponseStream.Supervisor
  alias Ankole.AIGateway.ToolSearch
  alias Ankole.AIGateway.ToolSearch.StreamLoop
  alias Ankole.Kernel.UniversalAIClient

  defmodule CollectorStream do
    @moduledoc false

    use GenServer

    def start(receiver, ref, statuses, test_pid),
      do: GenServer.start(__MODULE__, {receiver, ref, statuses, test_pid})

    @impl true
    def init({receiver, ref, statuses, test_pid}) do
      {:ok, %{receiver: receiver, ref: ref, statuses: statuses, test_pid: test_pid}}
    end

    @impl true
    def handle_call({:read, count}, _from, state) do
      send(state.test_pid, {:collector_read, self(), count})

      case state.statuses do
        [:continue | statuses] ->
          send(
            state.receiver,
            {:ai_gateway_response_stream, state.ref, :events, [], :continue}
          )

          {:reply, :ok, %{state | statuses: statuses}}

        [{:terminal, outcome} | statuses] ->
          send(
            state.receiver,
            {:ai_gateway_response_stream, state.ref, :events, [], {:terminal, outcome}}
          )

          {:stop, :normal, :ok, %{state | statuses: statuses}}

        [:down | _statuses] ->
          {:stop, :normal, :ok, state}

        [:hold | _statuses] ->
          {:reply, :ok, state}

        [:block_read | _statuses] ->
          {:noreply, state}
      end
    end

    def handle_call({:cancel, reason}, _from, state) do
      send(state.test_pid, {:collector_cancel, self(), reason})
      {:stop, :normal, :ok, state}
    end

    @impl true
    def handle_cast({:cancel, reason}, state) do
      send(state.test_pid, {:collector_cancel, self(), reason})
      {:stop, :normal, state}
    end
  end

  test "a provider waiting for ready does not block other stream starts" do
    test_pid = self()

    slow_open = fn ->
      send(test_pid, {:slow_open_started, self()})

      receive do
        :release_slow_open -> {:error, :released}
      end
    end

    slow_starter =
      Task.async(fn -> Supervisor.start_stream(stream_opts(slow_open, test_pid)) end)

    assert {:ok, slow_pid} = Task.await(slow_starter, 1_000)
    assert_receive {:slow_open_started, slow_worker}
    assert slow_worker != slow_pid

    state = :sys.get_state(slow_pid)
    assert state.phase == :opening
    assert is_reference(state.owner_monitor)

    assert :ok =
             Task.async(fn -> GenServer.call(slow_pid, {:read, 1}) end)
             |> Task.await(250)

    assert :sys.get_state(slow_pid).outstanding_credit == 1

    fast_open = fn ->
      send(test_pid, {:fast_open_started, self()})
      {:error, :fast_failed}
    end

    fast_starter =
      Task.async(fn -> Supervisor.start_stream(stream_opts(fast_open, test_pid)) end)

    assert {:ok, fast_pid} = Task.await(fast_starter, 1_000)
    assert_receive {:fast_open_started, fast_worker}
    assert fast_worker != fast_pid

    slow_monitor = Process.monitor(slow_pid)
    fast_monitor = Process.monitor(fast_pid)

    assert {:error, :fast_failed} = GenServer.call(fast_pid, :describe)
    assert_receive {:DOWN, ^fast_monitor, :process, ^fast_pid, :normal}

    send(slow_worker, :release_slow_open)
    assert {:error, :released} = GenServer.call(slow_pid, :describe)

    assert_receive {:DOWN, ^slow_monitor, :process, ^slow_pid, :normal}, 2_000
  end

  test "owner DOWN terminates the opening worker instead of orphaning recovery" do
    test_pid = self()

    receiver =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    open_fun = fn ->
      send(test_pid, {:owner_down_open_started, self()})

      receive do
        :never -> {:error, :unexpected_release}
      end
    end

    assert {:ok, stream_pid} = Supervisor.start_stream(stream_opts(open_fun, receiver))
    assert_receive {:owner_down_open_started, worker_pid}

    stream_monitor = Process.monitor(stream_pid)
    worker_monitor = Process.monitor(worker_pid)
    Process.exit(receiver, :kill)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker_pid, _reason}, 1_000
    assert_receive {:DOWN, ^stream_monitor, :process, ^stream_pid, :normal}, 1_000
  end

  test "stale ready error retry and deadline messages cannot replace the current opening" do
    test_pid = self()

    open_fun = fn ->
      send(test_pid, {:stale_open_started, self()})

      receive do
        :never -> {:error, :unexpected_release}
      end
    end

    assert {:ok, stream_pid} = Supervisor.start_stream(stream_opts(open_fun, self()))
    assert_receive {:stale_open_started, worker_pid}
    worker_monitor = Process.monitor(worker_pid)

    before = :sys.get_state(stream_pid)
    stale_token = make_ref()
    {:ok, stale_url, stale_server} = start_cancel_observer_server()

    assert {:ok, stale_native_stream} =
             UniversalAIClient.open(stale_stream_spec(stale_url), receiver: stream_pid)

    assert_receive {:stale_stream_connected, ^stale_server}, 1_000
    stale_native_ref = stale_native_stream.ref

    send(stream_pid, {:universal_ai_client, stale_native_ref, :ready, %{"stale" => true}})
    send(stream_pid, {:universal_ai_client, stale_native_ref, :error, :stale_error})

    send(
      stream_pid,
      {:response_stream_custom_open, stale_token, {:ok, stale_native_stream, %{"stale" => true}}}
    )

    send(stream_pid, {:response_stream_custom_open, stale_token, {:error, :stale_error}})

    send(
      stream_pid,
      {:response_stream_retry_planned, stale_token, :stale_error, {:stop, :stale_retry, %{}}}
    )

    send(stream_pid, {:response_stream_open_deadline, stale_token})

    after_stale = :sys.get_state(stream_pid)
    assert after_stale.phase == :opening
    assert after_stale.opening.token == before.opening.token
    assert after_stale.opening.worker.pid == worker_pid
    refute after_stale.public_open?
    assert Process.alive?(worker_pid)
    assert_receive {:stale_stream_cancelled, ^stale_server}, 1_000

    stream = %ResponseStream{pid: stream_pid, ref: after_stale.ref}
    assert :ok = ResponseStream.cancel(stream, "test_cleanup")
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker_pid, _reason}, 1_000
  end

  test "ready processed after the absolute deadline cannot promote the opening" do
    test_pid = self()

    open_fun = fn ->
      send(test_pid, {:late_ready_open_started, self()})

      receive do
        :never -> {:error, :unexpected_release}
      end
    end

    assert {:ok, stream_pid} = Supervisor.start_stream(stream_opts(open_fun, self()))
    assert_receive {:late_ready_open_started, worker_pid}
    worker_monitor = Process.monitor(worker_pid)

    state =
      :sys.replace_state(stream_pid, fn state ->
        opening = %{
          state.opening
          | deadline_ms: System.monotonic_time(:millisecond) - 1
        }

        %{state | opening: opening}
      end)

    send(
      stream_pid,
      {:response_stream_custom_open, state.opening.token, {:ok, nil, %{"late" => true}}}
    )

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker_pid, _reason}, 1_000

    stream_monitor = Process.monitor(stream_pid)

    assert {:error,
            {:universal_ai_request_failed,
             %{"code" => "universal_ai_stream_ready_timeout", "stage" => "open"}}} =
             GenServer.call(stream_pid, :describe)

    assert_receive {:DOWN, ^stream_monitor, :process, ^stream_pid, :normal}, 1_000
  end

  test "retry settlement survives the response deadline and finishes independently" do
    test_pid = self()

    open_fun = fn ->
      send(test_pid, {:absolute_deadline_open_started, self()})

      receive do
        :never -> {:error, :unexpected_release}
      end
    end

    assert {:ok, stream_pid} = Supervisor.start_stream(stream_opts(open_fun, self()))
    assert_receive {:absolute_deadline_open_started, original_worker}

    {:ok, retry_worker} =
      Task.Supervisor.start_child(
        Ankole.AIGateway.ResponseRecoveryTaskSupervisor,
        fn ->
          send(test_pid, {:retry_worker_started, self()})

          receive do
            :finish_settlement ->
              send(test_pid, {:retry_settlement_finished, self()})
          end
        end
      )

    assert_receive {:retry_worker_started, ^retry_worker}
    retry_monitor = Process.monitor(retry_worker)

    state =
      :sys.replace_state(stream_pid, fn state ->
        Process.demonitor(state.opening.worker.monitor, [:flush])

        worker = %{
          pid: retry_worker,
          monitor: Process.monitor(retry_worker),
          kind: :retry_plan
        }

        opening = %{
          state.opening
          | worker: worker,
            deadline_ms: System.monotonic_time(:millisecond) - 1
        }

        %{state | opening: opening}
      end)

    assert :ok =
             Task.Supervisor.terminate_child(
               Ankole.AIGateway.ResponseRecoveryTaskSupervisor,
               original_worker
             )

    token = state.opening.token

    send(
      stream_pid,
      {:response_stream_retry_planned, token, :first_attempt_failed, {:retry, %{}, %{}, 0}}
    )

    stream_monitor = Process.monitor(stream_pid)

    assert {:error,
            {:universal_ai_request_failed,
             %{"code" => "universal_ai_stream_ready_timeout", "stage" => "open"}}} =
             GenServer.call(stream_pid, :describe)

    assert_receive {:DOWN, ^stream_monitor, :process, ^stream_pid, :normal}, 1_000
    refute_receive {:DOWN, ^retry_monitor, :process, ^retry_worker, _reason}, 50
    assert Process.alive?(retry_worker)

    send(retry_worker, :finish_settlement)
    assert_receive {:retry_settlement_finished, ^retry_worker}, 1_000
    assert_receive {:DOWN, ^retry_monitor, :process, ^retry_worker, :normal}, 1_000
  end

  test "a continuation open failure flushes buffered lifecycle and output before terminal" do
    task_supervisor = start_supervised!({Task.Supervisor, max_children: 2})
    test_pid = self()

    round_open = fn continuation_request, _opts ->
      send(test_pid, {:failing_resume_open_started, self(), continuation_request})

      receive do
        :fail_open -> {:error, :resume_open_failed}
      end
    end

    runner = fn _code, _bindings, _memo ->
      {:ok,
       %{
         status: :completed,
         output: [%{kind: "text", value: "resumed"}],
         pending_calls: []
       }}
    end

    assert {:ok, stream, _meta} =
             ResponseStream.open(
               "agent-test",
               %{},
               %{
                 api_resolver: :openai_chat_completions,
                 tool_loop: resume_tool_loop(round_open)
               },
               program_runner: runner,
               program_task_supervisor: task_supervisor
             )

    assert_receive {:failing_resume_open_started, open_worker, continuation_request}
    assert provider_input_has_output?(continuation_request["input"], "prog_resume")

    stream_monitor = Process.monitor(stream.pid)
    send(open_worker, :fail_open)

    assert_receive {:ai_gateway_response_stream, ref, :events,
                    [created_event, program_event, failure_event], {:terminal, outcome}}
                   when ref == stream.ref

    assert created_event["type"] == "response.created"
    assert created_event["sequence_number"] == 0
    assert program_event["item"]["type"] == "program_output"
    assert program_event["sequence_number"] == 1

    assert failure_event["type"] == "response.failed"
    assert failure_event["sequence_number"] == 2
    assert failure_event["response"]["id"] == created_event["response"]["id"]
    assert get_in(failure_event, ["response", "error", "code"]) == "resume_open_failed"
    assert outcome.terminal_error["code"] == "resume_open_failed"

    assert Enum.any?(failure_event["response"]["output"], fn item ->
             item["type"] == "program_output" and item["call_id"] == "prog_resume"
           end)

    assert_receive {:DOWN, ^stream_monitor, :process, _, :normal}, 1_000
  end

  test "provider terminal retry classification uses stable fields instead of messages" do
    retryable_event =
      failed_event(%{
        "code" => "rate_limit_exceeded",
        "message" => "opaque provider text"
      })

    assert {:ok, _state, [public_event],
            {:terminal,
             %{
               terminal_error: %{
                 "message" => "The upstream provider request failed.",
                 "retryable" => true
               }
             }, :keep_upstream}} =
             State.observe(State.new("agent-test", %{}, %{}), retryable_event, 0)

    assert get_in(public_event, ["response", "error"]) == %{
             "code" => "rate_limit_exceeded",
             "failure_kind" => "provider_response",
             "message" => "The upstream provider request failed.",
             "provider_error_code" => "rate_limit_exceeded",
             "retryable" => true
           }

    refute Ankole.JSON.encode!(public_event) =~ "opaque provider text"

    non_retryable_event =
      failed_event(%{
        "code" => "invalid_request",
        "message" => "rate limit 429 too many requests"
      })

    assert {:ok, _state, [public_event],
            {:terminal, %{terminal_error: terminal_error}, :keep_upstream}} =
             State.observe(State.new("agent-test", %{}, %{}), non_retryable_event, 0)

    assert terminal_error["retryable"] == false
    assert terminal_error["code"] == "invalid_request"
    assert terminal_error["message"] == "The upstream provider request failed."
    refute Ankole.JSON.encode!(terminal_error) =~ "rate limit 429 too many requests"
    refute Ankole.JSON.encode!(public_event) =~ "rate limit 429 too many requests"
  end

  test "completed with an unfinished tool call is one public and durable failure fact" do
    partial_call = %{
      "type" => "function_call",
      "call_id" => "call_partial",
      "name" => "lookup",
      "arguments" => "{",
      "status" => "in_progress"
    }

    event = %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_provider",
        "object" => "response",
        "status" => "completed",
        "output" => [partial_call]
      }
    }

    assert {:ok, _state, [public_event],
            {:terminal, %{terminal_response: response, terminal_error: error}, :keep_upstream}} =
             State.observe(State.new("agent-test", %{}, %{}), event, 0)

    assert public_event["type"] == "response.failed"
    assert response["status"] == "failed"
    assert response["error"]["code"] == "partial_tool_call_completed"
    assert error["type"] == "response.failed"
    assert error["code"] == "partial_tool_call_completed"
    assert response["output"] == [partial_call]
  end

  test "max-tool metadata cannot turn an unsupported incomplete terminal into success" do
    event = %{
      "type" => "response.incomplete",
      "response" => %{
        "id" => "resp_provider",
        "object" => "response",
        "status" => "incomplete",
        "provider_metadata" => %{"max_tool_calls" => %{"limit" => 1}},
        "output" => []
      }
    }

    assert {:ok, _state, [public_event], {:terminal, %{terminal_error: error}, :keep_upstream}} =
             State.observe(State.new("agent-test", %{}, %{}), event, 0)

    assert public_event["type"] == "response.incomplete"
    assert error["code"] == "response_incomplete"
    assert error["reason"] == "unknown"
  end

  test "a providerless initial local effect preserves the loop incomplete reason" do
    loop = %{resume_loop() | incomplete_reason: "program_history_limit_exceeded"}
    state = State.new("agent-test", %{}, %{}, tool_loop: loop)

    assert {:ok, state, [created], [_job], context} = State.take_initial_local_effect(state)

    outcomes = [
      %{
        call_id: "prog_resume",
        outcome: %{
          status: :completed,
          output: [],
          pending_calls: [],
          error: nil,
          error_code: nil
        }
      }
    ]

    assert {:ok, _state, [output, terminal],
            {:terminal, %{terminal_response: response}, :keep_upstream}} =
             State.complete_local_effect(state, context, outcomes)

    assert created["type"] == "response.created"
    assert created["sequence_number"] == 0
    assert output["item"]["type"] == "program_output"
    assert output["sequence_number"] == 1
    assert terminal["type"] == "response.incomplete"
    assert terminal["sequence_number"] == 2
    assert terminal["response"]["id"] == created["response"]["id"]
    assert response["status"] == "incomplete"

    assert response["incomplete_details"] == %{
             "reason" => "program_history_limit_exceeded"
           }
  end

  test "synchronous collector spends exactly one credit per continuation" do
    ref = make_ref()
    outcome = %{terminal_response: %{"id" => "resp_collected"}}

    {:ok, pid} =
      CollectorStream.start(self(), ref, [:continue, :continue, {:terminal, outcome}], self())

    stream = %ResponseStream{pid: pid, ref: ref}

    assert {:ok, ^outcome, %{"api_resolver" => "openai_responses"}} =
             ResponseStream.await_terminal(
               stream,
               %{"api_resolver" => "openai_responses"},
               1_000
             )

    assert_receive {:collector_read, ^pid, 1}
    assert_receive {:collector_read, ^pid, 1}
    assert_receive {:collector_read, ^pid, 1}
    refute_receive {:collector_read, ^pid, _count}
  end

  test "synchronous collector reports owner DOWN instead of hanging" do
    ref = make_ref()
    {:ok, pid} = CollectorStream.start(self(), ref, [:down], self())

    assert {:error, {:response_stream_closed, :normal}} =
             ResponseStream.await_terminal(%ResponseStream{pid: pid, ref: ref}, %{}, 1_000)

    assert_receive {:collector_read, ^pid, 1}
  end

  test "synchronous collector cancels a stalled owner at its total deadline" do
    ref = make_ref()
    {:ok, pid} = CollectorStream.start(self(), ref, [:hold], self())

    assert {:error, :response_stream_collect_timeout} =
             ResponseStream.await_terminal(%ResponseStream{pid: pid, ref: ref}, %{}, 25)

    assert_receive {:collector_read, ^pid, 1}
    assert_receive {:collector_cancel, ^pid, "synchronous_collector_timeout"}
  end

  test "synchronous collector deadline also bounds a blocked read call" do
    ref = make_ref()
    {:ok, pid} = CollectorStream.start(self(), ref, [:block_read], self())

    assert {:error, :response_stream_collect_timeout} =
             ResponseStream.await_terminal(%ResponseStream{pid: pid, ref: ref}, %{}, 25)

    assert_receive {:collector_read, ^pid, 1}
    assert_receive {:collector_cancel, ^pid, "synchronous_collector_timeout"}
  end

  test "resumed program execution leaves read heartbeat and cancel responsive" do
    task_supervisor = start_supervised!({Task.Supervisor, max_children: 2})
    test_pid = self()

    runner = fn _code, _bindings, _memo ->
      send(test_pid, {:program_runner_started, self()})

      receive do
        :release_program ->
          {:ok, %{status: :completed, output: [], pending_calls: []}}
      end
    end

    assert {:ok, stream, meta} =
             ResponseStream.open(
               "agent-test",
               %{"max_tool_calls" => 2},
               %{
                 api_resolver: :openai_chat_completions,
                 tool_loop: resume_loop()
               },
               program_runner: runner,
               program_task_supervisor: task_supervisor
             )

    assert meta["api_resolver"] == :openai_chat_completions
    assert_receive {:program_runner_started, program_pid}
    program_monitor = Process.monitor(program_pid)

    assert :ok =
             Task.async(fn -> ResponseStream.read(stream, 1) end)
             |> Task.await(250)

    assert_receive {:ai_gateway_response_stream, ref, :events, [created_event], :continue}
                   when ref == stream.ref

    assert created_event["type"] == "response.created"
    assert created_event["sequence_number"] == 0

    send(stream.pid, :response_stream_heartbeat)
    state = :sys.get_state(stream.pid)
    assert %MaxToolCalls{limit: 2} = state.semantic.max_tool_calls
    assert state.outstanding_credit == 0
    assert state.heartbeat_timer == nil

    assert :ok =
             Task.async(fn -> ResponseStream.cancel(stream, "test_cancel") end)
             |> Task.await(250)

    assert_receive {:DOWN, ^program_monitor, :process, ^program_pid, _reason}, 1_000
  end

  test "a frozen terminal program drains native done and chunks without observing twice" do
    task_supervisor = start_supervised!({Task.Supervisor, max_children: 2})
    test_pid = self()

    runner = fn _code, _bindings, _memo ->
      send(test_pid, {:frozen_program_started, self()})

      receive do
        :never_release ->
          {:ok, %{status: :completed, output: [], pending_calls: []}}
      end
    end

    assert {:ok, stream, _meta} =
             ResponseStream.open(
               "agent-test",
               %{},
               %{api_resolver: :openai_chat_completions, tool_loop: resume_loop()},
               program_runner: runner,
               program_task_supervisor: task_supervisor
             )

    assert_receive {:frozen_program_started, program_pid}
    program_monitor = Process.monitor(program_pid)
    native_ref = make_ref()
    before = :sys.get_state(stream.pid).semantic

    :sys.replace_state(stream.pid, fn state ->
      %{
        state
        | native_stream: %{ref: native_ref},
          outstanding_credit: 2
      }
    end)

    send(
      stream.pid,
      {:universal_ai_client, native_ref, :chunk, 99, :websocket_text,
       Ankole.JSON.encode!(failed_event(%{"code" => "late_duplicate"}))}
    )

    send(stream.pid, {:universal_ai_client, native_ref, :done, %{}})

    state = :sys.get_state(stream.pid)
    assert state.semantic == before
    assert state.outstanding_credit == 1
    assert state.native_done?
    refute_receive {:ai_gateway_response_stream, _, :events, _, _}

    :sys.replace_state(stream.pid, &%{&1 | native_stream: nil})
    assert :ok = ResponseStream.cancel(stream, "test_cleanup")
    assert_receive {:DOWN, ^program_monitor, :process, ^program_pid, _reason}, 1_000
  end

  test "buffered resume lifecycle and output consume one read credit before provider demand" do
    task_supervisor = start_supervised!({Task.Supervisor, max_children: 2})
    test_pid = self()
    native_ref = make_ref()

    round_open = fn continuation_request, _opts ->
      send(test_pid, {:resume_provider_opened, continuation_request})
      {:ok, %{ref: native_ref}, %{"api_resolver" => "openai_chat_completions"}}
    end

    runner = fn _code, _bindings, _memo ->
      {:ok,
       %{
         status: :completed,
         output: [%{kind: "text", value: "resumed"}],
         pending_calls: []
       }}
    end

    assert {:ok, stream, _meta} =
             ResponseStream.open(
               "agent-test",
               %{},
               %{
                 api_resolver: :openai_chat_completions,
                 tool_loop: resume_tool_loop(round_open)
               },
               program_runner: runner,
               program_task_supervisor: task_supervisor
             )

    assert_receive {:resume_provider_opened, continuation_request}
    assert provider_input_has_output?(continuation_request["input"], "prog_resume")

    assert :ok = ResponseStream.read(stream, 1)

    assert_receive {:ai_gateway_response_stream, ref, :events, [created, event], :continue}
                   when ref == stream.ref

    assert created["type"] == "response.created"
    assert event["item"]["type"] == "program_output"
    state = :sys.get_state(stream.pid)
    assert state.semantic.provider_response_id == created["response"]["id"]
    assert state.outstanding_credit == 0
    assert Process.alive?(stream.pid)

    :sys.replace_state(stream.pid, &%{&1 | native_stream: nil})
    assert :ok = ResponseStream.cancel(stream, "test_cleanup")
  end

  test "a saturated program task supervisor becomes an explicit terminal failure" do
    task_supervisor = start_supervised!({Task.Supervisor, max_children: 1})

    {:ok, occupant} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        receive do
          :stop -> :ok
        end
      end)

    test_pid = self()

    runner = fn _code, _bindings, _memo ->
      send(test_pid, :unexpected_program_execution)
      {:ok, %{status: :completed, output: [], pending_calls: []}}
    end

    assert {:ok, stream, _meta} =
             ResponseStream.open(
               "agent-test",
               %{},
               %{api_resolver: :openai_chat_completions, tool_loop: resume_loop()},
               program_runner: runner,
               program_task_supervisor: task_supervisor
             )

    assert :ok = ResponseStream.read(stream, 1)

    assert_receive {:ai_gateway_response_stream, ref, :events, [created_event, failed_event],
                    {:terminal, outcome}}
                   when ref == stream.ref

    assert created_event["type"] == "response.created"
    assert created_event["sequence_number"] == 0
    assert failed_event["type"] == "response.failed"
    assert failed_event["sequence_number"] == 1
    assert get_in(failed_event, ["response", "error", "code"]) == "program_runtime_busy"
    assert get_in(failed_event, ["response", "error", "retryable"]) == true
    assert outcome.terminal_error["code"] == "program_runtime_busy"
    refute_receive :unexpected_program_execution

    assert :ok = Task.Supervisor.terminate_child(task_supervisor, occupant)
    assert :ok = ResponseStream.cancel(stream, "test_cleanup")
  end

  defp stream_opts(open_fun, receiver) do
    [
      subject_uid: "agent_test",
      request: %{},
      stateful: nil,
      receiver: receiver,
      telemetry_spec: %{},
      open_fun: open_fun
    ]
  end

  defp resume_loop do
    %StreamLoop{
      plan: resume_plan(),
      provider_request: %{"input" => [], "tools" => []},
      downstream_tools: []
    }
  end

  defp resume_tool_loop(round_open) do
    %{
      plan: resume_plan(),
      provider_request: %{"input" => [], "tools" => []},
      round_open: round_open
    }
  end

  defp resume_plan do
    code = "text('resumed')"
    bindings = []

    %ToolSearch.Plan{
      ptc: %PTC.Plan{
        enabled?: true,
        program: %{
          tool_name: "program",
          bindings: bindings,
          synthesized_tool: %{}
        },
        resumes: [
          %{
            call_id: "prog_resume",
            code: code,
            fingerprint: PTC.fingerprint(code, bindings),
            memo: []
          }
        ]
      }
    }
  end

  defp provider_input_has_output?(input, call_id) when is_list(input) do
    Enum.any?(input, fn
      %{"type" => "function_call_output", "call_id" => ^call_id} -> true
      _item -> false
    end)
  end

  defp provider_input_has_output?(_input, _call_id), do: false

  defp stale_stream_spec(url) do
    %{
      api_resolver: :openai_responses,
      upstream: %{
        kind: :http_sse,
        method: "POST",
        url: url,
        headers: [{"content-type", "application/json"}],
        body: ~s({"stream":true}),
        timeout: %{connect_ms: 500, first_byte_ms: 5_000, idle_ms: 5_000, total_ms: nil},
        transport: %{http_versions: [:h1], compression: []}
      },
      downstream: :sse,
      response_context: %{model: "test-model", request: %{"input" => "hello"}}
    }
  end

  defp start_cancel_observer_server do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)
    test_pid = self()

    server =
      spawn_link(fn ->
        case :gen_tcp.accept(listen_socket) do
          {:ok, socket} ->
            case :gen_tcp.recv(socket, 0, 1_000) do
              {:ok, _request} ->
                send(test_pid, {:stale_stream_connected, self()})
                await_stale_stream_cancel(socket, test_pid)

              {:error, reason} ->
                send(test_pid, {:stale_stream_connect_failed, self(), reason})
            end

            :gen_tcp.close(socket)

          {:error, reason} ->
            send(test_pid, {:stale_stream_accept_failed, self(), reason})
        end

        :gen_tcp.close(listen_socket)
      end)

    {:ok, "http://127.0.0.1:#{port}/responses", server}
  end

  defp await_stale_stream_cancel(socket, test_pid) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, _remaining_request} ->
        await_stale_stream_cancel(socket, test_pid)

      {:error, reason} when reason in [:closed, :econnreset] ->
        send(test_pid, {:stale_stream_cancelled, self()})

      {:error, reason} ->
        send(test_pid, {:stale_stream_cancel_failed, self(), reason})
    end
  end

  defp failed_event(error) do
    %{
      "type" => "response.failed",
      "sequence_number" => 0,
      "response" => %{
        "id" => "provider-response",
        "object" => "response",
        "status" => "failed",
        "error" => error,
        "output" => []
      }
    }
  end
end
