defmodule Ankole.AIGateway.Jobs.CleanupExpiredArtifacts do
  @moduledoc """
  Idempotent hourly cleanup for expired artifacts, failed generated images,
  and media jobs whose retention has ended.
  """

  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 3

  alias Ankole.AIGateway.Artifacts

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) :: :ok
  def run(job), do: Ankole.Tenants.map_all(fn -> sweep(job) end) |> Ankole.Tenants.fanout_result()

  defp sweep(%Oban.Job{}) do
    _counts = Artifacts.cleanup_expired_and_failed()
    _count = Ankole.AIGateway.MediaJobs.cleanup_expired()
    :ok
  end
end
