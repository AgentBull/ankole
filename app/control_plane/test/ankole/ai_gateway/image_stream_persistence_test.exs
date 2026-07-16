defmodule Ankole.AIGateway.ImageStreamPersistenceTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Artifacts.Image
  alias Ankole.AIGateway.Artifacts.ReferenceBudget
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.ImageStreamPersistence
  alias Ankole.AIGateway.ResponseStream.State, as: ResponseStreamState
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulLifecycle
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  test "image and aggregate reference byte limits accept the exact boundary only" do
    fifty_mib = 50 * 1024 * 1024
    hundred_mib = 100 * 1024 * 1024

    assert :ok = Image.validate_generated_byte_size(fifty_mib, fifty_mib)

    assert {:error, %{code: "response_too_large"}} =
             Image.validate_generated_byte_size(fifty_mib + 1, fifty_mib)

    assert {:ok, ^hundred_mib} = ReferenceBudget.consume(fifty_mib, fifty_mib)
    assert {:error, :request_too_large} = ReferenceBudget.consume(hundred_mib, 1)
  end

  test "withholds image completion until final bytes are persisted" do
    agent = agent_fixture()
    image_id = "ig_#{UUIDv7.autogenerate()}"
    state = ImageStreamPersistence.new(agent.principal.uid)

    created = %{
      "type" => "response.created",
      "sequence_number" => 0,
      "response" => %{
        "id" => "resp_test",
        "object" => "response",
        "model" => "main-model",
        "status" => "in_progress",
        "output" => []
      }
    }

    completed = %{
      "type" => "response.image_generation_call.completed",
      "sequence_number" => 4,
      "item_id" => image_id,
      "output_index" => 0
    }

    done = %{
      "type" => "response.output_item.done",
      "sequence_number" => 5,
      "output_index" => 0,
      "item" => %{
        "id" => image_id,
        "type" => "image_generation_call",
        "status" => "completed",
        "result" => @png_base64,
        "revised_prompt" => "a tiny image"
      }
    }

    assert {:ok, state, [^created]} = ImageStreamPersistence.observe(state, created)
    assert {:ok, state, []} = ImageStreamPersistence.observe(state, completed)
    assert {:error, _not_found} = Artifacts.get_generated_image(agent.principal.uid, image_id)

    assert {:ok, _state, [^completed, ^done]} =
             ImageStreamPersistence.observe(state, done)

    assert {:ok, artifact} =
             Artifacts.get_generated_image(agent.principal.uid, image_id, payload?: true)

    assert artifact.payload == Base.decode64!(@png_base64)
    assert artifact.mime_type == "image/png"
    assert artifact.expires_at
  end

  test "never releases a terminal response while completed image bytes are missing" do
    agent = agent_fixture()
    image_id = "ig_#{UUIDv7.autogenerate()}"
    state = ImageStreamPersistence.new(agent.principal.uid)

    completed = %{
      "type" => "response.image_generation_call.completed",
      "sequence_number" => 4,
      "item_id" => image_id,
      "output_index" => 0
    }

    terminal = %{
      "type" => "response.completed",
      "sequence_number" => 5,
      "response" => %{
        "id" => "resp_missing_bytes",
        "object" => "response",
        "status" => "completed",
        "output" => []
      }
    }

    assert {:ok, state, []} = ImageStreamPersistence.observe(state, completed)

    assert {:error, _state, [failed_item, failed_response], error} =
             ImageStreamPersistence.observe(state, terminal)

    assert failed_item["type"] == "response.output_item.done"
    assert failed_item["item"]["status"] == "failed"
    assert failed_response["type"] == "response.failed"
    assert error.code == "upstream_error"
    refute Enum.any?([failed_item, failed_response], &(&1["type"] == "response.completed"))
    assert {:error, _not_found} = Artifacts.get_generated_image(agent.principal.uid, image_id)
  end

  test "rejects a completed image item without bytes even when no completion marker preceded it" do
    agent = agent_fixture()
    image_id = "ig_#{UUIDv7.autogenerate()}"
    state = ImageStreamPersistence.new(agent.principal.uid)

    done = %{
      "type" => "response.output_item.done",
      "sequence_number" => 1,
      "output_index" => 0,
      "item" => %{
        "id" => image_id,
        "type" => "image_generation_call",
        "status" => "completed",
        "result" => nil
      }
    }

    assert {:error, _state, [failed_item, failed_response], error} =
             ImageStreamPersistence.observe(state, done)

    assert failed_item["item"]["status"] == "failed"
    assert failed_response["type"] == "response.failed"
    assert error.code == "upstream_error"
    assert {:error, _not_found} = Artifacts.get_generated_image(agent.principal.uid, image_id)
  end

  test "rejects a terminal image that did not pass through the persistence gate" do
    agent = agent_fixture()
    image_id = "ig_#{UUIDv7.autogenerate()}"
    state = ImageStreamPersistence.new(agent.principal.uid)

    terminal = %{
      "type" => "response.completed",
      "sequence_number" => 1,
      "response" => %{
        "id" => "resp_terminal_only_image",
        "object" => "response",
        "status" => "completed",
        "output" => [
          %{
            "id" => image_id,
            "type" => "image_generation_call",
            "status" => "completed",
            "result" => @png_base64
          }
        ]
      }
    }

    assert {:error, _state, [failed_item, failed_response], error} =
             ImageStreamPersistence.observe(state, terminal)

    assert failed_item["item"]["status"] == "failed"
    assert failed_response["type"] == "response.failed"
    assert error.code == "upstream_error"
    refute Enum.any?([failed_item, failed_response], &(&1["type"] == "response.completed"))
    assert {:error, _not_found} = Artifacts.get_generated_image(agent.principal.uid, image_id)
  end

  test "invalid provider image bytes fail as an upstream server error" do
    agent = agent_fixture()
    image_id = "ig_#{UUIDv7.autogenerate()}"
    state = ImageStreamPersistence.new(agent.principal.uid)

    created = %{
      "type" => "response.created",
      "sequence_number" => 0,
      "response" => %{
        "id" => "resp_invalid_image",
        "object" => "response",
        "model" => "main-model",
        "status" => "in_progress",
        "output" => []
      }
    }

    in_progress = %{
      "type" => "response.image_generation_call.in_progress",
      "sequence_number" => 1,
      "item_id" => image_id,
      "output_index" => 0
    }

    completed = %{
      "type" => "response.image_generation_call.completed",
      "sequence_number" => 2,
      "item_id" => image_id,
      "output_index" => 0
    }

    done = %{
      "type" => "response.output_item.done",
      "sequence_number" => 3,
      "output_index" => 0,
      "item" => %{
        "id" => image_id,
        "type" => "image_generation_call",
        "status" => "completed",
        "result" => "not-base64"
      }
    }

    assert {:ok, state, [^created]} = ImageStreamPersistence.observe(state, created)
    assert {:ok, state, [^in_progress]} = ImageStreamPersistence.observe(state, in_progress)
    assert {:ok, state, []} = ImageStreamPersistence.observe(state, completed)

    assert {:error, _state, [failed_item, failed_response], error} =
             ImageStreamPersistence.observe(state, done)

    assert error.status == 502
    assert error.type == "server_error"
    assert error.code == "upstream_error"
    assert error.param == nil
    assert failed_item["sequence_number"] == 2
    assert failed_item["item"]["status"] == "failed"
    assert failed_item["item"]["result"] == nil
    assert failed_response["sequence_number"] == 3
    assert failed_response["type"] == "response.failed"
    assert get_in(failed_response, ["response", "error", "code"]) == "upstream_error"

    assert {:error, non_stream_error} =
             ImageGeneration.persist_response(agent.principal.uid, %{
               "output" => [done["item"]]
             })

    assert non_stream_error.status == 502
    assert non_stream_error.type == "server_error"
    assert non_stream_error.code == "upstream_error"

    assert {:error, missing_result_error} =
             ImageGeneration.persist_response(agent.principal.uid, %{
               "output" => [Map.put(done["item"], "result", nil)]
             })

    assert missing_result_error.status == 502
    assert missing_result_error.code == "upstream_error"
  end

  test "a later persistence failure keeps prior public output in the failed response" do
    agent = agent_fixture()
    first_id = "ig_#{UUIDv7.autogenerate()}"
    second_id = "ig_#{UUIDv7.autogenerate()}"
    state = ImageStreamPersistence.new(agent.principal.uid)

    created = %{
      "type" => "response.created",
      "sequence_number" => 0,
      "response" => %{"id" => "resp_two_images", "object" => "response", "output" => []}
    }

    first_completed = %{
      "type" => "response.image_generation_call.completed",
      "sequence_number" => 4,
      "item_id" => first_id,
      "output_index" => 0
    }

    first_done = %{
      "type" => "response.output_item.done",
      "sequence_number" => 5,
      "output_index" => 0,
      "item" => %{
        "id" => first_id,
        "type" => "image_generation_call",
        "status" => "completed",
        "result" => @png_base64
      }
    }

    second_completed = %{
      "type" => "response.image_generation_call.completed",
      "sequence_number" => 9,
      "item_id" => second_id,
      "output_index" => 1
    }

    second_done = %{
      "type" => "response.output_item.done",
      "sequence_number" => 10,
      "output_index" => 1,
      "item" => %{
        "id" => second_id,
        "type" => "image_generation_call",
        "status" => "completed",
        "result" => "not-base64"
      }
    }

    assert {:ok, state, [_]} = ImageStreamPersistence.observe(state, created)
    assert {:ok, state, []} = ImageStreamPersistence.observe(state, first_completed)

    assert {:ok, state, [^first_completed, ^first_done]} =
             ImageStreamPersistence.observe(state, first_done)

    state =
      Enum.reduce(6..8, state, fn sequence, state ->
        event = %{
          "type" => "response.image_generation_call.generating",
          "sequence_number" => sequence
        }

        assert {:ok, state, [^event]} = ImageStreamPersistence.observe(state, event)
        state
      end)

    assert {:ok, state, []} = ImageStreamPersistence.observe(state, second_completed)

    assert {:error, _state, [failed_item, failed_response], _error} =
             ImageStreamPersistence.observe(state, second_done)

    assert failed_item["sequence_number"] == 9
    assert failed_response["sequence_number"] == 10
    assert Enum.map(failed_response["response"]["output"], & &1["id"]) == [first_id, second_id]
    assert Enum.at(failed_response["response"]["output"], 0)["status"] == "completed"
    assert Enum.at(failed_response["response"]["output"], 1)["status"] == "failed"
  end

  test "non-stream persistence rolls back earlier images when a later image is invalid" do
    agent = agent_fixture()
    first_id = "ig_#{UUIDv7.autogenerate()}"
    second_id = "ig_#{UUIDv7.autogenerate()}"

    response = %{
      "output" => [
        %{
          "id" => first_id,
          "type" => "image_generation_call",
          "status" => "completed",
          "result" => @png_base64
        },
        %{
          "id" => second_id,
          "type" => "image_generation_call",
          "status" => "completed",
          "result" => "not-base64"
        }
      ]
    }

    assert {:error, error} = ImageGeneration.persist_response(agent.principal.uid, response)
    assert error.code == "upstream_error"
    assert {:error, not_found} = Artifacts.get_generated_image(agent.principal.uid, first_id)
    assert not_found.status == 404
  end

  test "generated artifacts are subject isolated and hydrate stored image items" do
    owner = agent_fixture()
    other = agent_fixture()
    image_id = "ig_#{UUIDv7.autogenerate()}"

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(
               owner.principal.uid,
               image_id,
               @png_base64,
               "image/png"
             )

    stored = [
      %{
        "id" => image_id,
        "type" => "image_generation_call",
        "status" => "completed",
        "result" => nil,
        "revised_prompt" => "kept"
      }
    ]

    assert {:ok, [%{"result" => @png_base64}]} =
             Artifacts.hydrate_generated_images(owner.principal.uid, stored)

    assert {:error, error} = Artifacts.hydrate_generated_images(other.principal.uid, stored)
    assert error.status == 404
    assert error.code == "not_found"
  end

  test "a prior image_generation_call id resolves to a private data URL for editing" do
    owner = agent_fixture()
    image_id = "ig_#{UUIDv7.autogenerate()}"

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(
               owner.principal.uid,
               image_id,
               @png_base64,
               "image/png"
             )

    request = %{
      "input" => [
        %{
          "id" => image_id,
          "type" => "image_generation_call",
          "status" => "completed",
          "result" => nil
        }
      ]
    }

    assert {:ok, [reference]} = Artifacts.resolve_references(owner.principal.uid, request)
    assert reference["id"] == image_id
    assert reference["source"] == "artifact"
    assert reference["image_url"] == "data:image/png;base64,#{@png_base64}"
  end

  test "data URLs are validated and counted without downloading external URLs" do
    agent = agent_fixture()

    request = %{
      "input" => [
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "input_image",
              "image_url" => "data:image/png;base64,#{@png_base64}"
            },
            %{"type" => "input_image", "image_url" => "https://example.test/source.png"}
          ]
        }
      ],
      "tools" => [
        %{
          "type" => "image_generation",
          "input_image_mask" => %{"image_url" => "data:image/png;base64,#{@png_base64}"}
        }
      ]
    }

    assert {:ok, [data_url, external, mask]} =
             Artifacts.resolve_references(agent.principal.uid, request)

    assert data_url["source"] == "data_url"
    assert external["source"] == "external"
    refute data_url["mask"]
    assert mask["mask"]
    assert mask["id"] == "tools[0].input_image_mask"

    assert {:error, mask_only_error} =
             ImageGeneration.prepare(agent.principal.uid, %{
               "input" => [],
               "tools" => [
                 %{
                   "type" => "image_generation",
                   "action" => "edit",
                   "input_image_mask" => %{
                     "image_url" => "data:image/png;base64,#{@png_base64}"
                   }
                 }
               ]
             })

    assert mask_only_error.param == "tools[0].action"
    assert mask_only_error.code == "invalid_value"

    invalid =
      put_in(
        request,
        ["input", Access.at(0), "content", Access.at(1), "image_url"],
        "ftp://example.test/image.png"
      )

    assert {:error, error} = Artifacts.resolve_references(agent.principal.uid, invalid)
    assert error.code == "invalid_value"
    assert error.param == "input[0].content[1]"
  end

  test "stateful images link to the response message and hydrate only on retrieve" do
    agent = agent_fixture()

    assert {:ok, conversation} =
             Conversations.ensure_conversation(agent.principal.uid, "image-ws")

    assert {:ok, message} =
             StatefulResponses.start_response_run(%{
               subject_uid: agent.principal.uid,
               conversation_id: conversation.id,
               request_items: []
             })

    image_id = "ig_#{UUIDv7.autogenerate()}"

    state =
      ResponseStreamState.new(agent.principal.uid, %{}, %{},
        stateful: %{message_id: message.id, message: message}
      )

    completed = %{
      "type" => "response.image_generation_call.completed",
      "sequence_number" => 3,
      "item_id" => image_id,
      "output_index" => 0
    }

    image_item = %{
      "id" => image_id,
      "type" => "image_generation_call",
      "status" => "completed",
      "result" => @png_base64,
      "revised_prompt" => "stateful image"
    }

    done = %{
      "type" => "response.output_item.done",
      "sequence_number" => 4,
      "output_index" => 0,
      "item" => image_item
    }

    assert {:ok, state, [], :continue} = ResponseStreamState.observe(state, completed, 3)

    assert {:ok, state, [^completed, public_done], :continue} =
             ResponseStreamState.observe(state, done, 4)

    assert public_done["item"]["result"] == @png_base64

    assert {:ok, artifact} =
             Artifacts.get_generated_image(agent.principal.uid, image_id, payload?: true)

    assert artifact.message_id == message.id
    assert artifact.expires_at == nil

    terminal = %{
      "type" => "response.completed",
      "sequence_number" => 5,
      "response" => %{
        "id" => "provider_response",
        "object" => "response",
        "status" => "completed",
        "output" => [image_item]
      }
    }

    assert {:ok, _state, [public_terminal], {:terminal, _outcome, :keep_upstream}} =
             ResponseStreamState.observe(state, terminal, 5)

    assert get_in(public_terminal, ["response", "output", Access.at(0), "result"]) ==
             @png_base64

    persisted_message = Repo.get!(Message, message.id)
    assert [%{"result" => nil}] = persisted_message.content

    assert {:ok, %{body: response}} =
             StatefulLifecycle.retrieve_response(agent.principal.uid, "resp_#{message.id}")

    assert [%{"id" => ^image_id, "result" => @png_base64}] = response["output"]
  end

  test "stateful retrieve keeps a prior image call in input and the new image in output" do
    agent = agent_fixture()

    assert {:ok, conversation} =
             Conversations.ensure_conversation(agent.principal.uid, "image-ws-edit")

    prior_image_id = "ig_#{UUIDv7.autogenerate()}"

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(
               agent.principal.uid,
               prior_image_id,
               @png_base64,
               "image/png"
             )

    prior_item = %{
      "id" => prior_image_id,
      "type" => "image_generation_call",
      "status" => "completed",
      "result" => nil
    }

    assert {:ok, message} =
             StatefulResponses.start_response_run(%{
               subject_uid: agent.principal.uid,
               conversation_id: conversation.id,
               request_items: [prior_item]
             })

    generated_image_id = "ig_#{UUIDv7.autogenerate()}"

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(
               agent.principal.uid,
               generated_image_id,
               @png_base64,
               "image/png",
               message_id: message.id
             )

    generated_item = %{
      "id" => generated_image_id,
      "type" => "image_generation_call",
      "status" => "completed",
      "result" => nil
    }

    assert {:ok, _message} = StatefulResponses.commit_complete(message, [generated_item])

    assert {:ok, %{body: response}} =
             StatefulLifecycle.retrieve_response(agent.principal.uid, "resp_#{message.id}")

    assert [%{"id" => ^prior_image_id, "result" => @png_base64}] = response["input"]
    assert [%{"id" => ^generated_image_id, "result" => @png_base64}] = response["output"]
  end
end
