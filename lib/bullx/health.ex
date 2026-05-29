defmodule BullX.Health do
  @moduledoc """
  Health probe semantics for BullX.

  Liveness is intentionally local to the node: if `/livez` can return, the
  Phoenix endpoint and BEAM process are alive. Readiness includes dependencies
  required to safely receive traffic.
  """

  alias BullX.Repo

  @postgres_query "SELECT 1"
  @postgres_timeout 1_000
  @redis_timeout 1_000

  @type check :: %{required(:status) => String.t(), optional(:error) => String.t()}
  @type report :: %{required(:status) => String.t(), required(:checks) => %{atom() => check()}}

  @spec live() :: report()
  def live do
    %{
      status: "ok",
      checks: %{
        beam: %{status: "ok"}
      }
    }
  end

  @spec ready(keyword()) :: {:ok, report()} | {:error, report()}
  def ready(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    redis = Keyword.get(opts, :redis, BullX.Redis)

    %{postgres: check_postgres(repo), redis: check_redis(redis)}
    |> readiness_report()
  end

  defp readiness_report(checks) do
    case checks_ok?(checks) do
      true -> {:ok, %{status: "ok", checks: checks}}
      false -> {:error, %{status: "error", checks: checks}}
    end
  end

  defp checks_ok?(checks) do
    Enum.all?(checks, fn
      {_name, %{status: "ok"}} -> true
      _failed -> false
    end)
  end

  defp check_postgres(repo) do
    case query_postgres(repo) do
      :ok -> %{status: "ok"}
      {:error, reason} -> %{status: "error", error: reason}
    end
  end

  defp query_postgres(repo) do
    case safe_postgres_query(repo) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp check_redis(redis) do
    case query_redis(redis) do
      :ok -> %{status: "ok"}
      {:error, reason} -> %{status: "error", error: reason}
    end
  end

  defp query_redis(redis) do
    case safe_redis_ping(redis) do
      {:ok, "PONG"} -> :ok
      {:ok, response} -> {:error, "unexpected Redis PING response: #{inspect(response)}"}
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp safe_postgres_query(repo) do
    Ecto.Adapters.SQL.query(repo, @postgres_query, [],
      timeout: @postgres_timeout,
      pool_timeout: @postgres_timeout
    )
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_redis_ping(redis) do
    redis.command(["PING"], timeout: @redis_timeout)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, reason}
  end
end
