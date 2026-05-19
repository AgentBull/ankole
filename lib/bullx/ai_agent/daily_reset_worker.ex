defmodule BullX.AIAgent.DailyResetWorker do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias BullX.AIAgent.{DailyReset, Profile}
  alias BullX.Principals.Agent
  alias BullX.Repo

  @interval_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    now = DateTime.utc_now(:microsecond)

    Agent
    |> join(:inner, [a], p in assoc(a, :principal))
    |> where([_a, p], p.status == :active)
    |> select([a, p], {p.id, a.profile})
    |> Repo.all()
    |> Enum.each(fn {principal_id, raw_profile} ->
      with {:ok, profile} <- Profile.cast(raw_profile),
           true <- profile.daily_reset.enabled do
        DailyReset.close_eligible(profile, now, principal_id)
      end
    end)

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :poll, @interval_ms)
end
