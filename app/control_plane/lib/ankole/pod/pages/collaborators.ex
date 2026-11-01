defmodule Ankole.Pod.Pages.Collaborators do
  @moduledoc "Owns collaborator catalogs and visibility shared by mentions and sharing."
  import Bitwise
  require Ash.Expr
  require Ash.Query
  alias Ankole.{AuthZ, Repo, Tenants}
  alias Ankole.Files.Access
  alias Ankole.Pod.{Page, PageContent, Pages}

  def current_space_name do
    case Tenants.get(Repo.tenant_id!()) do
      {:ok, tenant} -> tenant.display_name
      _ -> ""
    end
  end

  @doc """
  Returns `{:ok, :all}` for Members or `{:ok, MapSet.t()}` of visible collaborator UIDs
  for Guest-scoped callers within the current transaction.
  """
  def visible_principal_uids_in_tx(%Ankole.AuthZ.Actor{} = actor, reachable, opts \\ []) do
    with {:ok, scope} <- Access.collaborator_scope(actor) do
      case scope do
        :all ->
          {:ok, :all}

        :shared ->
          uids =
            actor
            |> shared_collaborator_uids_in_tx(reachable)
            |> union_context_page_contributors(Keyword.get(opts, :context_page_id), reachable)

          {:ok, uids}
      end
    end
  end

  defp shared_collaborator_uids_in_tx(%Ankole.AuthZ.Actor{} = actor, reachable) do
    uid = Ankole.AuthZ.Actor.uid(actor)
    {containers, own} = Access.visibility_ids(reachable)
    visible_anchor_ids = MapSet.union(MapSet.new(containers), MapSet.new(own))

    anchors = Ankole.Files.acl_anchor_nodes() |> Map.new(&{&1.id, &1})

    private_anchor_ids =
      MapSet.new(
        for {id, anchor} <- anchors,
            private_anchor?(anchor, anchors, MapSet.new()),
            do: id
      )

    inherited_visible_by_ancestor =
      visible_anchor_ids
      |> Enum.reduce(%{}, fn anchor_id, acc ->
        case Map.get(anchors, anchor_id) do
          nil ->
            acc

          visible_anchor ->
            record_inherited_ancestors(
              visible_anchor,
              visible_anchor,
              anchors,
              MapSet.new([anchor_id]),
              acc
            )
        end
      end)

    grants =
      Access.grants(
        target_node_id: [is_nil: false],
        principal_uid: [is_nil: false],
        action: [in: Access.page_actions()]
      )

    entries_by_uid =
      Enum.reduce(grants, %{}, fn grant, acc ->
        if grant.principal_uid == uid do
          acc
        else
          direct =
            if MapSet.member?(visible_anchor_ids, grant.target_node_id) do
              case Map.get(anchors, grant.target_node_id) do
                nil -> []
                anchor -> [anchor]
              end
            else
              []
            end

          inherited =
            if (grant.target_scope || "container") != "self" do
              Map.get(inherited_visible_by_ancestor, grant.target_node_id, [])
            else
              []
            end

          reached = direct ++ inherited

          if reached == [] do
            acc
          else
            Map.update(acc, grant.principal_uid, [{grant, reached}], &[{grant, reached} | &1])
          end
        end
      end)

    candidate_uids = Map.keys(entries_by_uid)

    principals_by_uid =
      if candidate_uids == [] do
        %{}
      else
        Ankole.Principals.list_principals!(
          query: [
            filter: [uid: [in: candidate_uids], status: :active, type: [in: [:human, :agent]]],
            load: [:human_user, :agent]
          ]
        )
        |> Enum.filter(&match?({:ok, _}, Access.principal(Ankole.AuthZ.Actor.new(&1))))
        |> Map.new(&{&1.uid, &1})
      end

    Enum.reduce(entries_by_uid, MapSet.new([uid]), fn {candidate, grant_entries}, acc ->
      case Map.get(principals_by_uid, candidate) do
        nil ->
          acc

        principal ->
          if unconditional_view_on_visible?(principal, grant_entries, private_anchor_ids) or
               shares_visible_page?(
                 actor,
                 principal,
                 grant_entries
                 |> Enum.flat_map(&elem(&1, 1))
                 |> Enum.uniq_by(& &1.id)
               ) do
            MapSet.put(acc, candidate)
          else
            acc
          end
      end
    end)
  end

  defp private_anchor?(anchor, anchors, seen) do
    cond do
      not is_nil(anchor.private_owner_uid) ->
        true

      is_nil(anchor.parent_anchor_id) or MapSet.member?(seen, anchor.parent_anchor_id) ->
        false

      true ->
        case Map.get(anchors, anchor.parent_anchor_id) do
          nil ->
            false

          parent ->
            private_anchor?(parent, anchors, MapSet.put(seen, anchor.parent_anchor_id))
        end
    end
  end

  defp record_inherited_ancestors(current, visible_anchor, anchors, seen, acc) do
    if current.inherit_permissions and not is_nil(current.parent_anchor_id) and
         not MapSet.member?(seen, current.parent_anchor_id) do
      case Map.get(anchors, current.parent_anchor_id) do
        nil ->
          acc

        parent ->
          next_acc =
            Map.update(acc, parent.id, [visible_anchor], &[visible_anchor | &1])

          record_inherited_ancestors(
            parent,
            visible_anchor,
            anchors,
            MapSet.put(seen, parent.id),
            next_acc
          )
      end
    else
      acc
    end
  end

  defp unconditional_view_on_visible?(principal, grant_entries, private_anchor_ids) do
    Enum.any?(grant_entries, fn {grant, reached} ->
      grant.action == "node_view" and grant.condition == "true" and
        Enum.any?(reached, fn anchor ->
          not (principal.membership == :guest and MapSet.member?(private_anchor_ids, anchor.id))
        end)
    end)
  end

  defp union_context_page_contributors(uids, context_page_id, reachable)
       when is_binary(context_page_id) do
    with {:ok, id} <- Ecto.UUID.cast(context_page_id),
         {:ok, %Page{} = page} <- Pages.fetch(id),
         :ok <-
           Access.authorize_reachable(page, "node_view", reachable)
           |> elem(0)
           |> then(&if(&1 == :ok, do: :ok, else: :error)) do
      content =
        PageContent
        |> Ash.Query.filter(page_id == ^page.id)
        |> Ash.Query.select([:page_id, :updated_by, :contributors])
        |> Ankole.Ash.read_one!()

      contributors =
        if content,
          do: [page.created_by, content.updated_by | content.contributors],
          else: [page.created_by]

      tenant_id = Repo.tenant_id!()

      contributors
      |> Enum.filter(&(&1.tenant_id == tenant_id))
      |> Enum.reduce(uids, &MapSet.put(&2, &1.uid))
    else
      _ -> uids
    end
  end

  defp union_context_page_contributors(uids, _context_page_id, _reachable), do: uids

  def subjects_in_tx(%Ankole.AuthZ.Actor{} = actor, opts \\ []) do
    with {:ok, scope} <- Access.collaborator_scope(actor) do
      subjects =
        Keyword.get_lazy(opts, :subjects, fn -> catalog(include_internal: false) end)

      if scope == :shared do
        result =
          case Keyword.fetch(opts, :reachable) do
            {:ok, reachable} -> {:ok, reachable}
            :error -> Access.reachable_anchors(actor)
          end

        with {:ok, reachable} <- result,
             {:ok, visible_uids} <-
               visible_principal_uids_in_tx(actor, reachable,
                 context_page_id: Keyword.get(opts, :context_page_id)
               ) do
          {:ok,
           subjects
           |> Enum.filter(fn subject ->
             case Map.get(subject, :principal_uid) do
               nil -> false
               candidate -> MapSet.member?(visible_uids, candidate)
             end
           end)
           |> Enum.map(&redact_subject_pii(&1, scope))}
        end
      else
        {:ok, subjects}
      end
    end
  end

  def redact_subject_pii(subject, :shared) when is_map(subject),
    do: Map.put(subject, :subtitle, nil)

  def redact_subject_pii(subject, _scope), do: subject

  defp shares_visible_page?(_caller, _principal, []), do: false

  defp shares_visible_page?(caller, principal, pages) do
    actor = Ankole.AuthZ.Actor.new(principal, authn: Map.take(caller.authn, ["ip", "surface"]))
    targets = Enum.map(pages, & &1.acl_anchor_id) |> Enum.uniq()

    case Access.reachable_anchors(actor, target_ids: targets) do
      {:ok, reachable} ->
        Enum.any?(pages, &(band(Access.page_bits(&1, reachable), 1) != 0))

      {:error, _} ->
        false
    end
  end

  def catalog(opts) do
    include_internal = Keyword.get(opts, :include_internal, false)

    principals =
      Ankole.Principals.list_principals!(
        query: [
          filter:
            Ash.Expr.expr(
              status == :active and
                (type == :human or (type == :agent and agent.type == :ai_colleague))
            ),
          load: [:human_user, :agent],
          sort: [uid: :asc]
        ]
      )
      |> Enum.map(&principal_subject/1)

    groups =
      AuthZ.list_principal_groups()
      |> Enum.map(&group_subject/1)
      |> then(fn items ->
        if include_internal, do: items, else: Enum.reject(items, &internal_picker_subject?/1)
      end)

    principals ++ groups
  end

  @doc false
  def principal_subject(principal) do
    name = Ankole.Principals.display_name(principal)

    subtitle =
      case principal.type do
        :human -> principal.human_user && principal.human_user.email
        :agent -> "@" <> principal.uid
      end

    %{
      principal_uid: principal.uid,
      group_id: nil,
      name: name,
      kind: principal.type,
      avatar_url: principal.avatar_url,
      subtitle: subtitle,
      membership: principal.membership,
      group_domain: nil,
      group_slug: nil,
      built_in: nil
    }
  end

  defp group_subject(group) do
    %{
      principal_uid: nil,
      group_id: group.id,
      name: group.display_name,
      kind: :group,
      avatar_url: nil,
      subtitle: if(group.built_in, do: nil, else: group.name),
      membership: nil,
      group_domain: group.domain,
      group_slug: group.name,
      built_in: group.built_in
    }
  end

  def internal_picker_subject?(%{kind: :group, group_domain: :signal_source}), do: true

  def internal_picker_subject?(%{kind: :group, built_in: true, group_slug: "siteadmin"}),
    do: true

  def internal_picker_subject?(_subject), do: false
end
