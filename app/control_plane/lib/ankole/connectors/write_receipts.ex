defmodule Ankole.Connectors.WriteReceipts do
  @moduledoc """
  Tracks non-idempotent Connector tool executions within an active turn/attempt
  so retries can detect prior writes and report uncertain upstream outcomes.
  """
  require Ash.Query

  alias Ankole.Connectors.{ToolSpec, WriteReceipt}
  alias Ankole.Repo

  @in_flight_ttl_seconds 120
  @settled_ttl_seconds 7_200

  def toolkit_identity(toolkit, auth_config_id, account_id)
      when is_binary(toolkit) and is_binary(auth_config_id) and auth_config_id != "" do
    "#{toolkit}:#{auth_config_id}:#{account_id || "app"}"
  end

  def toolkit_identity(toolkit, _auth_config_id, _account_id) when is_binary(toolkit), do: toolkit

  def card_target_identity({:toolkit, id}, payload) when is_map(payload),
    do: toolkit_identity(id, payload["auth_config_id"], payload["account_id"])

  def card_target_identity({:skill, skill, server}, _payload),
    do: "skill:#{skill}:#{server}"

  def exists_for_scope?(scope) do
    WriteReceipt
    |> Ash.Query.filter(authority_scope == ^scope)
    |> Ankole.Ash.exists?()
  end

  def execute(spec, args, context, invoke_fn) when is_function(invoke_fn, 0) do
    case guard_scope(spec, context) do
      nil ->
        invoke_fn.()

      scope ->
        auth_config_id =
          case Map.get(context, :auth_config) do
            %{id: id} -> id
            _ -> nil
          end

        account_id =
          case Map.get(context, :account) do
            %{id: id} -> id
            _ -> nil
          end

        identity = toolkit_identity(spec.toolkit, auth_config_id, account_id)
        execute_scope(scope, identity, spec.name, args, invoke_fn)
    end
  end

  def execute_skill(_skill, _server, _tool_name, true, _args, _context, invoke_fn)
      when is_function(invoke_fn, 0),
      do: invoke_fn.()

  def execute_skill(skill, server, tool_name, false, args, context, invoke_fn)
      when is_binary(skill) and is_binary(server) and is_binary(tool_name) and
             is_function(invoke_fn, 0) do
    case authority_scope(get_in(context, [:actor, Access.key(:turn_authority)])) do
      nil ->
        invoke_fn.()

      scope ->
        case execute_scope(scope, "skill:#{skill}:#{server}", tool_name, args, fn ->
               case invoke_fn.() do
                 {:ok, result} -> {:ok, result, context}
                 other -> other
               end
             end) do
          {:ok, result, _ctx} -> {:ok, result}
          other -> other
        end
    end
  end

  def execute_scope(scope, toolkit, tool_name, args, invoke_fn, opts \\ [])
      when is_binary(scope) and is_binary(toolkit) and is_binary(tool_name) and
             is_function(invoke_fn, 0) do
    hash = args_hash(args)
    recover_settled? = Keyword.get(opts, :recover_settled?, false)

    case claim(scope, toolkit, tool_name, hash, recover_settled?) do
      {:claimed, claimed_toolkit, claimed_hash} ->
        result =
          try do
            invoke_fn.()
          rescue
            exception ->
              settle(scope, claimed_toolkit, tool_name, claimed_hash, "outcome_unknown", nil, nil)
              reraise exception, __STACKTRACE__
          catch
            kind, reason ->
              settle(scope, claimed_toolkit, tool_name, claimed_hash, "outcome_unknown", nil, nil)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        finalize(scope, claimed_toolkit, tool_name, claimed_hash, result)

      {:recovered, %WriteReceipt{} = receipt} ->
        {:recovered, receipt}

      {:error, _} = blocked ->
        blocked
    end
  end

  def prune_expired_in_tx(now \\ DateTime.utc_now(:microsecond)) do
    settled_expires_at = DateTime.add(now, @settled_ttl_seconds, :second)

    {:ok, _} =
      WriteReceipt
      |> Ash.Query.filter(status == "in_flight" and expires_at <= ^now)
      |> Ankole.Ash.update_where(:settle_in_tx, %{
        status: "outcome_unknown",
        http_status: nil,
        external_ref: nil,
        expires_at: settled_expires_at
      })

    WriteReceipt
    |> Ash.Query.filter(
      status != "in_flight" and expires_at <= ^now and
        not fragment(
          "starts_with(?, 'action_card:') AND EXISTS (SELECT 1 FROM conversation_action_cards c WHERE c.tenant_id = ? AND c.id::text = substring(? FROM 13) AND c.status = 'executing')",
          authority_scope,
          tenant_id,
          authority_scope
        )
    )
    |> Ankole.Ash.destroy_where(:release_in_tx)
  end

  defp guard_scope(spec, context) do
    if ToolSpec.retry_safe?(spec) do
      nil
    else
      authority_scope(get_in(context, [:actor, Access.key(:turn_authority)]))
    end
  end

  defp authority_scope({%Ankole.Sessions.RunRef{signal_id: id}, _uid}) when is_binary(id),
    do: "signal:" <> id

  defp authority_scope({%Ankole.Sessions.JobTurnRef{signal_id: id}, _uid}) when is_binary(id),
    do: "job_turn:" <> id

  defp authority_scope({%Ankole.AutomationJobs.AttemptRef{run_id: id}, _uid})
       when is_integer(id),
       do: "applet_run:" <> Integer.to_string(id)

  defp authority_scope(_), do: nil

  defp claim(scope, toolkit, tool_name, hash, recover_settled?) do
    now = DateTime.utc_now(:microsecond)

    Repo.transact_top_level(fn ->
      existing =
        lock_existing_in_tx(scope, toolkit, tool_name, hash, recover_settled?)
        |> maybe_expire_in_flight_in_tx(now, recover_settled?)

      cond do
        recover_settled? and not is_nil(existing) and
            existing.status in ["succeeded", "outcome_unknown"] ->
          {:ok, {:recovered, existing}}

        recover_settled? and is_nil(existing) ->
          {:ok,
           {:error,
            %{
              code: "no_recorded_receipt",
              message:
                "Previous execution attempt ended before completing the upstream call; ask the Agent to retry if needed.",
              retryable: true,
              request_sent: false
            }}}

        is_nil(existing) ->
          insert_claim(scope, toolkit, tool_name, hash, now)

        existing.status == "succeeded" ->
          ref_hint = if existing.external_ref, do: " (ref: #{existing.external_ref})", else: ""

          {:ok,
           {:error,
            %{
              code: "duplicate_turn_write_prevented",
              message:
                "This non-idempotent connector write already succeeded earlier in this turn#{ref_hint}. Inspect upstream state before repeating.",
              retryable: false,
              request_sent: false
            }}}

        existing.status == "outcome_unknown" ->
          {:ok,
           {:error,
            %{
              code: "previous_write_outcome_unknown",
              message:
                "An identical non-idempotent connector write earlier in this turn ended with an uncertain upstream outcome. Inspect upstream state before retrying.",
              retryable: false,
              request_sent: false
            }}}

        true ->
          {:ok, in_flight_error()}
      end
    end)
    |> case do
      {:ok, {:claimed, _, _} = claimed} -> claimed
      {:ok, {:recovered, %WriteReceipt{}} = recovered} -> recovered
      {:ok, {:error, _} = blocked} -> blocked
      {:error, _} = error -> error
    end
  end

  defp lock_existing_in_tx(scope, _toolkit, tool_name, _hash, true) do
    WriteReceipt
    |> Ash.Query.filter(authority_scope == ^scope and tool_name == ^tool_name)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!(lock_identity: {:rows, "connector_write_receipts", :id})
  end

  defp lock_existing_in_tx(scope, toolkit, tool_name, hash, false) do
    WriteReceipt
    |> Ash.Query.filter(
      authority_scope == ^scope and toolkit == ^toolkit and tool_name == ^tool_name and
        args_sha256 == ^hash
    )
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!(
      lock_identity: {"connector_write_receipts", [{scope, toolkit, tool_name, hash}]}
    )
  end

  defp maybe_expire_in_flight_in_tx(%WriteReceipt{status: "in_flight"} = row, now, recover?) do
    if recover? or DateTime.compare(row.expires_at, now) != :gt do
      {:ok, updated} =
        Ankole.Ash.update(row, :settle_in_tx, %{
          status: "outcome_unknown",
          http_status: nil,
          external_ref: nil,
          expires_at: DateTime.add(now, @settled_ttl_seconds, :second)
        })

      updated
    else
      row
    end
  end

  defp maybe_expire_in_flight_in_tx(other, _now, _recover?), do: other

  defp insert_claim(scope, toolkit, tool_name, hash, now) do
    case Ankole.Ash.create(WriteReceipt, :claim_in_tx, %{
           authority_scope: scope,
           toolkit: toolkit,
           tool_name: tool_name,
           args_sha256: hash,
           status: "in_flight",
           expires_at: DateTime.add(now, @in_flight_ttl_seconds, :second)
         }) do
      {:ok, _row} ->
        {:ok, {:claimed, toolkit, hash}}

      {:error, _} ->
        in_flight_error()
    end
  end

  defp in_flight_error do
    {:error,
     %{
       code: "write_already_in_flight",
       message:
         "This non-idempotent call has already started in this turn and has not settled. Use a read-only tool to inspect upstream state; do not blindly resend it.",
       retryable: false,
       request_sent: true
     }}
  end

  def uncertain_failure?(error) when is_map(error) do
    status = Ankole.Attrs.get_truthy(error, :status)
    request_sent = Ankole.Attrs.get(error, :request_sent, true)

    request_sent != false and
      not (is_integer(status) and status >= 400 and status < 500 and status not in [408, 499])
  end

  def uncertain_failure?(_error), do: true

  defp finalize(scope, toolkit, tool_name, hash, {:ok, %{"isError" => true}, _ctx} = tool_err) do
    settle(scope, toolkit, tool_name, hash, "outcome_unknown", 200, nil)
    tool_err
  end

  defp finalize(scope, toolkit, tool_name, hash, {:ok, result, _ctx} = ok) do
    settle(scope, toolkit, tool_name, hash, "succeeded", 200, extract_external_ref(result))
    ok
  end

  defp finalize(scope, toolkit, tool_name, hash, {:error, error} = err) when is_map(error) do
    status = Ankole.Attrs.get_truthy(error, :status)

    if uncertain_failure?(error) do
      settle(scope, toolkit, tool_name, hash, "outcome_unknown", status, nil)
    else
      release(scope, toolkit, tool_name, hash)
    end

    err
  end

  defp finalize(scope, toolkit, tool_name, hash, other) do
    settle(scope, toolkit, tool_name, hash, "outcome_unknown", nil, nil)
    other
  end

  defp settle(scope, toolkit, tool_name, hash, status, http_status, external_ref) do
    now = DateTime.utc_now(:microsecond)

    persist_resolution(scope, toolkit, tool_name, :settle, fn ->
      case WriteReceipt
           |> Ash.Query.filter(
             authority_scope == ^scope and toolkit == ^toolkit and tool_name == ^tool_name and
               args_sha256 == ^hash
           )
           |> Ash.Query.lock(:for_update)
           |> Ankole.Ash.read_one!(
             lock_identity: {"connector_write_receipts", [{scope, toolkit, tool_name, hash}]}
           ) do
        %WriteReceipt{} = row ->
          Ankole.Ash.update(row, :settle_in_tx, %{
            status: status,
            http_status: http_status,
            external_ref: external_ref,
            expires_at: DateTime.add(now, @settled_ttl_seconds, :second)
          })

        nil ->
          {:ok, nil}
      end
    end)
  end

  defp release(scope, toolkit, tool_name, hash) do
    persist_resolution(scope, toolkit, tool_name, :release, fn ->
      WriteReceipt
      |> Ash.Query.filter(
        authority_scope == ^scope and toolkit == ^toolkit and tool_name == ^tool_name and
          args_sha256 == ^hash and status == "in_flight"
      )
      |> Ankole.Ash.destroy_where(:release_in_tx)
    end)
  end

  defp persist_resolution(scope, toolkit, tool_name, operation, write) do
    case Repo.transact_top_level(write) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        log_resolution_failure(scope, toolkit, tool_name, operation, :error, reason, [])
    end
  catch
    kind, reason ->
      log_resolution_failure(scope, toolkit, tool_name, operation, kind, reason, __STACKTRACE__)
  end

  defp log_resolution_failure(scope, toolkit, tool_name, operation, kind, reason, stacktrace) do
    Ankole.Logging.warning(
      "connectors.write_receipt_persistence_failed",
      "Could not persist the connector write receipt; preserving the upstream result",
      Map.merge(Ankole.Logging.failure_fields(kind, reason, stacktrace), %{
        authority_scope: scope,
        toolkit: toolkit,
        tool_name: tool_name,
        operation: operation
      })
    )

    :ok
  end

  defp extract_external_ref(result) when is_map(result) do
    candidate = result["id"] || result["number"] || result["ts"] || result["message_id"]
    if is_binary(candidate) or is_integer(candidate), do: to_string(candidate), else: nil
  end

  defp extract_external_ref(_), do: nil

  defp args_hash(args) do
    :crypto.hash(:sha256, :erlang.term_to_binary(args, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
