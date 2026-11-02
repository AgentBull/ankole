defmodule Ankole.AIAgent.Library.StartupSync do
  @moduledoc "Reconciles organization templates and shipped Skill packages on control-plane startup."
  require Logger
  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.SkillPages

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  def start_link(_opts) do
    Task.start_link(fn ->
      case sync() do
        {:error, reason} ->
          Logger.error("Agent knowledge synchronization failed: #{inspect(reason)}")

        _ ->
          :ok
      end
    end)
  end

  def sync do
    with {:ok, sources} <- Library.shipped_skill_sources() do
      Ankole.Tenants.map_active(fn -> SkillPages.sync(sources) end)
      |> Ankole.Tenants.fanout_result()
    end
  end
end
