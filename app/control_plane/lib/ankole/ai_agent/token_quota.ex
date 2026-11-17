defmodule Ankole.AIAgent.TokenQuota do
  @moduledoc """
  Agent and Service Account token quota service.

  The configuration lives under `options["ai_agent"]["token_quota"]` on `Agent`
  and `ServiceAccount` rows. A subject without that object has no limit.

  Periods tile the timeline from `period_start_at` in both directions, so a start
  time in the future is valid and the window before it counts the same way. The
  used tokens of a window are the `Ankole.AIGateway.UsageLedger` sum from the
  window start onwards. A reset writes `period_start_at = now`, which ends the
  current window at once and starts an empty one. No change touches the ledger.
  """

  alias Ankole.AIGateway.UsageLedger
  alias Ankole.Attrs
  alias Ankole.Principals
  alias Ankole.Principals.{Agent, ServiceAccount, ServiceAccounts}
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

  defp spec(:agent) do
    %{
      not_found: :agent_not_found,
      exceeded_tag: :agent_token_quota_exceeded,
      fetch: &__MODULE__.fetch_agent/1,
      lock: &Principals.lock_agent_in_tx/1,
      write: &__MODULE__.write_agent_quota/2,
      ledger_tokens: &UsageLedger.window_tokens/2
    }
  end

  defp spec(:service) do
    %{
      not_found: :service_account_not_found,
      exceeded_tag: :service_token_quota_exceeded,
      fetch: &ServiceAccounts.fetch/1,
      lock: &ServiceAccounts.lock_in_tx/1,
      write: &__MODULE__.write_service_quota/2,
      ledger_tokens: &UsageLedger.service_window_tokens/2
    }
  end

  @doc """
  Reads the configuration and the current window of one Agent.

  Both are `nil` for an Agent without a limit.
  """
  @spec status(String.t()) ::
          {:ok, %{token_quota: quota() | nil, usage: window() | nil}} | {:error, term()}
  def status(agent_uid), do: subject_status(spec(:agent), agent_uid)

  @doc """
  Validates and writes the token quota of one Agent.
  """
  @spec put(String.t(), map()) :: {:ok, quota()} | {:error, term()}
  def put(agent_uid, attrs), do: run_subject(spec(:agent), agent_uid, &put_in_tx(&1, attrs))

  @doc """
  Removes the token quota of one Agent, which leaves it without a limit.
  """
  @spec delete(String.t()) :: {:ok, nil} | {:error, term()}
  def delete(agent_uid),
    do: run_subject(spec(:agent), agent_uid, &delete_subject_in_tx(spec(:agent), &1))

  @doc """
  Starts a new period at this instant.
  """
  @spec reset(String.t()) :: {:ok, quota()} | {:error, term()}
  def reset(agent_uid),
    do: run_subject(spec(:agent), agent_uid, &reset_subject_in_tx(spec(:agent), &1))

  @doc false
  def put_in_tx(agent_uid, attrs) do
    :ok = Repo.require_transaction()
    put_subject_in_tx(spec(:agent), agent_uid, attrs)
  end

  @doc """
  Returns whether the Agent may still send a model request.

  The limit is a soft limit: the check rejects a request only when the window is
  already at or above the limit, so one request can end above it.
  """
  @spec ensure_available(String.t()) :: :ok | {:error, {:agent_token_quota_exceeded, window()}}
  def ensure_available(agent_uid), do: ensure_subject_available(spec(:agent), agent_uid)

  @doc """
  Reads the configuration and the current window of one Service Account.
  """
  @spec service_status(String.t()) ::
          {:ok, %{token_quota: quota() | nil, usage: window() | nil}} | {:error, term()}
  def service_status(service_uid), do: subject_status(spec(:service), service_uid)

  @spec put_service(String.t(), map()) :: {:ok, quota()} | {:error, term()}
  def put_service(service_uid, attrs),
    do: run_subject(spec(:service), service_uid, &put_subject_in_tx(spec(:service), &1, attrs))

  @spec delete_service(String.t()) :: {:ok, nil} | {:error, term()}
  def delete_service(service_uid),
    do: run_subject(spec(:service), service_uid, &delete_subject_in_tx(spec(:service), &1))

  @spec reset_service(String.t()) :: {:ok, quota()} | {:error, term()}
  def reset_service(service_uid),
    do: run_subject(spec(:service), service_uid, &reset_subject_in_tx(spec(:service), &1))

  @spec ensure_service_available(String.t()) ::
          :ok | {:error, {:service_token_quota_exceeded, window()}}
  def ensure_service_available(service_uid),
    do: ensure_subject_available(spec(:service), service_uid)

  defp subject_status(spec, uid) do
    with {:ok, record} <- spec.fetch.(uid) do
      {:ok,
       %{
         token_quota: stored_quota(record),
         usage: subject_window(spec, record, DateTime.utc_now())
       }}
    end
  end

  defp ensure_subject_available(spec, uid) do
    case spec.fetch.(uid) do
      {:ok, record} ->
        case subject_window(spec, record, DateTime.utc_now()) do
          %{exceeded: true} = win -> {:error, {spec.exceeded_tag, win}}
          _available -> :ok
        end

      {:error, _missing} ->
        :ok
    end
  end

  defp run_subject(spec, uid, fun) do
    case Principals.normalize_uid(uid) do
      {:ok, normalized} -> Repo.transact_top_level(fn -> fun.(normalized) end)
      {:error, _reason} -> {:error, spec.not_found}
    end
  end

  defp put_subject_in_tx(spec, uid, attrs) do
    with record when not is_nil(record) <- spec.lock.(uid),
         {:ok, quota} <- normalize(attrs, stored_quota(record)),
         {:ok, _updated} <- spec.write.(record, quota) do
      {:ok, quota}
    else
      nil -> {:error, spec.not_found}
      {:error, _reason} = error -> error
    end
  end

  defp delete_subject_in_tx(spec, uid) do
    with record when not is_nil(record) <- spec.lock.(uid),
         {:ok, _updated} <- spec.write.(record, nil) do
      {:ok, nil}
    else
      nil -> {:error, spec.not_found}
      {:error, _reason} = error -> error
    end
  end

  defp reset_subject_in_tx(spec, uid) do
    case spec.lock.(uid) do
      nil ->
        {:error, spec.not_found}

      record ->
        case stored_quota(record) do
          %{} = quota ->
            quota = Map.put(quota, "period_start_at", DateTime.to_iso8601(DateTime.utc_now()))
            with {:ok, _updated} <- spec.write.(record, quota), do: {:ok, quota}

          nil ->
            {:error, :token_quota_not_configured}
        end
    end
  end

  defp subject_window(spec, %{uid: uid, inserted_at: inserted_at} = record, %DateTime{} = now) do
    with %{} = quota <- stored_quota(record),
         {:ok, period_start_at} <- parse_instant(Map.get(quota, "period_start_at")) do
      period_days = Map.fetch!(quota, "period_days")
      limit_tokens = Map.fetch!(quota, "limit_tokens")
      window_started_at = window_start(period_start_at, period_days, now)
      counted_from = Enum.max([window_started_at, inserted_at], DateTime)
      used_tokens = spec.ledger_tokens.(uid, counted_from)

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

  defp normalize(attrs, stored) when is_map(attrs) do
    attrs =
      attrs
      |> Attrs.normalize_external_attrs()
      |> Map.put_new("period_start_at", (stored || %{})["period_start_at"])

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

  defp normalize(_attrs, _stored), do: {:error, :invalid_token_quota}

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

  defp parse_instant(value) do
    case Ankole.Attrs.parse_datetime(value) do
      %DateTime{} = instant -> {:ok, instant}
      nil -> :error
    end
  end

  @doc false
  def fetch_agent(agent_uid) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      case Principals.get_agent(agent_uid) do
        {:ok, %{agent: %Agent{} = agent}} -> {:ok, agent}
        {:error, :not_found} -> {:error, :agent_not_found}
        {:error, _error} = error -> error
      end
    end
  end

  @doc false
  def write_agent_quota(%Agent{} = agent, quota) do
    agent
    |> Principals.options_agent(%{options: put_quota_options(agent.options || %{}, quota)})
    |> Ankole.Errors.reason()
  end

  @doc false
  def write_service_quota(%ServiceAccount{} = account, quota) do
    account
    |> Principals.options_service_account(%{
      options: put_quota_options(account.options || %{}, quota)
    })
    |> Ankole.Errors.reason()
  end

  defp stored_quota(%{options: options}) when is_map(options) do
    case get_in(options, ["ai_agent", "token_quota"]) do
      %{"period_days" => period_days, "limit_tokens" => limit_tokens} = quota
      when is_integer(period_days) and is_integer(limit_tokens) ->
        quota

      _value ->
        nil
    end
  end

  defp stored_quota(_record), do: nil

  defp put_quota_options(options, nil),
    do: replace_ai_agent(options, &Map.delete(&1, "token_quota"))

  defp put_quota_options(options, quota),
    do: replace_ai_agent(options, &Map.put(&1, "token_quota", quota))

  defp replace_ai_agent(options, fun) do
    ai_agent =
      case Map.get(options, "ai_agent") do
        value when is_map(value) -> value
        _value -> %{}
      end

    Map.put(options, "ai_agent", fun.(ai_agent))
  end
end
