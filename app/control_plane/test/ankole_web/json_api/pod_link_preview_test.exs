defmodule AnkoleWeb.JSONAPI.PodLinkPreviewTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod

  alias Ankole.Pod.Pages.LinkPreview

  defmodule PreviewTestPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      case conn.request_path do
        "/paper" ->
          html = """
          <!doctype html>
          <html>
            <head>
              <meta charset="utf-8" />
              <title>Fallback Title</title>
              <meta content="GDPval: Evaluating AI Model Performance &amp; Value" property="og:title" />
              <meta name="twitter:description" content="We introduce GDPval &#8212; a real-world benchmark." />
              <meta property="og:image" content="/static/arxiv-logo.png" />
              <link rel="shortcut icon" href="/static/favicon.svg" />
            </head>
            <body>
              #{String.duplicate("<p>Large body content</p>", 5_000)}
            </body>
          </html>
          """

          conn
          |> put_resp_content_type("text/html; charset=utf-8")
          |> send_resp(200, html)

        "/plain" ->
          html = """
          <!doctype html>
          <html>
            <head>
              <title>  Plain   Document &lt;Draft&gt;  </title>
              <meta name="description" content="Concise summary of the page." />
            </head>
            <body>Hello</body>
          </html>
          """

          conn
          |> put_resp_content_type("text/html")
          |> send_resp(200, html)

        "/redirect" ->
          conn
          |> put_resp_header("location", "/sub/final")
          |> send_resp(302, "")

        "/sub/final" ->
          html = """
          <!doctype html>
          <html>
            <head>
              <title>Final Destination</title>
              <meta property="og:image" content="cover.jpg" />
            </head>
            <body>Moved</body>
          </html>
          """

          conn
          |> put_resp_content_type("text/html")
          |> send_resp(200, html)

        "/redirect-metadata" ->
          conn
          |> put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
          |> send_resp(302, "")

        "/file.pdf" ->
          conn
          |> put_resp_content_type("application/pdf")
          |> send_resp(200, "%PDF-1.7 binary payload")

        "/arrows" ->
          conn =
            conn
            |> put_resp_content_type("text/html; charset=utf-8")
            |> send_chunked(200)

          {:ok, conn} =
            chunk(
              conn,
              ~s(<html><head><!-- <meta property="og:title" content="Commented Out" /> --><script>const s = '<meta property="og:title" content="From Script" />';</script><meta property="og:title" content="Result<T, E> -> Ok" /><meta name="description" content="A > B => C" /></he)
            )

          {:ok, conn} = chunk(conn, "ad><body>Done</body></html>")
          conn

        "/gzipped" ->
          compressed =
            :zlib.gzip(
              ~s(<!doctype html><html><head><title>Compressed Page</title><meta name="description" content="Gzipped summary" /></head><body>Body</body></html>)
            )

          conn
          |> put_resp_header("content-type", "text/html; charset=utf-8")
          |> put_resp_header("content-encoding", "gzip")
          |> send_resp(200, compressed)

        _ ->
          send_resp(conn, 404, "not found")
      end
    end
  end

  setup do
    server =
      start_supervised!(
        {Bandit, plug: PreviewTestPlug, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{base_url: "http://127.0.0.1:#{port}"}
  end

  test "POST /api/v2/pod/links/unfurl requires authentication and extracts OpenGraph, fallback tags, and redirects",
       %{conn: conn, base_url: base_url} do
    unauthenticated = api_post(conn, "/api/v2/pod/links/unfurl", %{url: "#{base_url}/paper"})
    assert response(unauthenticated, 401)

    {authed_conn, _uid} = console_conn_with_principal(conn)

    paper_conn = api_post(authed_conn, "/api/v2/pod/links/unfurl", %{url: "#{base_url}/paper"})

    assert api_response(paper_conn, 200) == %{
             "url" => "#{base_url}/paper",
             "title" => "GDPval: Evaluating AI Model Performance & Value",
             "description" => "We introduce GDPval — a real-world benchmark.",
             "image" => "#{base_url}/static/arxiv-logo.png",
             "icon" => "#{base_url}/static/favicon.svg"
           }

    plain_conn =
      paper_conn
      |> recycle_api()
      |> api_post("/api/v2/pod/links/unfurl", %{url: "#{base_url}/plain"})

    assert api_response(plain_conn, 200) == %{
             "url" => "#{base_url}/plain",
             "title" => "Plain Document <Draft>",
             "description" => "Concise summary of the page.",
             "image" => nil,
             "icon" => "#{base_url}/favicon.ico"
           }

    redirected_conn =
      plain_conn
      |> recycle_api()
      |> api_post("/api/v2/pod/links/unfurl", %{url: "#{base_url}/redirect"})

    assert api_response(redirected_conn, 200) == %{
             "url" => "#{base_url}/sub/final",
             "title" => "Final Destination",
             "description" => nil,
             "image" => "#{base_url}/sub/cover.jpg",
             "icon" => "#{base_url}/favicon.ico"
           }

    arrows_conn =
      redirected_conn
      |> recycle_api()
      |> api_post("/api/v2/pod/links/unfurl", %{url: "#{base_url}/arrows"})

    assert api_response(arrows_conn, 200) == %{
             "url" => "#{base_url}/arrows",
             "title" => "Result<T, E> -> Ok",
             "description" => "A > B => C",
             "image" => nil,
             "icon" => "#{base_url}/favicon.ico"
           }

    gzip_conn =
      arrows_conn
      |> recycle_api()
      |> api_post("/api/v2/pod/links/unfurl", %{url: "#{base_url}/gzipped"})

    assert api_response(gzip_conn, 200) == %{
             "url" => "#{base_url}/gzipped",
             "title" => "Compressed Page",
             "description" => "Gzipped summary",
             "image" => nil,
             "icon" => "#{base_url}/favicon.ico"
           }
  end

  test "LinkPreview supports IPv6 URLs without registering permanent Finch pools" do
    case :gen_tcp.listen(0, [:inet6, {:ip, {0, 0, 0, 0, 0, 0, 0, 1}}]) do
      {:ok, probe} ->
        :gen_tcp.close(probe)

        v6_server =
          start_supervised!(
            {Bandit, plug: PreviewTestPlug, scheme: :http, ip: {0, 0, 0, 0, 0, 0, 0, 1}, port: 0},
            id: :preview_ipv6_server
          )

        {:ok, {_ip, v6_port}} = ThousandIsland.listener_info(v6_server)
        v6_base = "http://[::1]:#{v6_port}"

        assert {:ok, metadata} =
                 LinkPreview.fetch_metadata("#{v6_base}/plain", ssrf_filter: false)

        assert metadata == %{
                 url: "#{v6_base}/plain",
                 title: "Plain Document <Draft>",
                 description: "Concise summary of the page.",
                 image: nil,
                 icon: "#{v6_base}/favicon.ico"
               }

      {:error, _} ->
        :ok
    end
  end

  test "POST /api/v2/pod/links/unfurl degrades non-HTML and upstream errors cleanly while rejecting non-HTTP URLs",
       %{conn: conn, base_url: base_url} do
    {authed_conn, _uid} = console_conn_with_principal(conn)

    pdf_conn = api_post(authed_conn, "/api/v2/pod/links/unfurl", %{url: "#{base_url}/file.pdf"})

    assert api_response(pdf_conn, 200) == %{
             "url" => "#{base_url}/file.pdf",
             "title" => nil,
             "description" => nil,
             "image" => nil,
             "icon" => nil
           }

    Enum.reduce(
      [
        "javascript:alert(1)",
        "data:text/html,<title>x</title>",
        "https://user:pw@example.com",
        ""
      ],
      pdf_conn,
      fn invalid, prev_conn ->
        next_conn =
          prev_conn
          |> recycle_api()
          |> api_post("/api/v2/pod/links/unfurl", %{url: invalid})

        assert %{"code" => "invalid_url"} = api_error(next_conn, 422)
        next_conn
      end
    )
  end

  test "LinkPreview enforces cloud-metadata and SSRF filter rules including redirect hops",
       %{base_url: base_url} do
    assert {:error, :metadata_url_blocked} =
             LinkPreview.fetch_metadata("http://169.254.169.254/latest/meta-data/",
               ssrf_filter: false
             )

    assert {:error, :metadata_url_blocked} =
             LinkPreview.fetch_metadata("#{base_url}/redirect-metadata", ssrf_filter: false)

    assert {:error, :private_url_blocked} =
             LinkPreview.fetch_metadata("#{base_url}/paper", ssrf_filter: true)

    assert {:error, :unsupported_content_type} =
             LinkPreview.fetch_metadata("#{base_url}/file.pdf", ssrf_filter: false)
  end
end
