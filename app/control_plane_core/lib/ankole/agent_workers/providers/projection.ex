defmodule Ankole.AgentWorkers.Providers.Projection do
  @moduledoc """
  Calculates the operator fields of a Worker provider.

  `agent_count` counts the Worker rows of the provider in every tenant.
  `selectable` tells whether a new Agent can select the provider: its kind is
  known and the Plugin of the kind is enabled. `stored_credentials` gives the
  names of the stored credentials, never their values.
  """
  use Ash.Resource.Calculation

  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.Providers

  @impl true
  def init(opts) do
    if opts[:field] in [:agent_count, :selectable, :stored_credentials],
      do: {:ok, opts},
      else: {:error, "field must be :agent_count, :selectable, or :stored_credentials"}
  end

  @impl true
  def load(_query, opts, _context) do
    case opts[:field] do
      :agent_count -> [:provider_id]
      :selectable -> [:kind]
      :stored_credentials -> [:credentials]
    end
  end

  @impl true
  def calculate(providers, opts, _context), do: {:ok, calculate(providers, opts[:field])}

  defp calculate(providers, :agent_count),
    do: Enum.map(providers, &AgentWorkers.provider_worker_count(&1.provider_id))

  defp calculate(providers, :selectable) do
    selectable? = Providers.selectable_fun()
    Enum.map(providers, selectable?)
  end

  defp calculate(providers, :stored_credentials),
    do: Enum.map(providers, &(&1.credentials |> Map.keys() |> Enum.sort()))
end
