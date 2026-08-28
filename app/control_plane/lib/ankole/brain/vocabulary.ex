defmodule Ankole.Brain.Vocabulary do
  @moduledoc """
  Read-side owner of the global vocabulary file: the versioned reference list
  of canonical naming terms for subtype, tag, claim_metric, event_type, and
  dimension values. The file ships with the product and never materializes
  into PostgreSQL. Dreaming counts term usage for schema suggestions, and the
  object write path names the closest terms inside a type-rejection error, so
  the model gets the canonical term at the moment of the mistake instead of
  through a separate lookup surface.
  """

  # Below this Jaro distance a term says nothing about the candidate; the
  # error is better off with only the installed-type list.
  @similarity_floor 0.72

  @doc "All vocabulary term names, or [] when the file is unavailable."
  @spec terms() :: [String.t()]
  def terms do
    path =
      Application.get_env(:ankole, :brain, [])
      |> Keyword.get(
        :vocabulary_path,
        Path.join(
          Ankole.AIAgent.Library.SourceReader.library_root(),
          "schema-pack/vocabulary.yml"
        )
      )

    with {:ok, raw} <- File.read(path),
         {:ok, parsed} <- YamlElixir.read_from_string(raw) do
      parsed
      |> Map.get("sections", [])
      |> Enum.flat_map(fn section ->
        section |> Map.get("entries", []) |> Enum.map(& &1["term"])
      end)
      |> Enum.filter(&is_binary/1)
    else
      _unavailable -> []
    end
  end

  @doc """
  Vocabulary terms closest to one candidate name: the exact case-insensitive
  match alone when one exists, otherwise the nearest terms by Jaro distance
  in a deterministic order. An empty list means the vocabulary offers nothing
  useful for this candidate.
  """
  @spec closest_terms(String.t(), pos_integer()) :: [String.t()]
  def closest_terms(candidate, limit \\ 5) when is_binary(candidate) do
    normalized = String.downcase(candidate)
    terms = terms()

    case Enum.filter(terms, &(String.downcase(&1) == normalized)) do
      [] ->
        terms
        |> Enum.map(&{String.jaro_distance(String.downcase(&1), normalized), &1})
        |> Enum.filter(fn {distance, _term} -> distance >= @similarity_floor end)
        |> Enum.sort_by(fn {distance, term} -> {-distance, term} end)
        |> Enum.take(limit)
        |> Enum.map(&elem(&1, 1))

      exact ->
        exact
    end
  end
end
