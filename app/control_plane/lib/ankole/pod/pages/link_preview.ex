defmodule Ankole.Pod.Pages.LinkPreview do
  @moduledoc """
  Fetches public webpage metadata (title, description, preview image, and site icon)
  for Pod editor link views outside database transactions.

  Outbound requests honor `security.ssrf_filter` and `Ankole.EgressProxy`: cloud
  metadata addresses are always rejected, private/loopback addresses are rejected
  when `security.ssrf_filter` is enabled, each redirect hop is re-validated, and
  one-shot Mint connections stop streaming once `</head>` or the byte ceiling is reached.
  """

  alias Ankole.{AuthZ, EgressProxy, Repo}
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Pod.Access
  alias Ankole.Security.SSRFFilter

  @max_url_bytes 2_048
  @max_redirects 5
  @max_body_bytes 256 * 1_024
  @connect_timeout_ms 4_000
  @receive_timeout_ms 6_000
  @max_title_graphemes 300
  @max_description_graphemes 500

  @named_entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "#39" => "'",
    "nbsp" => " ",
    "ndash" => "–",
    "mdash" => "—",
    "hellip" => "…",
    "middot" => "·",
    "bull" => "•",
    "copy" => "©",
    "reg" => "®",
    "trade" => "™",
    "lsquo" => "‘",
    "rsquo" => "’",
    "ldquo" => "“",
    "rdquo" => "”"
  }

  @type metadata :: %{
          url: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          image: String.t() | nil,
          icon: String.t() | nil
        }

  @spec unfurl(AuthZ.Actor.t(), String.t(), keyword()) ::
          {:ok, metadata()} | {:error, term()}
  def unfurl(%AuthZ.Actor{} = actor, raw_url, opts \\ []) when is_binary(raw_url) do
    with {:ok, ssrf_filter?} <- authorize_and_resolve_policy(actor, opts),
         {:ok, normalized_url} <- normalize_http_url(raw_url) do
      case fetch_metadata(normalized_url, Keyword.put(opts, :ssrf_filter, ssrf_filter?)) do
        {:ok, metadata} ->
          {:ok, metadata}

        {:error, _reason} ->
          {:ok, empty_metadata(normalized_url)}
      end
    end
  end

  defp authorize_and_resolve_policy(actor, opts) do
    Repo.transact_repeatable_read_only(fn ->
      with {:ok, _principal} <- Access.principal(actor) do
        case Keyword.fetch(opts, :ssrf_filter) do
          {:ok, explicit} -> {:ok, explicit == true}
          :error -> SSRFFilter.enabled?()
        end
      end
    end)
  end

  @spec fetch_metadata(String.t(), keyword()) :: {:ok, metadata()} | {:error, term()}
  def fetch_metadata(raw_url, opts \\ []) when is_binary(raw_url) do
    Repo.assert_outside_transaction!()
    ssrf_filter? = Keyword.get(opts, :ssrf_filter, false)
    deadline = System.monotonic_time(:millisecond) + @connect_timeout_ms + @receive_timeout_ms

    with {:ok, url} <- normalize_http_url(raw_url),
         {:ok, fetched} <- do_fetch(url, ssrf_filter?, deadline, @max_redirects) do
      {:ok, parse_html_metadata(fetched.body, fetched.final_url)}
    end
  end

  @spec parse_html_metadata(binary(), String.t()) :: metadata()
  def parse_html_metadata(raw_html, final_url)
      when is_binary(raw_html) and is_binary(final_url) do
    head =
      raw_html
      |> ensure_valid_utf8()
      |> strip_head_noise()
      |> extract_head_slice()

    metas = extract_meta_tags(head)
    links = extract_link_tags(head)

    title =
      first_present([
        meta_content(metas, ["og:title", "twitter:title"]),
        extract_title_tag(head)
      ])
      |> truncate_text(@max_title_graphemes)

    description =
      meta_content(metas, ["og:description", "twitter:description", "description"])
      |> truncate_text(@max_description_graphemes)

    image =
      meta_content(metas, [
        "og:image",
        "og:image:url",
        "og:image:secure_url",
        "twitter:image",
        "twitter:image:src"
      ])
      |> resolve_web_asset_url(final_url)

    icon =
      extract_icon_href(links)
      |> resolve_web_asset_url(final_url)
      |> Kernel.||(default_favicon_url(final_url))

    %{
      url: final_url,
      title: title,
      description: description,
      image: image,
      icon: icon
    }
  end

  @spec normalize_http_url(String.t()) :: {:ok, String.t()} | {:error, :invalid_url}
  def normalize_http_url(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" or byte_size(trimmed) > @max_url_bytes or contains_control_bytes?(trimmed) do
      {:error, :invalid_url}
    else
      with {:ok, ascii} <- iri_to_ascii_url(trimmed),
           {:ok, %URI{scheme: scheme, host: host, userinfo: nil} = uri}
           when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.new(ascii) do
        normalized_path = if uri.path in [nil, ""], do: "/", else: uri.path
        {:ok, URI.to_string(%{uri | path: normalized_path, fragment: nil})}
      else
        _invalid ->
          {:error, :invalid_url}
      end
    end
  end

  defp empty_metadata(url) do
    %{url: url, title: nil, description: nil, image: nil, icon: nil}
  end

  defp do_fetch(_url, _ssrf_filter?, _deadline, redirects_left) when redirects_left < 0,
    do: {:error, :too_many_redirects}

  defp do_fetch(url, ssrf_filter?, deadline, redirects_left) do
    with {:ok, response} <- fetch_single_hop(url, ssrf_filter?, deadline) do
      handle_hop_response(url, response, ssrf_filter?, deadline, redirects_left)
    end
  end

  defp handle_hop_response(url, response, ssrf_filter?, deadline, redirects_left) do
    cond do
      response.status in [301, 302, 303, 307, 308] ->
        with location when is_binary(location) <- response_header(response.headers, "location"),
             {:ok, next_url} <- resolve_redirect_url(url, location) do
          do_fetch(next_url, ssrf_filter?, deadline, redirects_left - 1)
        else
          _ -> {:error, :invalid_redirect}
        end

      response.non_html? ->
        {:error, :unsupported_content_type}

      response.status in 200..299 ->
        if html_content_type?(response_header(response.headers, "content-type")) do
          {:ok, %{body: response.body, final_url: url}}
        else
          {:error, :unsupported_content_type}
        end

      true ->
        {:error, {:http_status, response.status}}
    end
  end

  defp fetch_single_hop(url, ssrf_filter?, deadline) do
    with :ok <- validate_url(url, ssrf_filter?),
         uri = URI.parse(url),
         {:ok, target, connect_opts} <- resolve_connect_target(uri, url, ssrf_filter?, deadline),
         scheme = if(uri.scheme == "https", do: :https, else: :http),
         port = uri.port || URI.default_port(uri.scheme),
         {:ok, conn} <- Mint.HTTP.connect(scheme, target, port, connect_opts) do
      try do
        send_and_collect(conn, uri, deadline)
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  defp resolve_connect_target(uri, url, ssrf_filter?, deadline) do
    timeout = min(@connect_timeout_ms, max(deadline - System.monotonic_time(:millisecond), 0))

    if timeout <= 0 do
      {:error, :timeout}
    else
      proxy_opts = Keyword.get(EgressProxy.req_options(url), :connect_options, [])
      build_connect_target(uri, proxy_opts, ssrf_filter?, timeout)
    end
  end

  defp build_connect_target(uri, [], ssrf_filter?, timeout) do
    with {:ok, addresses} <- resolve_addresses(uri.host),
         :ok <- validate_addresses(addresses, ssrf_filter?) do
      address = hd(addresses)

      opts = [
        mode: :passive,
        protocols: [:http1],
        hostname: uri.host,
        transport_opts: [timeout: timeout, inet6: tuple_size(address) == 8]
      ]

      {:ok, address, opts}
    end
  end

  defp build_connect_target(uri, proxy_opts, _ssrf_filter?, timeout) do
    opts =
      Keyword.merge(
        [
          mode: :passive,
          protocols: [:http1],
          hostname: uri.host,
          transport_opts: [timeout: timeout]
        ],
        proxy_opts
      )

    {:ok, uri.host, opts}
  end

  defp send_and_collect(conn, uri, deadline) do
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    headers = [
      {"host", format_host_header(uri)},
      {"accept", "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1"},
      {"accept-encoding", "identity"},
      {"accept-language", "zh-CN,zh;q=0.9,en;q=0.8"},
      {"user-agent", "Mozilla/5.0 (compatible; AnkoleLinkPreview/1.0)"},
      {"connection", "close"}
    ]

    case Mint.HTTP.request(conn, "GET", path, headers, nil) do
      {:ok, conn, ref} ->
        state = %{
          conn: conn,
          ref: ref,
          status: nil,
          headers: [],
          chunks: [],
          bytes: 0,
          tail: "",
          non_html?: false,
          done?: false,
          zstream: nil
        }

        receive_head_loop(state, deadline)

      {:error, _conn, reason} ->
        {:error, reason}
    end
  end

  defp receive_head_loop(state, deadline) do
    try do
      do_receive_head_loop(state, deadline)
    after
      close_zstream(state.zstream)
    end
  end

  defp do_receive_head_loop(%{done?: true} = state, _deadline) do
    close_zstream(state.zstream)
    body = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    {:ok, %{status: state.status, headers: state.headers, body: body, non_html?: state.non_html?}}
  end

  defp do_receive_head_loop(state, deadline) do
    remaining_ms = min(@receive_timeout_ms, deadline - System.monotonic_time(:millisecond))

    if remaining_ms <= 0 do
      close_zstream(state.zstream)
      {:error, :timeout}
    else
      case Mint.HTTP.recv(state.conn, 0, remaining_ms) do
        {:ok, conn, responses} ->
          case apply_mint_responses(responses, %{state | conn: conn}) do
            {:ok, next_state} ->
              if next_state.zstream != state.zstream and state.zstream != nil,
                do: close_zstream(state.zstream)

              do_receive_head_loop(next_state, deadline)

            {:error, _} = error ->
              close_zstream(state.zstream)
              error
          end

        {:error, _conn, :closed, responses} when responses != [] ->
          case apply_mint_responses(responses, state) do
            {:ok, next_state} -> do_receive_head_loop(%{next_state | done?: true}, deadline)
            {:error, _} = error -> error
          end

        {:error, _conn, reason, _responses} ->
          close_zstream(state.zstream)
          {:error, reason}
      end
    end
  end

  defp apply_mint_responses(responses, initial) do
    Enum.reduce_while(responses, {:ok, initial}, fn message, {:ok, state} ->
      case apply_mint_message(message, state) do
        {:ok, %{done?: true} = halted} ->
          {:halt, {:ok, halted}}

        {:ok, next} ->
          {:cont, {:ok, next}}

        {:error, _} = error ->
          close_zstream(state.zstream)
          {:halt, error}
      end
    end)
  end

  defp apply_mint_message({:status, ref, status}, %{ref: ref} = state),
    do: {:ok, %{state | status: status}}

  defp apply_mint_message({:headers, ref, headers}, %{ref: ref} = state) do
    merged = state.headers ++ headers

    cond do
      state.status in [301, 302, 303, 307, 308] ->
        {:ok, %{state | headers: merged, done?: true}}

      state.status in 200..299 and not html_content_type?(response_header(merged, "content-type")) ->
        {:ok, %{state | headers: merged, non_html?: true, done?: true}}

      true ->
        zstream = maybe_open_zstream(state.zstream, response_header(merged, "content-encoding"))
        {:ok, %{state | headers: merged, zstream: zstream}}
    end
  end

  defp apply_mint_message({:data, ref, chunk}, %{ref: ref} = state) when is_binary(chunk) do
    remaining = max(@max_body_bytes - state.bytes, 0)

    if remaining == 0 do
      {:ok, %{state | done?: true}}
    else
      with {:ok, decoded} <- decode_chunk(state.zstream, chunk, remaining) do
        append_body_chunk(state, decoded)
      end
    end
  end

  defp apply_mint_message({:done, ref}, %{ref: ref} = state),
    do: {:ok, %{state | done?: true}}

  defp apply_mint_message(_other, state), do: {:ok, state}

  defp append_body_chunk(state, ""), do: {:ok, state}

  defp append_body_chunk(state, chunk) do
    remaining = max(@max_body_bytes - state.bytes, 0)
    slice = if byte_size(chunk) > remaining, do: binary_part(chunk, 0, remaining), else: chunk
    bytes = state.bytes + byte_size(slice)
    window = state.tail <> slice
    next_chunks = [slice | state.chunks]

    head_closed? =
      contains_head_close?(window) and
        next_chunks
        |> Enum.reverse()
        |> IO.iodata_to_binary()
        |> ensure_valid_utf8()
        |> strip_head_noise()
        |> contains_head_close?()

    done? = bytes >= @max_body_bytes or head_closed?

    {:ok,
     %{
       state
       | bytes: bytes,
         tail: tail_bytes(window, 6),
         chunks: next_chunks,
         done?: done?
     }}
  end

  defp maybe_open_zstream(nil, encoding) when is_binary(encoding) do
    case encoding |> String.trim() |> String.downcase() do
      enc when enc in ["gzip", "x-gzip", "deflate"] ->
        z = :zlib.open()
        :ok = :zlib.inflateInit(z, 47)
        z

      _ ->
        nil
    end
  end

  defp maybe_open_zstream(existing, _encoding), do: existing

  defp decode_chunk(nil, chunk, _limit), do: {:ok, chunk}

  defp decode_chunk(zstream, chunk, limit) do
    inflate_bounded(zstream, chunk, [], 0, limit)
  rescue
    ErlangError -> {:error, :invalid_compressed_body}
  end

  defp inflate_bounded(zstream, data, parts, size, limit) do
    case :zlib.safeInflate(zstream, data) do
      {:continue, output} ->
        next_size = size + IO.iodata_length(output)
        next_parts = [parts, output]

        if next_size >= limit,
          do: {:ok, IO.iodata_to_binary(next_parts)},
          else: inflate_bounded(zstream, [], next_parts, next_size, limit)

      {:finished, output} ->
        {:ok, IO.iodata_to_binary([parts, output])}

      {:need_dictionary, _adler, _output} ->
        {:error, :invalid_compressed_body}
    end
  end

  defp close_zstream(nil), do: :ok

  defp close_zstream(zstream) do
    :zlib.close(zstream)
  rescue
    ArgumentError -> :ok
  end

  defp format_host_header(%URI{host: host, port: port, scheme: scheme}) do
    bracketed =
      if String.contains?(host, ":") and not String.starts_with?(host, "["),
        do: "[#{host}]",
        else: host

    if port in [nil, URI.default_port(scheme)], do: bracketed, else: "#{bracketed}:#{port}"
  end

  defp resolve_addresses(host) when is_binary(host) do
    trimmed = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(to_charlist(trimmed)) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, _} ->
        addresses =
          for family <- [:inet, :inet6],
              {:ok, resolved} <- [:inet.getaddrs(to_charlist(trimmed), family)],
              address <- resolved,
              do: address

        case Enum.uniq(addresses) do
          [] -> {:error, :dns_resolution_failed}
          list -> {:ok, list}
        end
    end
  end

  defp validate_url(url, ssrf_filter?) do
    case NativeKernel.validate_web_url(url, ["http", "https"], ssrf_filter?) do
      :ok -> :ok
      {:error, :metadata} -> {:error, :metadata_url_blocked}
      {:error, :private} -> {:error, :private_url_blocked}
      {:error, :invalid} -> {:error, :invalid_url}
    end
  end

  defp validate_addresses(addresses, ssrf_filter?) do
    ip_strings = Enum.map(addresses, &to_string(:inet.ntoa(&1)))

    case NativeKernel.validate_ip_addresses(ip_strings, ssrf_filter?) do
      :ok -> :ok
      {:error, :metadata} -> {:error, :metadata_url_blocked}
      {:error, :private} -> {:error, :private_url_blocked}
      {:error, :invalid} -> {:error, :invalid_url}
    end
  end

  defp tail_bytes(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp tail_bytes(binary, max_bytes) do
    binary_part(binary, byte_size(binary) - max_bytes, max_bytes)
  end

  defp contains_head_close?(window) when is_binary(window) do
    Regex.match?(~r/<\/head>/i, window)
  end

  defp html_content_type?(nil), do: true

  defp html_content_type?(content_type) when is_binary(content_type) do
    media_type =
      content_type
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    media_type in ["", "text/html", "application/xhtml+xml"]
  end

  defp resolve_redirect_url(current_url, location) do
    with {:ok, ref} <- iri_reference_to_ascii(String.trim(location)) do
      merged = current_url |> URI.parse() |> URI.merge(ref) |> URI.to_string()
      normalize_http_url(merged)
    else
      _ -> {:error, :invalid_redirect}
    end
  rescue
    ArgumentError -> {:error, :invalid_redirect}
  end

  defp response_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == name, do: value

      _ ->
        nil
    end)
  end

  defp extract_head_slice(html) do
    case Regex.run(~r/\A[\s\S]*?<\/head>/iu, html) do
      [head] -> head
      nil -> html
    end
  end

  defp strip_head_noise(head) do
    head
    |> String.replace(~r/<!--[\s\S]*?(?:-->|\z)/u, " ")
    |> String.replace(~r/<(script|style|template|noscript)\b[^>]*>[\s\S]*?(?:<\/\1>|\z)/iu, " ")
  end

  defp extract_title_tag(html) do
    case Regex.run(~r/<title(?:\s[^>]*)?>([\s\S]*?)<\/title>/iu, html, capture: :all_but_first) do
      [raw] -> clean_text(raw)
      _ -> nil
    end
  end

  defp extract_meta_tags(html) do
    ~r/<meta\s+((?:"[^"]*"|'[^']*'|[^>"'])*)>/iu
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [attrs_raw] -> parse_attributes(attrs_raw) end)
  end

  defp extract_link_tags(html) do
    ~r/<link\s+((?:"[^"]*"|'[^']*'|[^>"'])*)>/iu
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [attrs_raw] -> parse_attributes(attrs_raw) end)
  end

  defp parse_attributes(raw) do
    ~r/([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/u
    |> Regex.scan(raw, capture: :all_but_first)
    |> Enum.reduce(%{}, fn
      [name, dq, "", ""], acc ->
        Map.put_new(acc, String.downcase(name), dq)

      [name, "", sq, ""], acc ->
        Map.put_new(acc, String.downcase(name), sq)

      [name, "", "", bare], acc ->
        Map.put_new(acc, String.downcase(name), bare)

      [name | values], acc ->
        Map.put_new(acc, String.downcase(name), Enum.find(values, "", &(&1 != "")))
    end)
  end

  defp meta_content(metas, keys) do
    Enum.find_value(keys, fn target ->
      Enum.find_value(metas, fn attrs ->
        matched? =
          Enum.any?(["property", "name", "itemprop"], fn attr ->
            String.downcase(attrs[attr] || "") == target
          end)

        if matched? do
          clean_text(attrs["content"])
        end
      end)
    end)
  end

  defp extract_icon_href(links) do
    priorities = ["icon", "shortcut icon", "apple-touch-icon", "apple-touch-icon-precomposed"]

    Enum.find_value(priorities, fn expected ->
      Enum.find_value(links, fn attrs ->
        rel =
          attrs
          |> Map.get("rel", "")
          |> String.downcase()
          |> String.split(~r/\s+/, trim: true)

        href = Map.get(attrs, "href", "") |> decode_html_entities() |> String.trim()

        cond do
          href == "" or String.starts_with?(String.downcase(href), "data:") ->
            nil

          expected == "shortcut icon" and "shortcut" in rel and "icon" in rel ->
            href

          expected in rel ->
            href

          true ->
            nil
        end
      end)
    end)
  end

  defp resolve_web_asset_url(nil, _base_url), do: nil
  defp resolve_web_asset_url("", _base_url), do: nil

  defp resolve_web_asset_url(candidate, base_url) do
    with {:ok, ref} <- iri_reference_to_ascii(String.trim(candidate)),
         merged <- base_url |> URI.parse() |> URI.merge(ref) |> URI.to_string(),
         {:ok, valid} <- normalize_http_url(merged) do
      valid
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp default_favicon_url(final_url) do
    case URI.parse(final_url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        URI.to_string(%URI{scheme: scheme, host: host, port: port, path: "/favicon.ico"})

      _ ->
        nil
    end
  end

  defp clean_text(nil), do: nil

  defp clean_text(value) when is_binary(value) do
    cleaned =
      value
      |> decode_html_entities()
      |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if cleaned == "", do: nil, else: cleaned
  end

  defp truncate_text(nil, _max), do: nil

  defp truncate_text(value, max) do
    if String.length(value) <= max do
      value
    else
      String.slice(value, 0, max - 1) <> "…"
    end
  end

  defp first_present(values), do: Enum.find(values, &(is_binary(&1) and &1 != ""))

  defp decode_html_entities(text) when is_binary(text) do
    Regex.replace(~r/&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z0-9]+);/u, text, fn full, entity ->
      cond do
        Map.has_key?(@named_entities, String.downcase(entity)) ->
          Map.fetch!(@named_entities, String.downcase(entity))

        String.starts_with?(entity, "#x") or String.starts_with?(entity, "#X") ->
          decode_codepoint(String.slice(entity, 2..-1//1), 16, full)

        String.starts_with?(entity, "#") ->
          decode_codepoint(String.slice(entity, 1..-1//1), 10, full)

        true ->
          full
      end
    end)
  end

  defp decode_codepoint(digits, base, fallback) do
    case Integer.parse(digits, base) do
      {codepoint, ""}
      when codepoint > 0 and codepoint <= 0x10FFFF and codepoint not in 0xD800..0xDFFF ->
        <<codepoint::utf8>>

      _ ->
        fallback
    end
  end

  defp ensure_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> String.chunk(:valid)
      |> Enum.map_join(fn part ->
        if String.valid?(part),
          do: part,
          else: :unicode.characters_to_binary(part, :latin1, :utf8)
      end)
    end
  end

  defp contains_control_bytes?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.any?(fn byte -> byte <= 0x1F or byte == 0x7F end)
  end

  defp iri_to_ascii_url(raw) do
    case Regex.run(~r/\A([a-zA-Z][a-zA-Z0-9+.-]*:\/\/)([^\/?#]*)(.*)\z/su, raw,
           capture: :all_but_first
         ) do
      [scheme_sep, authority, rest] ->
        with {:ok, ascii_authority} <- ascii_authority(authority) do
          {:ok, scheme_sep <> ascii_authority <> percent_encode_iri(rest)}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  defp iri_reference_to_ascii(raw) do
    cond do
      raw == "" or contains_control_bytes?(raw) ->
        {:error, :invalid_url}

      Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9+.-]*:\/\//u, raw) ->
        iri_to_ascii_url(raw)

      String.starts_with?(raw, "//") ->
        case Regex.run(~r/\A\/\/([^\/?#]*)(.*)\z/su, raw, capture: :all_but_first) do
          [authority, rest] ->
            with {:ok, ascii_authority} <- ascii_authority(authority) do
              {:ok, "//" <> ascii_authority <> percent_encode_iri(rest)}
            end

          _ ->
            {:error, :invalid_url}
        end

      true ->
        {:ok, percent_encode_iri(raw)}
    end
  end

  defp ascii_authority(authority) do
    cond do
      authority == "" or String.contains?(authority, "@") ->
        {:error, :invalid_url}

      String.starts_with?(authority, "[") ->
        {:ok, authority}

      true ->
        {host, port_suffix} =
          case String.split(authority, ":", parts: 2) do
            [h, p] -> {h, ":" <> p}
            [h] -> {h, ""}
          end

        with {:ok, ascii_host} <- idna_host(host) do
          {:ok, ascii_host <> port_suffix}
        end
    end
  end

  defp idna_host(""), do: {:error, :invalid_url}

  defp idna_host(host) do
    if String.printable?(host) and Enum.all?(:binary.bin_to_list(host), &(&1 < 0x80)) do
      {:ok, host}
    else
      encoded = host |> String.to_charlist() |> :idna.encode() |> List.to_string()
      {:ok, encoded}
    end
  rescue
    _ -> {:error, :invalid_url}
  catch
    _, _ -> {:error, :invalid_url}
  end

  defp percent_encode_iri(binary) do
    for <<byte <- binary>>, into: "" do
      if byte >= 0x80 or byte == ?\s do
        "%" <> Base.encode16(<<byte>>)
      else
        <<byte>>
      end
    end
  end
end
