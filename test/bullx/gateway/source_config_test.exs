defmodule BullX.Gateway.SourceConfigTest do
  use ExUnit.Case, async: true

  alias BullX.Gateway.SourceConfig

  test "connectivity freshness is scoped to the current source fingerprint" do
    source = %SourceConfig{
      adapter: "feishu",
      channel_id: "main",
      enabled?: true,
      config: %{"domain" => "feishu"},
      outbound_retry: %{"max_attempts" => 3}
    }

    checked_at = DateTime.utc_now() |> DateTime.to_iso8601()

    connected = %{
      source
      | connectivity: %{
          "status" => "ok",
          "fingerprint" => SourceConfig.fingerprint(source),
          "checked_at" => checked_at
        }
    }

    stale = %{connected | config: %{"domain" => "lark"}}

    assert SourceConfig.connectivity_fresh?(connected)
    refute SourceConfig.connectivity_fresh?(stale)
  end

  test "connectivity max_age_seconds bounds checked_at freshness" do
    now = ~U[2026-05-13 00:00:00Z]

    source = %SourceConfig{
      adapter: "feishu",
      channel_id: "main",
      enabled?: true,
      connectivity: %{}
    }

    source = %{
      source
      | connectivity: %{
          "status" => "ok",
          "fingerprint" => SourceConfig.fingerprint(source),
          "checked_at" => "2026-05-12T23:59:00Z",
          "max_age_seconds" => 30
        }
    }

    refute SourceConfig.connectivity_fresh?(source, now)
  end
end
