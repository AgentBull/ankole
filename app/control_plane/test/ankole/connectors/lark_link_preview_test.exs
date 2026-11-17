defmodule Ankole.Connectors.LarkLinkPreviewTest do
  use Ankole.DataCase, async: false

  import Bitwise
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures, only: [publish_applet_fixture: 2]

  alias Ankole.{BrainFixtures, Connectors, IdentityProviders, Kernel, Pod, Repo}
  alias Ankole.Plugins.LarkAdapter.{Config, ConnectionReconciler, Dispatcher}
  alias Ankole.Pod.{Bases, Documents, Files, Pages, PagesFixtures}
  alias AnkoleWeb.PodURL
  alias FeishuOpenAPI.Client, as: APIClient
  alias FeishuOpenAPI.WS.{Client, Frame}

  setup do
    previous_client_opts = Application.get_env(:ankole, Config)

    on_exit(fn ->
      if is_nil(previous_client_opts) do
        Application.delete_env(:ankole, Config)
      else
        Application.put_env(:ankole, Config, previous_client_opts)
      end

      ConnectionReconciler.reconcile_once()
    end)

    :ok
  end

  test "resolves /pages/* and /meta/brain/* links over WebSocket and rejects trashed, purging, container, or foreign links",
       %{tenant: tenant} do
    %{principal: owner} = human_fixture()
    {:ok, _} = Ankole.AuthZ.add_principal_to_group(owner.uid, "pod_admin")
    actor = actor_fixture(owner.uid)

    # 1. Collaboration document with > 2,000 characters and Markdown characters.
    {:ok, doc_page} = Pages.create(actor, %{title: "Q4 Product Strategy", icon: "🚀"})
    long_tail = String.duplicate(" word", 450)
    doc_body = "Keep *literal* `syntax` intact." <> long_tail

    {:ok, _} =
      Documents.write(actor, doc_page.id, doc_page.revision, "<page><p>#{doc_body}</p></page>")

    # 2. Private collaboration document — opted-in Pod preview still returns title & excerpt without per-reader ACL.
    {:ok, private_root} = ensure_private_root(owner.uid)

    {:ok, private_doc} =
      Pages.create(actor, %{parent_id: private_root.id, title: "Founder Notes"})

    {:ok, _} =
      Documents.write(
        actor,
        private_doc.id,
        private_doc.revision,
        "<page><p>Confidential memo summary</p></page>"
      )

    # 3. Knowledge pages shared as /meta/brain/<36-char-uuid> (summary-backed and body-fallback).
    {:ok, knowledge_page} =
      BrainFixtures.page_fixture_result(
        %{
          slug: "notes/customer-tiers",
          title: "Customer Tier Standard",
          meta: %{"summary" => "S/A/B tier thresholds by ARR and active seats."},
          body: "Detailed body fallback"
        },
        owner.uid
      )

    {:ok, knowledge_body_page} =
      BrainFixtures.page_fixture_result(
        %{
          slug: "notes/onboarding-checklist",
          title: "Onboarding Checklist",
          body: "Fallback from knowledge body text."
        },
        owner.uid
      )

    # 4. File attachment under a Knowledge page (Brain domain -> /meta/brain/<uuid>).
    {:ok, brain_file_page} =
      Files.create_from_upload(
        actor,
        %{parent_id: knowledge_page.id, title: "Handbook.pdf"},
        "handbook.pdf",
        "%PDF-1.4 sample handbook bytes",
        "application/pdf"
      )

    # 5. Base page & Applet page.
    {:ok, base_page} = Pages.create(actor, %{title: "Pipeline Tracker", type: :base})
    {:ok, _table} = Bases.create_table(actor, base_page.id, %{name: "Deals"})
    {:ok, applet_page} = Pages.create(actor, %{title: "Deal Desk App", type: :applet})
    publish_applet_fixture(%{actor: actor, page: applet_page}, "export default {}")

    # 6. Trashed page, ancestor-trashed child, and purging page.
    {:ok, trashed_parent} = Pages.create(actor, %{title: "Archived Folder"})

    {:ok, trashed_child} =
      Pages.create(actor, %{parent_id: trashed_parent.id, title: "Nested Child"})

    {:ok, _} = Pages.delete(actor, trashed_parent.id)

    {:ok, purging_page} = Pages.create(actor, %{title: "Purging Doc"})
    {:ok, purging_page} = Pages.delete(actor, purging_page.id)
    _ = PagesFixtures.update_record!(purging_page, :begin_purge)

    # Create Lark connection with linkPreview initially false.
    {:ok, config} =
      Connectors.create_auth_config(owner, %{
        "plugin_id" => "lark",
        "slug" => "feishu-main",
        "display_name" => "Feishu Main",
        "auth_scheme" => "lark_app",
        "public_metadata" => %{"domain" => "feishu", "linkPreview" => false},
        "secret" => %{"appID" => "cli_preview_ws", "appSecret" => "secret_preview_ws"}
      })

    doc_url =
      PodURL.canonical_page_url(tenant, %{id: doc_page.id, title: doc_page.title, domain: :pages})

    short_doc_url =
      String.trim_trailing(PodURL.tenant_origin(tenant), "/") <>
        "/pages/" <> Kernel.uuid_shorten(doc_page.id)

    private_url =
      PodURL.canonical_page_url(tenant, %{
        id: private_doc.id,
        title: private_doc.title,
        domain: :pages
      })

    knowledge_url =
      String.trim_trailing(PodURL.tenant_origin(tenant), "/") <>
        "/meta/brain/" <> knowledge_page.id

    knowledge_body_url =
      String.trim_trailing(PodURL.tenant_origin(tenant), "/") <>
        "/meta/brain/" <> knowledge_body_page.id

    brain_file_url =
      String.trim_trailing(PodURL.tenant_origin(tenant), "/") <>
        "/meta/brain/" <> brain_file_page.id

    base_url =
      PodURL.canonical_page_url(tenant, %{
        id: base_page.id,
        title: base_page.title,
        domain: :pages
      })

    applet_url =
      PodURL.canonical_page_url(tenant, %{
        id: applet_page.id,
        title: applet_page.title,
        domain: :pages
      })

    # While disabled, WS callback acknowledges 200 without data.
    disabled_consumers = [
      %{kind: :connector, tenant_id: tenant.id, auth_config_id: config.id, link_preview: false}
    ]

    assert ws_preview_roundtrip(disabled_consumers, doc_url) == %{"code" => 200}

    # Enable linkPreview via Connectors.update_auth_config and verify persistence without bumping secret_version.
    {:ok, updated_config} =
      Connectors.update_auth_config(owner, config.id, %{
        "display_name" => "Feishu Main",
        "slug" => "feishu-main",
        "is_default" => true,
        "public_metadata" => %{"domain" => "feishu", "linkPreview" => true},
        "secret" => %{}
      })

    assert updated_config.public_metadata["linkPreview"] == true
    assert updated_config.secret_version == config.secret_version

    enabled_consumers = [
      %{kind: :connector, tenant_id: tenant.id, auth_config_id: config.id, link_preview: true}
    ]

    # Real WebSocket frame roundtrip on slugged /pages/* URL and bare short-ID URL.
    for url <- [doc_url, short_doc_url] do
      ack = ws_preview_roundtrip(enabled_consumers, url)
      assert %{"code" => 200, "data" => b64} = ack
      payload = b64 |> Base.decode64!() |> Torque.decode!()
      assert payload["inline"] == %{"title" => "🚀 Q4 Product Strategy"}
      [summary_el, _meta_el, button_el] = get_in(payload, ["card", "data", "body", "elements"])
      excerpt = get_in(summary_el, ["text", "content"])
      assert String.starts_with?(excerpt, "Keep *literal* `syntax` intact.")
      assert String.ends_with?(excerpt, "…")
      assert String.length(excerpt) <= 181

      assert get_in(button_el, ["behaviors"]) == [
               %{"type" => "open_url", "default_url" => doc_url}
             ]
    end

    # Private page inside the same Pod resolves when linkPreview is enabled.
    private_ack = ws_preview_roundtrip(enabled_consumers, private_url)
    private_payload = private_ack["data"] |> Base.decode64!() |> Torque.decode!()
    assert private_payload["inline"] == %{"title" => "📄 Founder Notes"}

    # Knowledge page copied as /meta/brain/<36-char-uuid> resolves and links back to /meta/brain/<uuid>.
    knowledge_ack = ws_preview_roundtrip(enabled_consumers, knowledge_url)
    knowledge_payload = knowledge_ack["data"] |> Base.decode64!() |> Torque.decode!()
    assert knowledge_payload["inline"] == %{"title" => "📚 Customer Tier Standard"}

    [k_summary, _k_meta, k_button] =
      get_in(knowledge_payload, ["card", "data", "body", "elements"])

    assert get_in(k_summary, ["text", "content"]) ==
             "S/A/B tier thresholds by ARR and active seats."

    assert get_in(k_button, ["behaviors"]) == [
             %{"type" => "open_url", "default_url" => knowledge_url}
           ]

    kb_payload =
      ws_preview_roundtrip(enabled_consumers, knowledge_body_url)["data"]
      |> Base.decode64!()
      |> Torque.decode!()

    [kb_summary | _] = get_in(kb_payload, ["card", "data", "body", "elements"])
    assert get_in(kb_summary, ["text", "content"]) == "Fallback from knowledge body text."

    # Brain file attachment copied as /meta/brain/<uuid> includes file size and links to /meta/brain/<uuid>.
    file_ack = ws_preview_roundtrip(enabled_consumers, brain_file_url)
    file_payload = file_ack["data"] |> Base.decode64!() |> Torque.decode!()
    assert file_payload["inline"] == %{"title" => "📎 Handbook.pdf"}
    [f_summary, _f_meta, f_button] = get_in(file_payload, ["card", "data", "body", "elements"])
    assert get_in(f_summary, ["text", "content"]) =~ "PDF · 30 B"

    assert get_in(f_button, ["behaviors"]) == [
             %{"type" => "open_url", "default_url" => brain_file_url}
           ]

    # Base page includes table schema excerpt; Applet omits empty summary element.
    base_payload =
      ws_preview_roundtrip(enabled_consumers, base_url)["data"]
      |> Base.decode64!()
      |> Torque.decode!()

    [b_summary | _] = get_in(base_payload, ["card", "data", "body", "elements"])
    assert get_in(b_summary, ["text", "content"]) =~ "Deals"

    applet_payload =
      ws_preview_roundtrip(enabled_consumers, applet_url)["data"]
      |> Base.decode64!()
      |> Torque.decode!()

    assert length(get_in(applet_payload, ["card", "data", "body", "elements"])) == 2

    # Trashed, ancestor-trashed, purging, Brain root container, and foreign Pod URLs return 200 with no data.
    foreign_tenant = Ankole.DataCase.create_tenant()

    foreign_url =
      PodURL.canonical_page_url(foreign_tenant, %{
        id: doc_page.id,
        title: doc_page.title,
        domain: :pages
      })

    trashed_parent_url =
      PodURL.canonical_page_url(tenant, %{
        id: trashed_parent.id,
        title: trashed_parent.title,
        domain: :pages
      })

    trashed_child_url =
      PodURL.canonical_page_url(tenant, %{
        id: trashed_child.id,
        title: trashed_child.title,
        domain: :pages
      })

    purging_url =
      PodURL.canonical_page_url(tenant, %{
        id: purging_page.id,
        title: purging_page.title,
        domain: :pages
      })

    brain_root_url = String.trim_trailing(PodURL.tenant_origin(tenant), "/") <> "/meta/brain"
    {:ok, brain_root} = Ankole.Pod.Pages.Tree.system_node("ankole_brain")

    brain_root_id_url =
      String.trim_trailing(PodURL.tenant_origin(tenant), "/") <> "/meta/brain/" <> brain_root.id

    for rejected_url <- [
          foreign_url,
          trashed_parent_url,
          trashed_child_url,
          purging_url,
          brain_root_url,
          brain_root_id_url
        ] do
      assert ws_preview_roundtrip(enabled_consumers, rejected_url) == %{"code" => 200}
    end
  end

  test "ConnectionReconciler manages standalone linkPreview connections and preserves shared consumers when disabled",
       %{tenant: tenant} do
    {:ok, ws_listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_addr, ws_port}} = :inet.sockname(ws_listener)
    ws_acceptor = spawn_link(fn -> accept_ws_loop(ws_listener) end)

    on_exit(fn ->
      :gen_tcp.close(ws_listener)
      Process.exit(ws_acceptor, :kill)
    end)

    Application.put_env(:ankole, Config,
      client_opts: [
        req_options: [
          plug: fn conn ->
            Req.Test.json(conn, %{
              "code" => 0,
              "data" => %{"URL" => "ws://127.0.0.1:#{ws_port}/ws"}
            })
          end
        ]
      ]
    )

    %{principal: owner} = human_fixture()
    {:ok, _} = Ankole.AuthZ.add_principal_to_group(owner.uid, "pod_admin")

    # 1. Standalone connector: off -> on -> off.
    {:ok, standalone} =
      Connectors.create_auth_config(owner, %{
        "plugin_id" => "lark",
        "slug" => "feishu-standalone",
        "display_name" => "Feishu Standalone",
        "auth_scheme" => "lark_app",
        "public_metadata" => %{"domain" => "feishu", "linkPreview" => false},
        "secret" => %{"appID" => "cli_standalone_preview", "appSecret" => "secret_1"}
      })

    standalone_key = {tenant.id, standalone.id}
    ConnectionReconciler.reconcile_once()
    refute standalone_key in ConnectionReconciler.registered_keys()

    {:ok, _} =
      Connectors.update_auth_config(owner, standalone.id, %{
        "display_name" => "Feishu Standalone",
        "slug" => "feishu-standalone",
        "is_default" => false,
        "public_metadata" => %{"domain" => "feishu", "linkPreview" => true},
        "secret" => %{}
      })

    ConnectionReconciler.reconcile_once()
    assert standalone_key in ConnectionReconciler.registered_keys()

    {:ok, _} =
      Connectors.update_auth_config(owner, standalone.id, %{
        "display_name" => "Feishu Standalone",
        "slug" => "feishu-standalone",
        "is_default" => false,
        "public_metadata" => %{"domain" => "feishu", "linkPreview" => false},
        "secret" => %{}
      })

    ConnectionReconciler.reconcile_once()
    refute standalone_key in ConnectionReconciler.registered_keys()

    # 2. Shared app with realtime directory sync (:identity consumer):
    # enabling linkPreview rebuilds owner with merged consumers; disabling keeps :identity alive!
    {:ok, provider} =
      IdentityProviders.save_provider("lark-shared-idp", "lark", %{
        "appID" => "cli_shared_preview",
        "appSecret" => "secret_shared",
        "domain" => "feishu",
        "oidc" => %{"enabled" => true},
        "sync" => %{"contacts" => true, "websocket" => true}
      })

    {:ok, idp_config} = IdentityProviders.provider_config(provider)
    shared_auth_id = idp_config["authConfigId"]
    shared_key = {tenant.id, shared_auth_id}

    ConnectionReconciler.reconcile_once()

    assert [{initial_pid, {tenant_id_check, initial_fp}}] =
             Registry.lookup(Ankole.Plugins.LarkAdapter.ConnectionRegistry, shared_key)

    assert tenant_id_check == tenant.id

    {:ok, _} =
      Connectors.update_auth_config(owner, shared_auth_id, %{
        "display_name" => "Feishu Shared",
        "slug" => "lark-shared",
        "is_default" => true,
        "public_metadata" => %{"domain" => "feishu", "linkPreview" => true},
        "secret" => %{}
      })

    ConnectionReconciler.reconcile_once()

    assert [{preview_pid, {_, preview_fp}}] =
             Registry.lookup(Ankole.Plugins.LarkAdapter.ConnectionRegistry, shared_key)

    assert preview_pid != initial_pid
    assert preview_fp != initial_fp

    {:ok, _} =
      Connectors.update_auth_config(owner, shared_auth_id, %{
        "display_name" => "Feishu Shared",
        "slug" => "lark-shared",
        "is_default" => true,
        "public_metadata" => %{"domain" => "feishu", "linkPreview" => false},
        "secret" => %{}
      })

    ConnectionReconciler.reconcile_once()

    assert [{restored_pid, {_, restored_fp}}] =
             Registry.lookup(Ankole.Plugins.LarkAdapter.ConnectionRegistry, shared_key)

    assert Process.alive?(restored_pid)
    assert restored_fp == initial_fp
  end

  defp ensure_private_root(uid) do
    Repo.transact_top_level(fn -> Pod.ensure_private_root_in_tx(uid) end)
  end

  defp ws_preview_roundtrip(consumers, url) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_addr, port}} = :inet.sockname(listener)
    parent = self()

    frame = %Frame{
      seq_id: 42,
      log_id: 99,
      service: 7,
      method: 1,
      headers: [{"type", "card"}],
      payload:
        Torque.encode!(%{
          "schema" => "2.0",
          "header" => %{"event_type" => "url.preview.get"},
          "event" => %{
            "operator" => %{"open_id" => "ou_viewer"},
            "context" => %{"url" => url, "preview_token" => "tok_1"}
          }
        })
    }

    server = spawn_link(fn -> serve_one_ws_frame(listener, parent, frame) end)

    {:ok, task_sup} = Task.Supervisor.start_link()

    client =
      APIClient.new("cli_ws_preview", "secret",
        req_options: [
          plug: fn conn ->
            Req.Test.json(conn, %{"code" => 0, "data" => %{"URL" => "ws://127.0.0.1:#{port}/ws"}})
          end
        ]
      )

    {:ok, pid} =
      Client.start_link(
        client: client,
        dispatcher: Dispatcher.build(consumers, client: client),
        task_supervisor: task_sup,
        auto_reconnect: false
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    try do
      assert_receive {:ws_ack, ^server, {:ok, ack_frame}}, 2_000
      Torque.decode!(ack_frame.payload)
    after
      if Process.alive?(pid), do: Client.stop(pid)
      if Process.alive?(task_sup), do: Supervisor.stop(task_sup)
      send(server, :close)
    end
  end

  defp serve_one_ws_frame(listener, parent, frame) do
    with {:ok, socket} <- :gen_tcp.accept(listener, 1_000),
         :ok <- :gen_tcp.close(listener),
         {:ok, req} <- recv_headers(socket),
         {:ok, key} <- extract_ws_key(req),
         :ok <- :gen_tcp.send(socket, upgrade_101(key)),
         {:ok, {0x2, _initial_ping}} <- recv_client_frame(socket),
         :ok <- :gen_tcp.send(socket, encode_server_frame(0x2, Frame.encode(frame))),
         {:ok, {0x2, ack_bin}} <- recv_client_frame(socket) do
      send(parent, {:ws_ack, self(), Frame.decode(ack_bin)})

      receive do
        :close -> :gen_tcp.close(socket)
      after
        1_000 -> :gen_tcp.close(socket)
      end
    else
      err -> send(parent, {:ws_ack, self(), err})
    end
  end

  defp accept_ws_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn ->
          with {:ok, req} <- recv_headers(socket),
               {:ok, key} <- extract_ws_key(req),
               :ok <- :gen_tcp.send(socket, upgrade_101(key)) do
            Process.sleep(5_000)
          end

          :gen_tcp.close(socket)
        end)

        accept_ws_loop(listener)

      {:error, _} ->
        :ok
    end
  end

  defp recv_headers(socket, buf \\ <<>>) do
    case :binary.match(buf, "\r\n\r\n") do
      :nomatch ->
        with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 1_000),
             do: recv_headers(socket, buf <> chunk)

      _ ->
        {:ok, buf}
    end
  end

  defp extract_ws_key(req) do
    req
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> if String.downcase(k) == "sec-websocket-key", do: String.trim(v)
        _ -> nil
      end
    end)
    |> case do
      key when is_binary(key) -> {:ok, key}
      nil -> {:error, :missing_ws_key}
    end
  end

  defp upgrade_101(key) do
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
  end

  defp encode_server_frame(opcode, payload) when byte_size(payload) < 126,
    do: <<0x80 ||| opcode, byte_size(payload)>> <> payload

  defp encode_server_frame(opcode, payload),
    do: <<0x80 ||| opcode, 126, byte_size(payload)::16>> <> payload

  defp recv_client_frame(socket) do
    with {:ok, <<fin_op, mask_len>>} <- :gen_tcp.recv(socket, 2, 1_000),
         {:ok, len} <- recv_len(socket, mask_len &&& 0x7F),
         {:ok, mask} <- :gen_tcp.recv(socket, 4, 1_000),
         {:ok, masked} <- :gen_tcp.recv(socket, len, 1_000) do
      mask_bytes = :binary.bin_to_list(mask)

      unmasked =
        masked
        |> :binary.bin_to_list()
        |> Enum.with_index()
        |> Enum.map(fn {b, i} -> bxor(b, Enum.at(mask_bytes, rem(i, 4))) end)
        |> :erlang.list_to_binary()

      {:ok, {fin_op &&& 0x0F, unmasked}}
    end
  end

  defp recv_len(_socket, len) when len < 126, do: {:ok, len}

  defp recv_len(socket, 126) do
    with {:ok, <<len::16>>} <- :gen_tcp.recv(socket, 2, 1_000), do: {:ok, len}
  end

  defp recv_len(socket, 127) do
    with {:ok, <<len::64>>} <- :gen_tcp.recv(socket, 8, 1_000), do: {:ok, len}
  end
end
