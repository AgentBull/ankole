defmodule Ankole.Plugins.LarkAdapter.CardKit.ImageResolver do
  @moduledoc """
  Resolves remote Markdown images into Feishu image keys.

  Resolution is enabled by default. The existing
  `security.ssrf_filter` setting controls only whether private and
  loopback hosts are rejected; its default remains open for enterprise intranet
  use. The shared kernel URL classifier always rejects cloud metadata targets.
  """

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Security.SSRFFilter

  @image_pattern ~r/!\[([^\]]*)\]\((https?:\/\/[^\s\)]+)(?:\s+(?:"[^"]*"|'[^']*'))?\)/u
  @max_redirects 5
  @max_image_bytes 20 * 1_024 * 1_024
  @image_body_bytes_key :ankole_lark_image_body_bytes
  @image_body_chunks_key :ankole_lark_image_body_chunks
  @image_too_large_key :ankole_lark_image_too_large

  @type state :: %{optional(String.t()) => map()}

  @spec resolve(map(), String.t(), state(), term(), keyword()) ::
          {:ok, map(), state()} | {:error, term()}
  def resolve(presentation, agent_uid, state, client, opts \\ [])
      when is_map(presentation) and is_binary(agent_uid) and is_map(state) do
    answer = presentation["answer"] || ""
    urls = image_urls(answer)

    unresolved_urls =
      Enum.reject(urls, fn url ->
        match?(%{"status" => status} when status in ["ready", "failed"], state[url])
      end)

    if unresolved_urls == [] do
      {:ok, apply_resolved(presentation, state), state}
    else
      with {:ok, ssrf_filter?} <- SSRFFilter.enabled?(agent_uid),
           {:ok, state} <-
             resolve_urls(unresolved_urls, state, client, ssrf_filter?, opts) do
        {:ok, apply_resolved(presentation, state), state}
      end
    end
  end

  @spec apply_resolved(map(), state()) :: map()
  def apply_resolved(presentation, state) when is_map(presentation) and is_map(state) do
    answer = presentation["answer"] || ""

    rendered =
      Regex.replace(@image_pattern, answer, fn full, alt, url ->
        case state[url] do
          %{"status" => "ready", "image_key" => image_key}
          when is_binary(image_key) and image_key != "" ->
            "![#{alt}](#{image_key})"

          %{"status" => "failed"} ->
            "[#{image_link_label(alt)}](#{url})"

          _unresolved ->
            full
        end
      end)

    Map.put(presentation, "answer", rendered)
  end

  defp image_urls(answer) do
    @image_pattern
    |> Regex.scan(answer, capture: :all_but_first)
    |> Enum.map(fn [_alt, url] -> url end)
    |> Enum.uniq()
  end

  defp resolve_urls(urls, state, client, ssrf_filter?, opts) do
    Enum.reduce_while(urls, {:ok, state}, fn url, {:ok, state} ->
      case state[url] do
        %{"status" => status} when status in ["ready", "failed"] ->
          {:cont, {:ok, state}}

        _missing ->
          case resolve_url(url, client, ssrf_filter?, opts) do
            {:ok, image_key, final_url} ->
              resolved = %{
                "status" => "ready",
                "image_key" => image_key,
                "final_url" => final_url
              }

              {:cont, {:ok, Map.put(state, url, resolved)}}

            {:error, reason} ->
              failed = %{
                "status" => "failed",
                "reason" => inspect(reason, limit: 10, printable_limit: 240)
              }

              {:cont, {:ok, Map.put(state, url, failed)}}
          end
      end
    end)
  end

  defp resolve_url(url, client, ssrf_filter?, opts) do
    fetch_fun = Keyword.get(opts, :image_fetch_fun, &fetch_image/2)
    upload_fun = Keyword.get(opts, :image_upload_fun, &upload_image/4)

    with :ok <- validate_url(url, ssrf_filter?),
         {:ok, fetched} <- fetch_fun.(url, ssrf_filter?),
         :ok <- validate_image(fetched),
         filename <- image_filename(fetched.final_url, fetched.content_type),
         {:ok, image_key} <- upload_fun.(client, fetched.body, filename, fetched.content_type) do
      {:ok, image_key, fetched.final_url}
    end
  end

  defp fetch_image(url, ssrf_filter?) do
    do_fetch_image(url, ssrf_filter?, @max_redirects)
  end

  defp do_fetch_image(_url, _ssrf_filter?, redirects_left) when redirects_left < 0,
    do: {:error, :too_many_image_redirects}

  defp do_fetch_image(url, ssrf_filter?, redirects_left) do
    with :ok <- validate_url(url, ssrf_filter?),
         {:ok, %Req.Response{} = response} <-
           Req.request(
             method: :get,
             url: url,
             redirect: false,
             retry: false,
             receive_timeout: 15_000,
             connect_options: [timeout: 5_000],
             into: &collect_image_body/2
           ) do
      cond do
        Req.Response.get_private(response, @image_too_large_key, false) ->
          {:error, :image_too_large}

        response.status in 200..299 ->
          {:ok,
           %{
             body: collected_image_body(response),
             content_type: response_header(response, "content-type"),
             final_url: url
           }}

        response.status in [301, 302, 303, 307, 308] ->
          with location when is_binary(location) <- response_header(response, "location"),
               {:ok, next_url} <- redirect_url(url, location) do
            do_fetch_image(next_url, ssrf_filter?, redirects_left - 1)
          else
            _missing -> {:error, :image_redirect_location_missing}
          end

        true ->
          {:error, {:image_fetch_status, response.status}}
      end
    end
  end

  defp collect_image_body({:data, chunk}, {request, response}) when is_binary(chunk) do
    bytes = Req.Response.get_private(response, @image_body_bytes_key, 0) + byte_size(chunk)
    response = Req.Response.put_private(response, @image_body_bytes_key, bytes)

    if bytes > @max_image_bytes do
      response = Req.Response.put_private(response, @image_too_large_key, true)
      {:halt, {request, response}}
    else
      response =
        Req.Response.update_private(response, @image_body_chunks_key, [chunk], fn chunks ->
          [chunk | chunks]
        end)

      {:cont, {request, response}}
    end
  end

  defp collected_image_body(response) do
    response
    |> Req.Response.get_private(@image_body_chunks_key, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp validate_url(url, ssrf_filter?) do
    case NativeKernel.validate_web_url(url, ["http", "https"], ssrf_filter?) do
      :ok -> :ok
      {:error, :metadata} -> {:error, :cloud_metadata_image_url_blocked}
      {:error, :private} -> {:error, :private_network_image_url_blocked}
      {:error, :invalid} -> {:error, :invalid_image_url}
    end
  end

  defp validate_image(%{body: body, content_type: content_type}) when is_binary(body) do
    cond do
      byte_size(body) == 0 ->
        {:error, :empty_image_body}

      byte_size(body) > @max_image_bytes ->
        {:error, :image_too_large}

      is_binary(content_type) and String.starts_with?(String.downcase(content_type), "image/") ->
        :ok

      true ->
        {:error, :image_content_type_required}
    end
  end

  defp validate_image(_fetched), do: {:error, :invalid_image_response}

  defp upload_image(client, body, filename, _content_type) do
    case FeishuOpenAPI.upload(client, "im/v1/images",
           fields: [image_type: "message"],
           file_field: :image,
           file: {:iodata, body, filename}
         ) do
      {:ok, %{"data" => %{"image_key" => image_key}}}
      when is_binary(image_key) and image_key != "" ->
        {:ok, image_key}

      {:ok, _response} ->
        {:error, :image_upload_key_missing}

      {:error, _reason} = error ->
        error
    end
  end

  defp redirect_url(current, location) do
    {:ok, current |> URI.parse() |> URI.merge(location) |> URI.to_string()}
  rescue
    ArgumentError -> {:error, :invalid_image_redirect}
  end

  defp response_header(%Req.Response{headers: headers}, name) when is_map(headers) do
    headers
    |> Map.get(name, [])
    |> List.wrap()
    |> List.first()
  end

  defp response_header(%Req.Response{headers: headers}, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == name, do: value

      _header ->
        nil
    end)
  end

  defp response_header(_response, _name), do: nil

  defp image_filename(url, content_type) do
    basename = url |> URI.parse() |> Map.get(:path) |> to_string() |> Path.basename()

    cond do
      basename not in ["", ".", "/"] and Path.extname(basename) != "" -> basename
      true -> "image#{extension_for(content_type)}"
    end
  end

  defp extension_for("image/jpeg" <> _rest), do: ".jpg"
  defp extension_for("image/gif" <> _rest), do: ".gif"
  defp extension_for("image/webp" <> _rest), do: ".webp"
  defp extension_for("image/bmp" <> _rest), do: ".bmp"
  defp extension_for(_content_type), do: ".png"

  defp image_link_label(""), do: "image"
  defp image_link_label(alt), do: alt
end
