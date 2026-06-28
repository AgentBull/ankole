defmodule Ankole.AuthZ.Decision do
  @moduledoc false

  alias Ankole.AuthZ.Snapshot
  alias Ankole.Kernel, as: AnkoleKernel

  require Logger

  def authorize_decision(principal_uid, resource, action, context \\ %{}) do
    with {:ok, snapshot} <-
           Snapshot.build_authorization_snapshot(principal_uid, resource, action, context),
         {:ok, decision} <- kernel_decision(AnkoleKernel.authz_authorize(snapshot)) do
      emit_diagnostics(decision)
      {:ok, decision}
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

  defp kernel_decision(%{} = decision), do: {:ok, decision}
  defp kernel_decision({:error, reason}), do: {:error, reason}
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

    Logger.error("AuthZ invalid persisted data: #{inspect(metadata)}")
    :telemetry.execute([:ankole, :authz, :invalid_persisted_data], %{count: 1}, metadata)
  end

  defp emit_diagnostic(_diagnostic), do: :ok
end
