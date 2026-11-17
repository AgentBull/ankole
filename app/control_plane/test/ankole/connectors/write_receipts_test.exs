defmodule Ankole.Connectors.WriteReceiptsTest do
  use Ankole.DataCase, async: false
  import ExUnit.CaptureLog

  alias Ankole.Connectors.{WriteReceipt, WriteReceipts}

  test "an in-flight write asks the Agent to inspect upstream state without replaying" do
    result = {:ok, %{"id" => "created"}, %{}}

    assert ^result =
             WriteReceipts.execute_scope("signal:in-flight", "toolkit", "create", %{}, fn ->
               assert {:error, error} =
                        WriteReceipts.execute_scope(
                          "signal:in-flight",
                          "toolkit",
                          "create",
                          %{},
                          fn ->
                            flunk("must not repeat the in-flight write")
                          end
                        )

               assert error.code == "write_already_in_flight"
               assert error.retryable == false
               assert error.request_sent == true
               assert error.message =~ "read-only tool"
               result
             end)
  end

  test "a client process exit settles the write as outcome unknown and preserves the exit" do
    assert catch_exit(
             WriteReceipts.execute_scope("signal:exit", "toolkit", "create", %{}, fn ->
               exit({:timeout, {GenServer, :call, [:client, :request]}})
             end)
           ) == {:timeout, {GenServer, :call, [:client, :request]}}

    assert Repo.get_by!(WriteReceipt, authority_scope: "signal:exit").status == "outcome_unknown"

    assert {:error, %{code: "previous_write_outcome_unknown", retryable: false}} =
             WriteReceipts.execute_scope("signal:exit", "toolkit", "create", %{}, fn ->
               flunk("must not replay an uncertain write")
             end)
  end

  test "an expired card execution claim recovers an orphan receipt before its own expiry" do
    scope = "action_card:orphan"

    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary(%{}, [:deterministic]))
      |> Base.encode16(case: :lower)

    assert {:ok, _} =
             Ankole.Ash.create(WriteReceipt, :claim_in_tx, %{
               authority_scope: scope,
               toolkit: "toolkit",
               tool_name: "create",
               args_sha256: hash,
               status: "in_flight",
               expires_at: DateTime.add(DateTime.utc_now(), 7_200)
             })

    assert {:recovered, %{status: "outcome_unknown"}} =
             WriteReceipts.execute_scope(
               scope,
               "toolkit",
               "create",
               %{},
               fn ->
                 flunk("recovery must not invoke the provider")
               end,
               recover_settled?: true
             )
  end

  test "receipt database failures preserve known upstream results and emit a warning" do
    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_receipt_resolution() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'receipt persistence unavailable'; END; $$
    """)

    Repo.query!("""
    CREATE TRIGGER reject_receipt_resolution BEFORE UPDATE OR DELETE ON connector_write_receipts
    FOR EACH ROW WHEN (OLD.authority_scope = 'signal:persistence-failure')
    EXECUTE FUNCTION pg_temp.reject_receipt_resolution()
    """)

    for {tool, result} <- [
          {"succeeded", {:ok, %{"id" => "known-success"}, %{}}},
          {"rejected", {:error, %{code: "rejected", request_sent: false}}}
        ] do
      log =
        capture_log([format: "$metadata$message\n", metadata: [:event]], fn ->
          assert ^result =
                   WriteReceipts.execute_scope(
                     "signal:persistence-failure",
                     "toolkit",
                     tool,
                     %{},
                     fn -> result end
                   )
        end)

      assert log =~ "connectors.write_receipt_persistence_failed"
      assert Repo.get_by!(WriteReceipt, tool_name: tool).status == "in_flight"
    end
  end

  test "expired in_flight rows transition to outcome_unknown on claim and prune_expired_in_tx" do
    past = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)

    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary(%{}, [:deterministic]))
      |> Base.encode16(case: :lower)

    {:ok, stale_in_flight} =
      Repo.transact_top_level(fn ->
        Ankole.Ash.create(WriteReceipt, :claim_in_tx, %{
          authority_scope: "signal:expired-in-flight",
          toolkit: "toolkit",
          tool_name: "create",
          args_sha256: hash,
          status: "in_flight",
          expires_at: past
        })
      end)

    assert {:error, %{code: "previous_write_outcome_unknown", retryable: false}} =
             WriteReceipts.execute_scope(
               "signal:expired-in-flight",
               "toolkit",
               "create",
               %{},
               fn ->
                 flunk("expired in_flight write must not re-execute upstream")
               end
             )

    assert Repo.get_by!(WriteReceipt, id: stale_in_flight.id).status == "outcome_unknown"

    {:ok, {prune_in_flight, prune_settled}} =
      Repo.transact_top_level(fn ->
        {:ok, r1} =
          Ankole.Ash.create(WriteReceipt, :claim_in_tx, %{
            authority_scope: "signal:prune-test",
            toolkit: "toolkit",
            tool_name: "tool_a",
            args_sha256: "hash_a",
            status: "in_flight",
            expires_at: past
          })

        {:ok, r2} =
          Ankole.Ash.create(WriteReceipt, :claim_in_tx, %{
            authority_scope: "signal:prune-test",
            toolkit: "toolkit",
            tool_name: "tool_b",
            args_sha256: "hash_b",
            status: "succeeded",
            expires_at: past
          })

        {:ok, {r1, r2}}
      end)

    {:ok, _} = Repo.transact_top_level(fn -> WriteReceipts.prune_expired_in_tx() end)

    kept = Repo.get_by!(WriteReceipt, id: prune_in_flight.id)
    assert kept.status == "outcome_unknown"
    assert DateTime.diff(kept.expires_at, DateTime.utc_now(), :second) > 7_000
    assert is_nil(Repo.get_by(WriteReceipt, id: prune_settled.id))
  end

  test "recover_settled? returns no_recorded_receipt without re-invoking upstream when no receipt exists" do
    assert {:error, %{code: "no_recorded_receipt", request_sent: false, retryable: true}} =
             WriteReceipts.execute_scope(
               "action_card:missing",
               "toolkit",
               "create",
               %{},
               fn -> flunk("recovery without receipt must not invoke upstream") end,
               recover_settled?: true
             )
  end

  test "MCP isError responses settle non-idempotent WriteReceipts as outcome_unknown" do
    mcp_error =
      {:ok, %{"isError" => true, "content" => [%{"type" => "text", "text" => "fail"}]}, %{}}

    assert ^mcp_error =
             WriteReceipts.execute_scope(
               "signal:mcp-is-error",
               "skill:s:srv",
               "write",
               %{},
               fn -> mcp_error end
             )

    assert Repo.get_by!(WriteReceipt, authority_scope: "signal:mcp-is-error").status ==
             "outcome_unknown"
  end
end
