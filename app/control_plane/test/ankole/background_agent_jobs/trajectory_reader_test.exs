defmodule Ankole.BackgroundAgentJobs.TrajectoryReaderTest do
  use Ankole.AIGatewayCase

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.TrajectoryReader
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.Repo

  @page_bytes 24 * 1_024
  @opaque_prefix "ankole-aigateway-opaque-v1:"

  describe "current_attempt_lead" do
    setup do
      job = running_job!("lead-page", attempts: 1)
      base = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)

      older =
        record_turn!(job, %{
          turn_id: "turn-older",
          kind: "compaction",
          started_at: base,
          items: [assistant("a1"), tool("t1"), silent_reasoning("r1"), assistant("a2")]
        })

      newer =
        record_turn!(job, %{
          turn_id: "turn-newer",
          started_at: DateTime.add(base, 1, :second),
          items: [assistant("b1"), silent_reasoning("r2"), tool("t2"), assistant("b2")]
        })

      %{job: job, turns: [older, newer], older: older, newer: newer}
    end

    test "selects the newest groups within the group budget and spans their Turns", ctx do
      rows = [
        {1, ["b2"], true, [ctx.newer.id]},
        {2, ["t2", "t2", "b2"], true, [ctx.newer.id]},
        {3, ["b1", "t2", "t2", "b2"], true, [ctx.newer.id]},
        {4, ["a2", "b1", "t2", "t2", "b2"], true, [ctx.older.id, ctx.newer.id]},
        {6, ["a1", "t1", "t1", "a2", "b1", "t2", "t2", "b2"], false,
         [ctx.older.id, ctx.newer.id]},
        {20, ["a1", "t1", "t1", "a2", "b1", "t2", "t2", "b2"], false,
         [ctx.older.id, ctx.newer.id]}
      ]

      for {groups, expected, more?, turn_ids} <- rows do
        assert {:ok, page} = read(ctx, groups)
        assert labels(page) == expected, "groups=#{groups}"
        assert is_binary(page.next_cursor) == more?, "groups=#{groups}"
        assert page.turn_ids == turn_ids, "groups=#{groups}"
      end
    end

    test "walks the whole attempt through cursors without a gap or a repeat", ctx do
      assert {:ok, first} = read(ctx, 2)
      assert labels(first) == ["t2", "t2", "b2"]

      assert {:ok, second} = read(ctx, 2, first.next_cursor)
      assert labels(second) == ["a2", "b1"]
      assert second.turn_ids == [ctx.older.id, ctx.newer.id]

      assert {:ok, third} = read(ctx, 2, second.next_cursor)
      assert labels(third) == ["a1", "t1", "t1"]
      assert third.next_cursor == nil
      assert third.turn_ids == [ctx.older.id]
    end

    test "rejects every cursor that does not name one readable unit of the attempt", ctx do
      assert {:ok, %{next_cursor: cursor}} = read(ctx, 1)
      assert {:ok, _page} = read(ctx, 1, "")

      stale = %{ctx.job | attempts: 2}

      assert {:error, :background_agent_job_trajectory_cursor_stale} =
               read(%{ctx | job: stale}, 1, cursor)

      other_job = running_job!("lead-page-other", attempts: 1)

      stranger =
        record_turn!(other_job, %{turn_id: "turn-stranger", items: [assistant("s1")]})

      invalid = [
        {"garbage", "not-a-cursor"},
        {"version 1 shape",
         encode(%{"v" => 1, "attempt" => 1, "turn_id" => ctx.newer.id, "group_position" => 0})},
        {"replay-only item",
         encode(%{"v" => 2, "attempt" => 1, "turn_id" => ctx.newer.id, "position" => 1})},
        {"missing position",
         encode(%{"v" => 2, "attempt" => 1, "turn_id" => ctx.newer.id, "position" => 9})},
        {"another job's Turn",
         encode(%{"v" => 2, "attempt" => 1, "turn_id" => stranger.id, "position" => 0})},
        {"unknown Turn",
         encode(%{"v" => 2, "attempt" => 1, "turn_id" => Ecto.UUID.generate(), "position" => 0})}
      ]

      for {label, bad} <- invalid do
        assert {:error, :invalid_background_agent_job_trajectory_cursor} = read(ctx, 1, bad),
               label
      end
    end

    test "keeps the page within the byte budget and reports what it cut", _ctx do
      job = running_job!("lead-bytes", attempts: 1)

      turn =
        record_turn!(job, %{
          turn_id: "turn-large",
          header: %{
            "format" => "ankole_chatml",
            "version" => 1,
            "metadata" => %{"redacted" => true}
          },
          items: [assistant("large", String.duplicate("大", 80_000))]
        })

      assert {:ok, page} =
               TrajectoryReader.page(job, {:current_attempt_lead, [turn]}, nil, %{
                 groups: 3,
                 bytes: @page_bytes
               })

      assert [%{redacted: true, content_truncated: true}] = page.units
      assert page_bytes(page) <= @page_bytes
      assert page.next_cursor == nil
    end

    test "reads a bounded item window instead of the whole attempt", _ctx do
      job = running_job!("lead-window", attempts: 1)

      items =
        Enum.flat_map(1..30, fn index ->
          [assistant("m#{index}", "item-message-#{index}"), silent_reasoning("r#{index}")]
        end)

      turn = record_turn!(job, %{turn_id: "turn-window", items: items})
      count_rows_read(:turn_items)

      assert {:ok, page} =
               TrajectoryReader.page(job, {:current_attempt_lead, [turn]}, nil, %{
                 groups: 1,
                 bytes: @page_bytes
               })

      assert labels(page) == ["m30"]
      assert rows_read(:turn_items) < 30

      assert {:ok, second} =
               TrajectoryReader.page(job, {:current_attempt_lead, [turn]}, page.next_cursor, %{
                 groups: 2,
                 bytes: @page_bytes
               })

      assert labels(second) == ["m28", "m29"]
    end

    test "a Turn without items renders nothing and does not break the walk", _ctx do
      job = running_job!("lead-empty", attempts: 1)
      base = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)
      empty = record_turn!(job, %{turn_id: "turn-empty", started_at: base, items: []})

      newer =
        record_turn!(job, %{
          turn_id: "turn-after-empty",
          started_at: DateTime.add(base, 1, :second),
          items: [assistant("n1"), assistant("n2")]
        })

      assert {:ok, page} =
               TrajectoryReader.page(job, {:current_attempt_lead, [empty, newer]}, nil, %{
                 groups: 2,
                 bytes: @page_bytes
               })

      assert labels(page) == ["n1", "n2"]
      assert page.next_cursor == nil
      assert page.turn_ids == [empty.id, newer.id]
    end

    test "keeps AIGateway opaque values encoded on the model page", _ctx do
      job = running_job!("lead-opaque", attempts: 1)
      turn = record_turn!(job, %{turn_id: "turn-opaque", items: [opaque_tool("secret")]})

      assert {:ok, page} =
               TrajectoryReader.page(job, {:current_attempt_lead, [turn]}, nil, %{
                 groups: 1,
                 bytes: @page_bytes
               })

      assert [%{messages: [_call, %{"content" => content}]}] = page.units
      assert String.starts_with?(content, @opaque_prefix)
    end
  end

  describe "one_turn" do
    test "returns the newest groups of the Turn and says when earlier ones exist" do
      job = running_job!("one-turn", attempts: 1)

      full =
        record_turn!(job, %{turn_id: "turn-25", items: Enum.map(1..25, &assistant("m#{&1}"))})

      exact =
        record_turn!(job, %{turn_id: "turn-20", items: Enum.map(1..20, &assistant("e#{&1}"))})

      assert {:ok, page} =
               TrajectoryReader.page(job, {:one_turn, full}, nil, %{
                 groups: 20,
                 bytes: @page_bytes
               })

      assert labels(page) == Enum.map(6..25, &"m#{&1}")
      assert is_binary(page.next_cursor)
      assert page.turn_ids == [full.id]

      assert {:ok, whole} =
               TrajectoryReader.page(job, {:one_turn, exact}, nil, %{
                 groups: 20,
                 bytes: @page_bytes
               })

      assert length(whole.units) == 20
      assert whole.next_cursor == nil
    end

    test "reveals AIGateway opaque values for the owner Agent" do
      job = running_job!("one-turn-opaque", attempts: 1)
      turn = record_turn!(job, %{turn_id: "turn-opaque", items: [opaque_tool("secret")]})

      assert {:ok, page} =
               TrajectoryReader.page(job, {:one_turn, turn}, nil, %{
                 groups: 20,
                 bytes: @page_bytes
               })

      assert [%{messages: [_call, %{"content" => "secret"}]}] = page.units
    end
  end

  describe "attempt_summary" do
    test "returns the newest assistant text across the given Turns, bounded to the byte budget" do
      job = running_job!("summary", attempts: 1)
      base = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)
      long_text = String.duplicate("z", 3_000)

      reported =
        record_turn!(job, %{
          turn_id: "turn-report",
          started_at: base,
          items: [assistant("r", "Older report.")]
        })

      tools_only =
        record_turn!(job, %{
          turn_id: "turn-tools",
          started_at: DateTime.add(base, 1, :second),
          items: [tool("t1"), silent_reasoning("r1")]
        })

      long =
        record_turn!(job, %{
          turn_id: "turn-long",
          started_at: DateTime.add(base, 2, :second),
          items: [assistant("l", long_text)]
        })

      empty =
        record_turn!(job, %{
          turn_id: "turn-empty",
          started_at: DateTime.add(base, 3, :second),
          items: []
        })

      rows = [
        {[reported], "Older report."},
        {[reported, tools_only], "Older report."},
        {[tools_only], nil},
        {[reported, tools_only, long],
         String.duplicate("z", 993) <> "...[truncated]" <> String.duplicate("z", 993)},
        {[empty], nil},
        {[], nil}
      ]

      for {turns, expected} <- rows do
        assert {:ok, page} =
                 TrajectoryReader.page(job, {:attempt_summary, turns}, nil, %{bytes: 2_000})

        case expected do
          nil -> assert page.units == []
          text -> assert [%{text: ^text}] = page.units
        end

        assert page.next_cursor == nil
      end
    end
  end

  describe "console_detail" do
    setup do
      job = running_job!("console", attempts: 1)
      base = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)

      failed =
        record_turn!(job, %{
          turn_id: "turn-failed",
          status: "failed",
          error: %{"code" => "boom", "summary" => "It failed."},
          started_at: base,
          items: []
        })

      middle =
        record_turn!(job, %{
          turn_id: "turn-middle",
          started_at: DateTime.add(base, 1, :second),
          items: [assistant("m1"), assistant("m2"), assistant("m3")]
        })

      latest =
        record_turn!(job, %{
          turn_id: "turn-latest",
          started_at: DateTime.add(base, 2, :second),
          items: [assistant("l1"), assistant("l2"), assistant("l3")]
        })

      %{job: job, turns: [failed, middle, latest], failed: failed, middle: middle, latest: latest}
    end

    test "pages newest first and spans a Turn that recorded no readable item", ctx do
      budget = %{groups: 4, bytes: @page_bytes}

      assert {:ok, first} =
               TrajectoryReader.page(ctx.job, {:console_detail, ctx.turns}, nil, budget)

      assert labels(first) == ["m3", "l1", "l2", "l3"]
      assert first.turn_ids == [ctx.middle.id, ctx.latest.id]
      assert is_binary(first.next_cursor)

      assert {:ok, second} =
               TrajectoryReader.page(
                 ctx.job,
                 {:console_detail, ctx.turns},
                 first.next_cursor,
                 budget
               )

      assert labels(second) == ["m1", "m2"]
      assert second.turn_ids == [ctx.failed.id, ctx.middle.id]
      assert second.next_cursor == nil
    end

    test "does not span the cursor's Turn again once it has no unit left", ctx do
      budget = %{groups: 3, bytes: @page_bytes}

      assert {:ok, first} =
               TrajectoryReader.page(ctx.job, {:console_detail, ctx.turns}, nil, budget)

      assert labels(first) == ["l1", "l2", "l3"]
      assert first.turn_ids == [ctx.latest.id]
      assert is_binary(first.next_cursor)

      assert {:ok, second} =
               TrajectoryReader.page(
                 ctx.job,
                 {:console_detail, ctx.turns},
                 first.next_cursor,
                 budget
               )

      assert labels(second) == ["m1", "m2", "m3"]
      assert second.turn_ids == [ctx.failed.id, ctx.middle.id]
      assert second.next_cursor == nil
    end

    test "reveals opaque values and carries projection truncation into the unit", _ctx do
      job = running_job!("console-opaque", attempts: 1)
      base = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)

      opaque =
        record_turn!(job, %{
          turn_id: "turn-opaque",
          started_at: base,
          items: [opaque_tool("secret")]
        })

      huge =
        record_turn!(job, %{
          turn_id: "turn-huge",
          started_at: DateTime.add(base, 1, :second),
          items: [huge_arguments_tool("big")]
        })

      assert {:ok, page} =
               TrajectoryReader.page(job, {:console_detail, [opaque, huge]}, nil, %{
                 groups: 20,
                 bytes: @page_bytes
               })

      assert [
               %{messages: [_call, %{"content" => "secret"}], content_truncated: false},
               %{content_truncated: true}
             ] = page.units
    end
  end

  describe "lineage_replay" do
    test "walks the workspace lineage lead threads chronologically and skips child threads" do
      %{principal: agent} = background_agent_fixture()
      source = create_job!(agent.uid, "replay-source")
      base = DateTime.utc_now(:microsecond)

      source_attempt_one = %{source | attempts: 1, runtime_thread_id: "thread-lead-1"}

      record_turn!(source_attempt_one, %{
        thread: "thread-lead-1",
        turn_id: "turn-lead-1",
        started_at: DateTime.add(base, -50),
        items: [user("源任务"), assistant("a-1", "第一步完成")]
      })

      record_turn!(source_attempt_one, %{
        thread: "thread-child",
        turn_id: "turn-child",
        started_at: DateTime.add(base, -40),
        items: [assistant("c-1", "child noise")]
      })

      record_turn!(%{source | attempts: 2, runtime_thread_id: "thread-lead-2"}, %{
        thread: "thread-lead-2",
        turn_id: "turn-lead-2",
        started_at: DateTime.add(base, -30),
        items: [assistant("a-2", "重建后继续")]
      })

      source =
        source
        |> Ecto.Changeset.change(
          status: "succeeded",
          attempts: 2,
          runtime_thread_id: "thread-lead-2"
        )
        |> Repo.update!()

      respawn =
        create_job!(agent.uid, "replay-respawn")
        |> Ecto.Changeset.change(
          continued_from_job_id: source.id,
          workspace_owner_job_id: source.workspace_owner_job_id,
          runtime_thread_id: "thread-lead-3",
          attempts: 1
        )
        |> Repo.update!()

      record_turn!(respawn, %{
        thread: "thread-lead-3",
        turn_id: "turn-lead-3",
        started_at: DateTime.add(base, -20),
        items: [assistant("a-3", "续接补充")]
      })

      assert {:ok, %{units: items, next_cursor: nil}} =
               TrajectoryReader.page(respawn, :lineage_replay, nil, %{items: 200})

      assert Enum.map(items, & &1.item_key) == ["user-源任务", "a-1", "a-2", "a-3"]

      assert Enum.map(items, & &1.runtime_thread_id) ==
               ["thread-lead-1", "thread-lead-1", "thread-lead-2", "thread-lead-3"]

      assert %{"type" => "userMessage"} = hd(items).item
    end

    test "pages the stream with the shared cursor and stops when the stream ends" do
      job = running_job!("replay-paging", attempts: 1)

      record_turn!(job, %{
        turn_id: "turn-page",
        items: Enum.map(0..204, &assistant("item-#{&1}", "消息 #{&1}"))
      })

      assert {:ok, %{units: first_page, next_cursor: cursor}} =
               TrajectoryReader.page(job, :lineage_replay, nil, %{items: 200})

      assert length(first_page) == 200
      assert is_binary(cursor)

      assert {:ok, %{units: second_page, next_cursor: nil}} =
               TrajectoryReader.page(job, :lineage_replay, cursor, %{items: 200})

      assert Enum.map(second_page, & &1.position) == Enum.to_list(200..204)

      exact = running_job!("replay-exact", attempts: 1)

      record_turn!(exact, %{
        turn_id: "turn-exact",
        items: Enum.map(0..199, &assistant("item-#{&1}"))
      })

      assert {:ok, %{units: whole, next_cursor: nil}} =
               TrajectoryReader.page(exact, :lineage_replay, nil, %{items: 200})

      assert length(whole) == 200

      assert {:error, :invalid_background_agent_job_trajectory_cursor} =
               TrajectoryReader.page(job, :lineage_replay, "not-a-cursor", %{items: 200})

      assert {:error, :invalid_background_agent_job_trajectory_cursor} =
               BackgroundAgentJobs.replay_items_page(job, "not-a-cursor")
    end

    test "reads only one bounded database page instead of materializing the lineage" do
      %{principal: agent} = background_agent_fixture()
      source = create_job!(agent.uid, "replay-bounded-1")

      jobs =
        Enum.map(1..12, fn index ->
          job =
            if index == 1 do
              source
            else
              create_job!(agent.uid, "replay-bounded-#{index}")
              |> Ecto.Changeset.change(workspace_owner_job_id: source.workspace_owner_job_id)
              |> Repo.update!()
            end

          turn_job = %{job | attempts: 1, runtime_thread_id: "thread-bounded-#{index}"}

          record_turn!(turn_job, %{
            turn_id: "turn-bounded-#{index}",
            items: [assistant("bounded-#{index}")]
          })

          job
        end)

      count_rows_read(:trajectory)

      assert {:ok, %{units: units, next_cursor: cursor}} =
               TrajectoryReader.page(List.last(jobs), :lineage_replay, nil, %{items: 2})

      assert length(units) == 2
      assert is_binary(cursor)
      assert rows_read(:trajectory) == 3

      assert {:ok, %{units: next_units}} =
               TrajectoryReader.page(List.last(jobs), :lineage_replay, cursor, %{items: 2})

      assert length(next_units) == 2
      assert rows_read(:trajectory) == 4
    end
  end

  defp read(%{job: job, turns: turns}, groups, cursor \\ nil) do
    TrajectoryReader.page(job, {:current_attempt_lead, turns}, cursor, %{
      groups: groups,
      bytes: @page_bytes
    })
  end

  # Each message names the item it came from: a tool pair yields two labels.
  defp labels(%{units: units}) do
    Enum.flat_map(units, fn unit ->
      Enum.map(unit.messages, fn
        %{"role" => "tool", "tool_call_id" => id} -> id
        %{"tool_calls" => [%{"id" => id} | _]} -> id
        %{"id" => id} -> id
      end)
    end)
  end

  defp page_bytes(page) do
    %{format: "ankole_chatml", version: 1, messages: Enum.flat_map(page.units, & &1.messages)}
    |> Ankole.JSON.encode!()
    |> byte_size()
  end

  defp encode(cursor), do: cursor |> Ankole.JSON.encode!() |> Base.url_encode64(padding: false)

  defp running_job!(suffix, attempts: attempts) do
    %{principal: agent} = background_agent_fixture()

    create_job!(agent.uid, suffix)
    |> Ecto.Changeset.change(
      status: "running",
      attempts: attempts,
      runtime_thread_id: "thread-lead"
    )
    |> Repo.update!()
  end

  defp create_job!(agent_uid, suffix) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "owner_session_id" => "parent-session-#{suffix}",
               "source_tool_call_id" => "tool-background-agent-job-#{suffix}",
               "title" => "Job #{suffix}",
               "task" => "Complete the #{suffix} job.",
               "reply_route" => %{
                 "binding_name" => "lark",
                 "signal_channel_id" => "chat-#{suffix}",
                 "provider_thread_id" => "thread-#{suffix}",
                 "source_entry_id" => "message-#{suffix}"
               }
             })

    job
  end

  # Records one Turn through the Worker recorder, so the reader sees rows in
  # the shape the production write path produces.
  defp record_turn!(%Job{} = job, attrs) do
    status = Map.get(attrs, :status, "completed")
    started_at = Map.get(attrs, :started_at, DateTime.utc_now(:microsecond))

    worker_attrs =
      %{
        "attempt" => job.attempts,
        "runtime_thread_id" => Map.get(attrs, :thread, job.runtime_thread_id),
        "runtime_turn_id" => Map.fetch!(attrs, :turn_id),
        "kind" => Map.get(attrs, :kind, "agent"),
        "status" => status,
        "revision" => 0,
        "trajectory" => Map.get(attrs, :header, %{"format" => "ankole_chatml", "version" => 1}),
        "error" => Map.get(attrs, :error, %{}),
        "started_at" => DateTime.to_iso8601(started_at),
        "turn_items" =>
          attrs
          |> Map.fetch!(:items)
          |> Enum.with_index(fn item, position ->
            %{"position" => position, "item_key" => Map.fetch!(item, "id"), "item" => item}
          end)
      }
      |> Ankole.Attrs.maybe_put(
        "completed_at",
        if(status in ~w(completed failed interrupted), do: DateTime.to_iso8601(started_at))
      )

    assert {:ok, turn} =
             Repo.transact(fn repo -> Turns.upsert_from_worker_in_tx(repo, job, worker_attrs) end)

    turn
  end

  defp assistant(id, text \\ nil),
    do: %{"type" => "agentMessage", "id" => id, "text" => text || "text #{id}"}

  defp user(text),
    do: %{
      "type" => "userMessage",
      "id" => "user-#{text}",
      "content" => [%{"type" => "text", "text" => text}]
    }

  defp silent_reasoning(id), do: %{"type" => "reasoning", "id" => id, "summary" => []}

  defp tool(id) do
    %{
      "type" => "dynamicToolCall",
      "id" => id,
      "tool" => "shell",
      "status" => "completed",
      "success" => true,
      "arguments" => %{"command" => "true"},
      "contentItems" => "ok"
    }
  end

  defp opaque_tool(secret) do
    %{
      tool("opaque")
      | "contentItems" => @opaque_prefix <> Base.url_encode64(secret, padding: false)
    }
  end

  defp huge_arguments_tool(id) do
    %{tool(id) | "arguments" => %{"payload" => String.duplicate("大", 80_000)}}
  end

  defp count_rows_read(kind) when kind in [:turn_items, :trajectory] do
    handler_id = "trajectory-window-#{kind}-#{System.unique_integer([:positive])}"
    test_pid = self()
    event = Ankole.Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, pid ->
          table_names =
            case kind do
              :turn_items ->
                [~s("background_agent_job_turn_items")]

              :trajectory ->
                [
                  ~s("background_agent_jobs"),
                  ~s("background_agent_job_turns"),
                  ~s("background_agent_job_turn_items")
                ]
            end

          if Enum.any?(table_names, &String.contains?(metadata.query, &1)) do
            send(pid, {{:trajectory_query, kind}, metadata.result})
          end
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp rows_read(kind) do
    Stream.repeatedly(fn ->
      receive do
        {{:trajectory_query, ^kind}, {:ok, result}} -> result.num_rows
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&is_integer/1)
    |> Enum.sum()
  end
end
