defmodule Ankole.Sessions.Tools.Web do
  @behaviour Ankole.Sessions.Tool
  @moduledoc false
  @declarations Ankole.JSON.decode!(~S"""
                [
                {
                  "type": "function",
                  "name": "web_search",
                  "run_kinds": ["main", "ambient", "scheduled", "workflow_task"],
                  "activity": "web_search",
                  "description": "Search the public web through the configured AIGateway web search provider.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "query": {
                        "type": "string",
                        "minLength": 1,
                        "description": "Search query."
                      },
                      "limit": {
                        "description": "Maximum result count. Defaults to 5.",
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 100
                      }
                    },
                    "required": [
                      "query"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "parallel",
                  "read_only": true,
                  "destructive": false
                },
                {
                  "type": "function",
                  "name": "web_fetch",
                  "run_kinds": ["main", "ambient", "scheduled", "workflow_task"],
                  "activity": "web_fetch",
                  "description": "Extract and return readable text from HTTPS web pages through AIGateway, with an internal rendered-page fallback when the provider is unavailable. This tool returns text only, never binary file content. Do not use web_fetch for PDFs, archives, images, audio/video, executables, or other binary files; use the command shell tool to run aria2c for those downloads. Pass all needed text-page URLs in one call. One call returns a bounded page-text window. A longer page returns next_offset; call web_fetch with the same URL and result_offset to read the next window. The text is held in this run and is fetched again after recovery.",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "result_offset": {"type": "integer", "minimum": 0, "description": "UTF-8 byte offset from next_offset. Defaults to 0."},
                      "urls": {
                        "minItems": 1,
                        "maxItems": 5,
                        "type": "array",
                        "items": {
                          "type": "string",
                          "format": "uri"
                        },
                        "description": "HTTPS web-page URLs whose readable text should be extracted. Do not pass binary-file URLs. Maximum 5."
                      }
                    },
                    "required": [
                      "urls"
                    ],
                    "additionalProperties": false
                  },
                  "execution_mode": "sequential",
                  "read_only": true,
                  "destructive": false
                }
                ]
                """)
  @impl true
  def normalize(_name, args), do: args

  @impl true
  def declarations, do: @declarations
  @impl true
  def declarations(run) do
    hosted? =
      get_in(run.spec.request_context, ["ai_agent", "provider_hosted", "web_search"]) == true

    Enum.reject(@declarations, &(&1["name"] == "web_search" and hosted?))
  end

  @impl true
  def activity(%{name: "web_search"}, args, _phase, _result),
    do:
      {"web_search",
       %{"query" => Ankole.Sessions.Presentation.activity_excerpt(args["query"], 48)}}

  def activity(%{name: "web_fetch"}, args, _phase, result) do
    urls = args["urls"] || []
    pages = if result && is_map(result.details), do: result.details["results"] || [], else: []
    page = Enum.find(pages, &is_binary(&1["title"])) || List.first(pages) || %{}
    host = URI.parse(page["url"] || List.first(urls) || "").host

    title =
      if is_binary(page["title"]),
        do: "《#{Ankole.Sessions.Presentation.activity_excerpt(page["title"], 40)}》"

    target = [title, host] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
    key = if length(urls) == 1, do: "web_fetch", else: "web_fetch_many"

    {key <> if(target == "", do: "", else: "_target"),
     %{"target" => target, "count" => length(urls)}}
  end

  alias Ankole.AIGateway
  alias Ankole.Sessions.Tools

  @impl true
  def execute(run, %{"name" => "web_search"}, args) do
    with {:ok, response} <-
           AIGateway.create_web_search(
             run.agent_uid,
             Map.put(args, "model", "web_search.default")
           ) do
      results = response.body["results"] || []

      text =
        results
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {result, index} ->
          ["#{index}. #{result["title"] || "(untitled)"}", result["url"], result["snippet"]]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.join("\n")
        end)

      {:ok,
       Tools.result(response.body, text: if(text == "", do: "No web search results.", else: text))}
    end
  end

  def execute(run, %{"name" => "web_fetch"}, args) do
    with :ok <- validate_urls(args["urls"]), do: fetch(run, args)
  end

  defp fetch(run, args) do
    now = System.system_time(:millisecond)
    cached = Map.new(args["urls"], fn url -> {url, cache(run, url, now)} end)
    missing = args["urls"] |> Enum.uniq() |> Enum.reject(&cached[&1])

    result =
      if missing == [],
        do: {:ok, %{body: %{"results" => []}}},
        else:
          AIGateway.create_web_fetch(run.agent_uid, %{
            "model" => "web_fetch.default",
            "urls" => missing
          })

    offset = args["result_offset"] || 0

    case result do
      {:ok, response} ->
        render(run, response.body, args["urls"], cached, now, missing, offset)

      # The Agent's computer renders the pages in a browser; this module windows
      # its result like a gateway result.
      {:error, _reason} ->
        {:ok,
         {:delegate, "__rendered_web_fetch", %{"urls" => args["urls"]},
          fn run, rendered ->
            {:ok, result} = render(run, rendered.details, args["urls"], offset)
            result
          end}}
    end
  end

  def render(run, body, urls, offset \\ 0) do
    with :ok <- validate_urls(urls),
         do: render(run, body, urls, %{}, System.system_time(:millisecond), urls, offset)
  end

  defp validate_urls(urls) do
    if Enum.all?(urls, fn url ->
         case URI.new(url) do
           {:ok, %{scheme: scheme, host: host}} when is_binary(scheme) and is_binary(host) ->
             String.downcase(scheme) == "https" and host != ""

           _ ->
             false
         end
       end), do: :ok, else: {:error, "web_fetch requires HTTPS URLs"}
  end

  @max_result_bytes 8_000

  defp render(_run, body, urls, cached, now, missing, offset) do
    by_url = Map.new(Enum.zip(missing, body["results"] || []))

    {pages, new_cache} =
      Enum.map_reduce(urls, %{}, fn url, cache ->
        page = cached[url] || by_url[url] || %{"error" => "No web fetch result."}
        text = page["text"] || ""
        warning = AIGateway.web_fetch_render_warning(page)

        info =
          %{
            "url" => url,
            "title" => bounded(page["title"], 256),
            "source" => bounded(get_in(page, ["metadata", "source"]) || body["source"], 128),
            "error" => bounded(page["error"], 256),
            "render_warning" => warning,
            "note" => warning_note(warning),
            "repeat_fetch" => not is_nil(cached[url]),
            "text" => "",
            "total_bytes" => byte_size(text),
            "next_offset" => byte_size(text)
          }
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        cache =
          if not Map.has_key?(info, "error") and is_nil(warning),
            do: Map.put(cache, url, %{at: now, page: page}),
            else: cache

        {{info, text}, cache}
      end)

    overhead = byte_size(Ankole.JSON.encode!(%{"results" => Enum.map(pages, &elem(&1, 0))}))

    if overhead + length(pages) * 64 >= @max_result_bytes do
      {:ok,
       Tools.error("The URL metadata exceeds one result window. Fetch fewer or shorter URLs.")}
    else
      budget = div(@max_result_bytes - overhead, max(length(pages), 1)) - 64
      results = Enum.map(pages, fn {info, text} -> window(info, text, offset, budget) end)
      {:ok, Tools.result(%{"results" => results}, web_cache: new_cache)}
    end
  end

  defp window(info, text, offset, budget) when offset >= 0 and offset <= byte_size(text) do
    remaining = binary_part(text, offset, byte_size(text) - offset)

    if String.valid?(remaining) do
      build = fn body, next -> %{info | "text" => body, "next_offset" => next} end
      limit = budget + byte_size(Ankole.JSON.encode!(info))

      case Tools.window(remaining, offset, byte_size(text), build, limit) do
        {:ok, result} -> result.details
        {:error, reason} -> Map.put(info, "error", to_string(reason))
      end
    else
      Map.put(info, "error", "invalid_result_offset")
    end
  end

  defp window(info, _text, _offset, _budget), do: Map.put(info, "error", "invalid_result_offset")

  defp warning_note("script_shell"),
    do:
      "[Not rendered: this page served a script-loading shell instead of its content. Fetching the same URL again usually returns the same shell; find the material at a different URL — the site's API, a specific article page, an archive copy — or search for the page title.]"

  defp warning_note("empty_text"),
    do:
      "[No text: this fetch succeeded but extracted no page text. Fetching the same URL again usually returns the same; switch to a more specific URL or a different source.]"

  defp warning_note(_), do: nil
  defp bounded(value, limit) when is_binary(value), do: Ankole.Text.utf8_prefix(value, limit)
  defp bounded(_, _), do: nil

  defp cache(run, url, now) do
    case run.web_cache[url] do
      %{at: at, page: page} when now - at <= 900_000 -> page
      _ -> nil
    end
  end
end
