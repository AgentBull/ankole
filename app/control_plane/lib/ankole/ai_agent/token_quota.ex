defmodule Ankole.AIAgent.TokenQuota do
  @moduledoc """
  Agent-scoped token quota service.

  The configuration lives under `agents.options["ai_agent"]["token_quota"]`, next
  to `models` and `provider_hosted`. An Agent without that object has no limit.

  Periods tile the timeline from `period_start_at` in both directions, so a start
  time in the future is valid and the window before it counts the same way. The
  used tokens of a window are the `Ankole.AIGateway.UsageLedger` sum from the
  window start onwards. A reset writes `period_start_at = now`, which ends the
  current window at once and starts an empty one. No change touches the ledger.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.UsageLedger
  alias Ankole.Attrs
  alias Ankole.Principals
  alias Ankole.Principals.Agent
  alias Ankole.Repo

  @seconds_per_day 86_400

  @type quota :: %{String.t() => integer() | String.t()}
  @type window :: %{
          window_started_at: DateTime.t(),
          window_ends_at: DateTime.t(),
          used_tokens: non_neg_integer(),
          limit_tokens: pos_integer(),
          exceeded: boolean()
        }

  @doc """
  Reads the configuration and the current window of one Agent.

  Both are `nil` for an Agent without a limit.
  """
  @spec status(String.t()) ::
          {:ok, %{token_quota: quota() | nil, usage: window() | nil}} | {:error, term()}
  def status(agent_uid) do
    with {:ok, agent} <- fetch_agent(agent_uid) do
      {:ok, %{token_quota: quota_from_agent(agent), usage: window(agent, DateTime.utc_now())}}
    end
  end

  @doc """
  Validates and writes the token quota of one Agent.
  """
  @spec put(String.t(), map()) :: {:ok, quota()} | {:error, term()}
  def put(agent_uid, attrs) do
    Repo.transact(fn repo ->
      with %Agent{} = agent <- lock_agent(repo, agent_uid),
           {:ok, quota} <- normalize(attrs),
           {:ok, _agent} <- write_quota(repo, agent, quota) do
        {:ok, quota}
      else
        nil -> {:error, :agent_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Removes the token quota of one Agent, which leaves it without a limit.
  """
  @spec delete(String.t()) :: {:ok, nil} | {:error, term()}
  def delete(agent_uid) do
    Repo.transact(fn repo ->
      with %Agent{} = agent <- lock_agent(repo, agent_uid),
           {:ok, _agent} <- write_quota(repo, agent, nil) do
        {:ok, nil}
      else
        nil -> {:error, :agent_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Starts a new period at this instant.
  """
  @spec reset(String.t()) :: {:ok, quota()} | {:error, term()}
  def reset(agent_uid) do
    Repo.transact(fn repo ->
      case lock_agent(repo, agent_uid) do
        %Agent{} = agent -> reset_locked_agent(repo, agent)
        nil -> {:error, :agent_not_found}
      end
    end)
  end

  @doc """
  Returns whether the Agent may still send a model request.

  The limit is a soft limit: the check rejects a request only when the window is
  already at or above the limit, so one request can end above it.
  """
  @spec ensure_available(String.t()) :: :ok | {:error, {:agent_token_quota_exceeded, window()}}
  def ensure_available(agent_uid) do
    case fetch_agent(agent_uid) do
      {:ok, agent} ->
        case window(agent, DateTime.utc_now()) do
          %{exceeded: true} = window -> {:error, {:agent_token_quota_exceeded, window}}
          _available -> :ok
        end

      {:error, _no_such_agent} ->
        :ok
    end
  end

  defp reset_locked_agent(repo, %Agent{} = agent) do
    case quota_from_agent(agent) do
      %{} = quota ->
        quota = Map.put(quota, "period_start_at", DateTime.to_iso8601(DateTime.utc_now()))

        with {:ok, _agent} <- write_quota(repo, agent, quota), do: {:ok, quota}

      nil ->
        {:error, :token_quota_not_configured}
    end
  end

  defp window(%Agent{} = agent, %DateTime{} = now) do
    with %{} = quota <- quota_from_agent(agent),
         {:ok, period_start_at} <- parse_instant(Map.get(quota, "period_start_at")) do
      period_days = Map.fetch!(quota, "period_days")
      limit_tokens = Map.fetch!(quota, "limit_tokens")
      window_started_at = window_start(period_start_at, period_days, now)
      used_tokens = UsageLedger.window_tokens(agent.uid, window_started_at)

      %{
        window_started_at: window_started_at,
        window_ends_at: DateTime.add(window_started_at, period_days * @seconds_per_day, :second),
        used_tokens: used_tokens,
        limit_tokens: limit_tokens,
        exceeded: used_tokens >= limit_tokens
      }
    else
      _unlimited -> nil
    end
  end

  defp window_start(period_start_at, period_days, now) do
    period_seconds = period_days * @seconds_per_day
    elapsed = DateTime.diff(now, period_start_at, :microsecond)
    periods = Integer.floor_div(elapsed, period_seconds * 1_000_000)

    DateTime.add(period_start_at, periods * period_seconds, :second)
  end

  defp normalize(attrs) when is_map(attrs) do
    attrs = Attrs.normalize_external_attrs(attrs)

    with {:ok, period_days} <- positive_integer(attrs, "period_days", :invalid_period_days),
         {:ok, period_start_at} <- required_instant(attrs, "period_start_at"),
         {:ok, limit_tokens} <- positive_integer(attrs, "limit_tokens", :invalid_limit_tokens) do
      {:ok,
       %{
         "period_days" => period_days,
         "period_start_at" => DateTime.to_iso8601(period_start_at),
         "limit_tokens" => limit_tokens
       }}
    end
  end

  defp normalize(_attrs), do: {:error, :invalid_token_quota}

  defp positive_integer(attrs, key, error) do
    case Map.get(attrs, key) do
      value when is_integer(value) and value >= 1 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer >= 1 -> {:ok, integer}
          _value -> {:error, error}
        end

      _value ->
        {:error, error}
    end
  end

  defp required_instant(attrs, key) do
    case parse_instant(Map.get(attrs, key)) do
      {:ok, instant} -> {:ok, instant}
      :error -> {:error, :invalid_period_start_at}
    end
  end

  defp parse_instant(%DateTime{} = instant), do: {:ok, instant}

  defp parse_instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, instant, _offset} -> {:ok, instant}
      {:error, _reason} -> :error
    end
  end

  defp parse_instant(_value), do: :error

  defp fetch_agent(agent_uid) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      case Repo.get(Agent, agent_uid) do
        %Agent{} = agent -> {:ok, agent}
        nil -> {:error, :agent_not_found}
      end
    end
  end

  defp lock_agent(repo, agent_uid) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      Agent
      |> where([agent], agent.uid == ^agent_uid)
      |> lock("FOR UPDATE")
      |> repo.one()
    else
      {:error, _reason} -> nil
    end
  end

  defp write_quota(repo, %Agent{} = agent, quota) do
    agent
    |> Agent.changeset(%{options: put_quota_options(agent.options || %{}, quota)})
    |> repo.update()
  end

  defp put_quota_options(options, nil) do
    replace_ai_agent(options, &Map.delete(&1, "token_quota"))
  end

  defp put_quota_options(options, quota) do
    replace_ai_agent(options, &Map.put(&1, "token_quota", quota))
  end

  defp replace_ai_agent(options, fun) do
    ai_agent =
      case Map.get(options, "ai_agent") do
        value when is_map(value) -> value
        _value -> %{}
      end

    Map.put(options, "ai_agent", fun.(ai_agent))
  end

  defp quota_from_agent(%Agent{options: options}) when is_map(options) do
    case get_in(options, ["ai_agent", "token_quota"]) do
      %{"period_days" => period_days, "limit_tokens" => limit_tokens} = quota
      when is_integer(period_days) and is_integer(limit_tokens) ->
        quota

      _value ->
        nil
    end
  end

  defp quota_from_agent(%Agent{}), do: nil
end
