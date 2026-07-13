defmodule Ankole.Brain.TemporalDecay do
  @moduledoc """
  Exponential temporal decay used after hybrid result fusion.

  Route-specific BM25 and vector scores remain untouched; callers apply this
  only to the fused score so the original scores remain useful for diagnosis.
  """

  @default_half_life_days 30

  @doc "Returns the product default half-life in days."
  @spec default_half_life_days() :: pos_integer()
  def default_half_life_days, do: @default_half_life_days

  @doc "Returns the exponential multiplier for an age and half-life in days."
  @spec multiplier(number(), number()) :: float()
  def multiplier(age_in_days, half_life_days)
      when is_number(age_in_days) and is_number(half_life_days) do
    if half_life_days <= 0 do
      1.0
    else
      age_in_days = max(age_in_days, 0)
      :math.exp(-(:math.log(2) / half_life_days) * age_in_days)
    end
  end

  @doc "Multiplies a fused score by its temporal decay factor."
  @spec apply(number(), number(), number()) :: float()
  def apply(score, age_in_days, half_life_days)
      when is_number(score) and is_number(age_in_days) and is_number(half_life_days) do
    score * multiplier(age_in_days, half_life_days)
  end
end
