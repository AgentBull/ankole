defmodule BullX.Redis do
  @moduledoc false

  alias BullX.Config.CacheSettings

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(_opts) do
    case redix_options() do
      {:ok, opts} -> Redix.start_link(Keyword.put(opts, :name, __MODULE__))
      {:error, _reason} -> :ignore
    end
  end

  @spec redix_options() :: {:ok, keyword()} | {:error, term()}
  def redix_options do
    with {:ok, url} <- CacheSettings.redis_url(),
         {:ok, {host, port}} <- parse_redis_url(url) do
      {:ok, [host: host, port: port, sync_connect: false]}
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

  defp parse_redis_url(url) do
    uri = URI.parse(url)

    case {uri.scheme, uri.host, uri.port} do
      {"redis", host, port} when is_binary(host) -> {:ok, {host, port || 6379}}
      _other -> {:error, :invalid_redis_url}
    end
  end
end
