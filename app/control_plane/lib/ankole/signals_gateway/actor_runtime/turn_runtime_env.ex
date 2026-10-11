defmodule Ankole.SignalsGateway.ActorRuntime.TurnRuntimeEnv do
  @moduledoc """
  Builds trusted environment facts for one Actor turn.

  WorkerEnv owns static operator and binding configuration. This module adds
  facts that are true only for the current ActorEvent. Missing or non-human
  senders produce no variable, so unattended work cannot inherit a person's
  identity.

  For a human sender it also names the sender's opaque `lark-cli` profile:
  `ankole-u-` and the unpadded base64url HMAC-SHA256 of the sender identity,
  keyed with the installation's worker key. The identity is the Principal UID
  for access version 1, and otherwise the UID, a NUL byte, and the version.
  The key never leaves the control plane, and the name is stable across
  Workers, so an authorized user keeps the profile.
  """

  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey

  @current_sender_principal "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL"
  @lark_profile "ANKOLE_RUNTIME_LARK_PROFILE"

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
      @lark_profile => lark_profile(WorkerAuthKey.ensure!(), uid, version)
    }
  end

  defp runtime_env(:ineligible), do: %{}
  defp runtime_env(:missing), do: %{}

  @doc false
  @spec lark_profile(String.t(), String.t(), pos_integer()) :: String.t()
  def lark_profile(key, principal_uid, access_version) do
    # Version 1 keeps the profiles stored before access revocation existed.
    identity =
      if access_version == 1,
        do: principal_uid,
        else: principal_uid <> <<0>> <> Integer.to_string(access_version)

    "ankole-u-" <> Base.url_encode64(:crypto.mac(:hmac, :sha256, key, identity), padding: false)
  end
end
