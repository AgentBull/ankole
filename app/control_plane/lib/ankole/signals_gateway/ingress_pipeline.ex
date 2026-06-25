defmodule Ankole.SignalsGateway.IngressPipeline do
  @moduledoc """
  Fixed ingress pipeline helpers.

  This module keeps the high-level flow explicit without creating a stored plan
  or a second queue: construct fact, evaluate binding filters, then let the
  caller execute the existing transactional mirror / actor input work.

  Why construct-then-filter, and why inline rather than a stored plan or a
  second queue: ingress is supposed to be a thin admission boundary. A signal
  must be turned into a normalized fact *first* (so filters compare against
  durable, atom-free fields, not raw provider maps), and admission must be
  decided *before* any DB write so a rejected signal leaves no trace. The
  remaining accept work (channel/entry mirror + actor input) already runs in one
  Repo transaction in `SignalsGateway`; routing it through a persisted "plan" or
  a separate job queue would buy nothing but add a second source of truth and a
  recovery path nobody asked for. The whole ingress effect stays in the request
  that received it, succeeds or rolls back atomically, and is easy to reason
  about.
  """

  alias Ankole.SignalsGateway.BindingFilters
  alias Ankole.SignalsGateway.IngressFact
  alias Ankole.SignalsGateway.SignalBinding

  @type constructor :: (SignalBinding.t(), map(), DateTime.t() -> {:ok, map()} | {:error, term()})

  @doc """
  Builds a constructed ingress fact through one of the concrete fact constructors.
  """
  @spec construct(atom(), SignalBinding.t(), map(), DateTime.t(), constructor()) ::
          {:ok, IngressFact.t()} | {:error, term()}
  def construct(kind, %SignalBinding{} = binding, input, now, constructor)
      when is_atom(kind) and is_map(input) and is_function(constructor, 3) do
    with {:ok, attrs} <- constructor.(binding, input, now) do
      construct_fact(kind, attrs)
    end
  end

  @doc """
  Applies v1 exact-match binding filters.
  """
  @spec filter(SignalBinding.t(), IngressFact.t()) :: :match | :no_match | {:error, term()}
  def filter(%SignalBinding{filters: filters}, %IngressFact{} = fact) do
    BindingFilters.match?(filters, fact)
  end

  # `kind` selects which IngressFact constructor enforces the required keys for
  # that signal shape; an unrecognized kind is a programmer error in the gateway,
  # not provider input, so it surfaces as a plain error tuple.
  defp construct_fact(:entry, attrs), do: IngressFact.entry(attrs)
  defp construct_fact(:lifecycle, attrs), do: IngressFact.lifecycle(attrs)
  defp construct_fact(:reaction, attrs), do: IngressFact.reaction(attrs)
  defp construct_fact(:action, attrs), do: IngressFact.action(attrs)
  defp construct_fact(:internal, attrs), do: IngressFact.internal(attrs)
  defp construct_fact(_kind, _attrs), do: {:error, :unknown_ingress_fact_kind}
end
