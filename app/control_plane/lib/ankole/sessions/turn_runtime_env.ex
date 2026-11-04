defmodule Ankole.Sessions.TurnRuntimeEnv do
  @moduledoc """
  Builds trusted environment facts for one Session turn.

  WorkerEnv owns static operator and binding configuration. This module adds
  facts that are true only for the current Signal. Missing or non-human
  senders produce no variable, so unattended work cannot inherit a person's
  identity.

  """

  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Signals.Signal

  @current_sender_principal "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL"

  @spec resolve(Signal.t()) :: %{String.t() => String.t()}
  def resolve(%Signal{authorization_kind: "human", human_uid: uid, human_access_version: version}) do
    case principal_candidate(uid) do
      {:active_human, ^uid, ^version} = human ->
        runtime_env(human)

      _ ->
        %{}
    end
  end

  def resolve(%Signal{}), do: %{}

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

  defp runtime_env({:active_human, uid, _version}), do: %{@current_sender_principal => uid}
end
