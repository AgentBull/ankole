defmodule Ankole.Pod.Jobs.ExpireDocumentHistory do
  @moduledoc "Removes expired document snapshots, including those on idle Pages."
  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 3

  @impl Ankole.Job
  def run(%Oban.Job{}) do
    now = DateTime.utc_now(:microsecond)

    Ankole.Tenants.map_all(fn -> Ankole.Pod.Documents.History.expire(now) end)
    |> Ankole.Tenants.fanout_result()
  end
end
