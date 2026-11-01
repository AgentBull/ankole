defmodule Ankole.RuntimeFabricTest do
  use ExUnit.Case, async: true

  alias Ankole.RuntimeFabric
  alias Ankole.RuntimeFabric.V1, as: V1

  test "runtime fabric protocol version is the one that sealed envelopes carry" do
    bytes =
      RuntimeFabric.seal_and_encode(%V1.Envelope{
        message_id: "protocol-version",
        body: {:control_shutdown, %V1.ControlShutdown{reason: "test"}}
      })

    assert {:ok, %V1.Envelope{protocol_version: version}} =
             Ankole.RuntimeFabric.V1.Envelope.decode(bytes)

    assert RuntimeFabric.protocol_version() == version
  end

  test "runtime fabric envelope structs round trip through the generated codec" do
    envelope = %V1.Envelope{
      message_id: "turn-start-1",
      body:
        {:turn_start,
         %V1.TurnStart{
           mode: "start",
           turn: job_turn_ref(),
           signal: signal_envelope(),
           fetch_runtime_config: %V1.FetchRuntimeConfig{ssrf_filter: true},
           model_ref: %V1.TurnModelRef{
             provider_id: "openrouter-main",
             model: "openai/gpt-5.4-mini",
             provider_kind: "openrouter"
           },
           request_context_json: Torque.encode!(%{kind: "schedule", silent_success_allowed: true})
         }}
    }

    encoded = RuntimeFabric.encode_envelope(envelope)

    assert is_binary(encoded)
    assert {:ok, ^envelope} = Ankole.RuntimeFabric.V1.Envelope.decode(encoded)
  end

  test "runtime fabric rejects a mismatched protocol version" do
    envelope = %V1.Envelope{protocol_version: 10, message_id: "old-version"}

    assert {:error, {:unsupported_protocol_version, 10}} =
             envelope |> RuntimeFabric.encode_envelope() |> RuntimeFabric.decode_and_validate()

    assert {:ok, %{protocol_version: version}} =
             envelope |> RuntimeFabric.seal_and_encode() |> RuntimeFabric.decode_and_validate()

    assert version == RuntimeFabric.protocol_version()
  end

  test "conversation protocol fixtures retain run identity, capacity, probe and adoption" do
    golden_dir = Path.expand("../../../kernel/proto/golden", __DIR__)

    for type <- [:workspace_open, :workspace_ready, :tool_call, :tool_status, :tool_result] do
      bytes = File.read!(Path.join(golden_dir, "#{type}.v11.bin"))
      assert {:ok, envelope} = Ankole.RuntimeFabric.V1.Envelope.decode(bytes)
      assert {^type, value} = envelope.body
      assert value.run.signal_id == "input-1"
      assert value.run.session.session_id == "job:1000"
      assert envelope.protocol_version == RuntimeFabric.protocol_version()

      case type do
        :workspace_ready ->
          assert value.reason == :CAPACITY

        :tool_call ->
          assert value.mode == "probe" and value.response_id == "response-1" and
                   value.call_id == "call-1"

        :tool_status ->
          assert value.state == "unknown"

        :tool_result ->
          assert Torque.decode!(value.content_json) == [%{"type" => "text", "text" => "done"}]

          assert value.images == [
                   File.read!(
                     Path.expand(
                       "../fixtures/sessions/rgba.png",
                       __DIR__
                     )
                   )
                 ]

        :workspace_open ->
          assert value.workspace_id == 10_000
          assert value.agent_context.soul == "Agent instructions"

          assert [%V1.RuntimeSkillSummary{skill_name: "design-md", skill_root: "library"}] =
                   value.agent_context.skills
      end
    end

    assert {:ok, %{body: {:turn_start, %{agent_context: context}}}} =
             Ankole.RuntimeFabric.V1.Envelope.decode(
               File.read!(Path.join(golden_dir, "turn_start.v11.bin"))
             )

    assert context.conversation.timezone == "Asia/Shanghai"
    assert context.soul == "Agent instructions" and context.mission == "Mission instructions"

    assert context.design == "Design instructions" and
             context.confidentiality_policy == "Keep operator facts private"

    assert context.skills_prompt == "    - design-md: Design documents"

    assert [%V1.RuntimeSkillSummary{skill_name: "design-md", metadata_json: metadata}] =
             context.skills

    assert Torque.decode!(metadata) == %{"ankole-runtime" => "any"}

    assert [
             %V1.AgentPluginCatalogEntry{
               id: "research",
               skills: [%V1.AgentPluginCatalogSkill{catalog_name: "deep-research"}]
             }
           ] = context.agent_plugins

    assert {:ok, %{body: {:turn_start, %{mode: "adopt"}}}} =
             Ankole.RuntimeFabric.V1.Envelope.decode(
               File.read!(Path.join(golden_dir, "turn_adopt.v11.bin"))
             )
  end

  test "runtime fabric golden bytes decode to the same structs across runtimes" do
    golden_dir = Path.expand("../../../kernel/proto/golden", __DIR__)

    with_field =
      golden_dir |> Path.join("turn_start.v11.bin") |> File.read!() |> V1.Envelope.decode!()

    assert {:turn_start, %V1.TurnStart{} = turn_start} = with_field.body

    assert turn_start.fetch_runtime_config == %V1.FetchRuntimeConfig{
             ssrf_filter: true,
             rendered_fetch_idle_ttl_ms: 60000
           }

    assert turn_start.signal.type == "cron.fire"

    assert Torque.decode!(turn_start.signal.payload_json) == %{
             "data" => %{
               "wake_payload" => %{
                 "cron_schedule_name" => "golden",
                 "payload" => %{}
               }
             }
           }

    assert Torque.decode!(turn_start.request_context_json) == %{
             "schedule_origin" => %{
               "cron_schedule_name" => "golden",
               "payload" => %{}
             },
             "silent_success_allowed" => true
           }

    assert with_field.protocol_version == RuntimeFabric.protocol_version()
    assert turn_start.mode == "start"
    assert turn_start.turn.job_id == 1000
    assert turn_start.turn.attempt == 1
    assert turn_start.turn.signal_id == turn_start.signal.signal_id

    request =
      golden_dir
      |> Path.join("rpc_read_tool_request.v11.bin")
      |> File.read!()
      |> V1.Envelope.decode!()

    assert {:rpc_request,
            %V1.RPCRequest{request_id: "golden-rpc-read-tool-1", method: "tools.read"} = frame} =
             request.body

    assert %V1.ReadToolRequest{name: "skill_view", arguments_json: args} =
             V1.ReadToolRequest.decode!(frame.payload)

    assert Torque.decode!(args) == %{"name" => "pdf"}

    response =
      golden_dir
      |> Path.join("rpc_read_tool_response.v11.bin")
      |> File.read!()
      |> V1.Envelope.decode!()

    assert {:rpc_response, %V1.RPCResponse{request_id: "golden-rpc-read-tool-1"} = frame} =
             response.body

    assert %V1.JSONPassthroughResponse{body_json: body} =
             V1.JSONPassthroughResponse.decode!(frame.payload)

    assert Torque.decode!(body) == %{
             "output" => "Prefer page-by-page verification.",
             "details" => %{"name" => "pdf"}
           }
  end

  test "Drive golden payloads preserve node identity and reserve the removed Pod selector" do
    dir = Path.expand("../../../kernel/proto/golden", __DIR__)

    {:rpc_request, request} =
      dir
      |> Path.join("rpc_files_get_request.v11.bin")
      |> File.read!()
      |> V1.Envelope.decode!()
      |> Map.fetch!(:body)

    assert request.method == "files.get"
    decoded = V1.FilesGetRequest.decode!(request.payload)
    assert decoded.node_id == "019a0000-0000-7000-8000-000000000001"
    assert decoded.home_relative_path == "downloads/report.txt"
    refute Map.has_key?(decoded, :pod_drive)
    assert V1.FilesGetRequest.decode!(<<24, 1>>).node_id == ""

    {:rpc_response, response} =
      dir
      |> Path.join("rpc_files_get_response.v11.bin")
      |> File.read!()
      |> V1.Envelope.decode!()
      |> Map.fetch!(:body)

    file = V1.FilesGetResponse.decode!(response.payload).file
    assert file.node_id == decoded.node_id
    assert file.object_id == "019a0000-0000-7000-8000-000000000002"
    assert file.size == 5_000_000_000
    refute Map.has_key?(%V1.ConversationInfo{}, :drive_directory)
  end

  @tag :regenerate_golden
  test "regenerates the control-plane golden envelopes with Protox" do
    dir = Path.expand("../../../kernel/proto/golden", __DIR__)

    for {name, envelope} <- control_plane_golden_envelopes() do
      File.write!(
        Path.join(dir, "#{name}.v#{RuntimeFabric.protocol_version()}.bin"),
        RuntimeFabric.seal_and_encode(envelope)
      )
    end
  end

  defp control_plane_golden_envelopes do
    event = %{
      signal_envelope()
      | type: "cron.fire",
        payload_json:
          Torque.encode!(%{data: %{wake_payload: %{cron_schedule_name: "golden", payload: %{}}}})
    }

    context = %V1.AgentConversationContextResponse{
      conversation: %V1.ConversationInfo{timezone: "Asia/Shanghai"},
      soul: "Agent instructions",
      mission: "Mission instructions",
      design: "Design instructions",
      confidentiality_policy: "Keep operator facts private",
      skills_prompt: "    - design-md: Design documents",
      skills: [
        %V1.RuntimeSkillSummary{
          skill_name: "design-md",
          description: "Design documents",
          source_kind: "builtin",
          skill_root: "library",
          relative_path: "skills/design-md",
          metadata_json: Torque.encode!(%{"ankole-runtime" => "any"})
        }
      ],
      agent_plugins: [
        %V1.AgentPluginCatalogEntry{
          id: "research",
          skills: [%V1.AgentPluginCatalogSkill{catalog_name: "deep-research"}]
        }
      ]
    }

    start = %V1.TurnStart{
      agent_context: context,
      mode: "start",
      turn: job_turn_ref(),
      signal: event,
      model_ref: %V1.TurnModelRef{
        provider_id: "openrouter-main",
        model: "openai/gpt-5.4-mini",
        provider_kind: "openrouter",
        input_modalities: ["text"]
      },
      request_context_json:
        Torque.encode!(%{
          schedule_origin: %{cron_schedule_name: "golden", payload: %{}},
          silent_success_allowed: true
        }),
      hosted_tools: [:HOSTED_TOOL_IMAGE_GENERATION],
      fetch_runtime_config: %V1.FetchRuntimeConfig{
        ssrf_filter: true,
        rendered_fetch_idle_ttl_ms: 60000
      }
    }

    run = %V1.RunRef{session: %V1.SessionKey{session_id: "job:1000"}, signal_id: "input-1"}

    response = %V1.JSONPassthroughResponse{
      body_json:
        Torque.encode!(%{
          "output" => "Prefer page-by-page verification.",
          "details" => %{"name" => "pdf"}
        })
    }

    {response_bytes, _size} = V1.JSONPassthroughResponse.encode!(response)

    [
      {"turn_start", %V1.Envelope{message_id: "golden-turn-start-1", body: {:turn_start, start}}},
      {"turn_adopt",
       %V1.Envelope{
         message_id: "golden-turn-start-1",
         body: {:turn_start, %{start | mode: "adopt"}}
       }},
      {"workspace_open",
       %V1.Envelope{
         message_id: "workspace_open.v11.bin",
         body:
           {:workspace_open,
            %V1.WorkspaceOpen{
              run: run,
              workspace_id: 10000,
              runtime_env: %{"ANKOLE_RUNTIME_CURRENT_ACTOR_SESSION_ID" => "im:1"},
              binding_name: "lark",
              fetch_runtime_config: %V1.FetchRuntimeConfig{
                ssrf_filter: true,
                rendered_fetch_idle_ttl_ms: 60000
              },
              idle_timeout_ms: 1_800_000,
              agent_context: %V1.AgentConversationContextResponse{
                soul: "Agent instructions",
                skills: [
                  %V1.RuntimeSkillSummary{
                    skill_name: "design-md",
                    source_kind: "builtin",
                    skill_root: "library",
                    relative_path: "skills/design-md"
                  }
                ]
              }
            }}
       }},
      {"tool_call",
       %V1.Envelope{
         message_id: "tool_call.v11.bin",
         body:
           {:tool_call,
            %V1.ToolCall{
              run: run,
              response_id: "response-1",
              call_id: "call-1",
              name: "command",
              arguments_json: Torque.encode!(%{command: "printf done"}),
              mode: "probe"
            }}
       }},
      {"rpc_files_get_response",
       %V1.Envelope{
         message_id: "golden-rpc-files-get-response-1",
         body:
           {:rpc_response,
            %V1.RPCResponse{
              request_id: "golden-rpc-files-get-1",
              payload:
                %V1.FilesGetResponse{
                  file: %V1.DriveFile{
                    path: "report.txt",
                    node_id: "019a0000-0000-7000-8000-000000000001",
                    object_id: "019a0000-0000-7000-8000-000000000002",
                    size: 5_000_000_000,
                    content_type: "text/plain",
                    mode: 420
                  }
                }
                |> V1.FilesGetResponse.encode!()
                |> elem(0)
                |> IO.iodata_to_binary()
            }}
       }},
      {"rpc_read_tool_response",
       %V1.Envelope{
         message_id: "golden-rpc-read-tool-response-1",
         body:
           {:rpc_response,
            %V1.RPCResponse{
              request_id: "golden-rpc-read-tool-1",
              payload: IO.iodata_to_binary(response_bytes)
            }}
       }}
    ]
  end

  defp job_turn_ref do
    %V1.JobTurnRef{
      job_id: 1000,
      attempt: 1,
      signal_id: "00000000-0000-0000-0000-000000000001"
    }
  end

  defp signal_envelope do
    %V1.SignalEnvelope{
      signal_id: "00000000-0000-0000-0000-000000000001",
      type: "im.message.addressed",
      binding_name: "lark",
      payload_json: Torque.encode!(%{text: "PING"})
    }
  end
end
