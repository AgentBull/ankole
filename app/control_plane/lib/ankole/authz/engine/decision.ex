defmodule Ankole.AuthZ.Decision do
  @moduledoc false

  alias Ankole.AuthZ.Snapshot
  alias Ankole.AuthZ.Input
  alias Ankole.Kernel, as: AnkoleKernel
  alias Ankole.Logging

  def authorize(subject, resource, action, context \\ %{})

  def authorize(subject, resource, action, context) do
    with {:ok, decision} <- authorize_decision(subject, resource, action, context),
         do: result(decision)
  end

  def allowed?(subject, resource, action, context \\ %{}),
    do: authorize(subject, resource, action, context) == :ok

  def authorize_decision(principal_uid, resource, action, context \\ %{}) do
    with {:ok, snapshot} <-
           Snapshot.build_authorization_snapshot(principal_uid, resource, action, context),
         {:ok, decision} <- kernel_decision(AnkoleKernel.authz_authorize(snapshot)) do
      emit_diagnostics(decision)
      {:ok, decision}
    end
  end

  def evaluate_drive_context(principal_uid, context) do
    with {:ok, snapshot} <- Snapshot.build_drive_context_snapshot(principal_uid, context),
         {:ok, evaluated} <- kernel_decision(AnkoleKernel.authz_evaluate_drive_context(snapshot)) do
      emit_diagnostics(evaluated)
      {:ok, {snapshot, evaluated}}
    end
  end

  def authorize_checks(principal_uid, checks, context) do
    with {:ok, checks} <- Input.normalize_checks(checks) do
      checks
      |> Enum.with_index()
      |> Enum.group_by(fn {check, _} ->
        String.starts_with?(check["resource"], ["site_console:", "tenant_console:"])
      end)
      |> Enum.reduce_while({:ok, []}, fn {_management, entries}, {:ok, results} ->
        {group, indices} = Enum.unzip(entries)

        with {:ok, snapshot} <-
               Snapshot.build_authorization_batch_snapshot(
                 principal_uid,
                 hd(group)["resource"],
                 group |> Enum.map(& &1["action"]) |> Enum.uniq(),
                 context
               ),
             {:ok, allowed} <- evaluate_checks(snapshot, group) do
          {:cont, {:ok, Enum.zip(indices, allowed) ++ results}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, results |> Enum.sort() |> Enum.map(&elem(&1, 1))}
        error -> error
      end
    end
  end

  defp evaluate_checks(snapshot, checks) do
    result = AnkoleKernel.authz_authorize_checks(Map.put(snapshot, "checks", checks))

    with %{"allowed" => allowed} when is_list(allowed) <- result,
         true <- length(allowed) == length(checks) and Enum.all?(allowed, &is_boolean/1) do
      emit_diagnostics(result)
      {:ok, allowed}
    else
      _ -> {:error, :invalid_decision}
    end
  end

  def authorize_all_decision(principal_uid, resource, actions, context \\ %{}) do
    with {:ok, snapshot} <-
           Snapshot.build_authorization_batch_snapshot(principal_uid, resource, actions, context),
         {:ok, decision} <- kernel_decision(AnkoleKernel.authz_authorize_all(snapshot)) do
      emit_diagnostics(decision)
      {:ok, decision}
    end
  end

  def result(%{"status" => "allow"}), do: :ok
  def result(%{"status" => "principal_disabled"}), do: {:error, :principal_disabled}
  def result(%{"status" => "invalid_request"}), do: {:error, :invalid_request}

  def result(%{"status" => "deny", "deniedAction" => action}),
    do: {:error, {:forbidden, action}}

  def result(%{"status" => "deny"}), do: {:error, :forbidden}
  def result(_decision), do: {:error, :invalid_decision}

  @doc false
  def preview_computed_membership?(snapshot, group_id) do
    case kernel_decision(AnkoleKernel.authz_authorize(snapshot)) do
      {:ok, decision} ->
        emit_diagnostics(decision)
        group_id in Map.get(decision, "effectiveGroupIDs", [])

      _error ->
        false
    end
  end

  defp kernel_decision(%{} = decision), do: {:ok, decision}
  defp kernel_decision(_decision), do: {:error, :invalid_decision}

  defp emit_diagnostics(%{"diagnostics" => diagnostics}) when is_list(diagnostics) do
    Enum.each(diagnostics, &emit_diagnostic/1)
  end

  defp emit_diagnostics(_decision), do: :ok

  defp emit_diagnostic(%{} = diagnostic) do
    metadata = %{
      kind: diagnostic["kind"],
      id: diagnostic["id"],
      action: diagnostic["action"],
      resource_pattern: diagnostic["resourcePattern"],
      reason: diagnostic["reason"]
    }

    Logging.error("authz.invalid_persisted_data", "AuthZ invalid persisted data", metadata)
    :telemetry.execute([:ankole, :authz, :invalid_persisted_data], %{count: 1}, metadata)
  end

  defp emit_diagnostic(_diagnostic), do: :ok
end
