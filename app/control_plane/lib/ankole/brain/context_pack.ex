defmodule Ankole.Brain.ContextPack do
  @moduledoc """
  Zero-model context assembly for conversation starts and compaction, plus
  the per-turn volunteer pointer.

  Both run the full two-layer filtering with the Agent as querier and the
  current present members as disclosure recipients. The control plane owns
  the structural caps (entity cards, facts per card, open threads) and the
  filtering; the Worker renders the final injection text and enforces the
  token budget on that rendered text, because only it knows what the model
  receives. Every failure degrades to an empty result; injection never
  blocks a Turn.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Access
  alias Ankole.Brain.Config
  alias Ankole.Brain.ContextPackStats
  alias Ankole.Brain.Links
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Sanitize
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Repo

  @pack_entity_limit 8
  @pack_facts_per_entity 5
  @open_thread_limit 10
  @pointer_limit 5

  @type disclosure :: Ankole.Brain.Access.disclosure()

  @doc """
  Assembles the conversation context pack: entity cards for participants
  and recently mentioned entities, their high-salience current facts, and
  open threads. Zero model calls; any failure returns an empty pack.
  """
  @spec context_pack(String.t(), map(), keyword()) :: map()
  def context_pack(agent_uid, params, opts \\ []) do
    disclosure = Keyword.get(opts, :disclosure, Access.open_disclosure())

    with true <- Config.enabled?(),
         {:ok, access} <- Access.for_readers(agent_uid, disclosure),
         {:ok, visibility} <- LazySkillVisibility.for_querier(agent_uid) do
      forgetting = Config.forgetting()
      now = DateTime.utc_now()

      channel_id = params[:channel_id]

      cards =
        params
        |> pack_entity_slugs(visibility)
        |> Enum.map(&entity_card(&1, access, disclosure, forgetting, now, channel_id, visibility))
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
  rescue
    _error ->
      ContextPackStats.record(:degraded)
      %{entities: [], open_threads: []}
  end

  @doc """
  Builds the entity card of one object: title, type, aliases, selected
  current facts, open threads, edge summary, and backlink count.

  `channel_id` is the conversation the card is built for, or `nil` outside a
  channel; it brings in the claims this entity holds that were filed on that
  channel instead of a page.
  """
  @spec entity_card(String.t(), Access.t(), disclosure(), map(), DateTime.t(), String.t() | nil) ::
          map() | nil
  def entity_card(slug, access, disclosure, forgetting, now, channel_id) do
    entity_card(slug, access, disclosure, forgetting, now, channel_id, %LazySkillVisibility{})
  end

  @spec entity_card(
          String.t(),
          Access.t(),
          disclosure(),
          map(),
          DateTime.t(),
          String.t() | nil,
          LazySkillVisibility.t()
        ) :: map() | nil
  def entity_card(slug, access, disclosure, forgetting, now, channel_id, visibility) do
    case Repo.get_by(Object, slug: slug) do
      nil ->
        nil

      %Object{deleted_at: deleted} when not is_nil(deleted) ->
        nil

      %Object{} = object ->
        if LazySkillVisibility.visible?(visibility, object.slug) do
          facts =
            object.slug
            |> entity_claims(channel_id)
            |> where([claim], claim.claim_type == "fact" and is_nil(claim.expired_at))
            |> Access.filter_claims(access)
            |> LazySkillVisibility.filter_claims(visibility)
            |> order_by([claim], desc: claim.valid_from)
            |> limit(50)
            |> Repo.all()
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
              {text, _matched} = Sanitize.sanitize(claim.claim)
              %{claim: text, kind: claim.kind, holder: claim.holder}
            end)

          aka =
            Ankole.Brain.Schemas.ObjectAlias
            |> where([alias], alias.object_slug == ^object.slug)
            |> limit(5)
            |> select([alias], alias.alias_norm)
            |> Repo.all()

          outgoing =
            Link
            |> where([link], link.from_object_slug == ^object.slug)
            |> LazySkillVisibility.filter_links(visibility)
            |> limit(10)
            |> select([link], {link.link_type, link.to_object_slug})
            |> Repo.all()
            |> Enum.map(fn {link_type, to} -> %{link_type: link_type, to: to} end)

          backlinks =
            Link
            |> where([link], link.to_object_slug == ^object.slug)
            |> LazySkillVisibility.filter_links(visibility)
            |> Repo.aggregate(:count)

          %{
            slug: object.slug,
            title: object.title,
            type: object.type,
            subtype: object.subtype,
            aka: aka,
            facts: facts,
            edges: outgoing,
            backlink_count: backlinks,
            last_touched: object.salience_touched_at || object.updated_at
          }
        else
          nil
        end
    end
  end

  @doc """
  Zero-model volunteer pointers for one Text Turn: the pages this message
  names by an exact alias. Each pointer is one line of slug, title, and
  type; failures degrade silently to an empty list.

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
      message_text
      |> Links.match_aliases_in_text()
      |> Enum.map(&Repo.get_by(Object, slug: &1))
      |> Enum.filter(&live_object?/1)
      |> Enum.filter(&LazySkillVisibility.visible?(visibility, &1.slug))
      |> Enum.filter(fn object ->
        visible_to_querier?(object, access, disclosure)
      end)
      |> Enum.take(@pointer_limit)
      |> Enum.map(fn object ->
        %{slug: object.slug, title: object.title, type: object.type}
      end)
    else
      _disabled_or_blank -> []
    end
  rescue
    _error -> []
  end

  # An alias survives the soft delete of its page so a restore keeps it, so
  # the pointer path drops the pages a card would also refuse.
  defp live_object?(%Object{deleted_at: nil}), do: true
  defp live_object?(_missing_or_deleted), do: false

  # A pointer names a page (metadata is instance-visible), but pointing at a
  # page with no reachable content for the present recipients would leak the
  # association; require at least one reachable, disclosable chunk or fact.
  # Only the distinct scope values leave the database: the rows themselves
  # (chunk text, embeddings, claim bodies) never load on this per-turn path.
  defp visible_to_querier?(object, access, disclosure) do
    chunk_scopes =
      Ankole.Brain.Schemas.Chunk
      |> where([chunk], chunk.object_id == ^object.id)
      |> Access.filter_chunks(access)
      |> select([chunk], chunk.audience_scope)
      |> distinct(true)
      |> Repo.all()

    Enum.any?(chunk_scopes, &Access.disclosable?(&1, disclosure)) or
      Enum.any?(reachable_claim_scopes(object, access), &Access.disclosable?(&1, disclosure))
  end

  defp reachable_claim_scopes(object, access) do
    Claim
    |> where([claim], claim.object_slug == ^object.slug)
    |> Access.filter_current_claims()
    |> Access.filter_claims(access)
    |> select([claim], claim.audience_scope)
    |> distinct(true)
    |> Repo.all()
  end

  # A claim whose named entity does not resolve is filed on the Turn's
  # channel instead of a page, so a preference learned in conversation can
  # sit in storage that no card reads. The holder's own card is where it
  # belongs: a channel-filed claim held by somebody else is their knowledge,
  # not this entity's.
  defp entity_claims(slug, nil), do: where(Claim, [claim], claim.object_slug == ^slug)

  defp entity_claims(slug, channel_id) do
    where(
      Claim,
      [claim],
      claim.object_slug == ^slug or
        (claim.signal_gateway_channel_id == ^channel_id and claim.holder == ^slug)
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
      |> where([claim], claim.claim_type == "take" and claim.active == true)
      |> where([claim], is_nil(claim.resolved_at))
      |> where([claim], claim.weight >= 0.6)
      |> Access.filter_claims(access)
      |> LazySkillVisibility.filter_claims(visibility)
      |> order_by([claim], desc: claim.weight)
      |> limit(@open_thread_limit)
      |> Repo.all()

    commitments =
      Claim
      |> where([claim], claim.claim_type == "fact" and is_nil(claim.expired_at))
      |> where([claim], claim.kind == "commitment")
      |> Access.filter_claims(access)
      |> LazySkillVisibility.filter_claims(visibility)
      |> order_by([claim], desc: claim.valid_from)
      |> limit(@open_thread_limit)
      |> Repo.all()

    (takes ++ commitments)
    |> Access.filter_disclosable(& &1.audience_scope, disclosure)
    |> Enum.take(@open_thread_limit)
    |> Enum.map(fn claim ->
      {text, _matched} = Sanitize.sanitize(claim.claim)

      %{
        id: claim.id,
        claim: text,
        claim_type: claim.claim_type,
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
