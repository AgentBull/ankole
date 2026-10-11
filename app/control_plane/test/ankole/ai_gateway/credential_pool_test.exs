defmodule Ankole.AIGateway.CredentialPoolTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIGateway.{CredentialPool, ProviderConfigs}
  alias Ankole.AIGateway.ProviderConfigs.Provider

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok
  end

  test "rate limits use a short fallback unless the provider explicitly rejects quota" do
    for error <- [%{}, %{"code" => "RequestBurstTooFast"}, %{"code" => "rate_limit_exceeded"}] do
      assert CredentialPool.cooldown_ms(429, [], error) == 1_000
    end

    for error <- [%{"code" => "insufficient_quota"}, %{"type" => "usage_limit_reached"}] do
      assert CredentialPool.cooldown_ms(429, [], error) == 3_600_000
      assert CredentialPool.cooldown_ms(429, [{"Retry-After", "2"}], error) == 2_000
    end

    assert CredentialPool.cooldown_ms(401, [], %{}) == 300_000
  end

  test "Retry-After accepts delay seconds and HTTP dates across native header shapes" do
    for headers <- [
          %{"Retry-After" => "2"},
          [{"retry-after", "2"}],
          [["RETRY-AFTER", "2"]],
          %{"retry-after" => ["2"]}
        ] do
      assert CredentialPool.cooldown_ms(429, headers, %{}) == 2_000
    end

    future = DateTime.utc_now(:second) |> DateTime.add(30)
    headers = %{"retry-after" => Req.Utils.format_http_date(future)}
    assert CredentialPool.cooldown_ms(429, headers, %{}) in 28_000..30_000

    for value <- ["-2", "garbage", "1.5", "999999999999999999999999999"] do
      assert CredentialPool.cooldown_ms(429, %{"retry-after" => value}, %{}) == 1_000
    end

    assert CredentialPool.cooldown_ms(429, %{"retry-after" => "0"}, %{}) == 0

    assert CredentialPool.cooldown_ms(
             429,
             %{"retry-after" => "Sun, 06 Nov 1994 08:49:37 GMT"},
             %{}
           ) == 0

    assert CredentialPool.cooldown_ms(
             429,
             %{"retry-after" => "60", "x-codex-primary-reset-at" => unix(future)},
             %{}
           ) == 60_000
  end

  test "fill-first, round-robin, least-used, and random select only usable entries" do
    entries = entries()
    [first, second | _rest] = entries

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

    unavailable = [
      Map.put(first, "reauth_required", true),
      Map.put(second, "disabled_at", DateTime.to_iso8601(DateTime.utc_now())),
      List.last(entries)
    ]

    assert {:ok, %{credential_id: "third"}} =
             CredentialPool.select("random-single", unavailable, "random")
  end

  test "each provider retains only its 10,000 most recently used affinity keys" do
    [first, second | _rest] = entries()
    entries = [first, second]
    prefer_second = [first, Map.put(second, "priority", -1)]

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("other-provider", entries, "fill_first",
               affinity_key: "thread-2"
             )

    for index <- 1..10_000 do
      assert {:ok, %{credential_id: "first"}} =
               CredentialPool.select("lru", entries, "fill_first",
                 affinity_key: "thread-#{index}"
               )
    end

    assert_affinity_count("lru", 10_000)

    for _ <- 1..10_001 do
      assert {:ok, %{credential_id: "first"}} =
               CredentialPool.select("lru", prefer_second, "fill_first", affinity_key: "thread-1")
    end

    assert_affinity_count("lru", 10_000)

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("lru", entries, "fill_first", affinity_key: "thread-10001")

    assert_affinity_count("lru", 10_000)

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("lru", prefer_second, "fill_first", affinity_key: "thread-1")

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("other-provider", prefer_second, "fill_first",
               affinity_key: "thread-2"
             )

    assert {:ok, %{credential_id: "second"}} =
             CredentialPool.select("lru", prefer_second, "fill_first", affinity_key: "thread-2")

    assert_affinity_count("lru", 10_000)
    assert_affinity_count("other-provider", 1)
  end

  test "persisted reauthentication requirements survive runtime health reset" do
    [first, second | _rest] = entries()
    persisted_dead = Map.put(first, "reauth_required", true)

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

  test "successful headers and token usage stay attributed to one credential" do
    first = hd(entries())
    entries = [first]

    assert {:ok, %{credential_id: "first"}} =
             CredentialPool.select("usage", entries, "fill_first")

    :ok =
      CredentialPool.observe_success("usage", first, [
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

  test "an expired failure retains affinity until another selection replaces it" do
    provider = provider_fixture()
    first = hd(stored_entries(provider))

    assert {:ok, %{credential_id: id}} =
             CredentialPool.select(provider.id, stored_entries(provider), "fill_first",
               affinity_key: "recovering-thread"
             )

    assert id == first["id"]
    :ok = CredentialPool.mark_exhausted(provider.id, first, 429, %{"retry-after" => "0"})

    assert {:ok, _} =
             ProviderConfigs.update_credential(provider.provider_id, first["id"], %{
               "priority" => 10
             })

    assert {:ok, %{credential_id: ^id}} =
             CredentialPool.select(provider.id, stored_entries(provider), "fill_first",
               affinity_key: "recovering-thread"
             )
  end

  test "an absolute recovery header persists its exact instant" do
    provider = provider_fixture()
    first = hd(stored_entries(provider))
    recovery = DateTime.utc_now(:second) |> DateTime.add(300)

    for _ <- 1..20 do
      :ok =
        CredentialPool.mark_exhausted(provider.id, first, 429, %{
          "x-codex-primary-reset-at" => unix(recovery)
        })

      until = hd(stored_entries(provider))["cooldown_until"]
      assert {:ok, actual, _} = DateTime.from_iso8601(until)
      assert DateTime.compare(actual, recovery) == :eq
    end
  end

  test "a rate-limited failure records its x-codex headers" do
    provider = provider_fixture()
    first = hd(stored_entries(provider))

    :ok =
      CredentialPool.mark_exhausted(provider.id, first, 429, %{
        "x-codex-primary-used-percent" => "100",
        "retry-after" => "60"
      })

    assert CredentialPool.statuses(provider.id, stored_entries(provider))[first["id"]][
             "rate_limits"
           ] ==
             %{"x-codex-primary-used-percent" => "100"}
  end

  test "a cooldown survives selection-process replacement and controls affinity" do
    provider = provider_fixture()
    [first, second] = stored_entries(provider)

    assert {:ok, %{credential_id: id}} =
             CredentialPool.select(provider.id, stored_entries(provider), "round_robin",
               affinity_key: "thread"
             )

    assert id == first["id"]
    retry_at = DateTime.utc_now(:second) |> DateTime.add(600)

    :ok =
      CredentialPool.mark_exhausted(
        provider.id,
        first,
        429,
        %{"x-codex-primary-reset-at" => unix(retry_at)},
        %{"code" => "rate_limit", "message" => "wait"}
      )

    assert {:ok, %{credential_id: id}} =
             CredentialPool.select(provider.id, stored_entries(provider), "round_robin",
               affinity_key: "thread"
             )

    assert id == second["id"]
    :ok = Supervisor.terminate_child(Ankole.Supervisor, CredentialPool)
    assert {:ok, _pid} = Supervisor.restart_child(Ankole.Supervisor, CredentialPool)

    assert {:ok, %{credential_id: id}} =
             CredentialPool.select(provider.id, stored_entries(provider), "fill_first")

    assert id == second["id"]
    status = CredentialPool.statuses(provider.id, stored_entries(provider))[first["id"]]
    assert status["status"] == "exhausted"
    assert status["last_error_code"] == "rate_limit"
    assert_iso_equal(status["retry_at"], retry_at)
  end

  test "a shorter failure and a later success cannot clear the stored cooldown" do
    provider = provider_fixture()
    first = hd(stored_entries(provider))
    :ok = CredentialPool.mark_exhausted(provider.id, first, 429, %{"retry-after" => "60"})
    before = hd(stored_entries(provider))
    :ok = CredentialPool.mark_exhausted(provider.id, first, 429, %{"retry-after" => "0"})

    :ok =
      CredentialPool.observe_success(provider.id, first, %{"x-codex-primary-used-percent" => "80"})

    assert hd(stored_entries(provider))["cooldown_until"] == before["cooldown_until"]

    assert CredentialPool.statuses(provider.id, stored_entries(provider))[first["id"]]["status"] ==
             "exhausted"
  end

  test "credential replacement clears cooldown and rejects late failures from the old revision" do
    provider = provider_fixture()
    first = hd(stored_entries(provider))
    :ok = CredentialPool.mark_dead(provider.id, first, %{"code" => "revoked"})

    assert {:ok, _} =
             ProviderConfigs.update_credential(provider.provider_id, first["id"], %{
               "api_key" => "sk-new"
             })

    replacement = hd(stored_entries(provider))
    assert replacement["health_revision"] != first["health_revision"]
    refute replacement["cooldown_until"]

    assert {:ok, %{credential_id: id}} =
             CredentialPool.select(provider.id, stored_entries(provider), "fill_first",
               affinity_key: "thread"
             )

    assert id == first["id"]
    :ok = CredentialPool.mark_dead(provider.id, first, %{"code" => "late_old_failure"})

    :ok =
      CredentialPool.observe_success(provider.id, first, %{"x-codex-primary-used-percent" => "90"})

    assert hd(stored_entries(provider)) == replacement

    assert {:ok, %{credential_id: ^id}} =
             CredentialPool.select(
               provider.id,
               Enum.reverse(stored_entries(provider)),
               "round_robin",
               affinity_key: "thread"
             )

    assert CredentialPool.statuses(provider.id, stored_entries(provider))[id]["rate_limits"] ==
             %{}
  end

  test "metadata updates preserve cooldown and expired deadlines become selectable" do
    provider = provider_fixture()
    first = hd(stored_entries(provider))
    :ok = CredentialPool.mark_exhausted(provider.id, first, 429, %{"retry-after" => "60"})
    before = hd(stored_entries(provider))

    assert {:ok, _} =
             ProviderConfigs.update_credential(provider.provider_id, first["id"], %{
               "label" => "Renamed"
             })

    assert hd(stored_entries(provider))["cooldown_until"] == before["cooldown_until"]
    second = List.last(stored_entries(provider))
    :ok = CredentialPool.mark_exhausted(provider.id, second, 429, %{"retry-after" => "0"})

    assert {:ok, %{credential_id: id}} =
             CredentialPool.select(provider.id, stored_entries(provider), "fill_first")

    assert id == second["id"]
  end

  test "pool exhaustion reports the earliest current cooldown and ignores removed credentials" do
    provider = provider_fixture()
    [first, second] = stored_entries(provider)
    later = DateTime.utc_now(:second) |> DateTime.add(1200)
    earlier = DateTime.utc_now(:second) |> DateTime.add(600)

    :ok =
      CredentialPool.mark_exhausted(provider.id, first, 429, %{
        "x-codex-primary-reset-at" => unix(later)
      })

    :ok =
      CredentialPool.mark_exhausted(provider.id, second, 429, %{
        "x-codex-primary-reset-at" => unix(earlier)
      })

    assert {:error, {:credential_pool_exhausted, details}} =
             CredentialPool.select(provider.id, stored_entries(provider), "fill_first")

    assert_iso_equal(details["retry_at"], earlier)
    assert {:ok, _} = ProviderConfigs.delete_credential(provider.provider_id, second["id"])
    :ok = CredentialPool.mark_exhausted(provider.id, second, 429, %{"retry-after" => "3600"})

    assert {:error, {:credential_pool_exhausted, details}} =
             CredentialPool.select(provider.id, stored_entries(provider), "fill_first")

    assert_iso_equal(details["retry_at"], later)
    assert Map.keys(details["statuses"]) == [first["id"]]
  end

  defp provider_fixture do
    {:ok, provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "cooldown-#{System.unique_integer([:positive])}",
        provider_kind: "openai",
        credential_pool: %{
          "entries" => [
            %{"label" => "First", "api_key" => "sk-first", "priority" => 0},
            %{"label" => "Second", "api_key" => "sk-second", "priority" => 1}
          ]
        }
      })

    provider
  end

  defp stored_entries(provider), do: Repo.get!(Provider, provider.id).credential_pool["entries"]

  defp assert_affinity_count(provider, count) do
    state = :sys.get_state(CredentialPool)[provider]
    assert map_size(state.affinity) == count
    assert :gb_trees.size(state.affinity_lru) == count
  end

  defp entries do
    [
      %{
        "id" => "first",
        "label" => "First",
        "priority" => 0,
        "disabled_at" => nil,
        "health_revision" => "first-revision"
      },
      %{
        "id" => "second",
        "label" => "Second",
        "priority" => 1,
        "disabled_at" => nil,
        "health_revision" => "second-revision"
      },
      %{
        "id" => "third",
        "label" => "Third",
        "priority" => 2,
        "disabled_at" => nil,
        "health_revision" => "third-revision"
      }
    ]
  end

  defp unix(%DateTime{} = datetime), do: DateTime.to_unix(datetime)

  defp assert_iso_equal(value, %DateTime{} = expected) do
    assert {:ok, actual, _offset} = DateTime.from_iso8601(value)
    assert DateTime.compare(actual, expected) == :eq
  end
end
