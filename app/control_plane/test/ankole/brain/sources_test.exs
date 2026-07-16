defmodule Ankole.Brain.SourcesTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Citations
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Schemas.AuditLog
  alias Ankole.Brain.Schemas.RetainedSource
  alias Ankole.Brain.SourceLearning
  alias Ankole.Brain.Sources
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry, as: SignalEntry

  setup do
    %{principal: owner} = agent_fixture()
    %{principal: other} = agent_fixture()
    {:ok, scope} = Scope.for_store(owner.uid, "public")
    {:ok, other_scope} = Scope.for_store(other.uid, "public")

    %{owner: owner, other: other, scope: scope, other_scope: other_scope}
  end

  test "captures immutable source bytes and resolves them only through the owner's readable scope",
       ctx do
    assert {:ok, source} =
             Sources.capture(
               ctx.scope,
               %{kind: "paste", title: "Release policy", content: "Keep one durable source."},
               ctx.owner.uid
             )

    assert source.document_id == "brain-source:#{source.id}"

    assert source.sha256 ==
             Base.encode16(:crypto.hash(:sha256, "Keep one durable source."), case: :lower)

    assert {:ok, %{content: "Keep one durable source.", filename: "Release-policy.txt"}} =
             Sources.raw(ctx.scope, source.document_id)

    assert {:error, :not_found} = Sources.resolve(ctx.other_scope, source.document_id)
  end

  test "captured source rows reject updates at the database boundary", ctx do
    assert {:ok, source} =
             Sources.capture(
               ctx.scope,
               %{kind: "paste", title: "Immutable source", content: "Original bytes"},
               ctx.owner.uid
             )

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             Repo.query(
               "UPDATE brain_retained_sources SET title = $1 WHERE id = $2",
               ["Changed source", Ecto.UUID.dump!(source.id)]
             )

    assert message == "brain retained sources are immutable"
  end

  test "pasted bytes stay exact while model-facing source reads expose only semantic evidence",
       ctx do
    content = "\n  Preserve meaningful whitespace.  \n"

    assert {:ok, source} =
             Sources.capture(
               ctx.scope,
               %{kind: "paste", title: "Exact paste", content: content},
               ctx.owner.uid
             )

    assert {:ok, %{content: ^content}} = Sources.raw(ctx.scope, source.document_id)

    assert {:ok,
            %{
              document_id: document_id,
              kind: "retained_source",
              title: "Exact paste",
              text: ^content,
              history_notice: history_notice
            } = projection} = Sources.open_model(ctx.scope, source.document_id)

    assert document_id == source.document_id
    assert history_notice =~ "untrusted historical evidence"

    refute Map.has_key?(projection, :store_key)
    refute Map.has_key?(projection, :sha256)
    refute Map.has_key?(projection, :captured_by_uid)
    refute Map.has_key?(projection, :learning_actor_event_id)
    refute Map.has_key?(projection, :integrated_entries)
  end

  test "URL capture retains the fetched representation and final locator", ctx do
    fetch = fn owner_uid, url ->
      assert owner_uid == ctx.owner.uid
      assert url == "https://example.test/manual"

      {:ok,
       %{
         final_url: "https://cdn.example.test/manual.pdf",
         media_type: "application/pdf",
         content: "%PDF-source"
       }}
    end

    assert {:ok, source} =
             Sources.capture(
               ctx.scope,
               %{kind: "url", url: "https://example.test/manual"},
               ctx.owner.uid,
               fetch_fun: fetch
             )

    assert source.capture_method == "url"
    assert source.title == "https://cdn.example.test/manual.pdf"
    assert source.origin_locator == "https://cdn.example.test/manual.pdf"
    assert source.original_name == "manual.pdf"
    assert source.media_type == "application/pdf"
    assert source.raw_content == "%PDF-source"
  end

  test "an atomic entry body creates a structured citation and source integration view", ctx do
    assert {:ok, source} =
             Sources.capture(
               ctx.scope,
               %{
                 kind: "paste",
                 title: "Architecture note",
                 content: "PostgreSQL owns durable truth."
               },
               ctx.owner.uid
             )

    actor = %{kind: :human, uid: ctx.owner.uid}

    assert {:ok,
            %{
              results: [
                %{
                  entry_id: entry_id,
                  block_id: block_id,
                  entry_lock_version: 1,
                  block_lock_version: 1
                }
              ]
            }} =
             Knowledge.apply_operations(
               ctx.scope,
               %{
                 operation: "create_entry",
                 name: "Brain architecture",
                 type: "topic",
                 initial_body: "PostgreSQL owns durable truth. src:#{source.document_id}"
               },
               actor
             )

    assert [%{block_id: ^block_id, document_id: document_id, source_kind: "retained_source"}] =
             Citations.for_entry(Repo, entry_id)

    assert document_id == source.document_id

    assert {:ok, opened} = Sources.open_console(ctx.scope, source.document_id)
    assert [%{id: ^entry_id, name: "Brain architecture"}] = opened.integrated_entries
  end

  test "a visible conversation message resolves as a source without copying its bytes", ctx do
    now = DateTime.utc_now(:microsecond)

    channel =
      %Channel{}
      |> Channel.changeset(%{
        id: "brain-source-conversation",
        kind: :webhook_endpoint,
        reply_mode: :none,
        metadata: %{},
        raw_payload: %{},
        first_seen_at: now,
        last_seen_at: now
      })
      |> Repo.insert!()

    assert {:ok, _event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: ctx.owner.uid,
               binding_name: "brain-source-test",
               session_id: "brain-source-conversation",
               source_event_id: "brain-source-conversation-observed",
               signal_channel_id: channel.id,
               source_entry_id: "conversation-message",
               type: "webhook.received",
               available_at: now,
               payload: %{}
             })

    entry =
      %SignalEntry{}
      |> SignalEntry.changeset(%{
        signal_channel_id: channel.id,
        source_entry_id: "conversation-message",
        text: "Keep chat context in SignalsGateway.",
        attachments: [],
        links: [],
        author: %{"display_name" => "Alice"},
        mentions: [],
        metadata: %{},
        raw_payload: %{},
        provider_time: now,
        reactions: %{},
        raw_reaction_keys: %{},
        document_id: "signal-gateway-entry:conversation-message",
        content_hash: "conversation-content-hash",
        first_seen_at: now,
        last_seen_at: now
      })
      |> Repo.insert!()

    assert {:ok, opened} = Sources.open_console(ctx.scope, entry.document_id)
    assert opened.kind == "signal_message"
    assert opened.store_key == "public"
    assert opened.text == entry.text
    assert opened.sha256 == entry.content_hash
    refute Repo.get_by(RetainedSource, document_id: entry.document_id)

    assert {:error, :not_found} = Sources.resolve(ctx.other_scope, entry.document_id)
  end

  test "source learning materializes one fixed file and appends an explicitly scoped ActorEvent",
       ctx do
    assert {:ok, source} =
             Sources.capture(
               ctx.scope,
               %{kind: "file", title: "Manual", original_name: "manual.md", content: "# Manual"},
               ctx.owner.uid
             )

    test_pid = self()

    materialize = fn path, content ->
      send(test_pid, {:materialized, path, content})
      :ok
    end

    append = fn attrs ->
      send(test_pid, {:appended, attrs})
      {:ok, %{id: Ecto.UUID.generate()}}
    end

    assert {:ok, %{status: :queued, document_id: document_id}} =
             SourceLearning.enqueue(ctx.scope, source.document_id,
               materialize_fun: materialize,
               append_fun: append
             )

    assert document_id == source.document_id
    assert_receive {:materialized, relative_path, "# Manual"}
    assert relative_path =~ "/source/manual.md"

    assert_receive {:appended, attrs}
    assert attrs.type == "brain.source.learn"
    assert attrs.agent_uid == ctx.owner.uid
    assert attrs.source_entry_id == source.document_id
    assert get_in(attrs, [:payload, "data", "brain_scope"]) == %{"visibility" => "public"}

    assert get_in(attrs, [:payload, "data", "retained_source", "document_id"]) ==
             source.document_id

    assert get_in(attrs, [:payload, "data", "retained_source", "path"]) ==
             "/workspace/source/manual.md"

    assert get_in(attrs, [:payload, "data", "retained_source", "byte_size"]) ==
             byte_size("# Manual")

    assert get_in(attrs, [:payload, "data", "retained_source", "sha256"]) == source.sha256
  end

  test "source learning rejects a human owner before materializing bytes" do
    %{principal: human} = human_fixture()
    {:ok, scope} = Scope.for_store(human.uid, "public")

    assert {:ok, source} =
             Sources.capture(
               scope,
               %{kind: "paste", title: "Human note", content: "Retain without an Actor run."},
               human.uid
             )

    assert {:error, :source_owner_not_agent} =
             SourceLearning.enqueue(scope, source.document_id,
               materialize_fun: fn _path, _content -> flunk("human source was materialized") end,
               append_fun: fn _attrs -> flunk("human source learning event was appended") end
             )
  end

  test "source learning receives the human curation guide as semantic text without entry metadata",
       ctx do
    %{principal: human} = human_fixture()

    assert {:ok, %{results: [%{entry_id: guide_entry_id}]}} =
             Knowledge.apply_operations(
               ctx.scope,
               %{
                 operation: "create_entry",
                 name: "Brain Curation Guide",
                 type: "brain_curation_guide",
                 initial_body: "Create a project page only after it has an enduring owner."
               },
               %{kind: :human, uid: human.uid}
             )

    assert {:ok, source} =
             Sources.capture(
               ctx.scope,
               %{kind: "paste", title: "Project note", content: "A durable project note."},
               human.uid
             )

    test_pid = self()

    assert {:ok, _run} =
             SourceLearning.enqueue(ctx.scope, source.document_id,
               materialize_fun: fn _path, _content -> :ok end,
               append_fun: fn attrs ->
                 send(test_pid, {:learning_event, attrs})
                 {:ok, %{id: Ecto.UUID.generate()}}
               end
             )

    assert_receive {:learning_event, attrs}
    instruction = get_in(attrs, [:payload, "data", "entry", "text"])
    assert instruction =~ "Human-maintained Brain Curation Guide"
    assert instruction =~ "Create a project page only after it has an enduring owner."
    refute instruction =~ guide_entry_id
    refute instruction =~ "lock_version"
  end

  test "learning status follows ActorEvent completion and only reports integration after an audited write",
       ctx do
    assert {:ok, source} =
             Sources.capture(
               ctx.scope,
               %{kind: "paste", title: "Status source", content: "Status evidence"},
               ctx.owner.uid
             )

    assert {:ok, %{actor_event_id: event_id}} =
             SourceLearning.enqueue(ctx.scope, source.document_id,
               materialize_fun: fn _path, _content -> :ok end
             )

    assert %{status: "learning", actor_event_id: ^event_id} =
             SourceLearning.latest_outcome(source)

    event = Repo.get!(ActorEvent, event_id)
    now = DateTime.utc_now(:microsecond)
    event = event |> ActorEvent.changeset(%{completed_at: now}) |> Repo.update!()

    assert %{status: "failed", actor_event_id: ^event_id} =
             SourceLearning.latest_outcome(source)

    event =
      event
      |> ActorEvent.changeset(%{
        final_response_id: "resp_source_status",
        turn_outcome: "iteration_exhausted"
      })
      |> Repo.update!()

    assert %{status: "incomplete", actor_event_id: ^event_id} =
             SourceLearning.latest_outcome(source)

    event
    |> ActorEvent.changeset(%{turn_outcome: "loop_finished"})
    |> Repo.update!()

    assert %{status: "no_change", actor_event_id: ^event_id} =
             SourceLearning.latest_outcome(source)

    %AuditLog{}
    |> AuditLog.changeset(%{
      owner_uid: ctx.owner.uid,
      store_key: "public",
      actor_kind: :agent,
      actor_uid: ctx.owner.uid,
      action: "append_block",
      metadata: %{
        "actor_event_id" => event_id,
        "source_document_id" => source.document_id
      }
    })
    |> Repo.insert!()

    assert %{status: "integrated", actor_event_id: ^event_id} =
             SourceLearning.latest_outcome(source)
  end

  test "new citations must resolve in the current scope", ctx do
    actor = %{kind: :human, uid: ctx.owner.uid}

    assert {:error, {:invalid_source_citation, "brain-source:missing", :not_found}} =
             Knowledge.apply_operations(
               ctx.scope,
               %{
                 operation: "create_entry",
                 name: "Unsupported",
                 type: "topic",
                 initial_body: "A claim. src:brain-source:missing"
               },
               actor
             )

    refute Repo.get_by(Ankole.Brain.Schemas.Entry, owner_uid: ctx.owner.uid, name: "Unsupported")
  end

  test "source integration links remain owner scoped for a shared signal message", ctx do
    now = DateTime.utc_now(:microsecond)
    channel = insert_channel!("brain-shared-source", now)

    for {owner, suffix} <- [{ctx.owner, "owner"}, {ctx.other, "other"}] do
      assert {:ok, _event} =
               SignalsGateway.append_actor_event(%{
                 agent_uid: owner.uid,
                 binding_name: "brain-source-test",
                 session_id: "brain-shared-source-#{suffix}",
                 source_event_id: "brain-shared-source-#{suffix}",
                 signal_channel_id: channel.id,
                 source_entry_id: "brain-shared-source-message",
                 type: "webhook.received",
                 available_at: now,
                 payload: %{}
               })
    end

    entry = insert_signal_entry!(channel, now, "brain-shared-source-message", nil)

    owner_entry_id =
      create_cited_entry!(ctx.scope, ctx.owner.uid, "Owner page", entry.document_id)

    _other_entry_id =
      create_cited_entry!(ctx.other_scope, ctx.other.uid, "Other page", entry.document_id)

    assert {:ok, opened} = Sources.open_console(ctx.scope, entry.document_id)
    assert [%{id: ^owner_entry_id, name: "Owner page"}] = opened.integrated_entries
  end

  test "automated writers cannot cite a mirrored AI output as factual evidence", ctx do
    now = DateTime.utc_now(:microsecond)
    channel = insert_channel!("brain-ai-output-source", now)

    assert {:ok, _event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: ctx.owner.uid,
               binding_name: "brain-source-test",
               session_id: "brain-ai-output-source",
               source_event_id: "brain-ai-output-source",
               signal_channel_id: channel.id,
               source_entry_id: "brain-ai-output-message",
               type: "webhook.received",
               available_at: now,
               payload: %{}
             })

    entry = insert_signal_entry!(channel, now, "brain-ai-output-message", Ecto.UUID.generate())

    assert {:error,
            {:invalid_source_citation, document_id, {:source_not_allowed_for_write, document_id}}} =
             Knowledge.apply_operations(
               ctx.scope,
               %{
                 operation: "create_entry",
                 name: "Self-certified output",
                 type: "topic",
                 initial_body: "The Agent said so. src:#{entry.document_id}"
               },
               %{kind: :agent, uid: ctx.owner.uid}
             )

    assert document_id == entry.document_id

    assert {:ok, _result} =
             Knowledge.apply_operations(
               ctx.scope,
               %{
                 operation: "create_entry",
                 name: "Human-reviewed output",
                 type: "topic",
                 initial_body:
                   "A human deliberately retained this statement. src:#{entry.document_id}"
               },
               %{kind: :human, uid: ctx.owner.uid}
             )
  end

  defp insert_channel!(id, now) do
    %Channel{}
    |> Channel.changeset(%{
      id: id,
      kind: :webhook_endpoint,
      reply_mode: :none,
      metadata: %{},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert!()
  end

  defp insert_signal_entry!(channel, now, source_entry_id, ai_message_id) do
    %SignalEntry{}
    |> SignalEntry.changeset(%{
      signal_channel_id: channel.id,
      source_entry_id: source_entry_id,
      text: "Shared evidence",
      attachments: [],
      links: [],
      author: %{"display_name" => "Alice"},
      mentions: [],
      metadata: %{},
      raw_payload: %{},
      provider_time: now,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: "signal-gateway-entry:#{source_entry_id}",
      content_hash: "hash-#{source_entry_id}",
      first_seen_at: now,
      last_seen_at: now,
      ai_message_id: ai_message_id
    })
    |> Repo.insert!()
  end

  defp create_cited_entry!(scope, actor_uid, name, document_id) do
    assert {:ok, %{results: [%{entry_id: entry_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "create_entry",
                 name: name,
                 type: "topic",
                 initial_body: "Shared fact. src:#{document_id}"
               },
               %{kind: :human, uid: actor_uid}
             )

    entry_id
  end
end
