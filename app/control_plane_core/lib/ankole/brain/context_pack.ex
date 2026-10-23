defmodule Ankole.Brain.ContextPack do
  @moduledoc """
  Zero-model context assembly for conversation starts and compaction, plus
  the per-turn volunteer pointer.

  Both run the full two-layer filtering with the Agent as querier and the
  current present members as disclosure recipients. This module owns the
  structural caps (entity cards, facts per card, open threads) and the
  filtering; the hosted Brain tool renders the injection text and enforces
  the token budget on it. Every failure degrades to an empty result;
  injection never blocks a Turn.
  """

  require Ash.Query

  alias Ankole.Brain.Access
  alias Ankole.Brain.Config
  alias Ankole.Brain.ContextPackStats
  alias Ankole.Brain.Links
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Logging

  @pack_entity_limit 8
  @pack_facts_per_entity 5
  @open_thread_limit 10
  @pointer_limit 5

  @type disclosure :: Ankole.Brain.Access.disclosure()

  @doc """
  Assembles the conversation context pack: entity cards for participants
  and recently mentioned entities, their high-salience current facts, and
  open threads. Cards contain only the fields used by injection.
  Zero model calls; any failure returns an empty pack.
  """
  @spec context_pack(String.t(), map(), keyword()) :: map()
  def context_pack(agent_uid, params, opts \\ []) do
    disclosure = Keyword.get(opts, :disclosure, Access.open_disclosure())

    with true <- Config.enabled?(),
         {:ok, access} <- Access.for_readers(agent_uid, disclosure),
         {:ok, visibility} <- LazySkillVisibility.for_querier(agent_uid) do
      forgetting = Config.forgetting()
      now = DateTime.utc_now()

      conversation_id = params[:conversation_id]

      cards =
        params
        |> pack_entity_slugs(visibility)
        |> Enum.map(
          &base_card(&1, access, disclosure, forgetting, now, conversation_id, visibility)
        )
        |> Enum.reject(&is_nil/1)

      ContextPackStats.record(:served)

      %{
        entities: cards,
        open_threads: open_threads(access, disclosure, visibility)
      }
    else
      false ->
        %{entities: [], open_threads: []}

      _error ->
        ContextPackStats.record(:degraded)
        %{entities: [], open_threads: []}
    end
  catch
    :error, reason ->
      ContextPackStats.record(:degraded)

      Logging.warning(
        "brain.context_pack.failed",
        "Brain context assembly failed; the Turn continues without it",
        Map.put(Logging.failure_fields(:error, reason, __STACKTRACE__), :agent_uid, agent_uid)
      )

      %{entities: [], open_threads: []}
  end

  @doc """
  Builds the entity card of one object: title, type, aliases, selected
  current facts, open threads, edge summary, and backlink count.

  `conversation_id` is the conversation the card is built for, or `nil` outside a
  channel; it brings in the claims this entity holds that were filed on that
  channel instead of a page.
  """
  @spec entity_card(
          String.t(),
          Access.t(),
          disclosure(),
          map(),
          DateTime.t(),
          String.t() | nil,
          LazySkillVisibility.t()
        ) :: map() | nil
  def entity_card(slug, access, disclosure, forgetting, now, conversation_id, visibility) do
    case base_card(slug, access, disclosure, forgetting, now, conversation_id, visibility) do
      nil ->
        nil

      card ->
        aka =
          ObjectAlias
          |> Ash.Query.filter(object_slug == ^card.slug)
          |> Ash.Query.limit(5)
          |> Ash.Query.select([:alias_norm])
          |> Ankole.Ash.read!()
          |> Enum.map(& &1.alias_norm)

        outgoing =
          Link
          |> Ash.Query.filter(from_object_slug == ^card.slug)
          |> LazySkillVisibility.filter_links(visibility)
          |> Ash.Query.limit(10)
          |> Ash.Query.select([:link_type, :to_object_slug])
          |> Ankole.Ash.read!()
          |> Enum.map(&%{link_type: &1.link_type, to: &1.to_object_slug})

        backlinks =
          Link
          |> Ash.Query.filter(to_object_slug == ^card.slug)
          |> LazySkillVisibility.filter_links(visibility)
          |> Ankole.Ash.aggregate!({:count, :count})
          |> Map.fetch!(:count)

        Map.merge(card, %{aka: aka, edges: outgoing, backlink_count: backlinks})
    end
  end

  defp base_card(slug, access, disclosure, forgetting, now, conversation_id, visibility) do
    case Objects.get_by_slug(slug) do
      {:error, :not_found} ->
        nil

      {:ok, %Object{deleted_at: deleted}} when not is_nil(deleted) ->
        nil

      {:ok, %Object{} = object} ->
        if LazySkillVisibility.visible?(visibility, object.slug) do
          facts =
            object.slug
            |> entity_claims(conversation_id)
            |> Ash.Query.filter(claim_type == :fact and is_nil(expired_at))
            |> Access.filter_claims(access)
            |> LazySkillVisibility.filter_claims(visibility)
            |> Ash.Query.sort(valid_from: :desc)
            |> Ash.Query.limit(50)
            |> Ankole.Ash.read!()
            |> Access.filter_disclosable(& &1.audience_scope, disclosure)
            |> Enum.sort_by(
              fn claim ->
                notability_rank(claim.notability) +
                  Recall.effective_confidence(claim, forgetting, now)
              end,
              :desc
            )
            |> Enum.take(@pack_facts_per_entity)
            |> Enum.map(fn claim ->
              %{claim: claim.claim, kind: claim.kind, holder: claim.holder}
            end)

          %{
            slug: object.slug,
            title: object.title,
            type: object.type,
            subtype: object.subtype,
            facts: facts,
            last_touched: object.updated_at
          }
        else
          nil
        end
    end
  end

  @doc """
  Zero-model volunteer pointers for one Text Turn: the pages this message
  names by an exact alias. Each pointer is one line of slug, title, and
  type; failures return an empty list and log a warning.

  Only a named page points. A pointer the message did not ask for repeats
  on every Turn of the conversation whether or not it relates to anything,
  which teaches the model to skip the whole block; standing context belongs
  in the context pack, which the conversation start and each compaction
  already carry.
  """
  @spec volunteer_pointers(String.t(), String.t(), keyword()) :: [map()]
  def volunteer_pointers(agent_uid, message_text, opts \\ []) do
    disclosure = Keyword.get(opts, :disclosure, Access.open_disclosure())

    with true <- Config.enabled?(),
         true <- is_binary(message_text) and String.trim(message_text) != "",
         {:ok, access} <- Access.for_readers(agent_uid, disclosure),
         {:ok, visibility} <- LazySkillVisibility.for_querier(agent_uid) do
      slugs = Links.match_aliases_in_text(message_text)

      objects =
        Object
        |> Ash.Query.filter(slug in ^slugs and is_nil(deleted_at))
        |> LazySkillVisibility.filter_objects(visibility)
        |> Ash.Query.sort(slug: :asc)
        |> Ankole.Ash.read!()

      objects
      |> visible_pointer_objects(access, disclosure)
      |> Enum.take(@pointer_limit)
      |> Enum.map(fn object ->
        %{slug: object.slug, title: object.title, type: object.type}
      end)
    else
      _disabled_or_blank -> []
    end
  catch
    :error, reason ->
      Logging.warning(
        "brain.volunteer_pointers.failed",
        "Brain pointer assembly failed; the Turn continues without pointers",
        Map.put(Logging.failure_fields(:error, reason, __STACKTRACE__), :agent_uid, agent_uid)
      )

      []
  end

  # A pointer requires reachable content, not just instance-visible metadata.
  defp visible_pointer_objects([], _access, _disclosure), do: []

  defp visible_pointer_objects(objects, access, disclosure) do
    ids = Enum.map(objects, & &1.id)
    slugs = Enum.map(objects, & &1.slug)
    by_id = Map.new(objects, &{&1.id, &1.slug})

    chunk_scopes =
      Chunk
      |> Ash.Query.filter(object_id in ^ids)
      |> Access.filter_chunks(access)
      |> Ash.Query.distinct([:object_id, :audience_scope])
      |> Ash.Query.select([:object_id, :audience_scope])
      |> Ankole.Ash.read!()
      |> Enum.map(&{Map.fetch!(by_id, &1.object_id), &1.audience_scope})

    claim_scopes =
      Claim
      |> Ash.Query.filter(object_slug in ^slugs)
      |> Access.filter_current_claims()
      |> Access.filter_claims(access)
      |> Ash.Query.distinct([:object_slug, :audience_scope])
      |> Ash.Query.select([:object_slug, :audience_scope])
      |> Ankole.Ash.read!()
      |> Enum.map(&{&1.object_slug, &1.audience_scope})

    visible =
      (chunk_scopes ++ claim_scopes)
      |> Enum.filter(fn {_slug, scope} -> Access.disclosable?(scope, disclosure) end)
      |> MapSet.new(fn {slug, _scope} -> slug end)

    Enum.filter(objects, &MapSet.member?(visible, &1.slug))
  end

  # A claim whose named entity does not resolve is filed on the Turn's
  # channel instead of a page, so a preference learned in conversation can
  # sit in storage that no card reads. The holder's own card is where it
  # belongs: a channel-filed claim held by somebody else is their knowledge,
  # not this entity's.
  defp entity_claims(slug, nil), do: Ash.Query.filter(Claim, object_slug == ^slug)

  defp entity_claims(slug, conversation_id) do
    Ash.Query.filter(
      Claim,
      object_slug == ^slug or (conversation_id == ^conversation_id and holder == ^slug)
    )
  end

  defp pack_entity_slugs(params, visibility) do
    participant_slugs =
      params
      |> Map.get(:participant_uids, [])
      |> Enum.map(fn uid ->
        case Ankole.Brain.Scope.canonical_slug(uid) do
          {:ok, slug} -> slug
          {:error, _reason} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    mentioned_slugs =
      params
      |> Map.get(:recent_text, "")
      |> Links.match_aliases_in_text()

    (participant_slugs ++ mentioned_slugs)
    |> Enum.uniq()
    |> Enum.filter(&LazySkillVisibility.visible?(visibility, &1))
    |> Enum.take(@pack_entity_limit)
  end

  # Open threads: unresolved high-weight takes plus unclosed commitments.
  defp open_threads(access, disclosure, visibility) do
    takes =
      Claim
      |> Ash.Query.filter(claim_type == :take and active == true and is_nil(resolved_at))
      |> Ash.Query.filter(weight >= 0.6)
      |> Access.filter_claims(access)
      |> LazySkillVisibility.filter_claims(visibility)
      |> Ash.Query.sort(weight: :desc)
      |> Ash.Query.limit(@open_thread_limit)
      |> Ankole.Ash.read!()

    commitments =
      Claim
      |> Ash.Query.filter(claim_type == :fact and is_nil(expired_at) and kind == "commitment")
      |> Access.filter_claims(access)
      |> LazySkillVisibility.filter_claims(visibility)
      |> Ash.Query.sort(valid_from: :desc)
      |> Ash.Query.limit(@open_thread_limit)
      |> Ankole.Ash.read!()

    (takes ++ commitments)
    |> Access.filter_disclosable(& &1.audience_scope, disclosure)
    |> Enum.take(@open_thread_limit)
    |> Enum.map(fn claim ->
      %{
        id: claim.id,
        claim: claim.claim,
        claim_type: Atom.to_string(claim.claim_type),
        kind: claim.kind,
        holder: claim.holder,
        weight: claim.weight,
        object_slug: claim.object_slug
      }
    end)
  end

  defp notability_rank("high"), do: 2.0
  defp notability_rank("medium"), do: 1.0
  defp notability_rank(_low), do: 0.0
end
