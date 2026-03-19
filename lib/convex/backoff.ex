defmodule Convex.Backoff do
  @moduledoc false

  defstruct base_ms: 100, max_ms: 15_000, attempt: 0, rng: &__MODULE__.default_rng/0

  @type t :: %__MODULE__{
          base_ms: pos_integer(),
          max_ms: pos_integer(),
          attempt: non_neg_integer(),
          rng: (-> float())
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      base_ms: Keyword.get(opts, :base_ms, 100),
      max_ms: Keyword.get(opts, :max_ms, 15_000),
      attempt: Keyword.get(opts, :attempt, 0),
      rng: Keyword.get(opts, :rng, &__MODULE__.default_rng/0)
    }
  end

  @spec next_delay(t()) :: {non_neg_integer(), t()}
  def next_delay(%__MODULE__{} = backoff) do
    cap = min(backoff.base_ms * trunc(:math.pow(2, backoff.attempt)), backoff.max_ms)
    jitter = max(min(backoff.rng.(), 0.999_999), 0.0)
    delay = trunc(cap * jitter)
    {delay, %{backoff | attempt: backoff.attempt + 1}}
  end

  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = backoff), do: %{backoff | attempt: 0}

  def default_rng do
    :rand.uniform()
  end
end
