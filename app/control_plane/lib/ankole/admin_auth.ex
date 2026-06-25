defmodule Ankole.AdminAuth do
  @moduledoc """
  Coarse "is this caller a platform admin?" gate for operator-only surfaces.

  This sits in front of the finer-grained `Ankole.AuthZ` permission grants: the
  console and other operator endpoints use it as a blunt yes/no before they even
  consider per-resource authorization.
  """

  import Ecto.Query

  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  # The built-in admin group is identified by this reserved name. The query below
  # also pins `built_in == true` and `kind == :static` so a human-created group
  # that merely happens to be named "admin" can never grant admin power.
  @admin_group_name "admin"

  @doc """
  Returns true when the principal is an active human member of the built-in admin group.
  """
  @spec active_human_admin?(String.t()) :: boolean()
  def active_human_admin?(principal_uid) do
    # `type == :human` deliberately excludes agent principals: agents never get
    # operator admin even if added to the group. `status == :active` denies a
    # suspended/disabled human without having to scrub group memberships. A
    # malformed uid normalizes to an error and is treated as "not admin".
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
