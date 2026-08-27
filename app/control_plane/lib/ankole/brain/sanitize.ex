defmodule Ankole.Brain.Sanitize do
  @moduledoc """
  Prompt-injection neutralization for recalled memory text.

  Recalled content is attacker-adjacent data: a claim or chunk can carry
  jailbreak phrasing that a prompt would otherwise embed verbatim. Hits are
  neutralized in place and reported, never silently dropped; the caller
  wraps the result in a data envelope. The pattern set follows the GBrain
  INJECTION_PATTERNS list.
  """

  @patterns [
    {"ignore-prior",
     ~r/ignore\s+(?:all\s+)?(?:prior|previous|above|earlier)\s+(?:instructions?|prompts?|messages?)/iu,
     "[redacted]"},
    {"forget-everything", ~r/forget\s+(?:everything|all\s+(?:of\s+)?the\s+above)/iu,
     "[redacted]"},
    {"disregard",
     ~r/disregard\s+(?:all\s+)?(?:prior|previous|above|earlier)\s+(?:instructions?|prompts?)/iu,
     "[redacted]"},
    {"new-instructions", ~r/(?:new|updated|revised)\s+instructions?:/iu, "[redacted]:"},
    {"system-prompt", ~r/system\s*:\s*(?:you\s+are|you\s+must|never|always)/iu, "[redacted]"},
    {"role-jailbreak", ~r/you\s+are\s+(?:now|actually|really)\s+(?:a|an)\s+\w+/iu, "[redacted]"},
    {"do-anything-now", ~r/\b(?:DAN|do\s+anything\s+now|developer\s+mode\s+enabled?)\b/iu,
     "[redacted]"},
    {"close-memory", ~r/<\s*\/\s*memory\s*>/iu, "&lt;/memory&gt;"},
    {"close-take", ~r/<\s*\/\s*take\s*>/iu, "&lt;/take&gt;"},
    {"open-system", ~r/<\s*system\s*>/iu, "&lt;system&gt;"},
    {"open-instructions", ~r/<\s*instructions?\s*>/iu, "&lt;instructions&gt;"},
    {"xml-attr-inject", ~r/\s+(entity|metric|event_type|kind)\s*=\s*"[^"]*"/iu,
     " [redacted-attr]"},
    {"print-system",
     ~r/(?:print|output|reveal|show)\s+(?:your\s+)?(?:system\s+prompt|instructions?|hidden)/iu,
     "[redacted]"},
    {"verbatim", ~r/(?:repeat|echo)\s+(?:back|verbatim)/iu, "[redacted]"},
    {"eval-shell", ~r/\b(?:eval|exec|system|shell)\s*\(/iu, "[redacted]("}
  ]

  @doc """
  Neutralizes known injection phrasing in one text. Returns the cleaned text
  and the names of the matched patterns.
  """
  @spec sanitize(String.t()) :: {String.t(), [String.t()]}
  def sanitize(text) when is_binary(text) do
    Enum.reduce(@patterns, {text, []}, fn {name, pattern, replacement}, {text, matched} ->
      if Regex.match?(pattern, text) do
        {Regex.replace(pattern, text, replacement), [name | matched]}
      else
        {text, matched}
      end
    end)
    |> then(fn {text, matched} -> {text, Enum.reverse(matched)} end)
  end
end
