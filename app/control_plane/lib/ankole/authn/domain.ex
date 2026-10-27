defmodule Ankole.Authn.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource(Ankole.Authn.Challenge)
  end

  defdelegate request_otp(browser, target, source, opts \\ []),
    to: Ankole.Authn.Strategies.Otp.Actions,
    as: :request

  defdelegate verify_otp(browser, id, code, source, opts \\ []),
    to: Ankole.Authn.Strategies.Otp.Actions,
    as: :verify

  defdelegate verify_otp_with(browser, id, code, source, complete, opts \\ []),
    to: Ankole.Authn.Strategies.Otp.Actions,
    as: :verify_with

  defdelegate verified_proof(proof), to: Ankole.Authn.Strategies.Otp.Actions
  defdelegate expire_challenges(now), to: Ankole.Authn.Expunger, as: :expire
end
