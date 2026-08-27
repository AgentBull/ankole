defmodule Ankole.Brain.Scope do
  @moduledoc """
  Audience scope values for the Brain knowledge space.

  A scope is a normalized text value: `world`, `group:<principal_groups.name>`,
  or `principal:<principals.uid>`. The prefix is part of the value, so group
  names and Principal UIDs keep independent namespaces. Group membership is
  resolved against current relations at check time; memberships are never
  materialized into memory rows.
  """

  import Ecto.Query, warn: false

  alias Ankole.AuthZ
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @type t :: String.t()

  @doc "The scope every recipient can receive."
  @spec world() :: t()
  def world, do: "world"

  @doc "Builds a group scope value."
  @spec group(String.t()) :: t()
  def group(name) when is_binary(name), do: "group:" <> name

  @doc "Builds a principal scope value."
  @spec principal(String.t()) :: t()
  def principal(uid) when is_binary(uid), do: "principal:" <> uid

  @doc """
  Parses a scope value into its structured form.
  """
  @spec parse(term()) ::
          {:ok, :world | {:group, String.t()} | {:principal, String.t()}}
          | {:error, :invalid_audience_scope}
  def parse("world"), do: {:ok, :world}
  def parse("group:" <> name) when name != "", do: {:ok, {:group, name}}
  def parse("principal:" <> uid) when uid != "", do: {:ok, {:principal, uid}}
  def parse(_value), do: {:error, :invalid_audience_scope}

  @doc """
  Validates that a scope is well-formed and refers to an existing Group or
  Principal. `world` always validates.
  """
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(scope) do
    case parse(scope) do
      {:ok, :world} ->
        :ok

      {:ok, {:group, name}} ->
        case AuthZ.get_principal_group(name) do
          {:ok, _group} -> :ok
          {:error, :not_found} -> {:error, {:unknown_scope_group, name}}
        end

      {:ok, {:principal, uid}} ->
        case Principals.get_principal(uid) do
          {:ok, _principal} -> :ok
          {:error, _reason} -> {:error, {:unknown_scope_principal, uid}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Returns whether one Principal currently satisfies a scope.

  The rule is shared by reads and writes: `world` accepts every Principal, a
  principal scope only its own Principal, and a group scope the current group
  members resolved at check time.
  """
  @spec satisfied_by?(t(), String.t()) :: boolean()
  def satisfied_by?(scope, principal_uid) when is_binary(principal_uid) do
    case parse(scope) do
      {:ok, :world} ->
        true

      {:ok, {:principal, uid}} ->
        uid == principal_uid

      {:ok, {:group, name}} ->
        case AuthZ.get_principal_group(name) do
          {:ok, group} -> AuthZ.principal_in_group?(principal_uid, group)
          {:error, :not_found} -> false
        end

      {:error, _reason} ->
        false
    end
  end

  @doc """
  Validates write eligibility for one scope and writer.

  `world` accepts every writer. A principal scope requires the target
  Principal to exist; the writer does not have to match it. A group scope
  requires the writer to currently satisfy it: a Principal can file knowledge
  into its own organizational ranges but cannot claim a range it does not
  belong to. Owner read exemptions never extend writes.
  """
  @spec validate_writable(term(), String.t()) :: :ok | {:error, term()}
  def validate_writable(scope, writer_uid) when is_binary(writer_uid) do
    case parse(scope) do
      {:ok, :world} ->
        :ok

      {:ok, {:principal, uid}} ->
        case Principals.get_principal(uid) do
          {:ok, _principal} -> :ok
          {:error, _reason} -> {:error, {:unknown_scope_principal, uid}}
        end

      {:ok, {:group, name}} ->
        case AuthZ.get_principal_group(name) do
          {:ok, group} ->
            if AuthZ.principal_in_group?(writer_uid, group),
              do: :ok,
              else: {:error, {:writer_not_in_scope_group, name}}

          {:error, :not_found} ->
            {:error, {:unknown_scope_group, name}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Returns the enumerable scope values one querier can reach.

  The set is `world`, `principal:<own uid>`, and one `group:<name>` for every
  group the querier currently belongs to, including computed groups. The
  values feed SQL predicates directly, so knowledge-boundary filtering is a
  prefilter instead of a post-hit filter. Author accessibility is a separate
  predicate owned by the query layer.
  """
  @spec accessible_scopes(String.t()) :: {:ok, [t()]} | {:error, term()}
  def accessible_scopes(principal_uid) when is_binary(principal_uid) do
    with {:ok, uid} <- Principals.normalize_uid(principal_uid),
         {:ok, groups} <- AuthZ.list_current_groups_for_principal(uid) do
      {:ok, [world(), principal(uid) | Enum.map(groups, &group(&1.name))]}
    end
  end

  @doc """
  Returns whether every listed Principal satisfies one scope. Strict
  group-chat disclosure asks this over the present-member set; a static
  group resolves the whole set with one membership query.
  """
  @spec satisfied_by_all?(t(), [String.t()]) :: boolean()
  def satisfied_by_all?(scope, principal_uids) when is_list(principal_uids) do
    case parse(scope) do
      {:ok, :world} ->
        true

      {:ok, {:principal, uid}} ->
        Enum.all?(principal_uids, &(&1 == uid))

      {:ok, {:group, name}} ->
        case AuthZ.get_principal_group(name) do
          {:ok, group} -> AuthZ.all_in_group?(principal_uids, group)
          {:error, :not_found} -> false
        end

      {:error, _reason} ->
        false
    end
  end

  @doc """
  Returns the canonical Object slug of one Principal: `people/<uid>` for
  humans and `agents/<uid>` for Agents.
  """
  @spec canonical_slug(String.t()) :: {:ok, String.t()} | {:error, term()}
  def canonical_slug(principal_uid) do
    with {:ok, uid} <- Principals.normalize_uid(principal_uid) do
      case Repo.one(from p in Principal, where: p.uid == ^uid, select: p.type) do
        :human -> {:ok, "people/" <> uid}
        :agent -> {:ok, "agents/" <> uid}
        :system -> {:error, {:no_canonical_object, uid}}
        nil -> {:error, {:unknown_principal, uid}}
      end
    end
  end
end
