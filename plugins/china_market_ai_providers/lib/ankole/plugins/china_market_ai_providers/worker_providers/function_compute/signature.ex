defmodule Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute.Signature do
  @moduledoc "ACS3 request signing for the Sandbox and NAS OpenAPI services."

  def sign(method, uri, headers, body, secrets) do
    headers = Enum.sort(headers)
    names = Enum.map_join(headers, ";", &elem(&1, 0))
    canonical_headers = Enum.map_join(headers, "", fn {k, v} -> k <> ":" <> v <> "\n" end)

    canonical =
      Enum.join(
        [
          method |> to_string() |> String.upcase(),
          uri.path,
          uri.query || "",
          canonical_headers,
          names,
          hash(body)
        ],
        "\n"
      )

    signature =
      :crypto.mac(
        :hmac,
        :sha256,
        secrets["accessKeySecret"],
        "ACS3-HMAC-SHA256\n" <> hash(canonical)
      )
      |> Base.encode16(case: :lower)

    authorization =
      "ACS3-HMAC-SHA256 Credential=#{secrets["accessKeyId"]},SignedHeaders=#{names},Signature=#{signature}"

    [{"authorization", authorization} | headers]
  end

  def query(params) do
    params
    |> Enum.map(fn {k, v} -> {path(to_string(k)), path(to_string(v))} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> k <> "=" <> v end)
  end

  def path(value), do: URI.encode(value, &URI.char_unreserved?/1)
  def hash(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
