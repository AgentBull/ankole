defmodule Ankole.Sessions.Outcome do
  @moduledoc "The finite outcomes of a control-plane conversation run."

  @values [
    :loop_finished,
    :iteration_exhausted,
    :silent,
    :stopped,
    :dead_letter,
    :sleeping,
    :submitted,
    :requeued
  ]
  @type t ::
          :loop_finished
          | :iteration_exhausted
          | :silent
          | :stopped
          | :dead_letter
          | :sleeping
          | :submitted
          | :requeued
  def values, do: @values

  def class(:dead_letter), do: :failed
  def class(:stopped), do: :canceled
  def class(outcome) when outcome in [:sleeping, :submitted, :requeued], do: :committed
  def class(:silent), do: :silent
  def class(outcome) when outcome in [:loop_finished, :iteration_exhausted], do: :reply

  def decode(value) when value in @values, do: value

  def decode(value) when is_binary(value),
    do:
      Enum.find(@values, &(Atom.to_string(&1) == value)) ||
        raise(ArgumentError, "unknown conversation outcome")

  def encode(value) when value in @values, do: Atom.to_string(value)
end
