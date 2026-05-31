defmodule Discord.SourceRuntime do
  @moduledoc false

  use Supervisor

  alias Discord.{Channel, Source}

  @registry Discord.Registry

  @spec child_spec(Source.t()) :: Supervisor.child_spec()
  def child_spec(%Source{} = source) do
    %{
      id: child_id(source),
      start: {__MODULE__, :start_link, [source]},
      restart: :permanent,
      type: :supervisor
    }
  end

  @doc false
  @spec child_id(Source.t()) :: term()
  def child_id(%Source{id: id} = source) when is_binary(id),
    do: {__MODULE__, id, source_runtime_fingerprint(source)}

  @spec start_link(Source.t()) :: Supervisor.on_start()
  def start_link(%Source{} = source) do
    Supervisor.start_link(__MODULE__, source,
      name: {:via, Registry, {@registry, {:source_runtime, source.id}}}
    )
  end

  @impl true
  def init(%Source{} = source) do
    children =
      [Channel.child_spec(source)]
      |> maybe_add_bot(source)

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp maybe_add_bot(children, %Source{start_transport?: false}), do: children

  defp maybe_add_bot(children, %Source{nostrum_bot_module: module} = source) do
    case function_exported?(module, :child_spec, 1) do
      true -> children ++ [{module, Source.bot_options(source)}]
      false -> children
    end
  end

  defp source_runtime_fingerprint(%Source{} = source) do
    source
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
