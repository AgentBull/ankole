defmodule Ankole.Pod.AppletFilesTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Files, as: Drive
  alias Ankole.Pod.{Files, Pages}

  test "readers run published assets while source and environment follow edit access" do
    owner = human_fixture().principal
    viewer = human_fixture().principal
    contributor = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, page} = Pages.create(actor, %{type: "applet", private_owner_uid: owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [
          %{principal_uid: viewer.uid, role: "view"},
          %{principal_uid: contributor.uid, role: "contribute"}
        ]
      })

    contents = %{
      "src/main.tsx" => "source",
      "dist/index.html" => "<head></head>",
      "dist/main.js" => "export {}",
      "package.json" => "{}",
      "bun.lock" => "lock",
      "tsconfig.json" => "{}",
      "applet.env.json" => ~s({"WEBHOOK":"https://example.test"})
    }

    manifest = store_manifest(owner.uid, contents)
    assert {:ok, %{revision: 1}} = Files.publish(actor, page.id, 0, manifest)

    for principal <- [viewer, contributor] do
      reader = actor_fixture(principal)
      assert {:ok, %{files: files}} = Files.manifest(reader, page.id)
      assert Enum.sort(Enum.map(files, & &1.path)) == ["dist/index.html", "dist/main.js"]
      assert {:ok, _, "export {}"} = Files.read(reader, page.id, "dist/main.js")

      for path <- ~w(src/main.tsx package.json bun.lock tsconfig.json applet.env.json) do
        assert {:error, :forbidden} = Files.read(reader, page.id, path)
        local = Drive.temp_path()
        assert {:error, :forbidden} = Files.read_to_file(reader, page.id, path, local)
        refute File.exists?(local)
      end

      assert {:error, :forbidden} = Files.publish(reader, page.id, 1, manifest)
    end

    assert {:ok, %{files: files}} = Files.manifest(actor, page.id)
    assert length(files) == map_size(contents)

    assert {:ok, {_, _, "export {}"}} =
             Files.resolve_applet_frame_asset(actor_fixture(viewer), page.id, 1, "main.js")

    assert {:error, _} =
             Files.resolve_applet_frame_asset(
               actor_fixture(viewer),
               page.id,
               1,
               "../src/main.tsx"
             )

    replacement =
      Enum.reject(manifest, &(&1.path in ~w(package.json bun.lock tsconfig.json applet.env.json)))

    assert {:ok, %{revision: 2}} = Files.publish(actor, page.id, 1, replacement)

    assert {:error, {:applet_revision_changed, %{revision: 2}}} =
             Files.resolve_applet_frame_asset(actor_fixture(viewer), page.id, 1, "main.js")

    assert {:error, :not_found} = Files.read(actor, page.id, "applet.env.json")
  end

  test "contributors can upload record attachments and cannot upload document assets" do
    owner = human_fixture().principal
    contributor = human_fixture().principal
    actor = actor_fixture(owner)

    for type <- ["database", "doc"] do
      {:ok, page} = Pages.create(actor, %{type: type, private_owner_uid: owner.uid})

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
          grants: [%{principal_uid: contributor.uid, role: "contribute"}]
        })

      result =
        Files.upload(
          actor_fixture(contributor),
          page.id,
          if(type == "database", do: "attachment", else: "asset"),
          nil,
          "resume.txt",
          "resume"
        )

      if type == "database",
        do: assert(match?({:ok, _}, result)),
        else: assert(result == {:error, :forbidden})
    end
  end

  test "environment is a bounded flat string map" do
    owner = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, page} = Pages.create(actor, %{type: "applet", private_owner_uid: owner.uid})

    for invalid <- [
          ~s({"PORT":42}),
          "[]",
          "{",
          Torque.encode!(%{"BIG" => String.duplicate("x", 65_536)})
        ] do
      manifest =
        store_manifest(owner.uid, %{
          "src/main.tsx" => "source",
          "dist/index.html" => "html",
          "applet.env.json" => invalid
        })

      assert {:error, :invalid_manifest} = Files.publish(actor, page.id, 0, manifest)
    end
  end

  defp store_manifest(uid, contents) do
    Enum.map(contents, fn {path, bytes} ->
      {:ok, stored} = Drive.store(bytes)

      {:ok, _} =
        Drive.commit(uid, [%{path: "project/" <> path, sha256: stored.sha256, source: "agent"}])

      %{path: path, sha256: stored.sha256}
    end)
  end
end
