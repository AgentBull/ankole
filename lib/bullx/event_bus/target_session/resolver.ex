defmodule BullX.EventBus.TargetSession.Resolver do
  @moduledoc false

  import Ecto.Query

  alias BullX.EventBus.{AppendFailed, EventRoutingRule, Scope, TargetSession}
  alias BullX.Repo

  @hard_cap_seconds 86_400

  @type resolved :: %{
          session: TargetSession.t(),
          scope_key: String.t(),
          window_key: String.t()
        }

  @spec resolve(EventRoutingRule.t(), map(), DateTime.t()) ::
          {:ok, resolved()} | {:error, AppendFailed.t()}
  def resolve(%EventRoutingRule{} = rule, routing_context, now) do
    with {:ok, scope_key} <- Scope.scope_key(routing_context, rule.scope_fields),
         window_key <- Scope.window_key(routing_context, rule.window_type) do
      do_resolve(rule, scope_key, window_key, now, :first)
    end
  end

  defp do_resolve(rule, scope_key, window_key, now, attempt) do
    expires_at = initial_expires_at(rule, now)

    with :ok <- expire_stale_candidates(rule, scope_key, window_key, now),
         {:ok, session} <-
           reusable_or_insert(rule, scope_key, window_key, expires_at, now, attempt) do
      {:ok, %{session: session, scope_key: scope_key, window_key: window_key}}
    end
  end

  defp reusable_or_insert(rule, scope_key, window_key, expires_at, now, attempt) do
    case find_active(rule, scope_key, window_key) do
      nil ->
        insert_session(rule, scope_key, window_key, expires_at, now, attempt)

      %TargetSession{} = session ->
        refresh_reused_session(session, rule, now)
    end
  end

  defp find_active(rule, scope_key, window_key) do
    TargetSession
    |> where([s], s.event_routing_rule_id == ^rule.id)
    |> where([s], s.target_type == ^rule.target_type)
    |> where([s], s.target_ref == ^rule.target_ref)
    |> where([s], s.scope_key == ^scope_key)
    |> where([s], s.window_key == ^window_key)
    |> where([s], s.status == :active)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp insert_session(rule, scope_key, window_key, expires_at, _now, attempt) do
    %TargetSession{}
    |> TargetSession.changeset(%{
      event_routing_rule_id: rule.id,
      target_type: rule.target_type,
      target_ref: rule.target_ref,
      scope_key: scope_key,
      window_key: window_key,
      status: :active,
      expires_at: expires_at
    })
    |> Repo.insert()
    |> case do
      {:ok, session} ->
        {:ok, session}

      {:error, %Ecto.Changeset{} = changeset} ->
        retry_or_fail(rule, scope_key, window_key, expires_at, changeset, attempt)
    end
  end

  defp retry_or_fail(rule, scope_key, window_key, _expires_at, changeset, :first) do
    case unique_conflict?(changeset) do
      true ->
        do_resolve(rule, scope_key, window_key, DateTime.utc_now(:microsecond), :retry)

      false ->
        {:error,
         append_failed(:target_session_resolution_failed, "could not insert TargetSession")}
    end
  end

  defp retry_or_fail(_rule, _scope_key, _window_key, _expires_at, _changeset, :retry) do
    {:error,
     append_failed(
       :target_session_resolution_failed,
       "could not resolve TargetSession after retry"
     )}
  end

  defp refresh_reused_session(
         %TargetSession{} = session,
         %EventRoutingRule{window_type: :rolling_ttl} = rule,
         now
       ) do
    expires_at = refreshed_expires_at(session, rule, now)

    session
    |> TargetSession.changeset(%{expires_at: expires_at})
    |> Repo.update()
    |> case do
      {:ok, session} ->
        {:ok, session}

      {:error, _changeset} ->
        {:error,
         append_failed(:target_session_resolution_failed, "could not refresh TargetSession")}
    end
  end

  defp refresh_reused_session(%TargetSession{} = session, _rule, _now), do: {:ok, session}

  defp expire_stale_candidates(rule, scope_key, window_key, now) do
    rule
    |> active_candidates(scope_key, window_key)
    |> Repo.all()
    |> Enum.each(&expire_if_stale(&1, now))

    :ok
  end

  defp active_candidates(rule, scope_key, window_key) do
    TargetSession
    |> where([s], s.event_routing_rule_id == ^rule.id)
    |> where([s], s.target_type == ^rule.target_type)
    |> where([s], s.target_ref == ^rule.target_ref)
    |> where([s], s.scope_key == ^scope_key)
    |> where([s], s.window_key == ^window_key)
    |> where([s], s.status == :active)
    |> lock("FOR UPDATE")
  end

  defp expire_if_stale(%TargetSession{} = session, now) do
    case expiry_reason(session, now) do
      nil ->
        {:ok, session}

      reason ->
        session
        |> TargetSession.changeset(%{status: :expired, terminal_reason: reason})
        |> Repo.update()
    end
  end

  @spec hard_cap_at(TargetSession.t()) :: DateTime.t()
  def hard_cap_at(%TargetSession{inserted_at: inserted_at}) do
    DateTime.add(inserted_at, @hard_cap_seconds, :second)
  end

  @spec expiry_reason(TargetSession.t(), DateTime.t()) :: String.t() | nil
  def expiry_reason(%TargetSession{} = session, now) do
    case {hard_cap_passed?(session, now), expires_at_passed?(session, now)} do
      {true, _expires_at_passed?} -> "hard_max_runtime"
      {false, true} -> "runtime_window_expired"
      {false, false} -> nil
    end
  end

  @spec expired?(TargetSession.t(), DateTime.t()) :: boolean()
  def expired?(%TargetSession{} = session, now), do: not is_nil(expiry_reason(session, now))

  defp hard_cap_passed?(%TargetSession{} = session, now) do
    DateTime.compare(now, hard_cap_at(session)) != :lt
  end

  defp expires_at_passed?(%TargetSession{expires_at: nil}, _now), do: false

  defp expires_at_passed?(%TargetSession{expires_at: expires_at}, now) do
    DateTime.compare(now, expires_at) != :lt
  end

  defp initial_expires_at(%EventRoutingRule{window_type: :new_per_event}, _now), do: nil

  defp initial_expires_at(%EventRoutingRule{window_type: :rolling_ttl} = rule, now) do
    ttl_expires_at = DateTime.add(now, rule.window_ttl_seconds, :second)
    hard_cap_at = DateTime.add(now, @hard_cap_seconds, :second)
    min_datetime(ttl_expires_at, hard_cap_at)
  end

  defp refreshed_expires_at(%TargetSession{} = session, %EventRoutingRule{} = rule, now) do
    ttl_expires_at = DateTime.add(now, rule.window_ttl_seconds, :second)
    hard_cap_at = hard_cap_at(session)
    min_datetime(ttl_expires_at, hard_cap_at)
  end

  defp min_datetime(left, right) do
    case DateTime.compare(left, right) do
      :gt -> right
      _other -> left
    end
  end

  defp unique_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == "target_sessions_active_reuse_key_index"

      _error ->
        false
    end)
  end

  defp append_failed(code, message) do
    %AppendFailed{code: code, message: message, details: %{}}
  end
end
