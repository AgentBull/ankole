defmodule Ankole.Brain.AppletTakes do
  @moduledoc "Source-scoped Takes and calibration for Applet callers."
  require Ash.Query
  alias Ankole.AuthZ.Actor
  alias Ankole.Brain.{Access, Calibration, Claims, Config, Objects, RequestContext, Scope}
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Pod.Access, as: PodAccess
  alias Ankole.Pod.Pages
  alias Ankole.Repo
  alias Ankole.Sessions.{JobTurnRef, RunRef}

  @max_list 100
  @max_calibration 10_000

  def list(%Actor{} = actor, options) when is_map(options) do
    with limit when is_integer(limit) and limit in 1..@max_list <-
           Map.get(options, "limit", 50) do
      read(actor, options, fn query ->
        with {:ok, takes} <-
               query
               |> Ash.Query.sort(created_at: :desc, id: :desc)
               |> Ash.Query.limit(limit)
               |> Ash.Query.deselect(:embedding)
               |> Ankole.Ash.read() do
          {:ok, %{takes: Enum.map(takes, &payload/1)}}
        end
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def list(_actor, _options), do: {:error, :invalid_request}

  def calibration(%Actor{} = actor, options) when is_map(options) do
    with :ok <- optional_text(options["domain"]) do
      read(actor, options, fn query ->
        with {:ok, takes} <-
               query
               |> Ash.Query.filter(resolved_quality in ["correct", "incorrect"])
               |> filter_domain(options["domain"])
               |> Ash.Query.select([:weight, :resolved_outcome])
               |> Ash.Query.limit(@max_calibration + 1)
               |> Ankole.Ash.read() do
          score(takes)
        end
      end)
    end
  end

  def calibration(_actor, _options), do: {:error, :invalid_request}

  def write(%Actor{} = actor, options) when is_map(options) do
    with :ok <- enabled(),
         {:ok, source_id, subject_id} <- scope_ids(options) do
      PodAccess.write(
        actor.turn_authority,
        fn ->
          with {:ok, _} <- Pages.authorize(actor, source_id, "node_contribute"),
               {:ok, access} <- access(actor),
               :ok <- visible(access, source_id),
               :ok <- visible(access, subject_id),
               {:ok, holder} <- Scope.canonical_page_id(Actor.uid(actor)),
               {:ok, take} <-
                 Claims.write_take(
                   %{
                     source_node_id: source_id,
                     subject_page_id: subject_id,
                     holder: holder,
                     claim: options["claim"],
                     kind: options["kind"],
                     weight: options["weight"],
                     since_date: options["sinceDate"],
                     until_date: options["untilDate"],
                     provenance: options["provenance"]
                   },
                   actor,
                   embed: false
                 ) do
            {:ok, payload(take)}
          end
        end,
        shared_tree: true
      )
    end
  end

  def write(_actor, _options), do: {:error, :invalid_request}

  defp read(actor, options, run) do
    with :ok <- enabled(),
         {:ok, source_id, subject_id} <- scope_ids(options),
         :ok <- optional_text(options["kind"]) do
      Repo.transact_repeatable_read_only(fn ->
        with {:ok, access} <- access(actor),
             :ok <- visible(access, source_id),
             :ok <- visible(access, subject_id),
             {:ok, holders} <- holders(options["holderUid"]) do
          Claim
          |> Ash.Query.filter(claim_type == :take and source_node_id == ^source_id)
          |> Access.filter_claims(access)
          |> filter_subject(subject_id)
          |> filter_kind(options["kind"])
          |> filter_holders(holders)
          |> run.()
        end
      end)
    end
  end

  defp enabled, do: if(Config.enabled?(), do: :ok, else: {:error, :brain_disabled})

  defp access(actor) do
    with {:ok, disclosure} <- disclosure(actor.turn_authority) do
      Access.for_context(%{
        querier_uid: Actor.uid(actor),
        authn: actor.authn,
        disclosure: disclosure
      })
    end
  end

  defp disclosure({ref, _uid}) when is_struct(ref, RunRef) or is_struct(ref, JobTurnRef) do
    with {:ok, context} <- RequestContext.build(ref.agent_uid, %{"signal_id" => ref.signal_id}),
         do: {:ok, context.disclosure}
  end

  defp disclosure(_authority), do: {:ok, Access.open_disclosure()}

  defp visible(_access, nil), do: :ok

  defp visible(access, id) do
    if Access.visible?(access, id), do: :ok, else: {:error, :not_found}
  end

  defp scope_ids(options) do
    with {:ok, source_id} <- uuid(options["sourceNodeId"]),
         {:ok, subject_id} <- optional_uuid(options["subjectPageId"]) do
      {:ok, source_id, subject_id}
    end
  end

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(id), do: uuid(id)

  defp uuid(id) when is_binary(id) and byte_size(id) == 36 do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_request}
    end
  end

  defp uuid(_id), do: {:error, :invalid_request}

  defp optional_text(nil), do: :ok
  defp optional_text(text) when is_binary(text) and text != "", do: :ok
  defp optional_text(_value), do: {:error, :invalid_request}

  defp holders(nil), do: {:ok, nil}

  defp holders(uid) when is_binary(uid) and uid != "" do
    with {:ok, slug} <- Scope.canonical_slug(uid),
         {:ok, page} <- Objects.get_by_slug(slug, select: [:id]) do
      {:ok, [page.id, slug]}
    else
      {:error, :not_found} -> {:ok, []}
      error -> error
    end
  end

  defp holders(_uid), do: {:error, :invalid_request}

  defp filter_subject(query, nil), do: query
  defp filter_subject(query, id), do: Ash.Query.filter(query, subject_page_id == ^id)
  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind), do: Ash.Query.filter(query, kind == ^kind)
  defp filter_holders(query, nil), do: query
  defp filter_holders(query, holders), do: Ash.Query.filter(query, holder in ^holders)
  defp filter_domain(query, nil), do: query

  defp filter_domain(query, name),
    do: Ash.Query.filter(query, exists(take_domains, domain == ^name))

  defp score([]), do: {:ok, %{resolvedCount: 0, brier: nil}}

  defp score(takes) do
    count = length(takes)

    if count > @max_calibration,
      do: {:error, :calibration_scope_too_large},
      else: {:ok, %{resolvedCount: count, brier: Calibration.brier(takes)}}
  end

  defp payload(take) do
    %{
      id: take.id,
      sourceNodeId: take.source_node_id,
      subjectPageId: take.subject_page_id,
      holder: take.holder,
      author: take.author,
      claim: take.claim,
      kind: take.kind,
      weight: take.weight,
      active: take.active,
      sinceDate: take.since_date,
      untilDate: take.until_date && Date.to_iso8601(take.until_date),
      provenance: take.provenance,
      createdAt: take.created_at,
      resolvedAt: take.resolved_at,
      resolvedQuality: take.resolved_quality,
      resolvedOutcome: take.resolved_outcome,
      resolutionProvenance: take.resolution_provenance,
      supersededBy: take.superseded_by
    }
  end
end
