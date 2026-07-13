defmodule Ankole.Brain.ThreatScanner do
  @moduledoc """
  Best-effort prompt-injection and exfiltration scanner for projections that
  are injected into every conversation.

  The English pattern inventory and inclusive scope semantics are a direct
  Elixir port of Hermes' `threat_patterns.py`. A deliberately small Chinese
  inventory covers the same highest-signal attack classes.
  """

  @max_scan_chars 65_536
  @invisible_chars MapSet.new([
                     0x200B,
                     0x200C,
                     0x200D,
                     0x2060,
                     0x2062,
                     0x2063,
                     0x2064,
                     0xFEFF,
                     0x202A,
                     0x202B,
                     0x202C,
                     0x202D,
                     0x202E,
                     0x2066,
                     0x2067,
                     0x2068,
                     0x2069
                   ])

  @filler "(?:\\w+\\s+){0,8}"
  @patterns [
    {~r/ignore\s+#{@filler}(previous|all|above|prior)\s+#{@filler}instructions/iu,
     "prompt_injection", :all},
    {~r/system\s+prompt\s+override/iu, "sys_prompt_override", :all},
    {~r/disregard\s+#{@filler}(your|all|any)\s+#{@filler}(instructions|rules|guidelines)/iu,
     "disregard_rules", :all},
    {~r/act\s+as\s+(if|though)\s+#{@filler}you\s+#{@filler}(have\s+no|don't\s+have)\s+#{@filler}(restrictions|limits|rules)/iu,
     "bypass_restrictions", :all},
    {~r/<!--[^>]{0,512}(?:ignore|override|system|secret|hidden)[^>]{0,512}-->/iu,
     "html_comment_injection", :all},
    {~r/<\s*div\s+style\s*=\s*["'][^>]{0,2048}display\s*:\s*none/iu, "hidden_div", :all},
    {~r/translate\s+[^\n]{0,512}\s+into\s+[^\n]{0,512}\s+and\s+(execute|run|eval)/iu,
     "translate_execute", :all},
    {~r/do\s+not\s+#{@filler}tell\s+#{@filler}the\s+user/iu, "deception_hide", :all},
    {~r/you\s+are\s+#{@filler}now\s+(?:a|an|the)\s+/iu, "role_hijack", :context},
    {~r/pretend\s+#{@filler}(you\s+are|to\s+be)\s+/iu, "role_pretend", :context},
    {~r/output\s+#{@filler}(system|initial)\s+prompt/iu, "leak_system_prompt", :context},
    {~r/(respond|answer|reply)\s+without\s+#{@filler}(restrictions|limitations|filters|safety)/iu,
     "remove_filters", :context},
    {~r/you\s+have\s+been\s+#{@filler}(updated|upgraded|patched)\s+to/iu, "fake_update",
     :context},
    {~r/\bname\s+yourself\s+\w+/iu, "identity_override", :context},
    {~r/register\s+(as\s+)?a?\s*node/iu, "c2_node_registration", :context},
    {~r/(heartbeat|beacon|check[\s\-]?in)\s+(to|with)\s+/iu, "c2_heartbeat", :context},
    {~r/pull\s+(down\s+)?(?:new\s+)?task(?:ing|s)?\b/iu, "c2_task_pull", :context},
    {~r/connect\s+to\s+the\s+network\b/iu, "c2_network_connect", :context},
    {~r/you\s+must\s+(?:\w+\s+){0,3}(register|connect|report|beacon)\b/iu, "forced_action",
     :context},
    {~r/only\s+use\s+one[\s\-]?liners?\b/iu, "anti_forensic_oneliner", :context},
    {~r/never\s+#{@filler}(?:create|write)\s+#{@filler}(?:script|file)\s+#{@filler}disk/iu,
     "anti_forensic_disk", :context},
    {~r/unset\s+\w*(?:CLAUDE|CODEX|HERMES|AGENT|OPENAI|ANTHROPIC)\w*/iu, "env_var_unset_agent",
     :context},
    {~r/\b(?:cobalt\s*strike|sliver|havoc|mythic|metasploit|brainworm)\b/iu, "known_c2_framework",
     :context},
    {~r/\bc2\s+(?:server|channel|infrastructure|beacon)\b/iu, "c2_explicit", :context},
    {~r/\bcommand\s+and\s+control\b/iu, "c2_explicit_long", :context},
    {~r/curl\s+[^\n]{0,2048}\$\{?\w*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)/iu, "exfil_curl",
     :all},
    {~r/wget\s+[^\n]{0,2048}\$\{?\w*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)/iu, "exfil_wget",
     :all},
    {~r/cat\s+[^\n]{0,2048}(\.env|credentials|\.netrc|\.pgpass|\.npmrc|\.pypirc)/iu,
     "read_secrets", :all},
    {~r/(send|post|upload|transmit)\s+[^\n]{0,2048}\s+(to|at)\s+https?:\/\//iu, "send_to_url",
     :strict},
    {~r/(include|output|print|share)\s+#{@filler}(conversation|chat\s+history|previous\s+messages|full\s+context|entire\s+context)/iu,
     "context_exfil", :strict},
    {~r/authorized_keys/iu, "ssh_backdoor", :strict},
    {~r/\$HOME\/\.ssh|~\/\.ssh/iu, "ssh_access", :strict},
    {~r/\$HOME\/\.hermes\/\.env|~\/\.hermes\/\.env/iu, "hermes_env", :strict},
    {~r/(update|modify|edit|write|change|append|add\s+to)\s+[^\n]{0,2048}(?:AGENTS\.md|CLAUDE\.md|\.cursorrules|\.clinerules)/iu,
     "agent_config_mod", :strict},
    {~r/(update|modify|edit|write|change|append|add\s+to)\s+[^\n]{0,2048}\.hermes\/(config\.yaml|SOUL\.md)/iu,
     "hermes_config_mod", :strict},
    {~r/(?:api[_-]?key|token|secret|password)\s*[=:]\s*["'][A-Za-z0-9+\/_=-]{20,}/iu,
     "hardcoded_secret", :strict},
    {~r/忽略.{0,80}(之前|以上|所有).{0,80}(指令|提示|规则)/u, "zh_prompt_injection", :all},
    {~r/(不要|不得).{0,40}(告诉|告知).{0,20}用户/u, "zh_deception_hide", :all},
    {~r/(输出|泄露|显示).{0,40}(系统提示词|初始提示词|完整上下文)/u, "zh_context_exfil", :context},
    {~r/(发送|上传|传输).{0,100}https?:\/\//u, "zh_send_to_url", :strict},
    {~r/(修改|编辑|写入|追加).{0,80}(AGENTS\.md|CLAUDE\.md)/iu, "zh_agent_config_mod", :strict}
  ]

  @type scope :: :all | :context | :strict

  @doc "Returns all matching threat identifiers for the inclusive scope."
  @spec scan_for_threats(String.t(), scope()) :: [String.t()]
  def scan_for_threats(content, scope \\ :context)

  def scan_for_threats(content, scope)
      when is_binary(content) and scope in [:all, :context, :strict] do
    content = String.slice(content, 0, @max_scan_chars)

    invisible_findings =
      content
      |> String.to_charlist()
      |> MapSet.new()
      |> MapSet.intersection(@invisible_chars)
      |> Enum.sort()
      |> Enum.map(
        &("invisible_unicode_U+" <>
            (&1 |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.upcase()))
      )

    normalized = :unicode.characters_to_nfkc_binary(content)

    pattern_findings =
      for {regex, id, pattern_scope} <- @patterns,
          included?(scope, pattern_scope),
          Regex.match?(regex, normalized),
          do: id

    invisible_findings ++ pattern_findings
  end

  def scan_for_threats(content, _scope) when content in [nil, ""], do: []

  def scan_for_threats(_content, scope) do
    raise ArgumentError, "unknown threat scanning scope: #{inspect(scope)}"
  end

  @doc "Returns a readable blocking reason for the first threat, or nil."
  @spec first_threat_message(String.t(), scope()) :: String.t() | nil
  def first_threat_message(content, scope \\ :strict) do
    case scan_for_threats(content, scope) do
      [] ->
        nil

      ["invisible_unicode_" <> codepoint | _rest] ->
        "Blocked: content contains invisible unicode character #{codepoint} (possible injection)."

      [pattern_id | _rest] ->
        "Blocked: content matches threat pattern '#{pattern_id}'. " <>
          "Content is injected into the system prompt and must not contain injection or exfiltration payloads."
    end
  end

  @doc "Validates content for a write path that injects the projection into prompts."
  @spec validate(String.t()) :: :ok | {:error, {:threat_detected, String.t()}}
  def validate(content) when is_binary(content) do
    case first_threat_message(content, :strict) do
      nil -> :ok
      message -> {:error, {:threat_detected, message}}
    end
  end

  defp included?(:all, :all), do: true
  defp included?(:context, scope), do: scope in [:all, :context]
  defp included?(:strict, _scope), do: true
  defp included?(_scope, _pattern_scope), do: false
end
