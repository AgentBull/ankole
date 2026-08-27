defmodule Ankole.Brain.Access do
  @moduledoc """
  Knowledge-boundary context of one querier, applied as SQL prefilters.

  The reachable set is the querier's enumerable scope values plus the
  author-always-accessible rule, plus the narrowed Agent-owner exemption:
  an owner reads its Agents' `principal:<agent_uid>` scope and the rows its
  Agents wrote or hold, but never the Agents' group-shared knowledge.
  Disclosure filtering is a second, post-hit stage owned by the caller.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Scope
  alias Ankole.Principals.Agent
  alias Ankole.Repo

  defstruct querier_uid: nil, scopes: [], owned_agent_uids: [], owned_holder_slugs: []

  @type t :: %__MODULE__{
          querier_uid: String.t(),
          scopes: [String.t()],
          owned_agent_uids: [String.t()],
          owned_holder_slugs: [String.t()]
        }

  @doc """
  Builds the access context of one querier from current relations.
  """
  @spec for_querier(String.t()) :: {:ok, t()} | {:error, term()}
  def for_querier(querier_uid) when is_binary(querier_uid) do
    with {:ok, scopes} <- Scope.accessible_scopes(querier_uid) do
      owned_agent_uids =
        Agent
        |> where([agent], agent.owner_principal_uid == ^querier_uid)
        |> select([agent], agent.uid)
        |> Repo.all()

      {:ok,
       %__MODULE__{
         querier_uid: querier_uid,
         scopes: Enum.uniq(scopes ++ Enum.map(owned_agent_uids, &Scope.principal/1)),
         owned_agent_uids: owned_agent_uids,
         owned_holder_slugs: Enum.map(owned_agent_uids, &("agents/" <> &1))
       }}
    end
  end

  @doc """
  Returns whether one already-loaded row is reachable for this querier.

  Reachable rows satisfy an accessible scope, were written by the querier
  (authors always reach their own writes), or fall under the narrowed owner
  exemption: rows an owned Agent wrote or holds, except group-scoped
  organizational knowledge, which an owner cannot reach through its Agent.
  """
  @spec reachable?(t(), %{
          required(:audience_scope) => String.t(),
          optional(:author_uid) => String.t() | nil,
          optional(:holder) => String.t() | nil
        }) :: boolean()
  def reachable?(%__MODULE__{} = access, row) do
    scope = row.audience_scope
    author = Map.get(row, :author_uid)
    holder = Map.get(row, :holder)

    scope in access.scopes or author == access.querier_uid or
      ((author in access.owned_agent_uids or holder in access.owned_holder_slugs) and
         not String.starts_with?(scope, "group:"))
  end

  @doc """
  Applies the claim knowledge boundary and current-state predicates to a
  claims query. Internal terminal claims stay out of every read path.
  """
  @spec filter_claims(Ecto.Query.t(), t()) :: Ecto.Query.t()
  def filter_claims(query, %__MODULE__{} = access) do
    internal_prefix = Claims.internal_provenance_prefix() <> "%"

    query
    |> where(
      [claim],
      claim.audience_scope in ^access.scopes or
        claim.author_uid == ^access.querier_uid or
        ((claim.author_uid in ^access.owned_agent_uids or
            claim.holder in ^access.owned_holder_slugs) and
           not like(claim.audience_scope, "group:%"))
    )
    |> where([claim], not like(claim.provenance, ^internal_prefix))
  end

  @doc """
  Restricts a claims query to the current state: unexpired facts and active
  takes.
  """
  @spec filter_current_claims(Ecto.Query.t()) :: Ecto.Query.t()
  def filter_current_claims(query) do
    where(
      query,
      [claim],
      (claim.claim_type == "fact" and is_nil(claim.expired_at)) or
        (claim.claim_type == "take" and claim.active == true)
    )
  end

  @doc """
  Applies the chunk knowledge boundary. Chunks carry no author, so scope is
  the only reachability rule; the join keeps soft-deleted hosts out.
  """
  @spec filter_chunks(Ecto.Query.t(), t()) :: Ecto.Query.t()
  def filter_chunks(query, %__MODULE__{} = access) do
    where(query, [chunk, ...], chunk.audience_scope in ^access.scopes)
  end

  @doc """
  Applies the timeline knowledge boundary as a SQL prefilter, so a `limit`
  never spends its budget on unreachable rows. Timelines carry no holder;
  reachability is scope, author, or the narrowed owner exemption over the
  author.
  """
  @spec filter_timelines(Ecto.Query.t(), t()) :: Ecto.Query.t()
  def filter_timelines(query, %__MODULE__{} = access) do
    where(
      query,
      [timeline],
      timeline.audience_scope in ^access.scopes or
        timeline.author_uid == ^access.querier_uid or
        (timeline.author_uid in ^access.owned_agent_uids and
           not like(timeline.audience_scope, "group:%"))
    )
  end

  @typedoc """
  Disclosure context: who receives the recalled knowledge. Strict mode
  checks the asker and every present member; relaxed mode checks only the
  asker. A private chat carries only the asker, so both modes behave the
  same there. A missing asker (Console preview, system assembly) protects
  no recipient beyond the querier's own knowledge boundary.
  """
  @type disclosure :: %{
          mode: :strict | :relaxed,
          asker_uid: String.t() | nil,
          present_uids: [String.t()]
        }

  @doc """
  Post-hit disclosure check for one scope against the current recipients.
  """
  @spec disclosable?(String.t(), disclosure()) :: boolean()
  def disclosable?(scope, %{mode: mode} = disclosure) do
    recipients =
      case mode do
        :relaxed -> List.wrap(disclosure[:asker_uid])
        :strict -> List.wrap(disclosure[:asker_uid]) ++ (disclosure[:present_uids] || [])
      end

    case Enum.uniq(recipients) do
      [] -> true
      recipients -> Scope.satisfied_by_all?(scope, recipients)
    end
  end

  @doc """
  Keeps the rows whose scope is disclosable to the current recipients.

  One call evaluates each distinct scope once, so a result set full of hits
  from the same few scopes costs a handful of membership resolutions instead
  of one per row.
  """
  @spec filter_disclosable([row], (row -> String.t()), disclosure()) :: [row] when row: term()
  def filter_disclosable(rows, scope_fun, disclosure) when is_function(scope_fun, 1) do
    verdicts =
      rows
      |> Enum.map(scope_fun)
      |> Enum.uniq()
      |> Map.new(&{&1, disclosable?(&1, disclosure)})

    Enum.filter(rows, &Map.fetch!(verdicts, scope_fun.(&1)))
  end

  @doc """
  The empty disclosure context: no recipients beyond the querier.
  """
  @spec open_disclosure() :: disclosure()
  def open_disclosure, do: %{mode: :relaxed, asker_uid: nil, present_uids: []}
end
