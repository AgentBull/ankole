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
  @current_sender_access_version "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_ACCESS_VERSION"

  @spec resolve(ActorEvent.t()) :: %{String.t() => String.t()}
  def resolve(%ActorEvent{payload: payload, sender_key: sender_key}) do
    case principal_candidate(sender_key) do
      {:active_human, _uid, _version} = human ->
        runtime_env(human)

      :ineligible ->
        %{}

      :missing ->
        payload
        |> get_in(["data", "entry", "author", "principal_uid"])
        |> principal_candidate()
        |> runtime_env()
    end
  end

  @doc false
  @spec current_sender_principal_uid(map()) :: String.t() | nil
  def current_sender_principal_uid(%{} = runtime_env) do
    case Map.get(runtime_env, @current_sender_principal) do
      uid when is_binary(uid) and uid != "" -> uid
      _missing -> nil
    end
  end

  def current_sender_principal_uid(_runtime_env), do: nil

  defp principal_candidate(principal_uid) do
    case Principals.get_principal(principal_uid) do
      {:ok, %Principal{type: :human, status: :active, uid: uid, access_version: version}} ->
        {:active_human, uid, version}

      {:ok, %Principal{}} ->
        :ineligible

      {:error, _reason} ->
        :missing
    end
  end

  defp runtime_env({:active_human, uid, version}) do
    %{
      @current_sender_principal => uid,
      @current_sender_access_version => Integer.to_string(version)
    }
  end

  defp runtime_env(:ineligible), do: %{}
  defp runtime_env(:missing), do: %{}
end
