defmodule AnkoleWeb.PodURLVectorsTest do
  use ExUnit.Case, async: true

  alias AnkoleWeb.PodURL

  @vectors "../../../kernel/test/vectors/pod_url.json"
           |> Path.expand(__DIR__)
           |> File.read!()
           |> Torque.decode!()

  test "incoming browser URLs match the shared Pod URL vectors" do
    for %{
          "path" => path,
          "query" => query,
          "expected_path" => expected_path,
          "expected_query" => expected_query
        } <- @vectors["routes"] do
      assert {:ok, normalized} = path |> browser_conn(query) |> PodURL.path()
      assert split(normalized) == {expected_path, expected_query}
    end
  end

  test "malformed route IDs fail closed" do
    for %{"path" => path, "query" => query} <- @vectors["invalid_routes"] do
      assert {:error, :not_found} = path |> browser_conn(query) |> PodURL.path()
    end
  end

  defp browser_conn(path, query) do
    Plug.Test.conn(:get, path <> query_string(query))
  end

  defp query_string(query) when map_size(query) == 0, do: ""
  defp query_string(query), do: "?" <> URI.encode_query(query)

  defp split(normalized) do
    case String.split(normalized, "?", parts: 2) do
      [path] -> {path, %{}}
      [path, query] -> {path, URI.decode_query(query)}
    end
  end
end
