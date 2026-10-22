defmodule Ankole.Pod.TenantTeardownTest do
  @moduledoc """
  Tenant teardown for the Page and Database tables.

  These tests run with committed transactions, so the deletion job reaches the
  real batches. Each table is filled for one tenant, another tenant keeps its
  rows, and the job must remove every row of the deleted tenant.

  """

  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  alias Ankole.Pod.DbField
  alias Ankole.Pod.DbRecord
  alias Ankole.Pod.DbTable
  alias Ankole.Pod.DbView
  alias Ankole.Pod.Page
  alias Ankole.Pod.PageChange
  alias Ankole.Pod.PageContent
  alias Ankole.Pod.PageUserState
  alias Ankole.Repo
  alias Ankole.Tenants

  @author "ankole:019a2b00-0000-7000-8000-000000000001:principal/system"

  @schemas [
    DbRecord,
    DbView,
    DbField,
    DbTable,
    PageUserState,
    PageChange,
    PageContent,
    Page
  ]

  setup %{tenant: drop} do
    keep = Ankole.DataCase.create_tenant()

    on_exit(fn ->
      for tenant <- [keep, drop] do
        case Tenants.get(tenant.id) do
          {:error, :not_found} ->
            :ok

          {:ok, tenant} ->
            assert {:ok, _} = Tenants.delete(tenant)
            assert drain(tenant.id) == :ok
        end
      end
    end)

    %{keep: keep}
  end

  test "the deletion job removes every Page and Database row of one tenant", %{
    tenant: drop,
    keep: keep
  } do
    fill(keep)
    fill(drop)

    kept_rows =
      Map.new(@schemas, fn schema ->
        {schema, Repo.with_tenant(keep.id, fn -> MapSet.new(Repo.all(schema)) end)}
      end)

    # A second connection must see the committed rows that teardown will delete.
    assert Task.async(fn -> Repo.with_tenant(drop.id, fn -> Repo.aggregate(Page, :count) end) end)
           |> Task.await() == 3

    # Reject a parent deletion while any child remains. A bulk cascade would fail this check.
    Repo.query!("""
    CREATE FUNCTION test_pod_leaf_delete() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pages WHERE tenant_id = OLD.tenant_id AND parent_id = OLD.id) THEN
        RAISE EXCEPTION 'page deletion reached a parent before its children';
      END IF;
      RETURN OLD;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER test_pod_leaf_delete BEFORE DELETE ON pages FOR EACH ROW EXECUTE FUNCTION test_pod_leaf_delete()"
    )

    try do
      assert {:ok, _tenant} = Tenants.delete(drop)
      assert drain(drop.id) == :ok
    after
      Repo.query!("DROP TRIGGER test_pod_leaf_delete ON pages")
      Repo.query!("DROP FUNCTION test_pod_leaf_delete()")
    end

    # Child rows before their parents, as in the deletion list.
    for schema <- @schemas do
      assert Repo.with_tenant(drop.id, fn -> Repo.all(schema) end) == []

      assert Repo.with_tenant(keep.id, fn -> MapSet.new(Repo.all(schema)) end) ==
               kept_rows[schema]
    end
  end

  test "tenant teardown removes published Applet backend references while another tenant retains them",
       %{tenant: drop, keep: keep} do
    pages =
      for tenant <- [drop, keep], into: %{} do
        page =
          Repo.with_tenant(tenant.id, fn ->
            :ok = Tenants.ensure_scaffold(tenant)
            uid = Ankole.PrincipalsFixtures.human_fixture().principal.uid
            {:ok, page} = Ankole.Pod.Pages.create(uid, %{type: "applet", private_owner_uid: uid})

            manifest =
              Enum.map(
                [
                  {"src/main.tsx", "source"},
                  {"dist/index.html", "frontend"},
                  {"server/main.js", "export default {'GET /':()=>true}"}
                ],
                fn {path, bytes} ->
                  {:ok, blob} = Ankole.Files.store(bytes)

                  {:ok, _} =
                    Ankole.Files.commit(uid, [
                      %{path: "publish/#{page.id}/#{path}", sha256: blob.sha256, source: "pod"}
                    ])

                  %{path: path, sha256: blob.sha256}
                end
              )

            {:ok, _} = Ankole.Pod.Files.publish(uid, page.id, 0, manifest)
            page
          end)

        {tenant.id, page}
      end

    assert {:ok, _} = Tenants.delete(drop)
    assert drain(drop.id) == :ok

    for path <- ["src/main.tsx", "dist/index.html", "server/main.js"] do
      assert {:error, :not_found} =
               Repo.with_tenant(drop.id, fn ->
                 Ankole.Files.fetch(:pod, "pages/#{pages[drop.id].id}/#{path}")
               end)

      assert {:ok, _} =
               Repo.with_tenant(keep.id, fn ->
                 Ankole.Files.fetch(:pod, "pages/#{pages[keep.id].id}/#{path}")
               end)
    end
  end

  defp fill(tenant) do
    Repo.with_tenant(tenant.id, fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      page =
        Ankole.Pod.PagesFixtures.create_record!(Page, :create_in_tx, %{
          type: :doc,
          title: "Sales",
          position: "a0",
          created_by: @author,
          created_at: now,
          updated_at: now
        })

      child =
        Ankole.Pod.PagesFixtures.create_record!(Page, :create_in_tx, %{
          parent_id: page.id,
          type: :doc,
          title: "Child",
          position: "a0",
          created_by: @author,
          created_at: now,
          updated_at: now
        })

      Ankole.Pod.PagesFixtures.create_record!(PageContent, :create_in_tx, %{
        page_id: child.id,
        content: "<page><p>text</p></page>",
        plain_text: "text",
        updated_by: @author,
        updated_at: now
      })

      Ankole.Pod.PagesFixtures.create_record!(PageChange, :append, %{
        page_id: child.id,
        revision: 1,
        kind: :change,
        client_id: "editor",
        client_seq: 1,
        changes: [],
        author: @author,
        created_at: now
      })

      Ankole.Pod.PagesFixtures.create_record!(PageUserState, :put, %{
        principal_uid: "019a2b00-0000-7000-8000-0000000000cc",
        page_id: child.id,
        visited_at: now
      })

      database =
        Ankole.Pod.PagesFixtures.create_record!(Page, :create_in_tx, %{
          parent_id: page.id,
          type: :database,
          title: "Database",
          position: "a1",
          created_by: @author,
          created_at: now,
          updated_at: now
        })

      table =
        Ankole.Pod.PagesFixtures.create_record!(DbTable, :create_in_tx, %{
          page_id: database.id,
          name: "Sales",
          position: "a0"
        })

      Ankole.Pod.PagesFixtures.create_record!(DbField, :create_in_tx, %{
        table_id: table.id,
        name: "Title",
        position: "a0",
        type: :text,
        is_primary: true
      })

      Ankole.Pod.PagesFixtures.create_record!(DbView, :create_in_tx, %{
        table_id: table.id,
        name: "Grid",
        position: "a0",
        type: :grid
      })

      Ankole.Pod.PagesFixtures.create_record!(DbRecord, :create_in_tx, %{
        table_id: table.id,
        data: %{},
        versions: %{},
        created_by: @author,
        created_at: now,
        updated_by: @author,
        updated_at: now
      })
    end)
  end

  defp drain(id) do
    Enum.reduce_while(1..100, :pending, fn _, _ ->
      step =
        Repo.without_tenant(fn ->
          Ankole.Tenants.Jobs.Delete.run(%Oban.Job{args: %{"tenant_id" => id}})
        end)

      case step do
        :ok -> {:halt, :ok}
        {:snooze, _} -> {:cont, :pending}
        other -> raise "tenant deletion failed: #{inspect(other)} (drain of #{id})"
      end
    end)
  end
end
