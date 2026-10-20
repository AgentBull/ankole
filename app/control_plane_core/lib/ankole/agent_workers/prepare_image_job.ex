defmodule Ankole.AgentWorkers.PrepareImageJob do
  @moduledoc "Prepares each provider's target image before an Agent needs it."

  use Ankole.Job,
    tenancy: :site,
    queue: :agent_workers,
    max_attempts: 20,
    unique: [
      keys: [:provider_id, :image, :settings_digest],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Ankole.Logging
  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.Providers

  def enqueue(provider) do
    args = %{
      provider_id: provider.provider_id,
      image: provider.runtime.image,
      settings_digest: provider.settings_digest
    }

    case args |> new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> log_error(provider.provider_id, reason)
    end
  end

  @impl true
  def run(%Oban.Job{args: %{"provider_id" => id}}) do
    with {:ok, provider} <- Providers.load(id),
         {:ok, kind} <- ProviderKind.fetch(provider.kind),
         :ok <- kind.prepare_image(provider, provider.runtime.image) do
      :ok
    else
      {:pending, _reason} ->
        {:snooze, 15}

      {:error, reason} = error ->
        log_error(id, reason)
        error
    end
  end

  defp log_error(id, reason) do
    Logging.warning("agent_workers.image_prepare_failed", "Worker image preparation failed", %{
      provider_id: id,
      reason: inspect(reason)
    })

    :ok
  end
end
