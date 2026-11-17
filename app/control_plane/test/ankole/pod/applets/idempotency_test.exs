defmodule Ankole.Pod.Applets.IdempotencyTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Pod.{Applets, Pages}

  test "releases claim on transient 4xx statuses (408, 409, 425, 429) and caches deterministic 2xx/4xx outcomes" do
    human = human_fixture().principal
    actor = actor_fixture(human.uid)

    {:ok, page} =
      Pages.create(actor, %{
        type: "applet",
        title: "Idempotency Transient Test",
        private_owner_uid: human.uid
      })

    request = %{
      "method" => "POST",
      "path" => "/submit",
      "query" => %{},
      "body" => %{"item" => "alpha"}
    }

    for transient_status <- [408, 409, 425, 429] do
      key = "idem-transient-#{transient_status}"

      assert {:ok, %{"status" => ^transient_status}} =
               Applets.Idempotency.execute_route(actor, page.id, request, key, fn ->
                 {:ok, %{"status" => transient_status, "body" => %{"error" => "try_again"}}}
               end)

      # Retrying the same key must re-run the handler instead of replaying the transient error
      assert {:ok,
              %{"status" => 200, "body" => %{"ok" => true, "recovered_from" => ^transient_status}}} =
               Applets.Idempotency.execute_route(actor, page.id, request, key, fn ->
                 {:ok,
                  %{
                    "status" => 200,
                    "body" => %{"ok" => true, "recovered_from" => transient_status}
                  }}
               end)

      # Subsequent retry now replays the cached 200 response
      assert {:ok,
              %{"status" => 200, "body" => %{"ok" => true, "recovered_from" => ^transient_status}}} =
               Applets.Idempotency.execute_route(actor, page.id, request, key, fn ->
                 flunk("handler should not re-run after 200 completion")
               end)
    end

    # Deterministic 422 response IS cached and replayed
    assert {:ok, %{"status" => 422, "body" => %{"error" => "invalid_amount"}}} =
             Applets.Idempotency.execute_route(actor, page.id, request, "idem-422", fn ->
               {:ok, %{"status" => 422, "body" => %{"error" => "invalid_amount"}}}
             end)

    assert {:ok, %{"status" => 422, "body" => %{"error" => "invalid_amount"}}} =
             Applets.Idempotency.execute_route(actor, page.id, request, "idem-422", fn ->
               flunk("deterministic 422 should be replayed without re-running handler")
             end)
  end

  test "Bandit.TransportError preserves in-flight lease and sdk_complete validates key and 64KiB payload" do
    human = human_fixture().principal
    actor = actor_fixture(human.uid)

    {:ok, page} =
      Pages.create(actor, %{
        type: "applet",
        title: "Idempotency Transport Test",
        private_owner_uid: human.uid
      })

    request = %{"method" => "POST", "path" => "/pay", "query" => %{}, "body" => %{"n" => 1}}

    assert_raise Bandit.TransportError, fn ->
      Applets.Idempotency.execute_route(actor, page.id, request, "idem-disconnect", fn ->
        raise Bandit.TransportError, error: :closed
      end)
    end

    # The interrupted mutation's lease remains active rather than being released on disconnect.
    assert {:error, :idempotency_request_in_progress} =
             Applets.Idempotency.execute_route(actor, page.id, request, "idem-disconnect", fn ->
               flunk("retry while interrupted mutation lease is active must be rejected")
             end)

    assert {:error, :invalid_request} =
             Applets.Idempotency.sdk_complete(
               page.id,
               human.uid,
               "   ",
               %{"ok" => true},
               60,
               "c1"
             )

    oversized = %{"blob" => String.duplicate("a", 70_000)}

    assert {:error, :invalid_request} =
             Applets.Idempotency.sdk_complete(page.id, human.uid, "k1", oversized, 60, "c1")
  end
end
