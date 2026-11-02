defmodule Ankole.Brain.Knowledge do
  @moduledoc "Indexes live Pod content and derives permission-filtered knowledge panels."
  require Ash.Query
  alias Ankole.Brain.{Access, Chunks, Links, Objects}
  alias Ankole.Brain.Schemas.{Claim, Chunk, Link, SlugAlias, Timeline}
  alias Ankole.Files.Nodes

  @contracts ~w(AGENTS.md AGENTS.override.md DESIGN.md DESIGN.override.md)

  def folder_learning(%{type: :folder} = page) do
    with {:ok, node} <- Nodes.fetch(page.id),
         {:ok, path} <- Nodes.path(node),
         true <- is_nil(hd(path).private_owner_uid) and is_nil(hd(path).conversation_id),
         false <- Enum.any?(path, &(&1.name == "AnkoleBrain")) do
      inherited =
        path
        |> Enum.drop(-1)
        |> Enum.any?(fn ancestor ->
          case Ankole.Pod.Pages.fetch(ancestor.id) do
            {:ok, parent} -> parent.metadata["extract_facts"] == true
            _ -> false
          end
        end)

      %{enabled: page.metadata["extract_facts"] == true, inherited: inherited}
    else
      _ -> nil
    end
  end

  def folder_learning(_page), do: nil

  def folder_learning_enabled_in_tx(id) do
    if Ankole.Brain.Config.enabled?() do
      Enum.each(descendants(id), fn node_id ->
        with {:ok, page} <- Objects.get_by_slug(node_id),
             true <- extractable?(page),
             false <- String.trim(page.body) == "" do
          {:ok, _} = Ankole.Brain.Jobs.LearnSource.enqueue_page(page.id, page.revision)
        end
      end)
    end

    :ok
  end

  def indexable?(%{deleted_at: deleted}) when not is_nil(deleted), do: false

  def indexable?(page) do
    with {:ok, node} <- Nodes.fetch(page.id), {:ok, path} <- Nodes.path(node) do
      public? = is_nil(hd(path).private_owner_uid) and is_nil(hd(path).conversation_id)
      relative = path |> Enum.map(& &1.name) |> Enum.drop_while(&(&1 != "AnkoleBrain"))

      contract? =
        case relative do
          ["AnkoleBrain", name] -> name in @contracts
          ["AnkoleBrain", "agents", _uid, name] -> name in @contracts
          _ -> false
        end

      public? and Enum.all?(path, &is_nil(&1.deleted_at)) and
        node.kind in [:knowledge, :doc, :base, :applet] and not contract?
    else
      _ -> false
    end
  end

  def extractable?(%{meta: %{"role" => "synthesis"}}), do: false

  def extractable?(page) do
    with true <- indexable?(page),
         {:ok, node} <- Nodes.fetch(page.id),
         {:ok, path} <- Nodes.path(node) do
      names = Enum.map(path, & &1.name)
      brain = Enum.drop_while(names, &(&1 != "AnkoleBrain"))

      entity? =
        case brain do
          ["AnkoleBrain", category | _] -> category not in ["skills" | @contracts]
          _ -> false
        end

      not match?(["AnkoleBrain", "skills" | _], brain) and
        (entity? or
           Enum.any?(path, fn ancestor ->
             case Ankole.Pod.Pages.fetch(ancestor.id) do
               {:ok, ancestor} -> Map.get(ancestor.metadata, "extract_facts", false) == true
               _ -> false
             end
           end))
    else
      _ -> false
    end
  end

  def page_changed_in_tx(%{type: type}, _content) when type in [:folder, :file], do: :ok

  def page_changed_in_tx(page, _content) do
    with {:ok, knowledge} <- Objects.get_by_slug(page.id),
         {:ok, _} <- Chunks.reconcile_locked_in_tx(knowledge),
         {:ok, _} <- Links.reconcile_object_links_in_tx(page.id) do
      cond do
        not extractable?(knowledge) ->
          :ok

        String.trim(knowledge.body) == "" ->
          Ankole.Brain.SourceLearning.clear_page_facts_in_tx(knowledge)

        Ankole.Brain.Config.enabled?() ->
          with {:ok, _} <- Ankole.Brain.Jobs.LearnSource.enqueue_page(page.id, knowledge.revision),
               do: :ok

        true ->
          :ok
      end
    end
  end

  def page_moved_in_tx(id, old_path) do
    with {:ok, node} <- Nodes.fetch(id), {:ok, path} <- Nodes.path(node) do
      new_path = path |> Enum.reject(&is_nil(&1.parent_id)) |> Enum.map_join("/", & &1.name)
      old_brain_path = brain_path(old_path)

      descendants(id)
      |> Enum.each(fn page_id ->
        case Objects.get_by_slug(page_id) do
          {:ok, page} ->
            current =
              if String.starts_with?(new_path, "AnkoleBrain/"),
                do: "AnkoleBrain/" <> page.slug,
                else: page.slug

            if old_brain_path do
              previous = String.replace_prefix(current, new_path, old_brain_path)
              :ok = record_previous_path(page, previous)
            end

            {:ok, _} = Nodes.lock(page.id)
            :ok = page_changed_in_tx(page, nil)

          {:error, :not_found} ->
            :ok
        end
      end)

      :ok
    end
  end

  @doc "Returns a Brain-relative path only for descendants of the canonical namespace."
  def brain_path(path) do
    with {:ok, root} <- Ankole.AIAgent.Library.Knowledge.root(),
         [_root | relative] <- Enum.drop_while(path, &(&1.id != root.id)),
         do: Enum.map_join(relative, "/", & &1.name),
         else: (_ -> nil)
  end

  defp record_previous_path(%{slug: path}, path), do: :ok

  defp record_previous_path(page, previous) do
    result =
      case Ankole.Ash.read_one!(Ash.Query.filter(SlugAlias, alias_slug == ^previous)) do
        nil ->
          Ankole.Ash.create(SlugAlias, :add, %{alias_slug: previous, canonical_page_id: page.id})

        alias_row ->
          Ankole.Ash.update(alias_row, :repoint, %{canonical_page_id: page.id})
      end

    with {:ok, _} <- result, do: :ok
  end

  def page_deleted_in_tx(id) do
    ids = descendants(id)

    {:ok, _} =
      Chunk
      |> Ash.Query.filter(source_node_id in ^ids)
      |> Ankole.Ash.destroy_where(:remove_projection)

    now = DateTime.utc_now(:microsecond)

    {:ok, _} =
      Claim
      |> Ash.Query.filter(source_node_id in ^ids and claim_type == :fact and is_nil(expired_at))
      |> Ankole.Ash.update_where(:expire_fact, %{at: now})

    {:ok, _} =
      Claim
      |> Ash.Query.filter(source_node_id in ^ids and claim_type == :take and active)
      |> Ankole.Ash.update_where(:deactivate_take, %{at: now})

    :ok
  end

  def page_restored_in_tx(id) do
    Enum.each(descendants(id), fn node_id ->
      case Objects.get_by_slug(node_id) do
        {:ok, page} ->
          {:ok, _} = Nodes.lock(page.id)
          :ok = Ankole.Brain.SourceLearning.clear_facts_revision_in_tx(page.id)
          :ok = page_changed_in_tx(page, nil)

        {:error, :not_found} ->
          {:ok, _} = Chunks.reconcile_node_in_tx(node_id)
      end
    end)

    :ok
  end

  def panel(context, id) do
    with {:ok, access} <- Access.for_context(context), true <- Access.visible?(access, id) do
      claims =
        Claim
        |> Ash.Query.filter(subject_page_id == ^id or source_node_id == ^id)
        |> Access.filter_claims(access)
        |> Access.filter_current_claims()
        |> Ash.Query.sort(created_at: :desc)
        |> Ankole.Ash.read!()

      timelines =
        Timeline
        |> Ash.Query.filter(subject_page_id == ^id or source_node_id == ^id)
        |> Access.filter_timelines(access)
        |> Ash.Query.sort(date: :desc)
        |> Ankole.Ash.read!()

      backlinks =
        Link
        |> Ash.Query.filter(to_page_id == ^id)
        |> Access.filter_links(access)
        |> Ankole.Ash.read!()

      takes =
        Claim
        |> Ash.Query.filter(
          subject_page_id == ^id and claim_type == :take and
            resolved_quality in ["correct", "incorrect"]
        )
        |> Access.filter_claims(access)
        |> Ankole.Ash.read!()

      {:ok,
       %{
         claims:
           Enum.map(
             claims,
             &Map.take(&1, [
               :id,
               :claim_type,
               :claim,
               :context,
               :source_node_id,
               :confidence,
               :weight,
               :valid_from,
               :since_date,
               :provenance,
               :created_at
             ])
           ),
         timelines:
           Enum.map(
             timelines,
             &Map.take(&1, [:id, :date, :summary, :detail, :provenance, :source_node_id])
           ),
         backlinks:
           Enum.map(backlinks, fn link ->
             {:ok, page} = Objects.get_by_slug(link.from_page_id)

             Map.merge(Map.take(link, [:from_page_id, :link_type, :context, :link_source]), %{
               page_id: page.id,
               title: page.title
             })
           end),
         scorecard: %{
           takes: length(takes),
           brier: if(takes == [], do: nil, else: Ankole.Brain.Calibration.brier(takes))
         }
       }}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defdelegate descendants(id), to: Ankole.Files, as: :descendant_node_ids
end
