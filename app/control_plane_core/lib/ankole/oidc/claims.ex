defmodule Ankole.OIDC.Claims do
  @moduledoc false
  import Ecto.Query
  alias Ankole.Principals.{HumanUser, Principal}
  alias Ankole.Repo

  def load(subject) do
    case Repo.one(
           from(p in Principal,
             join: h in HumanUser,
             on: h.principal_uid == p.uid,
             where: p.uid == ^subject and p.type == :human and p.status == :active,
             lock: "FOR SHARE",
             select: {p, h}
           ),
           lock_identity: {"principals", subject}
         ) do
      {principal, human} -> {:ok, principal, human}
      nil -> {:error, :inactive_human}
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
