defmodule Ankole.OIDC.Boruta.ResourceOwners do
  @moduledoc false

  @behaviour Boruta.Oauth.ResourceOwners

  import Ecto.Query, warn: false

  alias Ankole.Principals.HumanUser
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Boruta.Oauth.ResourceOwner

  @impl true
  def get_by(sub: sub), do: load(sub)

  @impl true
  def get_by(username: username) do
    case Repo.one(
           from human in HumanUser,
             join: principal in assoc(human, :principal),
             where: human.email == ^String.downcase(String.trim(username)),
             select: {principal, human}
         ) do
      {%Principal{} = principal, %HumanUser{} = human} -> resource_owner(principal, human)
      nil -> {:error, "Resource owner was not found."}
    end
  end

  @impl true
  def check_password(_resource_owner, _password),
    do: {:error, "Resource owner password grant is not supported."}

  # Boruta 2.3.8 unions Client and Resource Owner scopes. Returning no scopes
  # keeps the operator-configured Client as the only scope authority.
  @impl true
  def authorized_scopes(_resource_owner), do: []

  @impl true
  def claims(%ResourceOwner{sub: sub}, scope) do
    case load_profile(sub) do
      {:ok, principal, human} -> project_claims(principal, human, scope)
      {:error, _reason} -> %{}
    end
  end

  @spec load(String.t()) :: {:ok, ResourceOwner.t()} | {:error, String.t()}
  def load(sub) when is_binary(sub) do
    with {:ok, principal, human} <- load_profile(sub) do
      resource_owner(principal, human)
    end
  end

  def load(_sub), do: {:error, "Resource owner was not found."}

  defp load_profile(sub) do
    case Repo.one(
           from principal in Principal,
             join: human in assoc(principal, :human_user),
             where:
               principal.uid == ^sub and principal.type == :human and principal.status == :active,
             select: {principal, human}
         ) do
      {%Principal{} = principal, %HumanUser{} = human} -> {:ok, principal, human}
      nil -> {:error, "Resource owner was not found or is inactive."}
    end
  end

  defp resource_owner(principal, human) do
    {:ok,
     %ResourceOwner{
       sub: principal.uid,
       username: human.email,
       extra_claims: %{}
     }}
  end

  defp project_claims(principal, human, scope) do
    names = String.split(scope || "", " ", trim: true)

    %{}
    |> maybe_put_profile(names, principal, human)
    |> maybe_put_email(names, human)
  end

  defp maybe_put_profile(claims, names, principal, human) do
    if "profile" in names do
      claims
      |> put_if_present("name", principal.display_name)
      |> put_if_present("preferred_username", human.email || principal.uid)
      |> put_if_present("picture", principal.avatar_url)
    else
      claims
    end
  end

  defp maybe_put_email(claims, names, human) do
    if "email" in names, do: put_if_present(claims, "email", human.email), else: claims
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
