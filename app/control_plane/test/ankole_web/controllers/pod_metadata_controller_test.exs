defmodule AnkoleWeb.PodMetadataControllerTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

  alias Ankole.BrowserSessions
  alias AnkoleWeb.Session, as: WebSession

  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  defp png_bytes(total_size) do
    @png_signature <> :crypto.strong_rand_bytes(total_size - byte_size(@png_signature))
  end

  test "uploads, lists, and serves a custom emoji outside any page", %{conn: conn} do
    {conn, _uid} = console_conn_with_principal(conn)
    bytes = png_bytes(64)
    path = Path.join(System.tmp_dir!(), "custom-emoji-#{Ecto.UUID.generate()}.png")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    upload = %Plug.Upload{path: path, filename: "brain.png", content_type: "image/png"}

    created =
      post(conn, "/api/v2/pod/metadata/custom-emojis", %{file: upload, name: ":brain:"})

    assert %{
             "path" => "metadata/custom-emoji/" <> rest = stored,
             "name" => ":brain:",
             "size" => 64
           } =
             json_response(created, 200)

    assert String.ends_with?(rest, "/:brain:")

    listed = created |> recycle_api() |> get("/api/v2/pod/metadata/custom-emojis")

    assert %{"custom_emojis" => [%{"path" => ^stored}], "can_upload" => true} =
             json_response(listed, 200)

    downloaded =
      listed
      |> recycle_api()
      |> get("/api/v2/pod/metadata/files/content", %{path: stored})

    assert response(downloaded, 200) == bytes

    ranged =
      downloaded
      |> recycle_api()
      |> put_req_header("range", "bytes=8-15")
      |> get("/api/v2/pod/metadata/files/content", %{path: stored})

    assert response(ranged, 206) == binary_part(bytes, 8, 8)
    assert get_resp_header(ranged, "content-range") == ["bytes 8-15/64"]
  end

  test "serves pictures to image tags that prove their session by reference", %{conn: conn} do
    {conn, _uid} = console_conn_with_principal(conn)
    bytes = png_bytes(64)
    path = Path.join(System.tmp_dir!(), "custom-emoji-#{Ecto.UUID.generate()}.png")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    upload = %Plug.Upload{path: path, filename: "brain.png", content_type: "image/png"}
    created = post(conn, "/api/v2/pod/metadata/custom-emojis", %{file: upload, name: ":brain:"})
    assert %{"path" => stored} = json_response(created, 200)

    reference = WebSession.authentication_reference(created)
    image_conn = recycle(created)

    served =
      get(image_conn, "/api/v2/pod/metadata/files/content", %{
        path: stored,
        authentication_ref: BrowserSessions.encode_reference(reference)
      })

    assert get_req_header(served, "x-ankole-authentication") == []
    assert response(served, 200) == bytes

    foreign = %{reference | "revision" => reference["revision"] + 1}

    denied =
      image_conn
      |> recycle()
      |> get("/api/v2/pod/metadata/files/content", %{
        path: stored,
        authentication_ref: BrowserSessions.encode_reference(foreign)
      })

    assert denied.status == 401
  end

  test "rejects files that are not pictures and paths outside the custom-emoji directory", %{
    conn: conn
  } do
    {conn, _uid} = console_conn_with_principal(conn)
    path = Path.join(System.tmp_dir!(), "custom-emoji-#{Ecto.UUID.generate()}.txt")
    File.write!(path, "not a picture")
    on_exit(fn -> File.rm(path) end)

    upload = %Plug.Upload{path: path, filename: "note.txt", content_type: "text/plain"}
    rejected = post(conn, "/api/v2/pod/metadata/custom-emojis", %{file: upload})
    assert %{"error" => %{"code" => "invalid_file_type"}} = json_response(rejected, 422)

    spoofed = %Plug.Upload{path: path, filename: "spoof.png", content_type: "image/png"}

    rejected_spoof =
      post(conn, "/api/v2/pod/metadata/custom-emojis", %{file: spoofed, name: ":spoof:"})

    assert %{"error" => %{"code" => "invalid_file_type"}} = json_response(rejected_spoof, 422)

    missing =
      conn
      |> recycle_api()
      |> get("/api/v2/pod/metadata/files/content", %{path: "pages/not-a-page/file.png"})

    assert %{"error" => %{"code" => "not_found"}} = json_response(missing, 404)
  end

  test "requires an ASCII icon name in :name: form", %{conn: conn} do
    {conn, _uid} = console_conn_with_principal(conn)
    path = Path.join(System.tmp_dir!(), "custom-emoji-#{Ecto.UUID.generate()}.png")
    File.write!(path, png_bytes(64))
    on_exit(fn -> File.rm(path) end)

    upload = %Plug.Upload{path: path, filename: "brain.png", content_type: "image/png"}

    too_long = ":" <> String.duplicate("a", 63) <> ":"

    for name <- ["brain", "Brain", ":brain", "brain:", ":大脑:", ":", too_long] do
      rejected = post(conn, "/api/v2/pod/metadata/custom-emojis", %{file: upload, name: name})
      assert %{"error" => %{"code" => "invalid_file_name"}} = json_response(rejected, 422)
    end

    missing = post(conn, "/api/v2/pod/metadata/custom-emojis", %{file: upload})
    assert %{"error" => %{"code" => "invalid_file_name"}} = json_response(missing, 422)

    longest = ":" <> String.duplicate("a", 62) <> ":"
    accepted = post(conn, "/api/v2/pod/metadata/custom-emojis", %{file: upload, name: longest})
    assert %{"name" => ^longest} = json_response(accepted, 200)
  end

  test "rejects pictures larger than one megabyte", %{conn: conn} do
    {conn, _uid} = console_conn_with_principal(conn)
    path = Path.join(System.tmp_dir!(), "custom-emoji-#{Ecto.UUID.generate()}.png")
    File.write!(path, @png_signature <> :binary.copy(<<0>>, 1024 * 1024 + 1))
    on_exit(fn -> File.rm(path) end)

    upload = %Plug.Upload{path: path, filename: "large.png", content_type: "image/png"}
    rejected = post(conn, "/api/v2/pod/metadata/custom-emojis", %{file: upload})

    assert %{"error" => %{"code" => "file_too_large"}} = json_response(rejected, 413)
  end

  test "guests and page-scoped agents can read custom emoji bytes while library listing, upload, and conflicting shortcodes stay gated",
       %{conn: conn} do
    {owner_conn, owner_uid} = console_conn_with_principal(conn)
    first_bytes = png_bytes(64)
    second_bytes = png_bytes(72)
    first_path = Path.join(System.tmp_dir!(), "emoji-a-#{Ecto.UUID.generate()}.png")
    second_path = Path.join(System.tmp_dir!(), "emoji-b-#{Ecto.UUID.generate()}.png")
    File.write!(first_path, first_bytes)
    File.write!(second_path, second_bytes)

    on_exit(fn ->
      File.rm(first_path)
      File.rm(second_path)
    end)

    upload_a = %Plug.Upload{path: first_path, filename: "a.png", content_type: "image/png"}
    upload_b = %Plug.Upload{path: second_path, filename: "b.png", content_type: "image/png"}

    created =
      post(owner_conn, "/api/v2/pod/metadata/custom-emojis", %{file: upload_a, name: ":shipit:"})

    assert %{"path" => stored} = json_response(created, 200)

    # Idempotent re-upload of the exact same image + shortcode succeeds; a different image fails.
    idempotent =
      owner_conn
      |> recycle_api()
      |> post("/api/v2/pod/metadata/custom-emojis", %{file: upload_a, name: ":shipit:"})

    assert %{"path" => ^stored} = json_response(idempotent, 200)

    conflict =
      owner_conn
      |> recycle_api()
      |> post("/api/v2/pod/metadata/custom-emojis", %{file: upload_b, name: ":shipit:"})

    assert %{"error" => %{"code" => "shortcode_taken"}} = json_response(conflict, 422)

    guest =
      Ankole.PrincipalsFixtures.human_fixture(%{
        membership: :guest,
        display_name: "External Guest"
      }).principal

    guest_session = conn |> Plug.Test.init_test_session(%{}) |> WebSession.ensure_browser()

    {:ok, %{browser: browser, authentication: auth}} =
      BrowserSessions.authenticate(WebSession.browser_reference(guest_session), %{
        "principal_uid" => guest.uid,
        "access_version" => guest.access_version,
        "provider_id" => "lark-main",
        "external_id" => "guest-emoji"
      })

    guest_conn =
      guest_session
      |> WebSession.put_authentication(browser, auth)
      |> with_console_csrf()
      |> get("/api/v2/browser/session")

    guest_download =
      guest_conn
      |> recycle_api()
      |> get("/api/v2/pod/metadata/files/content", %{path: stored})

    assert response(guest_download, 200) == first_bytes

    guest_list =
      guest_conn
      |> recycle_api()
      |> get("/api/v2/pod/metadata/custom-emojis")

    assert %{"error" => %{"code" => "forbidden"}} = json_response(guest_list, 403)

    guest_upload =
      guest_conn
      |> recycle_api()
      |> post("/api/v2/pod/metadata/custom-emojis", %{file: upload_b, name: ":guest:"})

    assert %{"error" => %{"code" => "forbidden"}} = json_response(guest_upload, 403)

    agent =
      Ankole.PrincipalsFixtures.agent_fixture(%{owner_principal_uid: owner_uid}).principal
      |> Ankole.PrincipalsFixtures.actor_fixture()

    agent_local = Ankole.Files.temp_path()
    on_exit(fn -> File.rm(agent_local) end)

    assert {:ok, %{name: ":shipit:", content_type: "image/png"}} =
             Ankole.Pod.Metadata.read_to_file(agent, stored, agent_local)

    assert File.read!(agent_local) == first_bytes

    assert {:error, :file_too_large} =
             Ankole.Pod.Metadata.upload_custom_emoji(
               Ankole.PrincipalsFixtures.actor_fixture(owner_uid),
               ":big:",
               @png_signature <> :binary.copy(<<0>>, 1024 * 1024 + 1),
               "image/png"
             )
  end
end
