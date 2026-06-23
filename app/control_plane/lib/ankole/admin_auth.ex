defmodule Ankole.AdminAuth do
  @moduledoc """
  Admin-session authorization checks.
  """

  import Ecto.Query

  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @admin_group_name "admin"

  @doc """
  Returns true when the principal is an active human member of the built-in admin group.
  """
  @spec active_human_admin?(String.t()) :: boolean()
  def active_human_admin?(principal_uid) do
    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid) do
      Repo.exists?(
        from membership in Membership,
          join: group in Group,
          on: group.id == membership.group_id,
          join: principal in Principal,
          on: principal.uid == membership.principal_uid,
          where:
            membership.principal_uid == ^principal_uid and group.name == ^@admin_group_name and
              group.built_in == true and group.kind == :static and principal.type == :human and
              principal.status == :active
      )
    else
      {:error, _reason} -> false
    end
  end
end
