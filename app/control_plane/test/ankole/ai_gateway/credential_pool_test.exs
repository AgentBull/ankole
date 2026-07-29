defmodule Ankole.AIGateway.CredentialPoolTest do
  use ExUnit.Case, async: false

  alias Ankole.AIGateway.CredentialPool

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok
  end

  test "fill-first, round-robin, least-used, and random select only usable entries" do
    entries = entries()

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("fill", entries, "fill_first")

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("fill", entries, "fill_first")

    assert Enum.map(1..4, fn _ ->
             {:ok, selection} = CredentialPool.select("round-robin", entries, "round_robin")
             selection.credential_id
           end) == ~w(first second third first)

    assert Enum.map(1..4, fn _ ->
             {:ok, selection} = CredentialPool.select("least-used", entries, "least_used")
             selection.credential_id
           end) == ~w(first second third first)

    random_ids =
      Enum.map(1..30, fn _ ->
        {:ok, selection} = CredentialPool.select("random", entries, "random")
        selection.credential_id
      end)

    assert Enum.all?(random_ids, &(&1 in ~w(first second third)))

    :ok = CredentialPool.mark_dead("random-single", "first")
    :ok = CredentialPool.mark_dead("random-single", "second")

    assert {:ok, %{credential_id: "third"}} =
             CredentialPool.select("random-single", entries, "random")
  end

  test "thread affinity wins over strategy until its credential becomes unavailable" do
    entries = entries()

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("affinity", entries, "round_robin", affinity_key: "thread-1")

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("affinity", entries, "round_robin", affinity_key: "thread-1")

    :ok =
      CredentialPool.mark_exhausted(
        "affinity",
        "first",
        429,
        %{"x-codex-primary-reset-at" => DateTime.utc_now() |> DateTime.add(600) |> unix()}
      )

    assert {:ok, %{credential_id: "second"}} =
             CredentialPool.select("affinity", entries, "round_robin", affinity_key: "thread-1")

    assert {:ok, %{credential_id: "second"}} =
             CredentialPool.select("affinity", entries, "round_robin", affinity_key: "thread-1")
  end

  test "upstream reset time controls cooldown and expired entries return automatically" do
    entries = [hd(entries())]
    retry_at = DateTime.utc_now(:second) |> DateTime.add(900)

    :ok =
      CredentialPool.mark_exhausted(
        "cooldown",
        "first",
        429,
        %{"x-codex-primary-reset-at" => unix(retry_at)},
        %{"code" => "rate_limit", "reason" => "quota", "message" => "wait"}
      )

    assert {:error, {:credential_pool_exhausted, details}} =
             CredentialPool.select("cooldown", entries, "fill_first")

    assert_iso_equal(details["retry_at"], retry_at)

    assert %{
             "first" => %{
               "status" => "exhausted",
               "retry_at" => retry_at_text,
               "last_error_code" => "rate_limit",
               "last_error_reason" => "quota",
               "last_error_message" => "wait",
               "provider_status" => 429
             }
           } = CredentialPool.statuses("cooldown", entries)

    assert_iso_equal(retry_at_text, retry_at)

    :ok =
      CredentialPool.mark_exhausted(
        "cooldown",
        "first",
        429,
        %{"x-codex-primary-reset-at" => DateTime.utc_now() |> DateTime.add(-1) |> unix()}
      )

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("cooldown", entries, "fill_first")
  end

  test "dead and disabled entries stay out until explicit reauthentication" do
    [first, second, third] = entries()
    disabled = Map.put(third, "disabled_at", DateTime.utc_now() |> DateTime.to_iso8601())

    :ok = CredentialPool.mark_dead("health", "first", %{"code" => "token_revoked"})

    assert {:ok, %{credential_id: "second"}} =
             CredentialPool.select("health", [first, second, disabled], "fill_first")

    assert %{
             "first" => %{"status" => "dead"},
             "third" => %{"status" => "disabled"}
           } = CredentialPool.statuses("health", [first, second, disabled])

    :ok = CredentialPool.mark_ok("health", "first")

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("health", [first, second, disabled], "fill_first")
  end

  test "persisted reauthentication requirements survive runtime health reset" do
    [first, second | _rest] = entries()
    persisted_dead = Map.put(first, "reauth_required", true)

    :ok = CredentialPool.mark_ok("persisted-dead", "first")

    assert {:ok, %{credential_id: "second", available_count: 1}} =
             CredentialPool.select(
               "persisted-dead",
               [persisted_dead, second],
               "fill_first"
             )

    assert %{"first" => %{"status" => "dead", "reauth_required" => true}} =
             CredentialPool.statuses("persisted-dead", [persisted_dead, second])
  end

  test "concurrent round-robin selection remains atomic and balanced" do
    selections =
      1..60
      |> Enum.map(fn _index ->
        Task.async(fn ->
          {:ok, selection} =
            CredentialPool.select("concurrent-selection", entries(), "round_robin")

          selection.credential_id
        end)
      end)
      |> Task.await_many(5_000)
      |> Enum.frequencies()

    assert selections == %{"first" => 20, "second" => 20, "third" => 20}
  end

  test "pool exhaustion reports the earliest recovery and exclusion never changes health" do
    [first, second | _rest] = entries()
    later = DateTime.utc_now(:second) |> DateTime.add(1_200)
    earlier = DateTime.utc_now(:second) |> DateTime.add(600)

    :ok =
      CredentialPool.mark_exhausted(
        "earliest",
        "first",
        429,
        %{"x-codex-primary-reset-at" => unix(later)}
      )

    :ok =
      CredentialPool.mark_exhausted(
        "earliest",
        "second",
        429,
        %{"x-codex-primary-reset-at" => unix(earlier)}
      )

    assert {:error, {:credential_pool_exhausted, %{"retry_at" => retry_at}}} =
             CredentialPool.select("earliest", [first, second], "fill_first")

    assert_iso_equal(retry_at, earlier)

    :ok = CredentialPool.mark_ok("earliest", "first")

    assert {:error, {:credential_pool_exhausted, _details}} =
             CredentialPool.select("earliest", [first, second], "fill_first", exclude: ["first"])

    assert %{"first" => %{"status" => "ok"}} =
             CredentialPool.statuses("earliest", [first, second])
  end

  test "removed credentials do not supply a recovery time for the current pool" do
    [first | _rest] = entries()
    retry_at = DateTime.utc_now(:second) |> DateTime.add(600)

    :ok =
      CredentialPool.mark_exhausted(
        "removed-entry",
        "removed",
        429,
        %{"x-codex-primary-reset-at" => unix(retry_at)}
      )

    assert {:error, {:credential_pool_exhausted, details}} =
             CredentialPool.select(
               "removed-entry",
               [Map.put(first, "reauth_required", true)],
               "fill_first"
             )

    assert details["retry_at"] == nil

    assert %{"first" => %{"status" => "dead", "reauth_required" => true}} =
             details["statuses"]
  end

  test "successful headers and token usage stay attributed to one credential" do
    entries = [hd(entries())]

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("usage", entries, "fill_first")

    :ok =
      CredentialPool.mark_ok("usage", "first", [
        {"x-codex-primary-used-percent", "25"},
        {"X-Codex-Primary-Window-Minutes", "300"},
        {"set-cookie", "must-not-leak"}
      ])

    :ok =
      CredentialPool.record_usage(
        "usage",
        "first",
        %{
          "input_tokens" => 10,
          "output_tokens" => 2,
          "input_tokens_details" => %{"cached_tokens" => 3},
          "service_tier" => "priority"
        },
        %{"image_gen" => %{"input_tokens" => 4, "output_tokens" => 1}}
      )

    :ok =
      CredentialPool.record_usage(
        "usage",
        "first",
        %{"input_tokens" => 5, "output_tokens" => 1},
        %{"image_gen" => %{"input_tokens" => 2}}
      )

    assert %{
             "first" => %{
               "rate_limits" => %{
                 "x-codex-primary-used-percent" => "25",
                 "x-codex-primary-window-minutes" => "300"
               },
               "usage" => %{
                 "model" => %{
                   "input_tokens" => 15,
                   "output_tokens" => 3,
                   "input_tokens_details" => %{"cached_tokens" => 3}
                 },
                 "image_gen" => %{"input_tokens" => 6, "output_tokens" => 1}
               }
             }
           } = CredentialPool.statuses("usage", entries)

    refute Map.has_key?(
             CredentialPool.statuses("usage", entries)["first"]["rate_limits"],
             "set-cookie"
           )
  end

  test "a later success observation does not erase an active cooldown" do
    entries = [hd(entries())]
    retry_at = DateTime.utc_now(:second) |> DateTime.add(600)

    :ok =
      CredentialPool.mark_exhausted(
        "concurrent-health",
        "first",
        429,
        %{"x-codex-primary-reset-at" => unix(retry_at)}
      )

    :ok =
      CredentialPool.observe_success(
        "concurrent-health",
        "first",
        %{"x-codex-primary-used-percent" => "80"}
      )

    assert %{
             "first" => %{
               "status" => "exhausted",
               "rate_limits" => %{"x-codex-primary-used-percent" => "80"}
             }
           } = CredentialPool.statuses("concurrent-health", entries)
  end

  defp entries do
    [
      %{"id" => "first", "label" => "First", "priority" => 0, "disabled_at" => nil},
      %{"id" => "second", "label" => "Second", "priority" => 1, "disabled_at" => nil},
      %{"id" => "third", "label" => "Third", "priority" => 2, "disabled_at" => nil}
    ]
  end

  defp unix(%DateTime{} = datetime), do: DateTime.to_unix(datetime)

  defp assert_iso_equal(value, %DateTime{} = expected) do
    assert {:ok, actual, _offset} = DateTime.from_iso8601(value)
    assert DateTime.compare(actual, expected) == :eq
  end
end
