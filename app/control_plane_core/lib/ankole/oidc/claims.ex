defmodule Ankole.OIDC.Claims do
  @moduledoc false
  alias Ankole.Principals

  # FOR SHARE holds the active Human and its profile until the tokens of the
  # grant are minted.
  def load(subject) do
    case Principals.lock_active_human_in_tx(Ankole.Repo, subject) do
      {:ok, %{principal: principal, human_user: human}} -> {:ok, principal, human}
      {:error, _reason} -> {:error, :inactive_human}
    end
  end

  def project(principal, human, scope) when is_binary(scope) do
    names = String.split(scope, " ", trim: true)

    %{}
    |> profile(names, principal, human)
    |> email(names, human)
  end

  defp profile(claims, names, principal, human) do
    if "profile" in names do
      claims
      |> put("name", principal.display_name)
      |> put("preferred_username", human.email || principal.uid)
      |> put("picture", principal.avatar_url)
    else
      claims
    end
  end

  defp email(claims, names, human),
    do: if("email" in names, do: put(claims, "email", human.email), else: claims)

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
