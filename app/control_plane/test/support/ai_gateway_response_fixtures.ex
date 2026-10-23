defmodule Ankole.AIGateway.ResponseFixtures do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ankole.AIGatewayCase, only: [start_response_run: 1, start_upstream_server: 1]

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway
  alias Ankole.AIGateway.CompactionPolicy
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ResponseChain
  alias Ankole.Repo

  defp seed_brain_fact!(agent) do
    {:ok, _packs} = Ankole.Brain.SchemaPacks.install_packs([])

    {:ok, object} =
      Ankole.Brain.create_object(
        %{
          slug: "concepts/wire-format",
          type: "concept",
          title: "Wire Format",
          body: "memory fixture"
        },
        agent.uid
      )

    {:ok, _claim} =
      Ankole.Brain.write_fact(
        %{
          object_slug: object.slug,
          claim: "MEMORY_ORION",
          kind: "fact",
          holder: "world",
          audience_scope: "world",
          notability: "medium",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "test"
        },
        agent.uid
      )

    {:ok, _alias} = Ankole.Brain.Links.add_alias(object.slug, "Wire Format")
  end

  def seed_checkpoint_memory!(agent, conversation, event_id) do
    seed_brain_fact!(agent)
    event = signal_fixture(agent.uid, conversation.conversation_key, event_id)
    history = ResponseChain.expand_history(conversation.id)
    first = hd(history)

    {input, injection} =
      Ankole.AIGateway.HostedTools.Brain.inject_stateful(
        agent.uid,
        %{
          "tools" => [%{"type" => "brain", "inject" => true}],
          "metadata" => %{"signal_id" => event.id}
        },
        conversation,
        [text_message("user", "Wire Format")],
        history
      )

    [pack] = injection["brain_context_pack"]
    assert input == [text_message("user", "Wire Format")]
    # Provenance is row-local; a user's literal wrapper remains an original.
    content = [
      text_message("user", "<recalled_memory>USER_LITERAL_TAG: VEGA</recalled_memory>")
      | first.content
    ]

    metadata = Map.merge(first.metadata, injection)
    assert metadata["brain_context_pack"] == [pack]
    first |> Ecto.Changeset.change(content: content, metadata: metadata) |> Repo.update!()
    Repo.reload!(conversation)
  end

  def start_recording_upstream(test_pid, response_fun) do
    start_upstream_server(fn request ->
      send(test_pid, {:gateway_request, request})
      response_fun.(request)
    end)
  end

  def create_openai_compaction_provider!(agent, provider_id, base_url, opts \\ []) do
    profiles =
      Keyword.get(opts, :profiles, [{"primary", "gpt-main"}, {"light", "gpt-compact-light"}])

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    for profile_entry <- profiles do
      {profile, model, context_length} =
        case profile_entry do
          {profile, model} -> {profile, model, nil}
          {profile, model, context_length} -> {profile, model, context_length}
        end

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(
                 agent.uid,
                 profile,
                 %{
                   provider_id: provider_id,
                   model: model
                 }
                 |> maybe_put("context_length", context_length)
               )
    end
  end

  def start_stateful_message(agent_uid, conversation, source_event_id, request_items) do
    signal = signal_fixture(agent_uid, conversation.conversation_key, source_event_id)

    start_response_run(%{
      subject_uid: agent_uid,
      conversation_id: conversation.id,
      request_items: request_items,
      metadata: %{"request_metadata" => %{"signal_id" => signal.id}}
    })
  end

  def start_linked_stateful_message(
        agent_uid,
        conversation,
        previous,
        source_event_id,
        request_items
      ) do
    signal = signal_fixture(agent_uid, conversation.conversation_key, source_event_id)

    start_response_run(%{
      subject_uid: agent_uid,
      previous_response_id: "resp_#{previous.id}",
      request_items: request_items,
      metadata: %{"request_metadata" => %{"signal_id" => signal.id}}
    })
  end

  def text_message(role, text) do
    content_type = if role == "assistant", do: "output_text", else: "input_text"

    %{
      "type" => "message",
      "role" => role,
      "content" => [%{"type" => content_type, "text" => text, "annotations" => []}]
    }
  end

  def usage(total_tokens), do: %{"usage" => %{"total_tokens" => total_tokens}}

  def programmatic_tools do
    [
      %{
        "type" => "function",
        "name" => "market",
        "description" => "Return market data.",
        "allowed_callers" => ["programmatic"],
        "parameters" => %{"type" => "object", "properties" => %{}}
      },
      %{"type" => "programmatic_tool_calling"}
    ]
  end

  def configure_openai_responses_provider!(agent_uid, base_url, provider_id) do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, "primary", %{
               provider_id: provider_id,
               model: "gpt-5.6"
             })

    :ok
  end

  def configure_openai_compatible_responses_provider!(
        agent_uid,
        base_url,
        provider_id,
        extra_connection \\ %{}
      ) do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai_compatible",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-compatible"}]
               },
               connection_options:
                 Map.merge(
                   %{
                     "endpoint_kind" => "responses",
                     "transport" => %{}
                   },
                   extra_connection
                 )
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, "primary", %{
               provider_id: provider_id,
               model: "gpt-compatible"
             })

    :ok
  end

  # Provider-native compaction is one instance setting, so a test opts in the
  # same way an operator does.
  def prefer_provider_compaction!(_agent_uid) do
    with_compaction_config(upstream: true)
  end

  # Compaction settings are one config key now, so the helpers must compose
  # instead of overwriting each other.
  def with_compaction_config(config) do
    merged =
      CompactionPolicy.config()
      |> Map.merge(Map.new(config, fn {key, value} -> {to_string(key), value} end))

    assert {:ok, _config} =
             Ankole.AppConfigure.put_global(
               Ankole.AIGateway.CompactionPolicy.config_definition(),
               merged
             )

    on_exit(fn ->
      _result =
        Ankole.AppConfigure.delete_global(Ankole.AIGateway.CompactionPolicy.config_definition())

      :ok
    end)
  end

  def local_checkpoint_summary(%{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => text}]
      })
      when is_binary(text) do
    prefix =
      "Context checkpoint: an earlier context window of this same agent already worked on this task and was compacted into the summary below. Tool side effects (files created or edited, commands run, processes started) remain in effect. Messages after this summary are verbatim and take precedence over it; continue the summary's in-progress work unless later messages supersede it.\n\n"

    case String.split_at(text, byte_size(prefix)) do
      {^prefix, summary} -> summary
      _not_checkpoint -> nil
    end
  end

  def local_checkpoint_summary(_item), do: nil

  def signal_fixture(agent_uid, session_id, source_event_id) do
    now = DateTime.utc_now(:microsecond)

    {:ok, signal} =
      Repo.transact(fn repo ->
        Ankole.Signals.accept_in_tx(repo, %{
          source: "test://gateway-runtime",
          id: "#{source_event_id}-#{System.unique_integer([:positive])}",
          type: "test.source",
          time: now,
          data: %{"text" => source_event_id},
          target: %{agent_uid: agent_uid, session_id: session_id},
          authorization: Ankole.Principals.WorkAccess.service()
        })
      end)

    signal
  end

  def collect_gateway_requests(0, requests), do: requests

  def collect_gateway_requests(remaining, requests) do
    receive do
      {:gateway_request, request} ->
        collect_gateway_requests(remaining - 1, [request | requests])
    after
      1_000 ->
        flunk("timed out waiting for gateway request")
    end
  end

  def collect_sse_chunks(stream, events) do
    with :ok <- AIGateway.read_response_stream(stream, 1) do
      receive do
        {:ai_gateway_response_stream, ref, :events, batch, :continue}
        when ref == stream.ref ->
          collect_sse_chunks(stream, events ++ batch)

        {:ai_gateway_response_stream, ref, :events, batch, {:terminal, _outcome}}
        when ref == stream.ref ->
          {:ok, events ++ batch}
      after
        1_000 ->
          _ = AIGateway.cancel_response_stream(stream, "test_receive_timeout")
          {:error, :response_stream_receive_timeout}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def terminal_response_body!(events) do
    assert %{"response" => body} =
             Enum.find(
               events,
               &(Map.get(&1, "type") in [
                   "response.completed",
                   "response.failed",
                   "response.incomplete"
                 ])
             )

    body
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
