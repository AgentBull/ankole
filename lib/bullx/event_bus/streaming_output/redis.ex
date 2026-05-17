defmodule BullX.EventBus.StreamingOutput.Redis do
  @moduledoc false

  alias BullX.EventBus.Config

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(_opts) do
    case Config.redix_options() do
      {:ok, opts} -> Redix.start_link(Keyword.put(opts, :name, __MODULE__))
      {:error, _reason} -> :ignore
    end
  end

  @spec command([term()], keyword()) :: {:ok, term()} | {:error, term()}
  def command(command, opts \\ []) when is_list(command) do
    Redix.command(__MODULE__, command, opts)
  catch
    :exit, reason -> {:error, reason}
  end

  @spec pipeline([[term()]], keyword()) :: {:ok, [term()]} | {:error, term()}
  def pipeline(commands, opts \\ []) when is_list(commands) do
    Redix.pipeline(__MODULE__, commands, opts)
  catch
    :exit, reason -> {:error, reason}
  end
end
