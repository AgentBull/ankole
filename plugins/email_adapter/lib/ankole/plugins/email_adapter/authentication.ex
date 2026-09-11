defmodule Ankole.Plugins.EmailAdapter.Authentication do
  @moduledoc """
  Decides whether the `From` header of one message can be trusted.

  The receiving mail server adds its `Authentication-Results` header above
  every earlier header, so the first one is the local verdict. The `dmarc`
  rule requires `dmarc=pass` there and, when the header names the checked
  domain, that domain must be the `From` domain.
  """

  @spec verify(:dmarc | :none, [String.t()], String.t() | nil) ::
          :ok
          | {:error, :authentication_results_missing | :dmarc_not_passed | :dmarc_domain_mismatch}
  def verify(:none, _results, _from_domain), do: :ok

  def verify(:dmarc, results, from_domain) do
    case results do
      [first | _rest] ->
        first
        |> parse()
        |> dmarc_verdict(from_domain)

      [] ->
        {:error, :authentication_results_missing}
    end
  end

  @doc "Parses one header value into `[{method, result, properties}]`."
  @spec parse(String.t()) :: [{String.t(), String.t(), %{String.t() => String.t()}}]
  def parse(value) when is_binary(value) do
    value
    |> strip_comments()
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn clause ->
      case Regex.run(~r/\A([a-z0-9_-]+)=([a-z0-9_-]+)(.*)\z/is, clause) do
        [_all, method, result, rest] ->
          [{String.downcase(method), String.downcase(result), properties(rest)}]

        nil ->
          []
      end
    end)
  end

  defp dmarc_verdict(clauses, from_domain) do
    case Enum.find(clauses, fn {method, _result, _props} -> method == "dmarc" end) do
      {"dmarc", "pass", props} ->
        case props["header.from"] do
          nil ->
            :ok

          checked ->
            if same_domain?(checked, from_domain), do: :ok, else: {:error, :dmarc_domain_mismatch}
        end

      _other ->
        {:error, :dmarc_not_passed}
    end
  end

  defp same_domain?(checked, from_domain) when is_binary(from_domain) do
    checked = checked |> String.downcase() |> String.trim_trailing(".")
    from_domain = from_domain |> String.downcase() |> String.trim_trailing(".")
    checked == from_domain or String.ends_with?(from_domain, "." <> checked)
  end

  defp same_domain?(_checked, _from_domain), do: false

  defp properties(rest) do
    ~r/([a-z0-9_.-]+)=("[^"]*"|[^\s;]+)/i
    |> Regex.scan(rest)
    |> Map.new(fn [_all, key, value] -> {String.downcase(key), String.trim(value, "\"")} end)
  end

  defp strip_comments(value), do: Regex.replace(~r/\([^()]*\)/, value, " ")
end
