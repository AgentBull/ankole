defimpl Ankole.Authn.Strategy, for: Ankole.Authn.Strategies.Otp do
  def name(strategy), do: strategy.name
  def scope(strategy), do: strategy.scope
  def provider_id(strategy), do: strategy.provider_id

  def action(%{sender: {sender, sender_opts}}, :request, params, opts),
    do:
      Ankole.Authn.Domain.request_otp(
        params.browser,
        params.flow,
        params.email,
        params.source,
        opts |> Keyword.merge(sender_opts) |> Keyword.put(:sender, sender)
      )

  def action(_strategy, :verify, params, opts) do
    case Keyword.fetch(opts, :complete) do
      {:ok, complete} ->
        Ankole.Authn.Domain.verify_otp_with(
          params.browser,
          params.flow,
          params.challenge_id,
          params.code,
          params.source,
          complete
        )

      :error ->
        Ankole.Authn.Domain.verify_otp(
          params.browser,
          params.flow,
          params.challenge_id,
          params.code,
          params.source
        )
    end
  end
end
