defmodule Ankole.KernelTest do
  use ExUnit.Case, async: false

  alias Ankole.Kernel.RuntimeFabric
  alias Ankole.Kernel.UniversalAIClient
  alias Ankole.Kernel, as: NativeKernel

  @aead_key "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
  @aead_ciphertext "vveE4WxRjp0KO8YVx7o09aQ5_q9ZzqX2.gb1S9PmqEp_5UuejAzvKErXrdE4-sQ"

  test "encoded bridge helpers are not exported as public kernel functions" do
    refute function_exported?(NativeKernel, :authz_authorize_json, 1)
    refute function_exported?(NativeKernel, :authz_authorize_all_json, 1)
    refute function_exported?(NativeKernel, :runtime_fabric_encode_envelope_json, 1)
    refute function_exported?(NativeKernel, :runtime_fabric_decode_envelope_json, 1)
    refute function_exported?(NativeKernel, :signals_gateway_filter_match_json, 2)
    refute function_exported?(NativeKernel, :jwt_decode_header_json, 1)
    refute function_exported?(NativeKernel, :jwt_sign_json, 3)
    refute function_exported?(NativeKernel, :jwt_verify_json, 3)
  end

  test "hash helpers use the shared BLAKE3 vectors" do
    assert NativeKernel.generic_hash("bullx") ==
             "7f31cabae40697f9404428671c582d3c1f80c8a13d0741f4be8c9b856fcc0706"

    assert NativeKernel.bs58_hash("bullx") == "9ZWpCkNYVXH91wFYb4cygXBxLe2xwsK9rBTVxwPMicWZ"

    assert NativeKernel.derive_key("seed", "tenant-A", "scope-a") ==
             "0553f445a2fb3dfc0fab4efa1e1ed31ef6a103277286cf63874904e341ee0d20"
  end

  test "generate_key/0 returns a hex encoded key" do
    assert NativeKernel.generate_key() =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "aead helpers encrypt and decrypt compact payloads" do
    encrypted = NativeKernel.aead_encrypt("secret", @aead_key)

    assert [_nonce, _ciphertext] = String.split(encrypted, ".")
    refute String.contains?(encrypted, "=")
    assert NativeKernel.aead_decrypt(encrypted, @aead_key) == "secret"
    assert NativeKernel.aead_decrypt(@aead_ciphertext, @aead_key) == "secret"
  end

  test "jwt helpers sign, verify, and decode headers" do
    token =
      NativeKernel.jwt_sign(
        %{
          iss: "ankole.control_plane",
          aud: "ankole.web_console",
          sub: "human-1",
          exp: 4_102_444_800,
          token_use: "access"
        },
        "jwt-secret",
        %{algorithm: "HS256", key_id: "test-key"}
      )

    assert %{
             "aud" => "ankole.web_console",
             "sub" => "human-1",
             "token_use" => "access"
           } =
             NativeKernel.jwt_verify(token, "jwt-secret", %{
               algorithms: ["HS256"],
               iss: ["ankole.control_plane"],
               aud: ["ankole.web_console"],
               sub: "human-1"
             })

    assert %{"algorithm" => "HS256", "key_id" => "test-key"} =
             NativeKernel.jwt_decode_header(token)
  end

  test "runtime fabric helpers encode and decode protobuf envelopes" do
    envelope = %{
      protocol_version: 1,
      message_id: "turn-start-1",
      correlation_id: "corr-1",
      lane: "LANE_TURN",
      sent_at_unix_ms: 1_782_300_000_000,
      durability: "CONTROL_REPLAYABLE",
      body: %{
        type: "turn_start",
        turn_start: %{
          turn: actor_turn_ref(),
          inputs: [
            %{
              actor_input_id: "input-1",
              live_queue_sequence: 1,
              type: "im.message.addressed",
              ingress_event_id: "event-1",
              provider_entry_id: "message-1",
              payload_json: %{"text" => "PING"}
            }
          ]
        }
      }
    }

    encoded = RuntimeFabric.encode_envelope(envelope)

    assert is_binary(encoded)

    assert %{
             "body" => %{
               "type" => "turn_start",
               "turn_start" => %{
                 "turn" => %{
                   "actor" => %{
                     "agent_uid" => "agent-1",
                     "session_id" => "signal-channel:lark:dm:1"
                   }
                 },
                 "inputs" => [%{"payload_json" => %{"text" => "PING"}}]
               }
             }
           } = RuntimeFabric.decode_envelope(encoded)
  end

  test "runtime fabric rejects profile fields on ActorKey" do
    assert {:error, reason} =
             RuntimeFabric.encode_envelope(%{
               protocol_version: 1,
               message_id: "turn-start-profile",
               correlation_id: "turn-start-profile",
               lane: "LANE_TURN",
               durability: "CONTROL_REPLAYABLE",
               body: %{
                 type: "turn_start",
                 turn_start: %{
                   turn: put_in(actor_turn_ref(), [:actor, :display_name], "ReleaseBot"),
                   inputs: []
                 }
               }
             })

    assert reason =~ "ActorKey must not carry display_name"
  end

  test "runtime fabric encodes and decodes generic RPC envelopes" do
    encoded =
      RuntimeFabric.encode_envelope(%{
        protocol_version: 1,
        message_id: "rpc-conversation-context",
        correlation_id: "rpc-conversation-context",
        lane: "LANE_RPC",
        durability: "CONTROL_EPHEMERAL",
        body: %{
          type: "rpc_request",
          rpc_request: %{
            request_id: "rpc-conversation-context",
            method: "agent_conversation.context.resolve",
            payload_json: %{
              turn: %{actor: %{agent_uid: "agent-1", session_id: "signal-channel:lark:dm:1"}}
            }
          }
        }
      })

    assert %{
             "body" => %{
               "type" => "rpc_request",
               "rpc_request" => %{"method" => "agent_conversation.context.resolve"}
             }
           } =
             RuntimeFabric.decode_envelope(encoded)
  end

  test "runtime fabric encodes and decodes final proposal reply attachments" do
    encoded =
      RuntimeFabric.encode_envelope(%{
        protocol_version: 1,
        message_id: "turn-final-1",
        correlation_id: "turn-start-1",
        lane: "LANE_TURN",
        durability: "CONTROL_DURABLE",
        body: %{
          type: "turn_final_proposal",
          turn_final_proposal: %{
            turn: actor_turn_ref(),
            messages: [],
            reply: %{
              text: "Here is the report.",
              content_json: [%{type: "text", text: "Here is the report."}],
              attachments: [
                %{
                  agent_computer_path: "/workspace/user-files/reports/a.txt",
                  user_files_relative_path: "reports/a.txt",
                  name: "report.txt",
                  mime_type: "text/plain",
                  size: 16
                }
              ]
            }
          }
        }
      })

    assert %{
             "body" => %{
               "turn_final_proposal" => %{
                 "reply" => %{
                   "attachments" => [
                     %{
                       "agent_computer_path" => "/workspace/user-files/reports/a.txt",
                       "user_files_relative_path" => "reports/a.txt",
                       "name" => "report.txt",
                       "mime_type" => "text/plain",
                       "size" => 16
                     }
                   ]
                 }
               }
             }
           } = RuntimeFabric.decode_envelope(encoded)
  end

  test "runtime fabric turn_control steer payload must be journaled, not inline" do
    assert {:error, reason} =
             NativeKernel.runtime_fabric_encode_envelope(%{
               protocol_version: 1,
               message_id: "steer-1",
               correlation_id: "steer-1",
               lane: "LANE_CONTROL",
               durability: "CONTROL_DURABLE",
               body: %{
                 type: "turn_control",
                 turn_control: %{
                   turn: actor_turn_ref(),
                   command: "steer",
                   payload_json: %{"text" => "inline steer is not allowed"}
                 }
               }
             })

    assert reason =~ "steer payload must be empty"
  end

  test "runtime fabric body must use its declared lane and durability" do
    assert {:error, reason} =
             NativeKernel.runtime_fabric_encode_envelope(%{
               protocol_version: 1,
               message_id: "turn-start-wrong-lane",
               lane: "LANE_CONTROL",
               durability: "CONTROL_EPHEMERAL",
               body: %{
                 type: "turn_start",
                 turn_start: %{
                   turn: actor_turn_ref(),
                   inputs: [
                     %{
                       actor_input_id: "input-1",
                       live_queue_sequence: 1,
                       type: "im.message.addressed",
                       ingress_event_id: "event-1"
                     }
                   ]
                 }
               }
             })

    assert reason =~ "turn_start must use lane LANE_TURN"
  end

  test "runtime fabric router maps mandatory unknown routes" do
    assert {:ok, router} =
             RuntimeFabric.router_start("tcp://127.0.0.1:*", self(),
               worker_auth_key: "test-token",
               poll_interval_ms: 1
             )

    on_exit(fn -> RuntimeFabric.router_stop(router) end)

    assert endpoint = RuntimeFabric.router_endpoint(router)
    assert endpoint =~ "tcp://"

    assert {:error, :unknown_route} =
             RuntimeFabric.router_send_mandatory(router, "missing-worker", turn_start_envelope())
  end

  test "encoding helpers preserve binary payloads" do
    assert NativeKernel.base58_encode("Hello World!") == "2NEpo7TZRRrLZSi2U"
    assert NativeKernel.base58_decode("2NEpo7TZRRrLZSi2U") == "Hello World!"

    assert NativeKernel.base64_url_safe_encode("bullx") == "YnVsbHg"
    assert NativeKernel.base64_url_safe_decode("YnVsbHg") == "bullx"
  end

  test "authz helpers evaluate snapshots without host database access" do
    assert NativeKernel.authz_validate_condition(~s(principal.type == "human"))
    assert NativeKernel.authz_validate_resource_pattern("workspace:**")
    assert NativeKernel.authz_match_resource_pattern("workspace:**", "workspace:default")

    decision =
      NativeKernel.authz_authorize(%{
        principal: %{
          uid: "alice",
          type: "human",
          status: "active"
        },
        staticGroupIds: [],
        computedGroups: [],
        grants: [
          %{
            id: "grant-1",
            principalUid: "alice",
            resourcePattern: "workspace:**",
            action: "read",
            condition: ~s(context.request.source == "test")
          }
        ],
        resource: "workspace:default",
        action: "read",
        context: %{source: "test"}
      })

    assert decision["status"] == "allow"
    assert decision["diagnostics"] == []
    assert decision["effectiveGroupIds"] == []
  end

  test "signals gateway CEL filters evaluate normalized contexts" do
    context = %{
      binding: %{name: "bot", adapter: "lark"},
      signal: %{
        kind: "entry_received",
        channel: %{id: "lark:chat:group-a", kind: "im_group", reply_mode: "entry"},
        entry: %{
          id: "msg-1",
          sender_key: "lark:user:alice",
          text: "hello from lark",
          metadata: %{repository: "ankole"}
        }
      }
    }

    assert NativeKernel.signals_gateway_validate_filter(
             "signal.channel.id == 'lark:chat:group-a'"
           )

    assert NativeKernel.signals_gateway_filter_match(
             "binding.name == 'bot' && signal.entry.sender_key.startsWith('lark:user:')",
             context
           )

    assert NativeKernel.signals_gateway_filter_match(
             "signal.entry.text.contains('hello') && signal.entry.sender_key.matches('^lark:user:[a-z]+$')",
             context
           )

    assert NativeKernel.signals_gateway_filter_match(
             "[1, 2, 3].all(n, n > 0) && ['a', 'bb', 'ccc'].filter(v, v.size() > 1).map(v, v.size()).exists(size, size == 3)",
             context
           )

    refute NativeKernel.signals_gateway_filter_match("signal.channel.kind == 'im_dm'", context)

    assert {:error, reason} =
             NativeKernel.signals_gateway_filter_match("signal.entry.text", context)

    assert reason =~ "signal filter returned string"

    assert {:error, reason} =
             NativeKernel.signals_gateway_filter_match("signal.entry.missing", context)

    assert reason =~ "signal filter execution failed"
    assert {:error, reason} = NativeKernel.signals_gateway_validate_filter("signal.")
    assert reason =~ "invalid signal filter"
  end

  test "authz batch decisions report the first denied action" do
    decision =
      NativeKernel.authz_authorize_all(%{
        principal: %{
          uid: "alice",
          type: "human",
          status: "active"
        },
        staticGroupIds: [],
        computedGroups: [],
        grants: [
          %{
            id: "grant-1",
            principalUid: "alice",
            resourcePattern: "workspace:**",
            action: "read",
            condition: "true"
          }
        ],
        resource: "workspace:default",
        actions: ["read", "write"],
        context: %{}
      })

    assert decision["status"] == "deny"
    assert decision["deniedAction"] == "write"
  end

  test "text and checksum helpers match existing vectors" do
    assert NativeKernel.any_ascii("Björk") == "Bjork"
    assert NativeKernel.crc32("TestCase😊") == 1_198_634_863
    assert NativeKernel.crc32_hex("TestCase😊") == "4771b76f"
    assert NativeKernel.xxh3_128_hex("TestCase") == "7b16fe7c3e492b87d9615265f0856cec"
    assert NativeKernel.phone_normalize_e164("+1 415 555 2671") == "+14155552671"
    assert {:error, _reason} = NativeKernel.phone_normalize_e164("13800000000")
  end

  test "uuid helpers return the expected textual formats" do
    assert NativeKernel.gen_uuid() =~
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    assert NativeKernel.gen_uuid_v7() =~
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    assert NativeKernel.gen_base36_uuid() =~ ~r/\A[0-9a-z]+\z/
    assert NativeKernel.gen_short_uuid() =~ ~r/\A[1-9A-HJ-NP-Za-km-z]+\z/
  end

  test "universal AI client sends raw HTTP requests" do
    {:ok, url} = start_http_json_server(%{"ok" => true, "value" => 42})

    assert {:ok,
            %{
              "status" => 200,
              "body" => %{"ok" => true, "value" => 42},
              "http_version" => "http/1.1",
              "http_negotiation" => "h1_only"
            }} =
             UniversalAIClient.raw_post(%{
               url: url,
               headers: [{"content-type", "application/json"}],
               body: ~s({"hello":"world"}),
               timeout: %{connect_ms: 500, first_byte_ms: 500, idle_ms: 500, total_ms: nil},
               transport: %{http_versions: [:h1], compression: []}
             })

    assert_receive {:http_json_server_request, request}, 1_000
    assert request =~ "POST /json HTTP/1.1"
    assert request =~ ~s({"hello":"world"})
  end

  test "universal AI client caps slow-drip non-stream response bodies" do
    {:ok, url} =
      start_slow_chunked_json_server(["{", ~s("ok"), ":", "true", ",", ~s("slow"), ":", "true"],
        delay_ms: 25
      )

    assert {:error,
            %{
              "code" => "total_timeout",
              "stage" => "read",
              "message" => "upstream response body total timeout"
            }} =
             UniversalAIClient.raw_post(%{
               url: url,
               headers: [{"content-type", "application/json"}],
               body: ~s({"hello":"world"}),
               timeout: %{connect_ms: 500, first_byte_ms: 500, idle_ms: 500, total_ms: 80},
               transport: %{http_versions: [:h1], compression: []}
             })

    assert_receive {:http_slow_json_server_request, request}, 1_000
    assert request =~ "POST /json HTTP/1.1"
  end

  test "universal AI client model_request builds model body natively" do
    {:ok, url} = start_http_json_server(%{"id" => "resp_test", "status" => "completed"})

    assert {:ok, %{"status" => 200, "body" => %{"id" => "resp_test", "model" => "test-model"}}} =
             UniversalAIClient.model_request(%{
               api_resolver: :openai_responses,
               upstream: %{
                 method: "POST",
                 url: url,
                 headers: [{"content-type", "application/json"}],
                 timeout: %{connect_ms: 500, first_byte_ms: 500, idle_ms: 500, total_ms: nil},
                 transport: %{http_versions: [:h1], compression: []}
               },
               response_context: %{model: "test-model", request: %{"input" => "hello"}}
             })

    assert_receive {:http_json_server_request, request}, 1_000
    assert request =~ "POST /json HTTP/1.1"
    assert request =~ ~s("model":"test-model")
    assert request =~ ~s("input":"hello")
  end

  test "universal AI client waits for ready and demand before sending SSE chunks" do
    {:ok, url} =
      start_http_sse_server([
        "event: response.created\ndata: {\"type\":\"response.created\"}\n\n",
        "event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n",
        "data: [DONE]\n\n"
      ])

    {:ok, stream} =
      UniversalAIClient.open(%{
        api_resolver: :openai_responses,
        upstream: %{
          kind: :http_sse,
          method: "POST",
          url: url,
          headers: [{"content-type", "application/json"}],
          body: ~s({"stream":true}),
          timeout: %{connect_ms: 500, first_byte_ms: 500, idle_ms: 500, total_ms: nil},
          transport: %{http_versions: [:h1], compression: []}
        },
        downstream: :sse,
        response_context: %{model: "test-model", request: %{"input" => "hello"}}
      })

    assert_receive {:universal_ai_client, ref, :ready,
                    %{"downstream_kind" => "sse", "status" => 200}},
                   1_000

    assert ref == stream.ref
    refute_receive {:universal_ai_client, ^ref, :chunk, _, _, _}, 100

    assert :ok = UniversalAIClient.read(stream, 1)

    assert_receive {:universal_ai_client, ^ref, :chunk, 1, :sse, chunk}, 1_000
    assert is_binary(chunk)
    assert chunk =~ "event: response.created\n"
    assert chunk =~ "\"type\":\"response.created\""
    assert chunk =~ "\"sequence_number\":0"

    refute_receive {:universal_ai_client, ^ref, :chunk, 2, :sse, _}, 100

    assert :ok = UniversalAIClient.read(stream, 1)
    assert_receive {:universal_ai_client, ^ref, :chunk, 2, :sse, done_chunk}, 1_000
    assert done_chunk =~ "event: response.completed\n"

    assert :ok = UniversalAIClient.read(stream, 1)
    assert_receive {:universal_ai_client, ^ref, :chunk, 3, :sse, sentinel}, 1_000
    assert sentinel == "data: [DONE]\n\n"

    assert_receive {:universal_ai_client, ^ref, :done, %{"reason" => "provider_terminal"}}, 1_000
  end

  test "universal AI client reports pre-ready provider status without chunks" do
    {:ok, url} =
      start_http_sse_server(
        [
          ~s({"error":{"message":"provider rejected"}})
        ],
        status: 429
      )

    {:ok, stream} =
      UniversalAIClient.open(%{
        api_resolver: :openai_responses,
        upstream: %{
          kind: :http_sse,
          method: "POST",
          url: url,
          headers: [{"content-type", "application/json"}],
          body: ~s({"stream":true}),
          timeout: %{connect_ms: 500, first_byte_ms: 500, idle_ms: 500, total_ms: nil},
          transport: %{http_versions: [:h1], compression: []}
        },
        downstream: :sse,
        response_context: %{model: "test-model", request: %{}}
      })

    ref = stream.ref

    assert_receive {:universal_ai_client, ^ref, :error,
                    %{
                      "code" => "provider_status_rejected",
                      "provider_status" => 429
                    }},
                   1_000

    refute_receive {:universal_ai_client, ^ref, :ready, _meta}, 100
    refute_receive {:universal_ai_client, ^ref, :chunk, _, _, _}, 100
  end

  test "universal AI client sends protocol error chunk before terminal error after ready" do
    {:ok, url} =
      start_http_sse_server([
        "data: {not-json}\n\n"
      ])

    {:ok, stream} =
      UniversalAIClient.open(%{
        api_resolver: :openai_responses,
        upstream: %{
          kind: :http_sse,
          method: "POST",
          url: url,
          headers: [{"content-type", "application/json"}],
          body: ~s({"stream":true}),
          timeout: %{connect_ms: 500, first_byte_ms: 500, idle_ms: 500, total_ms: nil},
          transport: %{http_versions: [:h1], compression: []}
        },
        downstream: :sse,
        response_context: %{model: "test-model", request: %{}}
      })

    assert_receive {:universal_ai_client, ref, :ready, _meta}, 1_000
    assert :ok = UniversalAIClient.read(stream, 3)

    assert_receive {:universal_ai_client, ^ref, :chunk, 1, :sse, chunk}, 1_000
    assert chunk =~ "event: error\n"
    assert chunk =~ "\"code\":\"invalid_provider_event\""

    assert_receive {:universal_ai_client, ^ref, :chunk, 2, :sse, failed}, 1_000
    assert failed =~ "event: response.failed\n"
    assert failed =~ "\"status\":\"failed\""

    assert_receive {:universal_ai_client, ^ref, :chunk, 3, :sse, sentinel}, 1_000
    assert sentinel == "data: [DONE]\n\n"

    assert_receive {:universal_ai_client, ^ref, :error,
                    %{"code" => "invalid_provider_event", "stage" => "api_resolver"}},
                   1_000

    assert stream.ref == ref
  end

  test "universal AI client cancel stops a ready stream" do
    {:ok, url} = start_http_sse_server([], keep_open?: true)

    {:ok, stream} =
      UniversalAIClient.open(%{
        api_resolver: :openai_responses,
        upstream: %{
          kind: :http_sse,
          method: "GET",
          url: url,
          headers: [],
          body: nil,
          timeout: %{connect_ms: 500, first_byte_ms: 500, idle_ms: 5_000, total_ms: nil},
          transport: %{http_versions: [:h1], compression: []}
        },
        downstream: :sse,
        response_context: %{model: "test-model", request: %{}}
      })

    assert_receive {:universal_ai_client, ref, :ready, _meta}, 1_000
    assert :ok = UniversalAIClient.cancel(stream)
    assert_receive {:universal_ai_client, ^ref, :aborted}, 1_000
  end

  defp start_http_sse_server(chunks, opts \\ []) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)
    test_pid = self()
    keep_open? = Keyword.get(opts, :keep_open?, false)
    status = Keyword.get(opts, :status, 200)

    server_pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        _ = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 #{status} #{status_reason(status)}\r\n",
            "content-type: text/event-stream\r\n",
            "transfer-encoding: chunked\r\n",
            "\r\n"
          ])

        Enum.each(chunks, fn chunk ->
          payload = IO.iodata_to_binary(chunk)

          :ok =
            :gen_tcp.send(socket, [
              Integer.to_string(byte_size(payload), 16),
              "\r\n",
              payload,
              "\r\n"
            ])
        end)

        if keep_open? do
          receive do
            :stop -> :ok
          after
            5_000 -> :ok
          end
        else
          :ok = :gen_tcp.send(socket, "0\r\n\r\n")
        end

        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
        send(test_pid, {:http_sse_server_done, self()})
      end)

    on_exit(fn ->
      send(server_pid, :stop)
      :gen_tcp.close(listen_socket)
    end)

    {:ok, "http://127.0.0.1:#{port}/stream"}
  end

  defp start_http_json_server(response_body) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)
    test_pid = self()

    server_pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = :gen_tcp.recv(socket, 0, 1_000)
        body = Torque.encode!(response_body)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: application/json\r\n",
            "content-length: #{byte_size(body)}\r\n",
            "\r\n",
            body
          ])

        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
        send(test_pid, {:http_json_server_request, request})
      end)

    on_exit(fn ->
      send(server_pid, :stop)
      :gen_tcp.close(listen_socket)
    end)

    {:ok, "http://127.0.0.1:#{port}/json"}
  end

  defp start_slow_chunked_json_server(chunks, opts) do
    delay_ms = Keyword.fetch!(opts, :delay_ms)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)
    test_pid = self()

    server_pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: application/json\r\n",
            "transfer-encoding: chunked\r\n",
            "\r\n"
          ])

        Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
          payload = IO.iodata_to_binary(chunk)

          case :gen_tcp.send(socket, [
                 Integer.to_string(byte_size(payload), 16),
                 "\r\n",
                 payload,
                 "\r\n"
               ]) do
            :ok ->
              :timer.sleep(delay_ms)
              {:cont, :ok}

            {:error, _reason} ->
              {:halt, :closed}
          end
        end)

        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
        send(test_pid, {:http_slow_json_server_request, request})
      end)

    on_exit(fn ->
      send(server_pid, :stop)
      :gen_tcp.close(listen_socket)
    end)

    {:ok, "http://127.0.0.1:#{port}/json"}
  end

  defp status_reason(200), do: "OK"
  defp status_reason(429), do: "Too Many Requests"
  defp status_reason(_status), do: "Status"

  defp actor_turn_ref do
    %{
      actor: %{
        agent_uid: "agent-1",
        session_id: "signal-channel:lark:dm:1"
      },
      activation_uid: "activation-1",
      actor_epoch: 1,
      llm_turn_id: "11111111-1111-1111-1111-111111111111",
      revision: 0
    }
  end

  defp turn_start_envelope do
    %{
      protocol_version: 1,
      message_id: "turn-start-route-test",
      correlation_id: "turn-start-route-test",
      lane: "LANE_TURN",
      durability: "CONTROL_REPLAYABLE",
      body: %{
        type: "turn_start",
        turn_start: %{
          turn: actor_turn_ref(),
          inputs: [
            %{
              actor_input_id: "input-1",
              live_queue_sequence: 1,
              type: "im.message.addressed",
              ingress_event_id: "event-1",
              payload_json: %{"text" => "PING"}
            }
          ]
        }
      }
    }
  end
end
