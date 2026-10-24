defmodule Ankole.Sessions.ConsoleQueriesTest do
  @moduledoc """
  Checks the `console_list` read action of the AIGateway conversations and the
  display facts that the operator console reads with it.
  """
  use Ankole.DataCase, async: true

  alias Ankole.AIGateway
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.BackgroundAgentJobs
  alias Ankole.PrincipalsFixtures
  alias Ankole.Repo
  alias Ankole.Conversations.Conversation, as: PublicConversation

  describe "console_list with min_messages" do
    test "keeps only conversations at or above the message threshold" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      empty = conversation_fixture(agent.uid, "signal-channel:lark:oc_empty")
      stub = conversation_fixture(agent.uid, "signal-channel:lark:oc_stub")
      full = conversation_fixture(agent.uid, "signal-channel:lark:oc_full")
      message_fixture(stub)
      message_fixture(full)
      message_fixture(full)

      assert {:ok, page} =
               list_conversations(subject_uid: agent.uid, min_messages: 2)

      assert Enum.map(page.conversations, & &1.id) == [full.id]

      assert {:ok, page} =
               list_conversations(subject_uid: agent.uid, min_messages: 1)

      assert page.conversations |> Enum.map(& &1.id) |> Enum.sort() ==
               [stub.id, full.id] |> Enum.sort()

      assert {:ok, all} = list_conversations(subject_uid: agent.uid)

      assert all.conversations |> Enum.map(& &1.id) |> Enum.sort() ==
               [empty.id, stub.id, full.id] |> Enum.sort()
    end
  end

  describe "console_list with a search" do
    test "matches an exact subject UID, key fragments, and displayed names" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      %{principal: peer} = PrincipalsFixtures.human_fixture(%{display_name: "Boris"})

      channel_fixture("lark:oc_market", kind: :im_group, name: "Ankole 用户群")
      channel_fixture("lark:oc_dm", kind: :im_dm, name: nil)

      group =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_market", %{
          metadata: %{
            "origin" => %{"channel_id" => "lark:oc_market", "channel_kind" => "im_group"}
          }
        })

      dm =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_dm", %{
          metadata: %{
            "origin" => %{
              "channel_id" => "lark:oc_dm",
              "channel_kind" => "im_dm",
              "peer_uid" => peer.uid
            }
          }
        })

      job = conversation_fixture(agent.uid, BackgroundAgentJobs.job_session_id(2000))
      decoy = conversation_fixture(agent.uid, "signal-channel:lark:ocXmarket")

      assert {:ok, page} = list_conversations(search: "用户群")
      assert Enum.map(page.conversations, & &1.id) == [group.id]

      assert {:ok, page} = list_conversations(search: "Bori")
      assert Enum.map(page.conversations, & &1.id) == [dm.id]

      # `_` matches only itself, not any character.
      assert {:ok, page} = list_conversations(search: "oc_market")
      assert Enum.map(page.conversations, & &1.id) == [group.id]

      # Subject input matches regardless of case; stored UIDs are lowercase.
      assert {:ok, page} = list_conversations(search: String.upcase(agent.uid))

      assert page.conversations |> Enum.map(& &1.id) |> Enum.sort() ==
               [group.id, dm.id, job.id, decoy.id] |> Enum.sort()

      assert {:ok, page} = list_conversations(search: "  ")
      assert length(page.conversations) == 4
    end
  end

  test "current UUID keys and metadata origins remain OR alternatives before cursor pagination" do
    %{principal: agent} = PrincipalsFixtures.agent_fixture()
    %{principal: peer} = PrincipalsFixtures.human_fixture(%{display_name: "Peer needle_%"})
    primary = channel_fixture("mock:canonical_%", name: "Canonical needle_%")
    origin = channel_fixture("mock:origin_%", name: "Origin needle_%")

    canonical =
      conversation_fixture(agent.uid, Ankole.Sessions.Key.conversation(primary.id), %{
        metadata: %{"origin" => %{"conversation_id" => origin.id, "peer_uid" => peer.uid}},
        updated_at: ~U[2026-07-02 12:00:00.000000Z]
      })

    metadata_only =
      conversation_fixture(agent.uid, "custom:metadata-only", %{
        metadata: %{"origin" => %{"conversation_id" => origin.id}},
        updated_at: ~U[2026-07-02 11:00:00.000000Z]
      })

    _newer_decoy =
      conversation_fixture(agent.uid, "custom:needleXY", %{
        updated_at: ~U[2026-07-02 13:00:00.000000Z]
      })

    for {row, at} <- [
          {canonical, ~U[2026-07-02 12:00:00.000000Z]},
          {metadata_only, ~U[2026-07-02 11:00:00.000000Z]}
        ] do
      row |> Ecto.Changeset.change(updated_at: at) |> Repo.update!()
    end

    for search <- ["Canonical needle_%", "mock:canonical_%", primary.id, "Peer needle_%"] do
      assert {:ok, page} = list_conversations(search: search)
      assert Enum.map(page.conversations, & &1.id) == [canonical.id]
    end

    for search <- ["Origin needle_%", "mock:origin_%", "needle_%"] do
      assert {:ok, first} = list_conversations(search: search, limit: 1)
      assert Enum.map(first.conversations, & &1.id) == [canonical.id]
      assert is_binary(first.next_cursor)

      assert {:ok, second} =
               list_conversations(
                 search: search,
                 limit: 1,
                 cursor: first.next_cursor
               )

      assert Enum.map(second.conversations, & &1.id) == [metadata_only.id]
      assert is_nil(second.next_cursor)
    end

    other_tenant = create_tenant()
    Repo.put_tenant_id(other_tenant.id)
    assert {:ok, %{conversations: []}} = list_conversations(search: "needle_%")
  end

  describe "console_list compared with the earlier Ecto query" do
    test "gives the same id order for each filter and for the joined pages" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      %{principal: other} = PrincipalsFixtures.agent_fixture()
      %{principal: peer} = PrincipalsFixtures.human_fixture(%{display_name: "Parity Peer"})
      group = channel_fixture("lark:oc_parity", kind: :im_group, name: "Parity 群")
      tie = ~U[2026-07-03 10:00:00.000000Z]

      channel =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_parity", %{
          metadata: %{"origin" => %{"channel_id" => "lark:oc_parity"}},
          updated_at: ~U[2026-07-03 12:00:00.000000Z]
        })

      dm =
        conversation_fixture(agent.uid, "custom:parity-dm", %{
          metadata: %{"origin" => %{"peer_uid" => peer.uid}},
          updated_at: tie
        })

      origin =
        conversation_fixture(agent.uid, "custom:parity-origin", %{
          metadata: %{"origin" => %{"conversation_id" => group.id}},
          updated_at: tie
        })

      ended =
        conversation_fixture(agent.uid, "manual:parity_%ended", %{
          updated_at: ~U[2026-07-03 09:00:00.000000Z]
        })

      foreign =
        conversation_fixture(other.uid, "manual:parity-other", %{
          updated_at: ~U[2026-07-03 11:00:00.000000Z]
        })

      ended |> Ecto.Changeset.change(ended_at: tie) |> Repo.update!()
      for _ <- 1..3, do: message_fixture(channel)
      message_fixture(dm)
      for _ <- 1..2, do: message_fixture(origin)
      message_fixture(foreign)

      filters = [
        [],
        [subject_uid: agent.uid],
        [subject_uid: other.uid],
        [conversation_key: "parity_%"],
        [conversation_key: "parity"],
        [search: "Parity 群"],
        [search: "Parity Peer"],
        [search: "lark:oc_parity"],
        [search: agent.uid],
        [search: "parity"],
        [active: true],
        [active: false],
        [min_messages: 1],
        [min_messages: 2],
        [min_messages: 3],
        [search: "parity", active: true, min_messages: 1],
        [subject_uid: agent.uid, search: "Parity", min_messages: 2]
      ]

      for filter <- filters do
        expected = legacy_ids(filter)
        assert {:ok, %{conversations: rows}} = list_conversations(filter)
        assert Enum.map(rows, & &1.id) == expected, "filter #{inspect(filter)}"
        assert paged_ids(filter, nil, []) == expected, "pages of #{inspect(filter)}"
      end

      assert {:error, %Ash.Error.Invalid{}} = list_conversations(cursor: "not-a-keyset")
    end
  end

  describe "console_list with a conversation key filter" do
    test "treats underscore and percent as literal characters" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      target = conversation_fixture(agent.uid, "manual:literal_%key")
      _decoy = conversation_fixture(agent.uid, "manual:literal-Xwildcard-key")

      assert {:ok, page} =
               list_conversations(conversation_key: "literal_%key")

      assert Enum.map(page.conversations, & &1.id) == [target.id]
    end
  end

  describe "the display facts of a conversation" do
    test "counts the conversation's messages" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()

      conversation =
        conversation_fixture(agent.uid, BackgroundAgentJobs.job_session_id(1000))

      message_fixture(conversation)
      message_fixture(conversation)

      projection = reload(conversation)

      assert projection.message_count == 2
      assert projection.kind == :job
      assert projection.display_name == nil
      assert projection.channel_kind == nil
      assert projection.signal_adapter == nil
    end

    test "uses the group name and lark adapter instead of the server domain" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()

      channel_fixture("lark:oc_named",
        kind: :im_group,
        name: "Ankole 用户群",
        metadata: %{"domain" => "feishu"}
      )

      conversation =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_named", %{
          metadata: %{
            "origin" => %{
              "channel_id" => "lark:oc_named",
              "channel_kind" => "im_group"
            }
          }
        })

      projection = reload(conversation)

      assert projection.kind == :conversation
      assert projection.display_name == "Ankole 用户群"
      assert projection.channel_kind == "im_group"
      assert projection.signal_adapter == "lark"
    end

    test "uses the peer display name instead of a DM channel name" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      %{principal: peer} = PrincipalsFixtures.human_fixture(%{display_name: "Boris"})
      channel_fixture("lark:oc_dm", kind: :im_dm, name: "Provider DM")

      conversation =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_dm", %{
          metadata: %{
            "origin" => %{
              "channel_id" => "lark:oc_dm",
              "channel_kind" => "im_dm",
              "peer_uid" => peer.uid
            }
          }
        })

      projection = reload(conversation)

      assert projection.display_name == "Boris"
      assert projection.channel_kind == "im_dm"
      assert projection.signal_adapter == "lark"
    end

    test "falls back to the bare peer uid when the peer has no display name" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      channel_fixture("lark:oc_ghost", kind: :im_dm, name: nil)

      conversation =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_ghost", %{
          metadata: %{
            "origin" => %{
              "channel_id" => "lark:oc_ghost",
              "channel_kind" => "im_dm",
              "peer_uid" => "ghost"
            }
          }
        })

      projection = reload(conversation)

      assert projection.display_name == "ghost"
    end

    test "cron execution sessions read as kind cron" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()

      conversation =
        conversation_fixture(agent.uid, "cron:#{Ecto.UUID.generate()}")

      projection = reload(conversation)

      assert projection.kind == :cron
      assert projection.channel_kind == nil
      assert projection.signal_adapter == nil
    end
  end

  describe "the display facts of a page" do
    test "decorates a mixed page in batch" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      channel_fixture("lark:oc_batch", kind: :im_group, name: "批量群")

      named =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_batch", %{
          metadata: %{
            "origin" => %{
              "channel_id" => "lark:oc_batch",
              "channel_kind" => "im_group"
            }
          }
        })

      plain = conversation_fixture(agent.uid, "manual-session:plain-#{Ecto.UUID.generate()}")
      message_fixture(named)

      projections = load_facts([named.id, plain.id])

      assert [%{display_name: "批量群", message_count: 1}, %{display_name: nil, message_count: 0}] =
               projections
    end
  end

  @facts [:kind, :display_name, :channel_kind, :signal_adapter, :message_count]

  defp reload(conversation),
    do: AIGateway.get_conversation_by_id!(conversation.id, load: @facts)

  # The facts of a page load in one batch, in the order of the ids.
  defp load_facts(ids) do
    rows =
      AIGateway.list_conversations!(query: [filter: [id: [in: ids]]], load: @facts)
      |> Map.new(&{&1.id, &1})

    Enum.map(ids, &Map.fetch!(rows, &1))
  end

  # Reads one page as the v2 list does: the action arguments, the page size,
  # and the keyset of the last row of the page before.
  defp list_conversations(opts) do
    {page, arguments} = Keyword.split(opts, [:limit, :cursor])
    page = [limit: page[:limit] || 50] ++ if(page[:cursor], do: [after: page[:cursor]], else: [])

    case Conversation
         |> Ash.Query.for_read(:console_list, Map.new(arguments))
         |> Ankole.Ash.read(page: page) do
      {:ok, %{results: conversations, more?: more?}} ->
        next_cursor = if more?, do: List.last(conversations).__metadata__.keyset
        {:ok, %{conversations: conversations, next_cursor: next_cursor}}

      error ->
        error
    end
  end

  defp paged_ids(filter, cursor, ids) do
    assert {:ok, page} =
             list_conversations(filter ++ [limit: 2, cursor: cursor])

    ids = ids ++ Enum.map(page.conversations, & &1.id)
    if page.next_cursor, do: paged_ids(filter, page.next_cursor, ids), else: ids
  end

  # The Ecto query that the console list used before the console_list read
  # action. The parity test compares the two id sequences.
  defp legacy_ids(opts) do
    import Ecto.Query

    query = from(conversation in Conversation, as: :conversation)

    query =
      case opts[:subject_uid] do
        nil -> query
        subject_uid -> where(query, [c], c.subject_uid == ^subject_uid)
      end

    query =
      case opts[:conversation_key] do
        nil ->
          query

        key ->
          where(query, [c], ilike(c.conversation_key, ^("%" <> Repo.escape_like(key) <> "%")))
      end

    query =
      case opts[:search] do
        nil ->
          query

        search ->
          pattern = "%#{Repo.escape_like(search)}%"
          prefix = Ankole.Sessions.Key.conversation("")
          subject = String.downcase(search)

          channel_match =
            from channel in PublicConversation,
              where:
                (ilike(channel.title, ^pattern) or
                   ilike(channel.provider_conversation_id, ^pattern)) and
                  (parent_as(:conversation).conversation_key ==
                     fragment("? || ?::text", ^prefix, channel.id) or
                     fragment(
                       "? -> 'origin' ->> 'conversation_id' = ?::text",
                       parent_as(:conversation).metadata,
                       channel.id
                     ))

          peer_match =
            from principal in Ankole.Principals.Principal,
              where:
                ilike(principal.display_name, ^pattern) and
                  principal.uid ==
                    fragment("? -> 'origin' ->> 'peer_uid'", parent_as(:conversation).metadata)

          where(
            query,
            [c],
            c.subject_uid == ^subject or ilike(c.conversation_key, ^pattern) or
              exists(channel_match) or exists(peer_match)
          )
      end

    query =
      case opts[:active] do
        nil -> query
        true -> where(query, [c], is_nil(c.ended_at))
        false -> where(query, [c], not is_nil(c.ended_at))
      end

    query =
      case opts[:min_messages] do
        min when is_integer(min) and min > 0 ->
          where(
            query,
            [c],
            fragment(
              "(SELECT COUNT(*) FROM (SELECT 1 FROM ai_gateway_messages m WHERE m.tenant_id = ? AND m.subject_uid = ? AND m.conversation_id = ? LIMIT ?) bounded) >= ?",
              c.tenant_id,
              c.subject_uid,
              c.id,
              ^min,
              ^min
            )
          )

        _none ->
          query
      end

    query
    |> order_by([c], desc: c.updated_at, desc: c.id)
    |> Repo.all()
    |> Enum.map(& &1.id)
  end

  defp conversation_fixture(subject_uid, key, attrs \\ %{}) do
    {key, attrs} =
      case key do
        "signal-channel:" <> provider_id ->
          public =
            Repo.get_by(PublicConversation, provider_conversation_id: provider_id) ||
              channel_fixture(provider_id, [])

          metadata = Map.get(attrs, :metadata, %{})

          metadata =
            case metadata["origin"] do
              nil ->
                metadata

              origin ->
                Map.put(
                  metadata,
                  "origin",
                  origin |> Map.delete("channel_id") |> Map.put("conversation_id", public.id)
                )
            end

          {Ankole.Sessions.Key.conversation(public.id), Map.put(attrs, :metadata, metadata)}

        _ ->
          {key, attrs}
      end

    attrs = Map.new(attrs)

    {:ok, conversation} =
      Ankole.Ash.create(
        Conversation,
        :open,
        Map.merge(
          %{subject_uid: subject_uid, conversation_key: key, metadata: %{}},
          Map.drop(attrs, [:updated_at])
        )
      )

    case Map.fetch(attrs, :updated_at) do
      {:ok, at} -> conversation |> Ecto.Changeset.change(updated_at: at) |> Repo.update!()
      :error -> conversation
    end
  end

  defp message_fixture(conversation) do
    {:ok, message} =
      Repo.transact(fn ->
        Ankole.Ash.create(Message, :journal, %{
          subject_uid: conversation.subject_uid,
          conversation_id: conversation.id,
          content: [%{"type" => "text", "text" => "hi"}],
          metadata: %{}
        })
      end)

    message
  end

  defp channel_fixture(provider_id, attrs) do
    now = DateTime.utc_now(:microsecond)
    attrs = Map.new(attrs)
    title = attrs[:name] || provider_id
    kind = attrs[:kind] || :im_group

    Ankole.ExternalConversationsFixtures.create_external_conversation!(
      Map.merge(Map.drop(attrs, [:kind, :name]), %{
        id: Ecto.UUID.generate(),
        external_kind: kind,
        title: title,
        provider_conversation_id: provider_id,
        reply_mode: :entry,
        last_activity_at: now,
        first_seen_at: now,
        last_seen_at: now
      })
    )
  end
end
