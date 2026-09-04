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

  test "format_status exposes lifecycle state without request credentials or output" do
    state = %{
      phase: :opening,
      public_open?: false,
      ref: make_ref(),
      stateful: %{credential: "stateful-secret"},
      telemetry_emitted?: false,
      failure_logged?: false,
      describe_waiters: [self()],
      opening: %{api_key: "opening-secret"},
      native_stream: %{token: "native-secret"},
      credential_success_recorded?: false,
      provider_output?: true,
      stateful_replay_recovery_attempted?: false,
      outstanding_credit: 2,
      pending_flush: %{output: "private-output"},
      program_task: %{result: "private-result"},
      native_done?: false,
      closing?: false,
      heartbeat_timer: make_ref(),
      request: %{api_key: "request-secret"},
      prepared_request: %{authorization: "prepared-secret"},
      upstream_opts: [api_key: "upstream-secret"]
    }

    assert %{state: formatted} = ResponseStream.format_status(%{state: state})
    assert formatted.phase == :opening
    assert formatted.describe_waiter_count == 1
    assert formatted.outstanding_credit == 2
    assert formatted.stateful?
    assert formatted.provider_output?

    inspected = inspect(formatted)
    refute inspected =~ "request-secret"
    refute inspected =~ "prepared-secret"
    refute inspected =~ "upstream-secret"
    refute inspected =~ "private-output"
    refute inspected =~ "private-result"
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

  test "keeps response observation context out of provider options" do
    {:module, Ankole.AIGateway.Observability} =
      Code.ensure_loaded(Ankole.AIGateway.Observability)

    response_supervisor = Process.whereis(Supervisor)
    assert is_pid(response_supervisor)

    assert 1 =
             :erlang.trace_pattern(
               {Ankole.AIGateway.Observability, :start_response, 3},
               true,
               []
             )

    assert 1 = :erlang.trace(response_supervisor, true, [:call, :set_on_spawn])

    try do
      task_supervisor = start_supervised!({Task.Supervisor, max_children: 2})
      request_context = %{"headers" => %{"traceparent" => "test-parent"}}

      runner = fn _code, _bindings, _memo ->
        receive do
          :finish -> {:ok, %{status: :completed, output: [], pending_calls: []}}
        end
      end

      round_open = fn _request, _opts -> flunk("provider round must not open") end

      assert {:ok, stream, _meta} =
               ResponseStream.open(
                 "agent-test",
                 %{},
                 %{
                   api_resolver: :openai_chat_completions,
                   tool_loop: resume_tool_loop(round_open)
                 },
                 request_context: request_context,
                 subject_type: "agent",
                 caller: "codex_vision",
                 provider_sentinel: "preserved",
                 program_runner: runner,
                 program_task_supervisor: task_supervisor
               )

      assert_receive {:trace, traced_pid, :call,
                      {Ankole.AIGateway.Observability, :start_response,
                       ["agent-test", %{}, observation_opts]}}

      assert traced_pid == stream.pid
      assert observation_opts[:stateful] == nil
      assert observation_opts[:request_context] == request_context
      assert observation_opts[:subject_type] == "agent"
      assert observation_opts[:caller] == "codex_vision"

      assert :sys.get_state(stream.pid).upstream_opts == [provider_sentinel: "preserved"]
      assert :ok = ResponseStream.cancel(stream, "test_cleanup")
    after
      :erlang.trace(response_supervisor, false, [:call, :set_on_spawn])

      :erlang.trace_pattern(
        {Ankole.AIGateway.Observability, :start_response, 3},
        false,
        []
      )
    end
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
    assert get_in(failure_event, ["response", "error", "retryable"]) == true
    assert outcome.terminal_error["code"] == "resume_open_failed"

    assert Enum.any?(failure_event["response"]["output"], fn item ->
             item["type"] == "program_output" and item["call_id"] == "prog_resume"
           end)

    assert_receive {:DOWN, ^stream_monitor, :process, _, :normal}, 1_000
  end

  test "provider error frames stay diagnostic until one canonical terminal" do
    state = State.new("agent-test", %{}, %{})

    raw_error = %{
      "type" => "error",
      "sequence_number" => 0,
      "error" => %{
        "code" => "upstream_stream_break",
        "message" => "provider stream broke",
        "type" => "provider_disconnect"
      }
    }

    assert {:ok, state, [], :continue} = State.observe(state, raw_error, 0)

    assert state.provider_error_diagnostic == %{
             provider_error_code: "upstream_stream_break",
             provider_error_type: "provider_disconnect",
             provider_message: "provider stream broke"
           }

    synthesized_error = %{
      "type" => "error",
      "sequence_number" => 1,
      "error" => %{
        "code" => "upstream_stream_closed_before_terminal_event",
        "message" => "upstream stream closed before a terminal event"
      }
    }

    assert {:ok, ^state, [], :continue} = State.observe(state, synthesized_error, 1)

    terminal =
      failed_event(%{
        "code" => "upstream_stream_closed_before_terminal_event",
        "message" => "upstream stream closed before a terminal event"
      })
      |> Map.put("sequence_number", 2)

    assert {:ok, _state, [public_event],
            {:terminal, %{terminal_error: terminal_error}, :keep_upstream}} =
             State.observe(state, terminal, 2)

    assert public_event["type"] == "response.failed"
    assert public_event["sequence_number"] == 2
    assert terminal_error["code"] == "upstream_stream_closed_before_terminal_event"
    assert terminal_error["failure_kind"] == "transport"
    assert terminal_error["message"] == "provider stream broke"
    assert terminal_error["provider_error_code"] == "upstream_stream_break"
    assert terminal_error["provider_error_type"] == "provider_disconnect"
    assert terminal_error["retryable"] == true
    assert get_in(public_event, ["response", "error", "message"]) == "provider stream broke"
  end

  test "a local transport terminal keeps the first provider error as bounded diagnostics" do
    raw_error = %{
      "type" => "error",
      "error" => %{
        "code" => "upstream_stream_break",
        "message" => "provider stream broke"
      }
    }

    assert {:ok, state, [], :continue} =
             State.observe(State.new("agent-test", %{}, %{}), raw_error, 0)

    assert {_state, [public_event], %{terminal_error: terminal_error}} =
             State.fail(state, "provider stream closed",
               code: "provider_stream_closed_without_terminal",
               retryable: true
             )

    assert terminal_error["code"] == "provider_stream_closed_without_terminal"
    assert terminal_error["failure_kind"] == "transport"
    assert terminal_error["message"] == "provider stream broke"
    assert terminal_error["provider_error_code"] == "upstream_stream_break"
    assert terminal_error["retryable"] == true

    assert public_event["response"]["error"] == terminal_error
  end

  test "a provider validation frame becomes the canonical permanent terminal" do
    raw_error = %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "status" => 400,
        "message" =>
          "Invalid Value: 'tools'. Function 'collaboration.followup_task' must match the configured schema."
      }
    }

    assert {:ok, state, [], :continue} =
             State.observe(State.new("agent-test", %{}, %{}), raw_error, 0)

    terminal =
      failed_event(%{
        "code" => "upstream_stream_closed_before_terminal_event",
        "message" => "upstream stream closed before a terminal event"
      })

    assert {:ok, _state, [public_event],
            {:terminal, %{terminal_error: terminal_error}, :keep_upstream}} =
             State.observe(state, terminal, 1)

    assert terminal_error["code"] == "invalid_prompt"
    assert terminal_error["failure_kind"] == "provider_response"
    assert terminal_error["provider_error_type"] == "invalid_request_error"
    assert terminal_error["provider_status"] == 400
    assert terminal_error["retryable"] == false
    assert terminal_error["message"] =~ "must match the configured schema"
    assert get_in(public_event, ["response", "error"]) == Map.delete(terminal_error, "type")
  end

  test "a local failure always emits boolean retryability" do
    assert {_state, [public_event], %{terminal_error: terminal_error}} =
             State.fail(State.new("agent-test", %{}, %{}), "local failure", retryable: nil)

    assert terminal_error["retryable"] == false
    assert get_in(public_event, ["response", "error", "retryable"]) == false
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
                 "message" => "opaque provider text",
                 "retryable" => true
               }
             }, :keep_upstream}} =
             State.observe(State.new("agent-test", %{}, %{}), retryable_event, 0)

    assert get_in(public_event, ["response", "error"]) == %{
             "code" => "rate_limit_exceeded",
             "failure_kind" => "provider_response",
             "message" => "opaque provider text",
             "provider_error_code" => "rate_limit_exceeded",
             "retryable" => true
           }

    assert Ankole.JSON.encode!(public_event) =~ "opaque provider text"

    non_retryable_event =
      failed_event(%{
        "code" => "invalid_request",
        "message" => "rate limit 429 too many requests"
      })

    assert {:ok, _state, [public_event],
            {:terminal, %{terminal_error: terminal_error}, :keep_upstream}} =
             State.observe(State.new("agent-test", %{}, %{}), non_retryable_event, 0)

    assert terminal_error["retryable"] == false
    assert terminal_error["code"] == "invalid_prompt"
    assert terminal_error["message"] == "rate limit 429 too many requests"
    assert get_in(public_event, ["response", "error", "retryable"]) == false
    assert Ankole.JSON.encode!(public_event) =~ "rate limit 429 too many requests"

    context_event =
      failed_event(%{
        "code" => "context_length_exceeded",
        "type" => "invalid_request_error",
        "status" => 400,
        "message" => "The input exceeds the context window."
      })

    assert {:ok, _state, [_public_event],
            {:terminal, %{terminal_error: context_error}, :keep_upstream}} =
             State.observe(State.new("agent-test", %{}, %{}), context_event, 0)

    assert context_error["code"] == "context_length_exceeded"
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

  test "an anonymous terminal snapshot keeps the streamed public item" do
    streamed_item = %{
      "type" => "message",
      "id" => "msg_provider",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => "one answer"}]
    }

    state = State.new("agent-test", %{}, %{}) |> observe_done(streamed_item)

    terminal_item = Map.drop(streamed_item, ["id", "status"])

    assert {:ok, _state, [public_terminal],
            {:terminal, %{terminal_response: response}, :keep_upstream}} =
             State.observe(state, completed_event(terminal_item), 1)

    assert public_terminal["response"]["output"] == [streamed_item]
    assert response["output"] == [streamed_item]
  end

  test "a missing or short terminal output materializes the recorded item tail" do
    first = %{
      "type" => "message",
      "id" => "msg_first",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => "first"}]
    }

    second = %{
      "type" => "function_call",
      "id" => "fc_second",
      "call_id" => "call_second",
      "name" => "command",
      "arguments" => "{}",
      "status" => "completed"
    }

    state =
      State.new("agent-test", %{}, %{})
      |> observe_done(first, 0, 0)
      |> observe_done(second, 1, 1)

    short_terminal =
      first
      |> Map.drop(["id", "status"])
      |> completed_event()
      |> Map.put("sequence_number", 2)

    assert {:ok, _state, [public_terminal],
            {:terminal, %{terminal_response: response}, :keep_upstream}} =
             State.observe(state, short_terminal, 2)

    assert public_terminal["response"]["output"] == [first, second]
    assert response["output"] == [first, second]

    missing_output =
      completed_event(first)
      |> Map.update!("response", &Map.delete(&1, "output"))

    single_state = State.new("agent-test", %{}, %{}) |> observe_done(first)

    assert {:ok, _state, [public_terminal], {:terminal, _outcome, :keep_upstream}} =
             State.observe(single_state, missing_output, 1)

    assert public_terminal["response"]["output"] == [first]
  end

  test "a conflicting anonymous terminal item is not reconciled by output index" do
    streamed_item = %{
      "type" => "message",
      "id" => "msg_provider",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => "streamed"}]
    }

    state = State.new("agent-test", %{}, %{}) |> observe_done(streamed_item)

    terminal_item = %{
      "type" => "message",
      "id" => nil,
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "different"}]
    }

    assert {:ok, _state, [public_terminal], {:terminal, _outcome, :keep_upstream}} =
             State.observe(state, completed_event(terminal_item), 1)

    assert public_terminal["response"]["output"] == [terminal_item]
  end

  test "a tool loop does not admit an anonymous terminal call twice" do
    streamed_call = %{
      "type" => "function_call",
      "id" => "fc_provider",
      "call_id" => "call_probe",
      "name" => "sub2api_probe_noop",
      "arguments" => ~s({"nonce":"probe-1019"}),
      "status" => "completed"
    }

    state =
      State.new("agent-test", %{}, %{}, tool_loop: client_tool_loop())
      |> observe_done(streamed_call)

    terminal_call = Map.drop(streamed_call, ["id", "status"])

    assert {:ok, _state, [public_terminal],
            {:terminal, %{terminal_response: response}, :keep_upstream}} =
             State.observe(state, completed_event(terminal_call), 1)

    assert public_terminal["type"] == "response.completed"
    assert public_terminal["response"]["output"] == [streamed_call]
    assert response["output"] == [streamed_call]
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

  test "next/2 reports an owner killed mid-stream instead of hanging" do
    ref = make_ref()
    receiver = self()

    killer =
      spawn_link(fn ->
        receive do
          {:collector_read, pid, 1} ->
            receive do
              {:collector_read, ^pid, 1} ->
                Process.exit(pid, :kill)
                send(receiver, {:owner_killed, pid})
            end
        end
      end)

    {:ok, pid} = CollectorStream.start(self(), ref, [:continue, :hold], killer)
    stream = %ResponseStream{pid: pid, ref: ref}

    assert {:ok, [], :continue} = ResponseStream.next(stream, 1_000)
    assert {:error, {:response_stream_closed, :killed}} = ResponseStream.next(stream, 5_000)
    assert_receive {:owner_killed, ^pid}
    refute Process.alive?(pid)

    assert {:error, {:response_stream_closed, :noproc}} = ResponseStream.next(stream, 1_000)
    assert {:error, :response_stream_collect_timeout} = ResponseStream.next(stream, 0)
    refute_receive {:DOWN, _monitor, :process, ^pid, _reason}
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

  defp client_tool_loop do
    %StreamLoop{
      plan: %ToolSearch.Plan{execution: :client},
      provider_request: %{"input" => [], "tools" => []},
      downstream_tools: []
    }
  end

  defp observe_done(state, item, output_index \\ 0, sequence_number \\ 0) do
    event = %{
      "type" => "response.output_item.done",
      "sequence_number" => sequence_number,
      "output_index" => output_index,
      "item" => item
    }

    assert {:ok, new_state, [_done], :continue} =
             State.observe(state, event, sequence_number)

    new_state
  end

  defp completed_event(item) do
    %{
      "type" => "response.completed",
      "sequence_number" => 1,
      "response" => %{
        "id" => "resp_provider",
        "object" => "response",
        "status" => "completed",
        "output" => [item]
      }
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
