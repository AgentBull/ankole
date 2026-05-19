defmodule BullX.HealthTest do
  use BullX.DataCase, async: true

  alias BullX.Health

  defmodule MissingRepo do
  end

  defmodule OkRedis do
    def command(["PING"], _opts), do: {:ok, "PONG"}
  end

  defmodule FailingRedis do
    def command(["PING"], _opts), do: {:error, :closed}
  end

  test "live/0 does not include dependency checks" do
    assert %{status: "ok", checks: %{beam: %{status: "ok"}}} = Health.live()
  end

  test "ready/1 reports dependency failures" do
    assert {:error, %{status: "error", checks: %{postgres: postgres}}} =
             Health.ready(repo: MissingRepo, redis: OkRedis)

    assert %{status: "error", error: error} = postgres
    assert is_binary(error)
  end

  test "ready/1 includes Redis readiness" do
    assert {:ok, %{status: "ok", checks: %{postgres: %{status: "ok"}, redis: %{status: "ok"}}}} =
             Health.ready(repo: Repo, redis: OkRedis)

    assert {:error, %{status: "error", checks: %{redis: redis}}} =
             Health.ready(repo: Repo, redis: FailingRedis)

    assert redis == %{status: "error", error: ":closed"}
  end
end
