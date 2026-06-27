defmodule Ankole.KernelTest do
  use ExUnit.Case, async: true

  alias Ankole.Kernel.RuntimeFabric
  alias Ankole.Kernel, as: NativeKernel

  @aead_key "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
  @aead_ciphertext "vveE4WxRjp0KO8YVx7o09aQ5_q9ZzqX2.gb1S9PmqEp_5UuejAzvKErXrdE4-sQ"

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
      seq: 1,
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
              broker_sequence: 1,
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
               turn_start: %{
                 turn: put_in(actor_turn_ref(), [:actor, :display_name], "ReleaseBot"),
                 inputs: []
               }
             })

    assert reason =~ "ActorKey must not carry display_name"
  end

  test "runtime fabric encodes and decodes generic RPC envelopes" do
    encoded =
      RuntimeFabric.encode_envelope(%{
        protocol_version: 1,
        message_id: "rpc-agent-profile",
        correlation_id: "rpc-agent-profile",
        lane: "LANE_RPC",
        durability: "CONTROL_EPHEMERAL",
        body: %{
          type: "rpc_request",
          rpc_request: %{
            request_id: "rpc-agent-profile",
            method: "agent_profile.resolve",
            payload_json: %{agent_uid: "agent-1", session_id: "signal-channel:lark:dm:1"}
          }
        }
      })

    assert %{
             "body" => %{
               "type" => "rpc_request",
               "rpc_request" => %{"method" => "agent_profile.resolve"}
             }
           } =
             RuntimeFabric.decode_envelope(encoded)
  end

  test "runtime fabric turn_control steer payload must be journaled, not inline" do
    assert {:error, reason} =
             NativeKernel.runtime_fabric_encode_envelope(%{
               protocol_version: 1,
               message_id: "steer-1",
               correlation_id: "steer-1",
               lane: "LANE_CONTROL",
               durability: "CONTROL_DURABLE",
               turn_control: %{
                 turn: actor_turn_ref(),
                 command: "steer",
                 payload_json: %{"text" => "inline steer is not allowed"}
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
               turn_start: %{
                 turn: actor_turn_ref(),
                 inputs: [
                   %{
                     actor_input_id: "input-1",
                     broker_sequence: 1,
                     type: "im.message.addressed",
                     ingress_event_id: "event-1"
                   }
                 ]
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
      seq: 0,
      lane: "LANE_TURN",
      durability: "CONTROL_REPLAYABLE",
      body: %{
        type: "turn_start",
        turn_start: %{
          turn: actor_turn_ref(),
          inputs: [
            %{
              actor_input_id: "input-1",
              broker_sequence: 1,
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
