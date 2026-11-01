defmodule Ankole.AuthZ.Actor do
  @moduledoc "The executing Principal, turn authority, and authentication evidence."
  @enforce_keys [:principal]
  defstruct [
    :principal,
    :turn_authority,
    authn: %{}
  ]

  @type t :: %__MODULE__{
          principal: struct(),
          turn_authority: term(),
          authn: map()
        }

  def new(principal, opts \\ []),
    do: struct!(__MODULE__, Keyword.put(opts, :principal, principal))

  def principal(%__MODULE__{principal: principal}), do: principal
  def uid(%__MODULE__{principal: %{uid: uid}}), do: uid
  def tenant_id(%__MODULE__{principal: %{tenant_id: id}}), do: id

  def from_browser(principal, authentication, surface, ip) do
    new(principal,
      authn: %{
        "surface" => surface,
        "provider_id" => authentication["provider_id"],
        "provider_scope" => authentication["provider_scope"],
        "amr" => authentication["amr"] || [],
        "authenticated_at" => authentication["authenticated_at"],
        "challenge_started_at" => time(authentication["challenge_started_at"]),
        "ip" => ip
      }
    )
  end

  def from_evidence(principal, proof, surface, ip) do
    new(principal,
      authn: %{
        "surface" => surface,
        "ip" => ip,
        "provider_id" => proof.provider_id,
        "provider_scope" => Atom.to_string(proof.scope),
        "amr" => proof.amr,
        "authenticated_at" => DateTime.to_unix(proof.authenticated_at),
        "challenge_started_at" => time(proof.challenge_started_at)
      }
    )
  end

  defp time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp time(value), do: value

  def request_context(%__MODULE__{authn: authn}),
    do: Map.merge(Map.take(authn, ["surface", "ip"]), %{"authn" => authn})
end
