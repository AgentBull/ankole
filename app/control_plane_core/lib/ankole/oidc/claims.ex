defmodule Ankole.OIDC.Claims do
  @moduledoc false
  alias Ankole.Principals.Domain, as: Principals

  # Principals owns these rows. FOR SHARE holds the active Human and its
  # profile until the tokens of the grant are minted.
  def load(subject) do
    Ankole.LockOrder.with_identity({"principals", subject}, fn ->
      with [principal] <-
             Principals.list_principals!(
               query: [filter: [uid: subject, type: :human, status: :active], lock: "FOR SHARE"]
             ),
           %{} = human <- Principals.get_human_user!(subject, query: [lock: "FOR SHARE"]) do
        {:ok, principal, human}
      else
        _missing -> {:error, :inactive_human}
      end
    end)
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
