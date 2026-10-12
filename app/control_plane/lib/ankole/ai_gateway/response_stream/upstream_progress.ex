defmodule Ankole.AIGateway.ResponseStream.UpstreamProgress do
  @moduledoc """
  Builds `metadata.upstream_progress` for one stream owner. `attempt` counts
  native opens, and each open starts a new timeline.
  """

  @type t :: %{required(String.t()) => term()}

  @spec new() :: t()
  def new, do: %{"attempt" => 0, "event_count" => 0}

  @spec dispatched(t()) :: t()
  def dispatched(%{"attempt" => attempt}),
    do: %{"attempt" => attempt + 1, "event_count" => 0, "dispatched_at" => now()}

  @spec ready(t(), term()) :: t()
  def ready(progress, status),
    do: progress |> Map.put("ready_at", now()) |> Map.put("ready_status", status)

  @spec event(t()) :: t()
  def event(progress) do
    at = now()

    progress
    |> Map.put_new("first_event_at", at)
    |> Map.put("last_event_at", at)
    |> Map.update!("event_count", &(&1 + 1))
  end

  defp now, do: DateTime.to_iso8601(DateTime.utc_now(:microsecond))
end
