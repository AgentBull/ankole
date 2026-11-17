defmodule Ankole.Pod.Applets.Idempotency do
  @moduledoc """
  Two-layer idempotency store for mutating Applet HTTP routes (`Idempotency-Key`)
  and SDK `AnkoleRuntime.idempotent(key, fn)` envelopes.
  """
  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Pod.{Access, AppletIdempotencyKey, Pages}
  alias Ankole.Repo

  @in_flight_status 0
  @min_in_flight_ttl_seconds 90
  @default_in_flight_ttl_seconds 330
  @completed_ttl_seconds 86_400
  @max_sdk_value_bytes 65_536

  @spec parse_header([String.t()]) :: {:ok, String.t() | nil} | {:error, :invalid_request}
  def parse_header([]), do: {:ok, nil}
  def parse_header([raw]) when is_binary(raw), do: normalize_key(raw)
  def parse_header(_multiple), do: {:error, :invalid_request}

  @spec execute_route(Actor.t(), String.t(), map(), String.t() | nil, (-> term()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_route(actor, page_id, request, key, run, opts \\ [])
      when is_function(run, 0) and is_list(opts) do
    {_conn, result} =
      do_execute_route(nil, actor, page_id, request, key, fn -> {nil, run.()} end, opts)

    result
  end

  @spec execute_conn_route(
          Plug.Conn.t(),
          Actor.t(),
          String.t(),
          map(),
          String.t() | nil,
          (Plug.Conn.t() -> {Plug.Conn.t(), term()}),
          keyword()
        ) :: {Plug.Conn.t(), {:ok, map()} | {:error, term()}}
  def execute_conn_route(conn, actor, page_id, request, key, run, opts \\ [])
      when is_function(run, 1) and is_list(opts) do
    {next_conn, result} =
      do_execute_route(conn, actor, page_id, request, key, fn -> run.(conn) end, opts)

    {next_conn || conn, result}
  end

  defp do_execute_route(
         _conn,
         _actor,
         _page_id,
         %{"method" => "GET"},
         _key,
         run_with_conn,
         _opts
       ),
       do: run_with_conn.()

  defp do_execute_route(_conn, _actor, _page_id, _request, nil, run_with_conn, _opts),
    do: run_with_conn.()

  defp do_execute_route(conn, %Actor{} = actor, page_id, request, key, run_with_conn, opts)
       when is_binary(page_id) and is_binary(key) do
    scope_uid = "http:" <> Actor.uid(actor)
    hash = request_hash(request)

    case claim(actor, page_id, scope_uid, key, hash, opts) do
      {:replay, outcome} ->
        {conn, {:ok, outcome}}

      {:claimed, claim_id} ->
        {next_conn, result} = run_claimed(page_id, scope_uid, key, claim_id, run_with_conn)

        settled =
          case result do
            {:ok, %{"status" => status} = outcome}
            when is_integer(status) and status < 500 and status not in [408, 409, 425, 429] ->
              complete(
                page_id,
                scope_uid,
                key,
                status,
                outcome,
                @completed_ttl_seconds,
                claim_id
              )

              {:ok, outcome}

            other ->
              release(page_id, scope_uid, key, claim_id)
              other
          end

        {next_conn, settled}

      {:error, _} = error ->
        {conn, error}
    end
  end

  defp run_claimed(page_id, scope_uid, key, claim_id, run_with_conn) do
    run_with_conn.()
  rescue
    exception in [Bandit.TransportError] ->
      # A client disconnect mid-flight cannot prove whether the Applet mutation finished;
      # keep the lease active so retries wait or observe conflict rather than re-running side effects.
      reraise exception, __STACKTRACE__

    exception ->
      release(page_id, scope_uid, key, claim_id)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      release(page_id, scope_uid, key, claim_id)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @spec sdk_claim(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def sdk_claim(page_id, scope, key, request_hash, opts \\ [])

  def sdk_claim(page_id, scope, key, request_hash, opts)
      when is_binary(page_id) and is_binary(scope) and is_binary(request_hash) and is_list(opts) do
    with {:ok, trimmed} <- normalize_key(key) do
      scope_uid = "sdk:" <> scope
      claim_opts = Keyword.put(opts, :check_access?, false)

      case do_claim_tx(nil, page_id, scope_uid, trimmed, request_hash, claim_opts) do
        {:replay, %{"body" => value}} ->
          {:ok, %{"status" => "replayed", "value" => value}}

        {:replay, _} ->
          {:ok, %{"status" => "replayed", "value" => nil}}

        {:claimed, claim_id} ->
          {:ok, %{"status" => "claimed", "claim_id" => claim_id}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def sdk_claim(_page_id, _scope, _key, _hash, _opts), do: {:error, :invalid_request}

  @spec sdk_complete(
          String.t(),
          String.t(),
          String.t(),
          term(),
          pos_integer(),
          String.t()
        ) :: {:ok, map()} | {:error, atom()}
  def sdk_complete(page_id, scope, key, value, ttl_seconds, claim_id)
      when is_binary(page_id) and is_binary(scope) and is_integer(ttl_seconds) and
             is_binary(claim_id) and byte_size(claim_id) > 0 do
    with {:ok, trimmed} <- normalize_key(key),
         true <- valid_sdk_value?(value) do
      bounded_ttl = min(max(ttl_seconds, 1), 7 * 86_400)
      complete(page_id, "sdk:" <> scope, trimmed, 200, %{"body" => value}, bounded_ttl, claim_id)
      {:ok, %{"completed" => true}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def sdk_complete(_page_id, _scope, _key, _value, _ttl_seconds, _claim_id),
    do: {:error, :invalid_request}

  @spec sdk_release(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def sdk_release(page_id, scope, key, claim_id)
      when is_binary(page_id) and is_binary(scope) and is_binary(claim_id) and
             byte_size(claim_id) > 0 do
    with {:ok, trimmed} <- normalize_key(key) do
      release(page_id, "sdk:" <> scope, trimmed, claim_id)
      {:ok, %{"released" => true}}
    end
  end

  def sdk_release(_page_id, _scope, _key, _claim_id), do: {:error, :invalid_request}

  defp normalize_key(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    if trimmed != "" and String.length(trimmed) <= 255 and String.valid?(trimmed),
      do: {:ok, trimmed},
      else: {:error, :invalid_request}
  end

  defp normalize_key(_), do: {:error, :invalid_request}

  defp valid_sdk_value?(value) do
    case value |> Ankole.JSON.plain() |> Ankole.JSON.encode() do
      {:ok, encoded} -> byte_size(encoded) <= @max_sdk_value_bytes
      {:error, _} -> false
    end
  end

  defp claim(actor, page_id, scope_uid, key, hash, opts) do
    do_claim_tx(actor, page_id, scope_uid, key, hash, Keyword.put(opts, :check_access?, true))
  end

  defp do_claim_tx(actor, page_id, scope_uid, key, hash, opts) do
    now = DateTime.utc_now(:microsecond)
    ttl_seconds = in_flight_ttl_seconds(opts)
    claim_id = Ash.UUIDv7.generate()

    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.fetch(page_id),
           :ok <- Ankole.Pod.Applets.available(page),
           :ok <- maybe_authorize(actor, page, Keyword.get(opts, :check_access?, true)) do
        existing =
          AppletIdempotencyKey
          |> Ash.Query.filter(
            page_id == ^page.id and scope_uid == ^scope_uid and idempotency_key == ^key
          )
          |> Ash.Query.lock(:for_update)
          |> Ankole.Ash.read_one!()

        case resolve_existing(existing, hash, now) do
          :insert ->
            case Ankole.Ash.create(AppletIdempotencyKey, :claim_in_tx, %{
                   page_id: page.id,
                   scope_uid: scope_uid,
                   idempotency_key: key,
                   request_hash: hash,
                   status_code: @in_flight_status,
                   response_body: %{"in_flight" => true, "claim_id" => claim_id},
                   expires_at: DateTime.add(now, ttl_seconds, :second)
                 }) do
              {:ok, _row} -> {:ok, {:claimed, claim_id}}
              {:error, _} -> {:error, :idempotency_claim_conflict}
            end

          other ->
            other
        end
      end
    end)
    |> case do
      {:ok, {:claimed, _} = claimed} ->
        claimed

      {:ok, {:replay, outcome}} ->
        {:replay, outcome}

      {:error, :idempotency_claim_conflict} ->
        if Keyword.get(opts, :retried?, false) do
          {:error, :idempotency_request_in_progress}
        else
          do_claim_tx(actor, page_id, scope_uid, key, hash, Keyword.put(opts, :retried?, true))
        end

      {:error, _} = error ->
        error
    end
  end

  defp in_flight_ttl_seconds(opts) do
    cond do
      is_integer(opts[:deadline]) ->
        remaining_ms = max(0, opts[:deadline] - System.monotonic_time(:millisecond))
        clamp_in_flight_ttl(div(remaining_ms + 999, 1_000) + 30)

      is_integer(opts[:timeout_ms]) and opts[:timeout_ms] > 0 ->
        clamp_in_flight_ttl(div(opts[:timeout_ms] + 999, 1_000) + 30)

      true ->
        @default_in_flight_ttl_seconds
    end
  end

  defp clamp_in_flight_ttl(seconds),
    do: max(seconds, @min_in_flight_ttl_seconds)

  defp maybe_authorize(_actor, _page, false), do: :ok

  defp maybe_authorize(actor, page, true) do
    case Access.authorize(actor, page, "node_view", trash: false) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp resolve_existing(nil, _hash, _now), do: :insert

  defp resolve_existing(%AppletIdempotencyKey{} = row, hash, now) do
    if DateTime.compare(row.expires_at, now) != :gt do
      {:ok, _} = Ankole.Ash.destroy(row, :release_in_tx)
      :insert
    else
      resolve_existing_active(row, hash)
    end
  end

  defp resolve_existing_active(%AppletIdempotencyKey{} = row, hash) do
    cond do
      row.request_hash != hash ->
        {:error, :idempotency_key_mismatch}

      row.status_code == @in_flight_status ->
        {:error, :idempotency_request_in_progress}

      row.response_body["has_body"] == false ->
        {:ok, {:replay, %{"status" => row.status_code}}}

      true ->
        {:ok, {:replay, %{"status" => row.status_code, "body" => row.response_body["value"]}}}
    end
  end

  defp complete(page_id, scope_uid, key, status, outcome, ttl_seconds, claim_id) do
    now = DateTime.utc_now(:microsecond)
    has_body = Map.has_key?(outcome, "body")

    body =
      if has_body,
        do: %{"has_body" => true, "value" => outcome["body"]},
        else: %{"has_body" => false}

    Repo.transact_top_level(fn ->
      case AppletIdempotencyKey
           |> Ash.Query.filter(
             page_id == ^page_id and scope_uid == ^scope_uid and idempotency_key == ^key
           )
           |> Ash.Query.lock(:for_update)
           |> Ankole.Ash.read_one!() do
        %AppletIdempotencyKey{status_code: @in_flight_status} = row ->
          if claim_matches?(row, claim_id) do
            Ankole.Ash.update(row, :complete_in_tx, %{
              status_code: status,
              response_body: body,
              expires_at: DateTime.add(now, ttl_seconds, :second)
            })
          else
            {:ok, nil}
          end

        _ ->
          {:ok, nil}
      end
    end)

    :ok
  end

  defp release(page_id, scope_uid, key, claim_id) do
    Repo.transact_top_level(fn ->
      case AppletIdempotencyKey
           |> Ash.Query.filter(
             page_id == ^page_id and scope_uid == ^scope_uid and idempotency_key == ^key
           )
           |> Ash.Query.lock(:for_update)
           |> Ankole.Ash.read_one!() do
        %AppletIdempotencyKey{status_code: @in_flight_status} = row ->
          if claim_matches?(row, claim_id),
            do: Ankole.Ash.destroy(row, :release_in_tx),
            else: {:ok, nil}

        _ ->
          {:ok, nil}
      end
    end)

    :ok
  end

  defp claim_matches?(row, claim_id), do: row.response_body["claim_id"] == claim_id

  @doc "Reclaims expired Applet idempotency rows inside the caller's transaction."
  def prune_expired_in_tx(%DateTime{} = now) do
    AppletIdempotencyKey
    |> Ash.Query.filter(expires_at <= ^now)
    |> Ankole.Ash.destroy_where(:release_in_tx)
  end

  @spec request_hash(term()) :: String.t()
  def request_hash(payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
