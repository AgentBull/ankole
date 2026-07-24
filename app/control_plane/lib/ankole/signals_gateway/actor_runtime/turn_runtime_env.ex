defmodule Ankole.SignalsGateway.ActorRuntime.TurnRuntimeEnv do
  @moduledoc """
  Builds trusted environment facts for one Actor turn.

  WorkerEnv owns static operator and binding configuration. This module adds
  facts that are true only for the current ActorEvent. Missing or non-human
  senders produce no variable, so unattended work cannot inherit a person's
  identity.
  """

  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.ActorEvent

  @current_sender_principal "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL"

  @spec resolve(ActorEvent.t()) :: %{String.t() => String.t()}
  def resolve(%ActorEvent{payload: payload, sender_key: sender_key}) do
    case principal_candidate(sender_key) do
      {:active_human, uid} ->
        %{@current_sender_principal => uid}

      :ineligible ->
        %{}

      :missing ->
        payload
        |> get_in(["data", "entry", "author", "principal_uid"])
        |> principal_candidate()
        |> runtime_env()
    end
  end

  defp principal_candidate(principal_uid) do
    case Principals.get_principal(principal_uid) do
      {:ok, %Principal{type: :human, status: :active, uid: uid}} ->
        {:active_human, uid}

      {:ok, %Principal{}} ->
        :ineligible

      {:error, _reason} ->
        :missing
    end
  end

  defp runtime_env({:active_human, uid}), do: %{@current_sender_principal => uid}
  defp runtime_env(:ineligible), do: %{}
  defp runtime_env(:missing), do: %{}
end
