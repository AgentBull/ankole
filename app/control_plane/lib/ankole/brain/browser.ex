defmodule Ankole.Brain.Browser do
  @moduledoc "The member's visible Brain ontology, semantic graph, and personal memory surface."
  use Ankole.Ash.OperationResource,
    domain: Ankole.Brain,
    authorizers: [Ankole.AuthZ.Authorizer],
    extensions: [Ankole.AuthZ.Extension]

  alias Ankole.Ash.Types.UUIDv7

  @claim_fields [
    id: [type: UUIDv7, allow_nil?: false],
    claim_type: [type: :string, allow_nil?: false],
    claim: [type: :string, allow_nil?: false],
    kind: [type: :string, allow_nil?: false],
    holder: [type: :string, allow_nil?: false],
    source_node_id: [type: UUIDv7, allow_nil?: false],
    source_title: [type: :string, allow_nil?: true],
    subject_page_id: [type: UUIDv7, allow_nil?: true],
    subject_title: [type: :string, allow_nil?: true],
    subject_slug: [type: :string, allow_nil?: true],
    bucket: [type: :string, allow_nil?: false],
    notability: [type: :string, allow_nil?: true],
    confidence: [type: :float, allow_nil?: true],
    weight: [type: :float, allow_nil?: true],
    provenance: [type: :string, allow_nil?: false],
    created_at: [type: :utc_datetime_usec, allow_nil?: false],
    can_edit: [type: :boolean, allow_nil?: false],
    can_forget: [type: :boolean, allow_nil?: false]
  ]

  authz do
    scope(:pod)
    allow(:graph, check: :guardrail)
    allow(:node_claims, check: :guardrail)
    allow(:my_context, check: :guardrail)
    allow(:add_my_fact, check: :guardrail)
    allow(:supersede_my_claim, check: :guardrail)
    allow(:forget_my_claim, check: :guardrail)
  end

  json_api do
    type("meta_brain")
  end

  actions do
    action :graph, :map do
      transaction?(false)

      constraints(
        fields: [
          viewer_uid: [type: :string, allow_nil?: false],
          assistant_uid: [type: :string, allow_nil?: true],
          categories: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  id: [type: UUIDv7, allow_nil?: false],
                  name: [type: :string, allow_nil?: false],
                  entity_type: [type: :string, allow_nil?: false],
                  primitive: [type: :string, allow_nil?: false],
                  can_edit: [type: :boolean, allow_nil?: false]
                ]
              ]
            ]
          ],
          nodes: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  id: [type: UUIDv7, allow_nil?: false],
                  title: [type: :string, allow_nil?: false],
                  slug: [type: :string, allow_nil?: false],
                  type: [type: :string, allow_nil?: false],
                  subtype: [type: :string, allow_nil?: true],
                  parent_id: [type: UUIDv7, allow_nil?: true]
                ]
              ]
            ]
          ],
          links: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  from_page_id: [type: UUIDv7, allow_nil?: false],
                  to_page_id: [type: UUIDv7, allow_nil?: false],
                  link_type: [type: :string, allow_nil?: false],
                  relation_kind: [type: :string, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :node_claims, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)

      constraints(
        fields: [
          claims: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @claim_fields]]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :my_context, :map do
      transaction?(false)

      constraints(
        fields: [
          viewer_uid: [type: :string, allow_nil?: false],
          assistant_uid: [type: :string, allow_nil?: true],
          canonical_page_id: [type: UUIDv7, allow_nil?: true],
          claims: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @claim_fields]]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :add_my_fact, :map do
      transaction?(false)
      argument(:claim, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:kind, :string, default: "preference")
      argument(:notability, :string, default: "medium")

      constraints(
        fields: [
          status: [type: :string, allow_nil?: false],
          claim: [type: :map, allow_nil?: false, constraints: [fields: @claim_fields]]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :supersede_my_claim, :map do
      transaction?(false)
      argument(:claim_id, UUIDv7, allow_nil?: false)
      argument(:claim, :string, allow_nil?: false, constraints: [trim?: false])

      constraints(
        fields: [
          claim: [type: :map, allow_nil?: false, constraints: [fields: @claim_fields]]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :forget_my_claim, :map do
      transaction?(false)
      argument(:claim_id, UUIDv7, allow_nil?: false)
      argument(:reason, :string, default: "Removed by user in Meta Brain")

      constraints(
        fields: [
          forgotten_id: [type: UUIDv7, allow_nil?: false]
        ]
      )

      run(__MODULE__.Actions)
    end
  end
end

defmodule Ankole.Brain.Browser.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  require Ash.Query
  alias Ankole.Brain.{Access, Claims, Forget, Namespace, Objects, Scope}
  alias Ankole.Brain.Schemas.{Claim, Link, Page, SchemaType, Timeline}
  alias Ankole.Pod.Pages.Tree
  alias Ankole.Repo

  def run(input, _, %{actor: actor}) do
    with :ok <- Ankole.AIAgent.Library.Management.member(actor) do
      dispatch(input.action.name, input.arguments, actor)
    end
    |> Ankole.Pod.APIError.result()
  end

  defp dispatch(:graph, _args, actor) do
    Repo.transact_repeatable_read_only(fn -> graph(actor) end)
  end

  defp dispatch(:node_claims, %{page_id: page_id}, actor) do
    Repo.transact_repeatable_read_only(fn -> node_claims(actor, page_id) end)
  end

  defp dispatch(:my_context, _args, actor) do
    Repo.transact_repeatable_read_only(fn -> my_context(actor) end)
  end

  defp dispatch(:add_my_fact, args, actor) do
    add_my_fact(actor, args)
  end

  defp dispatch(:supersede_my_claim, %{claim_id: claim_id, claim: text}, actor) do
    supersede_my_claim(actor, claim_id, text)
  end

  defp dispatch(:forget_my_claim, %{claim_id: claim_id} = args, actor) do
    forget_my_claim(actor, claim_id, Map.get(args, :reason))
  end

  defp viewer_assistant_uid(uid) do
    case Ankole.Principals.personal_assistant(uid) do
      %{principal: %{uid: assistant_uid}} -> assistant_uid
      %{uid: assistant_uid} -> assistant_uid
      _ -> nil
    end
  end

  defp open_access(actor) do
    Access.for_context(%{
      querier_uid: actor.principal.uid,
      authn: actor.authn,
      disclosure: Access.open_disclosure()
    })
  end

  defp node_claims(actor, page_id) do
    uid = actor.principal.uid

    with {:ok, access} <- open_access(actor),
         true <- Access.visible?(access, page_id) do
      claims =
        Claim
        |> Ash.Query.filter(subject_page_id == ^page_id or source_node_id == ^page_id)
        |> Access.filter_current_claims()
        |> Access.filter_claims(access)
        |> Ash.Query.deselect([:embedding, :embedding_signature, :embedding_error])
        |> Ash.Query.sort(created_at: :desc, id: :desc)
        |> Ash.Query.limit(100)
        |> Ankole.Ash.read!()

      {:ok, %{claims: serialize_claims(claims, uid, access)}}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp my_context(actor) do
    uid = actor.principal.uid
    assistant_uid = viewer_assistant_uid(uid)
    private_scope_id = Scope.principal(uid)

    canonical_id =
      case Scope.canonical_page_id(uid) do
        {:ok, id} -> id
        _ -> nil
      end

    assistant_canonical_id =
      case assistant_uid && Scope.canonical_page_id(assistant_uid) do
        {:ok, id} -> id
        _ -> nil
      end

    pa_dm_ids = Ankole.Conversations.assistant_dm_conversation_ids(uid, assistant_uid)

    pa_dm_root_ids =
      if pa_dm_ids == [],
        do: [],
        else: Ankole.Pod.root_ids_for_conversations(pa_dm_ids)

    source_candidates =
      [private_scope_id | pa_dm_root_ids]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    subject_candidates =
      [canonical_id, assistant_canonical_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    holder_candidates =
      [
        "people/" <> uid,
        canonical_id,
        assistant_uid && "agents/" <> assistant_uid,
        assistant_canonical_id
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    with {:ok, access} <- open_access(actor) do
      query =
        if subject_candidates != [] do
          Ash.Query.filter(
            Claim,
            source_node_id in ^source_candidates or subject_page_id in ^subject_candidates or
              holder in ^holder_candidates
          )
        else
          Ash.Query.filter(
            Claim,
            source_node_id in ^source_candidates or holder in ^holder_candidates
          )
        end

      claims =
        query
        |> Access.filter_current_claims()
        |> Access.filter_claims(access)
        |> Ash.Query.deselect([:embedding, :embedding_signature, :embedding_error])
        |> Ash.Query.sort(created_at: :desc, id: :desc)
        |> Ash.Query.limit(200)
        |> Ankole.Ash.read!()

      {:ok,
       %{
         viewer_uid: uid,
         assistant_uid: assistant_uid,
         canonical_page_id: canonical_id,
         claims: serialize_claims(claims, uid, access)
       }}
    end
  end

  defp add_my_fact(actor, args) do
    uid = actor.principal.uid
    kind = args[:kind] || "preference"
    notability = args[:notability] || "medium"

    with {:ok, canonical_id, private_scope_id} <- ensure_personal_memory_targets(actor),
         {:ok, %{claim: written, status: status}} <-
           Claims.write_fact(
             %{
               claim: args[:claim],
               kind: kind,
               notability: notability,
               confidence: 1.0,
               holder: "people/" <> uid,
               subject_page_id: canonical_id,
               source_node_id: private_scope_id,
               provenance: "user_explicit:meta_brain",
               valid_from: DateTime.utc_now(:microsecond)
             },
             uid
           ),
         {:ok, serialized} <-
           Repo.transact_repeatable_read_only(fn ->
             with {:ok, access} <- open_access(actor) do
               {:ok, hd(serialize_claims([written], uid, access))}
             end
           end) do
      {:ok, %{status: Atom.to_string(status), claim: serialized}}
    end
  end

  defp ensure_personal_memory_targets(actor) do
    uid = actor.principal.uid
    private_scope_id = Scope.principal(uid)

    ready? =
      match?({:ok, _}, Tree.fetch(private_scope_id)) and
        match?({:ok, _}, Scope.canonical_page_id(uid))

    ensure_result =
      if ready? do
        :ok
      else
        case Repo.transact_top_level(
               fn ->
                 Tree.lock_tree()

                 with {:ok, _} <- Ankole.Pod.ensure_private_root_in_tx(uid),
                      :ok <-
                        Objects.ensure_canonical_object_in_tx(
                          uid,
                          :human,
                          actor.principal.display_name
                        ) do
                   :ok
                 end
               end,
               after_commit: &Namespace.committed/1
             ) do
          {:ok, :ok} -> :ok
          {:error, _} = error -> error
        end
      end

    with :ok <- ensure_result,
         {:ok, canonical_id} <- Scope.canonical_page_id(uid) do
      {:ok, canonical_id, private_scope_id}
    end
  end

  defp supersede_my_claim(actor, claim_id, text) do
    uid = actor.principal.uid

    with :ok <- ensure_visible_claim(actor, claim_id),
         {:ok, updated} <-
           Claims.supersede_claim(
             claim_id,
             %{claim: text, provenance: "user_correction:meta_brain"},
             uid
           ) do
      Repo.transact_repeatable_read_only(fn ->
        with {:ok, access} <- open_access(actor) do
          {:ok, %{claim: hd(serialize_claims([updated], uid, access))}}
        end
      end)
    end
  end

  defp forget_my_claim(actor, claim_id, reason) do
    uid = actor.principal.uid

    trimmed_reason =
      case reason do
        value when is_binary(value) ->
          if String.trim(value) == "",
            do: "Removed by user in Meta Brain",
            else: String.trim(value)

        _ ->
          "Removed by user in Meta Brain"
      end

    with :ok <- ensure_visible_claim(actor, claim_id),
         {:ok, _forgotten} <- Forget.forget_claim(claim_id, trimmed_reason, uid) do
      {:ok, %{forgotten_id: claim_id}}
    end
  end

  defp ensure_visible_claim(actor, claim_id) do
    Repo.transact_repeatable_read_only(fn ->
      with {:ok, access} <- open_access(actor) do
        found =
          Claim
          |> Ash.Query.filter(id == ^claim_id)
          |> Access.filter_claims(access)
          |> Ash.Query.select([:id])
          |> Ankole.Ash.read_one!()

        if found, do: {:ok, :visible}, else: {:error, :not_found}
      end
    end)
    |> case do
      {:ok, :visible} -> :ok
      {:error, _} = error -> error
    end
  end

  defp serialize_claims([], _uid, _access), do: []

  defp serialize_claims(claims, uid, access) do
    private_scope_id = Scope.principal(uid)
    principal_ref = Ankole.ActorRef.from_principal(%{tenant_id: Repo.tenant_id!(), uid: uid})

    subject_ids =
      claims
      |> Enum.map(& &1.subject_page_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    source_ids =
      claims
      |> Enum.map(& &1.source_node_id)
      |> Enum.uniq()

    subjects_by_id =
      if subject_ids == [] do
        %{}
      else
        Page
        |> Ash.Query.filter(id in ^subject_ids and is_nil(deleted_at))
        |> Access.filter_objects(access)
        |> Ash.Query.select([:id, :title, :slug])
        |> Ankole.Ash.read!()
        |> Map.new(&{&1.id, &1})
      end

    sources_by_id =
      if source_ids == [] do
        %{}
      else
        Ankole.Pod.list_page_records!(
          query: [
            filter: [id: [in: source_ids], deleted_at: [is_nil: true]],
            select: [
              :id,
              :title,
              :name,
              :private_owner_uid,
              :conversation_id,
              :acl_anchor_id,
              :is_acl_anchor,
              :deleted_at
            ]
          ]
        )
        |> Enum.filter(&Access.visible_node?(access, &1))
        |> Map.new(&{&1.id, &1})
      end

    conversation_ids =
      sources_by_id
      |> Map.values()
      |> Enum.map(& &1.conversation_id)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    dm_conversation_ids =
      Ankole.Conversations.dm_conversation_ids_for_human(uid, conversation_ids)

    Enum.map(claims, fn claim ->
      subject = claim.subject_page_id && Map.get(subjects_by_id, claim.subject_page_id)
      source = Map.get(sources_by_id, claim.source_node_id)

      personal_source? =
        claim.source_node_id == private_scope_id or
          (not is_nil(source) and
             (source.private_owner_uid == uid or
                (is_binary(source.conversation_id) and
                   MapSet.member?(dm_conversation_ids, source.conversation_id))))

      source_title =
        cond do
          claim.source_node_id == private_scope_id ->
            nil

          not is_nil(source) and
              (not is_nil(source.private_owner_uid) or not is_nil(source.conversation_id)) ->
            nil

          source ->
            source.title || source.name

          true ->
            nil
        end

      eligible? = claim.author == principal_ref or not is_nil(source)

      can_edit =
        eligible? and is_nil(claim.superseded_by) and
          (claim.claim_type == :fact or is_nil(claim.resolved_at))

      %{
        id: claim.id,
        claim_type: Atom.to_string(claim.claim_type),
        claim: claim.claim,
        kind: claim.kind,
        holder: claim.holder,
        source_node_id: claim.source_node_id,
        source_title: source_title,
        subject_page_id: if(subject, do: subject.id),
        subject_title: subject && subject.title,
        subject_slug: subject && subject.slug,
        bucket: if(personal_source?, do: "personal", else: "workspace"),
        notability: claim.notability,
        confidence: claim.confidence,
        weight: claim.weight,
        provenance: claim.provenance,
        created_at: claim.created_at,
        can_edit: can_edit,
        can_forget: eligible?
      }
    end)
  end

  defp graph(actor) do
    uid = actor.principal.uid

    with {:ok, root} <- Namespace.root(),
         {:ok, access} <- open_access(actor) do
      schema_by_category =
        SchemaType
        |> Ash.Query.select([:name, :primitive, :slug_prefix])
        |> Ankole.Ash.read!()
        |> Map.new(fn schema_type ->
          {String.trim_trailing(schema_type.slug_prefix, "/"),
           %{entity_type: schema_type.name, primitive: schema_type.primitive}}
        end)

      categories =
        Tree.list_children(root.id)
        |> Enum.filter(
          &(&1.system_key != "ankole_brain_sources" and Access.visible_node?(access, &1))
        )
        |> Enum.map(fn category ->
          schema =
            Map.get(schema_by_category, category.name, %{
              entity_type: category.name,
              primitive: "concept"
            })

          %{
            id: category.id,
            name: category.name,
            entity_type: schema.entity_type,
            primitive: schema.primitive,
            can_edit:
              category.system_key != "ankole_brain_agents" and
                match?(
                  {:ok, _},
                  Ankole.Pod.Access.authorize_reachable(category, "node_edit", access.reachable)
                )
          }
        end)

      category_ids = MapSet.new(categories, & &1.id)

      excluded =
        [root.id | MapSet.to_list(category_ids)] ++
          case Namespace.system_node("ankole_brain_sources") do
            {:ok, source} -> Tree.descendants(source.id)
            _ -> []
          end

      # A file joins the graph once source learning has covered it, as the
      # evidence source of the facts extracted from it.
      raw_nodes =
        Page
        |> Ash.Query.filter(
          id not in ^excluded and is_nil(deleted_at) and
            (kind == :knowledge or (kind == :file and learned?))
        )
        |> Access.filter_objects(access)
        |> Ash.Query.sort(title: :asc)
        |> Ash.Query.select([:id, :title, :slug, :type, :subtype, :parent_id])
        |> Ankole.Ash.read!()

      visible_ids = MapSet.new(raw_nodes, & &1.id)
      known_parents = MapSet.union(category_ids, visible_ids)

      nodes =
        Enum.map(raw_nodes, fn node ->
          %{
            id: node.id,
            title: node.title,
            slug: node.slug,
            type: node.type,
            subtype: node.subtype,
            parent_id: resolve_visible_parent(node, known_parents)
          }
        end)

      links = collect_links(nodes, visible_ids, access)

      {:ok,
       %{
         viewer_uid: uid,
         assistant_uid: viewer_assistant_uid(uid),
         categories: categories,
         nodes: nodes,
         links: links
       }}
    end
  end

  defp resolve_visible_parent(%{parent_id: nil}, _known_parents), do: nil

  defp resolve_visible_parent(%{id: id, parent_id: parent_id}, known_parents) do
    cond do
      parent_id == id ->
        nil

      MapSet.member?(known_parents, parent_id) ->
        parent_id

      true ->
        case Tree.path(%{id: id, parent_id: parent_id}) do
          {:ok, ancestors} ->
            ancestors
            |> Enum.reject(&(&1.id == id))
            |> Enum.reverse()
            |> Enum.find_value(fn ancestor ->
              if MapSet.member?(known_parents, ancestor.id), do: ancestor.id
            end)

          _ ->
            nil
        end
    end
  end

  defp collect_links([], _visible_ids, _access), do: []

  defp collect_links(nodes, visible_ids, access) do
    visible = MapSet.to_list(visible_ids)
    id_by_slug = Map.new(nodes, &{&1.slug, &1.id})
    explicit = explicit_edges(visible, access)
    explicit_pairs = MapSet.new(explicit, &{&1.from_page_id, &1.to_page_id})

    (explicit ++
       hierarchy_edges(nodes, visible_ids) ++
       ownership_edges(id_by_slug) ++
       claim_edges(visible, access, explicit_pairs) ++
       timeline_edges(visible, visible_ids, access, explicit_pairs))
    |> Enum.uniq_by(&{&1.from_page_id, &1.to_page_id, &1.link_type})
    |> Enum.sort_by(&{&1.from_page_id, &1.to_page_id, &1.link_type})
  end

  defp explicit_edges(visible, access) do
    Link
    |> Ash.Query.filter(
      from_page_id in ^visible and to_page_id in ^visible and from_page_id != to_page_id
    )
    |> Access.filter_links(access)
    |> Ash.Query.select([:from_page_id, :to_page_id, :link_type, :link_source])
    |> Ankole.Ash.read!()
    |> Enum.map(fn link ->
      %{
        from_page_id: link.from_page_id,
        to_page_id: link.to_page_id,
        link_type: if(link.link_type == "", do: "relates_to", else: link.link_type),
        relation_kind:
          if(link.link_type == "references" or link.link_source in ["mention", "frontmatter"],
            do: "reference",
            else: "semantic"
          )
      }
    end)
  end

  defp hierarchy_edges(nodes, visible_ids) do
    nodes
    |> Enum.filter(&(&1.parent_id != nil and MapSet.member?(visible_ids, &1.parent_id)))
    |> Enum.map(fn node ->
      %{
        from_page_id: node.parent_id,
        to_page_id: node.id,
        link_type: "contains",
        relation_kind: "hierarchy"
      }
    end)
  end

  defp ownership_edges(id_by_slug) do
    Ankole.Principals.list_agents()
    |> Enum.flat_map(fn %{agent: agent} ->
      from_id = Map.get(id_by_slug, "agents/" <> agent.uid)

      to_id =
        if is_binary(agent.owner_principal_uid),
          do: Map.get(id_by_slug, "people/" <> agent.owner_principal_uid)

      if from_id && to_id && from_id != to_id do
        link_type = if agent.type == :personal_assistant, do: "assists", else: "owned_by"

        [
          %{
            from_page_id: from_id,
            to_page_id: to_id,
            link_type: link_type,
            relation_kind: "ownership"
          }
        ]
      else
        []
      end
    end)
  end

  defp claim_edges(visible, access, explicit_pairs) do
    claim_sources =
      Claim
      |> Ash.Query.filter(
        source_node_id in ^visible and not is_nil(subject_page_id) and
          subject_page_id in ^visible and source_node_id != subject_page_id
      )
      |> Access.filter_current_claims()
      |> Access.filter_claims(access)
      |> Ash.Query.select([:source_node_id, :subject_page_id])
      |> Ankole.Ash.read!()
      |> Enum.reject(&MapSet.member?(explicit_pairs, {&1.source_node_id, &1.subject_page_id}))
      |> Enum.map(fn claim ->
        %{
          from_page_id: claim.source_node_id,
          to_page_id: claim.subject_page_id,
          link_type: "evidences",
          relation_kind: "evidence"
        }
      end)

    take_holders =
      Claim
      |> Ash.Query.filter(
        claim_type == :take and holder in ^visible and not is_nil(subject_page_id) and
          subject_page_id in ^visible
      )
      |> Access.filter_current_claims()
      |> Access.filter_claims(access)
      |> Ash.Query.select([:holder, :subject_page_id])
      |> Ankole.Ash.read!()
      |> Enum.filter(&(&1.holder != &1.subject_page_id))
      |> Enum.map(fn claim ->
        %{
          from_page_id: claim.holder,
          to_page_id: claim.subject_page_id,
          link_type: "holds_take",
          relation_kind: "evidence"
        }
      end)

    claim_sources ++ take_holders
  end

  defp timeline_edges(visible, visible_ids, access, explicit_pairs) do
    Timeline
    |> Ash.Query.filter(
      not is_nil(subject_page_id) and subject_page_id in ^visible and
        (source_node_id in ^visible or event_page_id in ^visible)
    )
    |> Access.filter_timelines(access)
    |> Ash.Query.select([:source_node_id, :event_page_id, :subject_page_id])
    |> Ankole.Ash.read!()
    |> Enum.flat_map(&timeline_row_edges(&1, visible_ids, explicit_pairs))
  end

  defp timeline_row_edges(timeline, visible_ids, explicit_pairs) do
    event_edge =
      if timeline.event_page_id && MapSet.member?(visible_ids, timeline.event_page_id) &&
           timeline.event_page_id != timeline.subject_page_id do
        [
          %{
            from_page_id: timeline.event_page_id,
            to_page_id: timeline.subject_page_id,
            link_type: "involves",
            relation_kind: "semantic"
          }
        ]
      else
        []
      end

    source_edge =
      if MapSet.member?(visible_ids, timeline.source_node_id) &&
           timeline.source_node_id != timeline.subject_page_id &&
           not MapSet.member?(explicit_pairs, {timeline.source_node_id, timeline.subject_page_id}) do
        [
          %{
            from_page_id: timeline.source_node_id,
            to_page_id: timeline.subject_page_id,
            link_type: "evidences",
            relation_kind: "evidence"
          }
        ]
      else
        []
      end

    event_edge ++ source_edge
  end
end
