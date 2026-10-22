defmodule Ankole.AIGateway.ResponseChainReadTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  alias Ankole.AIGateway.{Events, ResponseChain, ResponseItems}
  alias Ankole.AIGateway.Schemas.Message

  setup do
    %{principal: subject} = human_fixture()
    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(subject.uid, "chain-reads")
    %{subject: subject, conversation: conversation}
  end

  test "suffix matches the original fold across checkpoints, invisible rows and unmatched journals",
       ctx do
    old_match = row(ctx, nil, caller("current"))
    boundary = row(ctx, old_match, caller("previous"))
    early = row(ctx, boundary, caller("current"))
    error = row(ctx, early, caller("other"), status: :error)
    retracted = row(ctx, error, caller("other"), status: :retracted)
    checkpoint = row(ctx, retracted, caller("other"), type: :checkpoint)
    missing = row(ctx, checkpoint, %{"tool_result_journal" => true})
    unmatched = row(ctx, missing, Map.put(caller("other"), "tool_result_journal", true))
    latest = row(ctx, unmatched, caller("current"))

    outputs = [
      %{"type" => "function_call_output", "call_id" => "function", "output" => "done"},
      %{"type" => "custom_tool_call_output", "call_id" => "custom", "output" => "done"},
      %{"type" => "message", "role" => "assistant", "content" => []}
    ]

    journal =
      row(ctx, latest, Map.put(caller("current"), "tool_result_journal", true), content: outputs)

    assert {:ok, actual} = suffix(ctx, "current")
    assert actual == original_suffix(ctx, "current")
    assert Enum.map(actual.rows, & &1.id) == [early.id, latest.id, journal.id]
    assert Enum.map(actual.responses, & &1.id) == [early.id, latest.id]
    assert actual.recorded_call_ids == MapSet.new(["function", "custom"])
    assert actual.leaf == journal.id

    assert Enum.map(ResponseChain.expand_history(ctx.conversation.id), & &1.id) ==
             [checkpoint.id, missing.id, unmatched.id, latest.id, journal.id]

    assert {:ok, empty} = suffix(ctx, "absent")
    assert empty == %{leaf: journal.id, rows: [], responses: [], recorded_call_ids: MapSet.new()}
    branch = row(ctx, boundary, caller("branch"))
    assert {:ok, selected} = suffix(ctx, "current")
    assert selected == original_suffix(ctx, "current")
    assert selected.leaf == branch.id
    assert selected.rows == []
  end

  test "metadata crosses checkpoints but excludes their watermarks and other branches", ctx do
    first = row(ctx, nil, caller("first"))
    _sibling = row(ctx, first, caller("unselected"))
    selected = row(ctx, first, caller("selected"))
    failed = row(ctx, selected, caller("failed"), status: :error)
    checkpoint = row(ctx, failed, caller("checkpoint"), type: :checkpoint)
    _last = row(ctx, checkpoint, %{"request_metadata" => "invalid"})

    assert {:ok, metadata} =
             ResponseChain.visible_response_metadata(ctx.subject.uid, ctx.conversation.id)

    assert metadata == [%{"run" => "first"}, %{"run" => "selected"}, %{}]
  end

  test "only a complete checkpoint stops history and all reads protect against cycles", ctx do
    oldest = row(ctx, nil, caller("current"))
    incomplete = row(ctx, oldest, caller("current"), type: :checkpoint, status: :error)
    final = row(ctx, incomplete, caller("current"))

    assert Enum.map(ResponseChain.expand_history(ctx.conversation.id), & &1.id) == [
             oldest.id,
             final.id
           ]

    oldest |> Ecto.Changeset.change(previous_message_id: incomplete.id) |> Repo.update!()
    assert {:ok, selected} = suffix(ctx, "current")
    assert Enum.map(selected.rows, & &1.id) == [oldest.id, final.id]

    assert {:ok, [%{"run" => "current"}, %{"run" => "current"}]} =
             ResponseChain.visible_response_metadata(ctx.subject.uid, ctx.conversation.id)
  end

  test "reads require active ownership and subscription cleanup survives end", ctx do
    %{principal: stranger} = human_fixture()

    assert {:error, :invalid_conversation} =
             ResponseChain.visible_response_metadata(stranger.uid, ctx.conversation.id)

    assert {:error, :invalid_conversation} =
             ResponseChain.visible_response_suffix(
               stranger.uid,
               ctx.conversation.id,
               {"run", "current"}
             )

    other_tenant = create_tenant()

    Repo.with_tenant(other_tenant.id, fn ->
      assert {:error, :invalid_conversation} =
               ResponseChain.visible_response_metadata(ctx.subject.uid, ctx.conversation.id)

      assert {:error, :invalid_conversation} = suffix(ctx, "current")
    end)

    assert {:error, :invalid_metadata_selector} =
             ResponseChain.visible_response_suffix(ctx.subject.uid, ctx.conversation.id, %{
               "run" => "current"
             })

    assert :ok = Events.subscribe(ctx.subject.uid, ctx.conversation.id)

    ctx.conversation
    |> Ecto.Changeset.change(ended_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()

    assert {:error, :invalid_conversation} =
             ResponseChain.visible_response_metadata(ctx.subject.uid, ctx.conversation.id)

    assert {:error, :invalid_conversation} = suffix(ctx, "current")

    assert {:error, :invalid_conversation} =
             Events.subscribe(ctx.subject.uid, ctx.conversation.id)

    assert :ok = Events.unsubscribe(ctx.subject.uid, ctx.conversation.id)
  end

  test "SQL metadata payload excludes large content and suffix returns no old content", ctx do
    old =
      row(ctx, nil, caller("old"),
        content: [%{"text" => String.duplicate("old content", 100_000)}]
      )

    current = row(ctx, old, caller("current"))
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:ankole, :repo, :query], &__MODULE__.capture_query/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, [%{"run" => "old"}, %{"run" => "current"}]} =
             ResponseChain.visible_response_metadata(ctx.subject.uid, ctx.conversation.id)

    assert_receive {:chain_query, query, %{columns: ["caller_metadata"], rows: metadata_rows}}
    refute query =~ "message.*"
    refute query =~ "message.content"
    assert byte_size(Ankole.JSON.encode!(metadata_rows)) < 100
    assert {:ok, selected} = suffix(ctx, "current")
    assert Enum.map(selected.rows, & &1.id) == [current.id]
    assert_receive {:chain_query, query, %{rows: [_only_current]}}
    assert query =~ "WHERE chain.continue"
  end

  test "fixed suffix and checkpoint reads return fixed payload as old history grows", ctx do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:ankole, :repo, :query], &__MODULE__.capture_query/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)

    for old_count <- [1, 100, 1000] do
      {:ok, conversation} =
        Ankole.AIGatewayCase.ensure_conversation(ctx.subject.uid, "payload-#{old_count}")

      ctx = %{ctx | conversation: conversation}

      old =
        Enum.reduce(1..old_count, nil, fn _, previous ->
          row(ctx, previous, caller("old"), content: [%{"text" => String.duplicate("x", 4096)}])
        end)

      checkpoint = row(ctx, old, caller("old"), type: :checkpoint)

      Enum.reduce(1..3, checkpoint, fn _, previous ->
        row(ctx, previous, caller("current"), content: [%{"text" => "current"}])
      end)

      {:ok, full} =
        ResponseChain.visible_response_chain(ctx.subject.uid, conversation.id,
          stop_at_checkpoint: false
        )

      assert_receive {:chain_query, full_sql, _}
      assert_receive {:chain_params, ^full_sql, full_params}
      {:ok, selected} = suffix(ctx, "current")
      assert_receive {:chain_query, suffix_sql, _}
      assert_receive {:chain_params, ^suffix_sql, suffix_params}
      checkpoint_rows = ResponseChain.expand_history(conversation.id)
      assert_receive {:chain_query, checkpoint_sql, _}
      assert_receive {:chain_params, ^checkpoint_sql, checkpoint_params}
      assert length(full) == old_count + 4
      assert length(selected.rows) == 3
      assert length(checkpoint_rows) == 4

      assert content_bytes(selected.rows) ==
               byte_size(Ankole.JSON.encode!(List.duplicate([%{"text" => "current"}], 3)))

      assert recursive_rows(full_sql, full_params) == old_count + 4
      assert recursive_rows(suffix_sql, suffix_params) == 5
      assert recursive_rows(checkpoint_sql, checkpoint_params) == 4

      IO.puts(
        Ankole.JSON.encode!(%{
          prior_rows: old_count,
          full_content_bytes: content_bytes(full),
          suffix_content_bytes: content_bytes(selected.rows),
          checkpoint_content_bytes: content_bytes(checkpoint_rows),
          full_recursive_rows: old_count + 4,
          suffix_recursive_rows: 5,
          checkpoint_recursive_rows: 4
        })
      )
    end
  end

  defp content_bytes(rows),
    do: rows |> Enum.map(& &1.content) |> Ankole.JSON.encode!() |> byte_size()

  defp recursive_rows(query, params) do
    %{rows: [[[plan]]]} =
      Ecto.Adapters.SQL.query!(Repo, "EXPLAIN (ANALYZE, FORMAT JSON) " <> query, params)

    recursive_plan(plan["Plan"])["Actual Rows"]
  end

  defp recursive_plan(%{"Node Type" => "Recursive Union"} = plan), do: plan
  defp recursive_plan(plan), do: Enum.find_value(Map.get(plan, "Plans", []), &recursive_plan/1)

  test "10000 raw ancestors include invisible rows while public chains stay capped at 500", ctx do
    oldest = row(ctx, nil, caller("outside"))
    now = DateTime.utc_now(:microsecond)

    {rows, last} =
      Enum.map_reduce(1..10_000, oldest.id, fn index, previous ->
        id = Ecto.UUID.generate()

        attrs = %{
          id: id,
          tenant_id: ctx.conversation.tenant_id,
          subject_uid: ctx.subject.uid,
          conversation_id: ctx.conversation.id,
          type: :message,
          status: if(index == 10_000, do: :complete, else: :error),
          previous_message_id: previous,
          content: [],
          metadata: caller("current"),
          inserted_at: now,
          updated_at: now
        }

        {attrs, id}
      end)

    Enum.each(Enum.chunk_every(rows, 1000), &Repo.insert_all(Message, &1))

    assert {:ok, [%{"run" => "current"}]} =
             ResponseChain.visible_response_metadata(ctx.subject.uid, ctx.conversation.id)

    assert {:ok, selected} = suffix(ctx, "current")
    assert Enum.map(selected.rows, & &1.id) == [last]
    assert {:ok, chain} = ResponseChain.list_response_chain(ctx.subject.uid, last, 10_001)
    assert length(chain) == 500
  end

  def capture_query(
        _event,
        _measurements,
        %{query: query, result: {:ok, result}, params: params},
        observer
      ) do
    if self() == observer and String.starts_with?(query, "WITH RECURSIVE chain") do
      send(observer, {:chain_query, query, result})
      send(observer, {:chain_params, query, params})
    end
  end

  def capture_query(_event, _measurements, _metadata, _observer), do: :ok

  defp caller(value), do: %{"request_metadata" => %{"run" => value}}

  defp suffix(ctx, value),
    do:
      ResponseChain.visible_response_suffix(ctx.subject.uid, ctx.conversation.id, {"run", value})

  defp row(ctx, previous, metadata, opts \\ []) do
    id = Ankole.Ecto.UUIDv7.autogenerate()
    type = Keyword.get(opts, :type, :message)

    content =
      if type == :checkpoint,
        do: [Ankole.AIGateway.CompactionArtifacts.ref_item(id)],
        else: Keyword.get(opts, :content, [])

    %Message{id: id}
    |> Ecto.Changeset.change(%{
      subject_uid: ctx.subject.uid,
      conversation_id: ctx.conversation.id,
      previous_message_id: previous && previous.id,
      type: type,
      status: Keyword.get(opts, :status, :complete),
      metadata: metadata,
      content: content
    })
    |> Repo.insert!()
  end

  # Keep the pre-change client fold as an oracle independent of the SQL boundary.
  defp original_suffix(ctx, value) do
    {:ok, history} =
      ResponseChain.visible_response_chain(ctx.subject.uid, ctx.conversation.id,
        stop_at_checkpoint: false
      )

    leaf =
      case List.last(history) do
        nil -> nil
        message -> message.id
      end

    rows =
      history
      |> Enum.reverse()
      |> Enum.reduce_while([], fn row, rows ->
        cond do
          row.type == :checkpoint -> {:cont, rows}
          ResponseChain.response_metadata(row)["run"] == value -> {:cont, [row | rows]}
          row.metadata["tool_result_journal"] == true -> {:cont, rows}
          true -> {:halt, rows}
        end
      end)

    responses = Enum.reject(rows, &(&1.metadata["tool_result_journal"] == true))
    latest = List.last(responses)

    recorded_call_ids =
      rows
      |> Enum.filter(
        &(latest && &1.metadata["tool_result_journal"] == true &&
            &1.previous_message_id == latest.id)
      )
      |> Enum.flat_map(& &1.content)
      |> Enum.filter(&ResponseItems.output_item?/1)
      |> Enum.map(& &1[ResponseItems.pair_identity_field(&1)])
      |> MapSet.new()

    %{leaf: leaf, rows: rows, responses: responses, recorded_call_ids: recorded_call_ids}
  end
end
