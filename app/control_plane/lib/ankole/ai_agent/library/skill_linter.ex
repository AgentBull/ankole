defmodule Ankole.AIAgent.Library.SkillLinter do
  @moduledoc """
  Deterministic structural, hygiene, and secret checks for `SKILL.md` drafts
  proposed via `library.skill.save` Action Cards.
  """

  alias Ankole.AIAgent.Library.{Skills, SourceReader}

  @max_bytes 100_000
  @max_lines 500
  @min_description_chars 12
  @max_description_chars 320
  @min_body_chars 40

  @bidi_override_regex ~r/[\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
  @zero_width_regex ~r/[\x{200B}-\x{200F}\x{FEFF}]/u

  @secret_patterns [
    {~r/\bsk-[A-Za-z0-9_-]{20,}\b/, "API key (`sk-...`)"},
    {~r/\bAKIA[0-9A-Z]{16}\b/, "AWS access key (`AKIA...`)"},
    {~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/, "private key PEM block"},
    {~r/\bgh[pousr]_[A-Za-z0-9]{30,}\b/, "GitHub token (`gh*_...`)"},
    {~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/, "Slack token (`xox*-...`)"}
  ]

  @doc """
  Validates and normalizes a proposed `SKILL.md` document and optional `slug`.

  Returns `{:ok, %{slug: slug, content: content, body: body}}` or
  `{:error, actionable_reason}` suitable for returning directly to the model
  so it can repair the draft in the same turn.
  """
  @spec validate_and_parse(term(), term()) ::
          {:ok, %{slug: String.t(), content: map(), body: String.t()}}
          | {:error, String.t()}
  def validate_and_parse(markdown, raw_slug \\ nil)

  def validate_and_parse(markdown, raw_slug) when is_binary(markdown) do
    with :ok <- check_size_and_encoding(markdown),
         cleaned = strip_zero_width(markdown),
         :ok <- check_no_secrets(cleaned),
         {:ok, content} <- parse_manifest(cleaned),
         :ok <- check_description_budget(content.description),
         body = SourceReader.skill_body(content.manifest_markdown),
         :ok <- check_body(body),
         {:ok, slug} <- resolve_slug(raw_slug, content.name) do
      {:ok, %{slug: slug, content: content, body: body}}
    end
  end

  def validate_and_parse(_markdown, _raw_slug),
    do: {:error, "library.skill.save requires a non-empty `markdown` string containing SKILL.md."}

  defp check_size_and_encoding(markdown) do
    cond do
      not String.valid?(markdown) ->
        {:error, "SKILL.md must be valid UTF-8 text."}

      byte_size(markdown) > @max_bytes ->
        {:error, "SKILL.md exceeds #{@max_bytes} bytes; keep the main manifest concise."}

      length(String.split(markdown, "\n")) > @max_lines ->
        {:error, "SKILL.md exceeds #{@max_lines} lines; keep only reusable rules and steps."}

      Regex.match?(@bidi_override_regex, markdown) ->
        {:error,
         "SKILL.md contains Unicode bidirectional override characters, which are rejected for prompt hygiene."}

      true ->
        :ok
    end
  end

  defp strip_zero_width(markdown) do
    String.replace(markdown, @zero_width_regex, "")
  end

  defp check_no_secrets(markdown) do
    case Enum.find(@secret_patterns, fn {regex, _label} -> Regex.match?(regex, markdown) end) do
      {_, label} ->
        {:error,
         "SKILL.md appears to embed a live credential (#{label}). Never store secrets in Skills; reference environment variables or Connectors instead."}

      nil ->
        :ok
    end
  end

  defp parse_manifest(markdown) do
    case Skills.parse(markdown) do
      {:ok, content} ->
        {:ok, content}

      {:error, :invalid_skill_manifest} ->
        {:error,
         "SKILL.md must start with valid YAML frontmatter containing non-empty `name` and `description` fields, followed by valid Markdown."}

      {:error, reason} ->
        {:error, "SKILL.md failed validation: #{inspect(reason)}"}
    end
  end

  defp check_description_budget(description) do
    len = description |> String.trim() |> String.length()

    cond do
      len < @min_description_chars ->
        {:error,
         "Frontmatter `description` is too short (#{len} chars; minimum #{@min_description_chars}). State clearly when to load this Skill and what it produces."}

      len > @max_description_chars ->
        {:error,
         "Frontmatter `description` is too long (#{len} chars; maximum #{@max_description_chars}). Keep routing descriptions to 1-2 concise trigger sentences."}

      String.contains?(description, "\n") ->
        {:error, "Frontmatter `description` must be a single concise line without newlines."}

      true ->
        :ok
    end
  end

  defp check_body(body) do
    visible = body |> String.trim()

    if String.length(visible) < @min_body_chars do
      {:error,
       "SKILL.md body is too short (minimum #{@min_body_chars} characters). Include concrete sections such as `## When to Use`, `## Procedure`, `## Pitfalls`, and `## Verification`."}
    else
      :ok
    end
  end

  defp resolve_slug(raw_slug, fallback_name) do
    trimmed = if is_binary(raw_slug), do: String.trim(raw_slug), else: ""

    if trimmed != "" do
      case Skills.validate_custom_slug(trimmed) do
        {:ok, slug} ->
          {:ok, slug}

        {:error, :reserved_skill_slug} ->
          {:error,
           "Slug `#{trimmed}` is reserved by a built-in slash command (#{Enum.join(Skills.reserved_custom_slugs(), ", ")}). Choose a descriptive domain slug such as `#{trimmed}-workflow`."}

        {:error, _} ->
          {:error,
           "Slug `#{trimmed}` is invalid. Use lowercase ASCII letters, digits, dots, underscores, or hyphens (`[a-z0-9][a-z0-9._-]{0,95}`)."}
      end
    else
      case Skills.resolve_custom_slug("", fallback_name) do
        {:ok, slug} -> {:ok, slug}
        {:error, reason} -> {:error, "Could not generate skill slug: #{inspect(reason)}"}
      end
    end
  end
end
