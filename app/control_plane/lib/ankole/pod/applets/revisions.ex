defmodule Ankole.Pod.Applets.Revisions do
  @moduledoc "Owns concrete Applet drafts and immutable publication snapshots."
  require Ash.Query
  alias Ankole.Repo
  alias Ankole.Pod.{Access, AppletRevision, AppletRevisionFile, Files, Pages}
  alias Ankole.Pod.Applets.Bindings

  @owned ~w(src dist server package.json bun.lock tsconfig.json applet.env.json applet.bindings.json)
  def owned_paths, do: @owned

  def owned_path?(path),
    do: Enum.any?(@owned, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  def parse_ref("draft-" <> id), do: parse_ref("draft:" <> id)

  def parse_ref("draft:" <> id) do
    with {:ok, id} <- Ecto.UUID.cast(id), do: {:ok, "draft:" <> id}
  end

  def parse_ref(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, :invalid_request}
    end
  end

  def parse_ref(value) when is_integer(value) and value >= 0, do: {:ok, value}
  def parse_ref(_), do: {:error, :invalid_request}

  def draft(page_id),
    do:
      AppletRevision
      |> Ash.Query.filter(page_id == ^page_id and is_draft)
      |> Ankole.Ash.read_one!()

  def published(page_id, revision),
    do:
      AppletRevision
      |> Ash.Query.filter(page_id == ^page_id and revision == ^revision and not is_draft)
      |> Ankole.Ash.read_one!()

  def summary(nil), do: nil

  def summary(row),
    do:
      Map.take(row, [
        :id,
        :revision,
        :base_revision,
        :summary,
        :published_by,
        :created_at,
        :updated_at,
        :restored_from_revision
      ])

  def detail(%{type: :applet} = page, true), do: summary(draft(page.id))
  def detail(%Ankole.Pod.Page{}, _editable?), do: nil

  def detail(%Ankole.AuthZ.Actor{} = actor, %{type: :applet} = page) do
    detail(page, match?({:ok, _}, Access.authorize(actor, page, "node_edit", trash: false)))
  end

  def detail(_actor, _page), do: nil

  def files(revision_id),
    do:
      AppletRevisionFile
      |> Ash.Query.filter(revision_id == ^revision_id)
      |> Ash.Query.load([:sha256, :size])
      |> Ash.Query.sort(:path)
      |> Ankole.Ash.read()

  @doc "Captures only the currently addressable live publication or a specific current draft."
  def resolve_target_in_tx(page, "draft:" <> id) do
    case draft(page.id) do
      %{id: ^id} = row ->
        with {:ok, files} <- files(row.id), do: {:ok, %{revision: "draft:" <> id, files: files}}

      _ ->
        changed(page)
    end
  end

  def resolve_target_in_tx(page, revision) when is_nil(revision) or revision == page.revision do
    with {:ok, files} <- Files.list_files(page.id),
         do: {:ok, %{revision: page.revision, files: files}}
  end

  def resolve_target_in_tx(page, _), do: changed(page)
  defp changed(page), do: {:error, {:applet_revision_changed, %{revision: page.revision}}}

  def authorize_target(actor, page, "draft:" <> _),
    do: Access.authorize(actor, page, "node_edit", trash: false)

  def authorize_target(actor, page, _),
    do: Access.authorize(actor, page, "node_view", trash: false)

  def list(actor, page_id) do
    Repo.transact_top_level(fn ->
      with {:ok, _} <- Pages.authorize(actor, page_id, "node_edit", trash: false) do
        rows =
          AppletRevision
          |> Ash.Query.filter(page_id == ^page_id and not is_draft)
          |> Ash.Query.sort(revision: :desc)
          |> Ankole.Ash.read!()

        {:ok, %{revisions: Enum.map(rows, &summary/1), draft: summary(draft(page_id))}}
      end
    end)
  end

  def preview(actor, page_id, draft_id) do
    snapshot =
      Repo.transact_top_level(fn ->
        with {:ok, page} <- Pages.lock(page_id, :share),
             {:ok, _} <- Access.authorize(actor, page, "node_edit", trash: false),
             :ok <- if(page.type == :applet, do: :ok, else: {:error, :invalid_page_type}),
             {:ok, target} <- resolve_target_in_tx(page, "draft:" <> draft_id) do
          binding_file = Enum.find(target.files, &(&1.path == "applet.bindings.json"))
          {:ok, {binding_file && binding_file.object_id, summary(draft(page_id))}}
        end
      end)

    with {:ok, {object_id, draft_summary}} <- snapshot,
         {:ok, resolved} <- Bindings.from_object(page_id, object_id) do
      {:ok, Map.put(resolved, :draft, draft_summary)}
    end
  end

  def baseline_in_tx(page) do
    if page.revision > 0 and is_nil(published(page.id, page.revision)) do
      with {:ok, files} <- Files.list_files(page.id) do
        if Enum.any?(files, &(&1.path == "dist/index.html")) do
          case snapshot_in_tx(page, files, %{
                 revision: page.revision,
                 base_revision: max(page.revision - 1, 0),
                 published_by: page.owner_uid
               }) do
            {:ok, _} -> :ok
            error -> error
          end
        else
          :ok
        end
      end
    else
      :ok
    end
  end

  def snapshot_in_tx(page, files, attrs) do
    Repo.require_transaction!({__MODULE__, :snapshot_in_tx})

    with {:ok, row} <-
           Ankole.Ash.create(AppletRevision, :create_in_tx, Map.put(attrs, :page_id, page.id)),
         {:ok, _} <-
           files
           |> Enum.filter(&owned_path?(&1.path))
           |> Enum.map(fn file ->
             Ankole.Ash.create(AppletRevisionFile, :create_in_tx, %{
               revision_id: row.id,
               path: file.path,
               object_id: file.object_id,
               content_type: file.content_type || MIME.from_path(file.path),
               mode: Map.get(file, :mode) || 0o644
             })
           end)
           |> Ankole.Attrs.collect_results() do
      {:ok, row}
    end
  end

  def save_draft_in_tx(actor, page, upserts, inspection, summary) do
    with {:ok, _} <-
           Ankole.Ash.destroy_where(
             Ash.Query.filter(AppletRevision, page_id == ^page.id and is_draft),
             :remove
           ),
         {:ok, row} <-
           snapshot_in_tx(page, upserts, %{
             is_draft: true,
             base_revision: page.revision,
             summary: summary,
             published_by: Ankole.AuthZ.Actor.uid(actor),
             routes_signature: inspection["routes"],
             actions_signature: inspection["actions"]
           }) do
      {:ok, %{page_id: page.id, revision: page.revision, draft: summary(row)}}
    end
  end

  def prune_in_tx(page_id) do
    obsolete =
      AppletRevision
      |> Ash.Query.filter(page_id == ^page_id and not is_draft)
      |> Ash.Query.sort(revision: :desc)
      |> Ash.Query.offset(100)
      |> Ankole.Ash.read!()

    with {:ok, _} <-
           obsolete
           |> Enum.map(&Ankole.Ash.destroy(&1, :remove))
           |> Ankole.Attrs.collect_results(),
         do: :ok
  end

  def check_draft_in_tx(page, draft_id, base_revision) do
    case draft(page.id) do
      %{id: ^draft_id, base_revision: ^base_revision} = row ->
        {:ok, row}

      _ ->
        {:error, :draft_changed}
    end
  end

  def promote(actor, page_id, draft_id, base_revision) do
    with {:ok, row, files} <- prepared(actor, page_id, {:draft, draft_id, base_revision}) do
      Files.publish_snapshot(actor, page_id, base_revision, row, files,
        expected_draft_id: draft_id
      )
    end
  end

  def rollback(actor, page_id, target_revision, base_revision) do
    with {:ok, row, files} <- prepared(actor, page_id, {:revision, target_revision}) do
      Files.publish_snapshot(actor, page_id, base_revision, row, files,
        restored_from_revision: target_revision
      )
    end
  end

  defp prepared(actor, page_id, target) do
    result =
      Repo.transact_top_level(fn ->
        with {:ok, page} <- Pages.lock(page_id, :share),
             {:ok, _} <- Pages.authorize(actor, page_id, "node_edit", trash: false),
             {:ok, row} <- selected(page, target),
             {:ok, files} <- files(row.id),
             do: {:ok, {row, files}}
      end)

    case result do
      {:ok, {row, files}} -> {:ok, row, files}
      error -> error
    end
  end

  defp selected(page, {:draft, id, base}), do: check_draft_in_tx(page, id, base)

  defp selected(page, {:revision, revision}) do
    case published(page.id, revision) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  def discard(actor, page_id, draft_id, base_revision) do
    Access.write(
      actor.turn_authority,
      fn ->
        with {:ok, page} <- Pages.lock(page_id),
             {:ok, _} <- Pages.authorize(actor, page_id, "node_edit", trash: false),
             {:ok, row} <- check_draft_in_tx(page, draft_id, base_revision),
             {:ok, _} <- Ankole.Ash.destroy(row, :remove),
             do: {:ok, %{page_id: page.id, revision: page.revision}}
      end,
      after_commit: &Files.committed/1
    )
  end
end
