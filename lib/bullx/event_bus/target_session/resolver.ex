defmodule BullX.EventBus.TargetSession.Resolver do
  @moduledoc """
  Resolves an incoming Event to an active TargetSession to append into.

  A TargetSession is keyed by (`event_routing_rule_id`, `target_type`,
  `target_ref`, `scope_key`). For each new Event we either reuse an existing
  active session under that key or insert a new one.

  TargetSession continuity is a runtime lane concern, not conversation truth.
  The resolver does not enforce a wall-clock lifetime. A TargetSession remains
  reusable while it is active and becomes terminal only when the Target closes
  or fails it.
  """

  import Ecto.Query

  alias BullX.EventBus.{AppendFailed, EventRoutingRule, Scope, TargetSession}
  alias BullX.Repo

  @type resolved :: %{
          session: TargetSession.t(),
          scope_key: String.t()
        }

  @spec resolve(EventRoutingRule.t(), map(), DateTime.t()) ::
          {:ok, resolved()} | {:error, AppendFailed.t()}
  def resolve(%EventRoutingRule{} = rule, routing_context, _now) do
    with {:ok, scope_key} <- Scope.scope_key(routing_context, rule.scope_fields) do
      do_resolve(rule, scope_key, :first)
    end
  end

  defp do_resolve(rule, scope_key, attempt) do
    with {:ok, session} <- reusable_or_insert(rule, scope_key, attempt) do
      {:ok, %{session: session, scope_key: scope_key}}
    end
  end

  defp reusable_or_insert(rule, scope_key, attempt) do
    case find_active(rule, scope_key) do
      nil ->
        insert_session(rule, scope_key, attempt)

      %TargetSession{} = session ->
        {:ok, session}
    end
  end

  defp find_active(rule, scope_key) do
    TargetSession
    |> where([s], s.event_routing_rule_id == ^rule.id)
    |> where([s], s.target_type == ^rule.target_type)
    |> where([s], s.target_ref == ^rule.target_ref)
    |> where([s], s.scope_key == ^scope_key)
    |> where([s], s.status == :active)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp insert_session(rule, scope_key, attempt) do
    %TargetSession{}
    |> TargetSession.changeset(%{
      event_routing_rule_id: rule.id,
      target_type: rule.target_type,
      target_ref: rule.target_ref,
      scope_key: scope_key,
      status: :active
    })
    |> Repo.insert()
    |> case do
      {:ok, session} ->
        {:ok, session}

      {:error, %Ecto.Changeset{} = changeset} ->
        retry_or_fail(rule, scope_key, changeset, attempt)
    end
  end

  # A unique-index violation here means a concurrent caller inserted the same
  # (rule_id, target_type, target_ref, scope_key, active) row between our
  # `find_active` and `insert`. Retry once — the second pass will take the
  # reuse branch.
  defp retry_or_fail(rule, scope_key, changeset, :first) do
    case unique_conflict?(changeset) do
      true ->
        do_resolve(rule, scope_key, :retry)

      false ->
        {:error,
         append_failed(:target_session_resolution_failed, "could not insert TargetSession")}
    end
  end

  defp retry_or_fail(_rule, _scope_key, _changeset, :retry) do
    {:error,
     append_failed(
       :target_session_resolution_failed,
       "could not resolve TargetSession after retry"
     )}
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
