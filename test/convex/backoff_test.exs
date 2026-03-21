defmodule Convex.BackoffTest do
  use ExUnit.Case, async: true

  alias Convex.Backoff

  describe "next_delay/1" do
    test "deterministic delay with injected RNG" do
      backoff = Backoff.new(rng: fn -> 0.5 end)
      {delay, backoff} = Backoff.next_delay(backoff)
      assert delay == 50
      assert backoff.attempt == 1
    end

    test "exponential growth sequence" do
      backoff = Backoff.new(rng: fn -> 0.5 end)

      expected = [50, 100, 200, 400, 800, 1600, 3200, 6400, 7500, 7500]

      {delays, _backoff} =
        Enum.map_reduce(expected, backoff, fn _expected, b ->
          {delay, b} = Backoff.next_delay(b)
          {delay, b}
        end)

      assert delays == expected
    end

    test "max_ms caps the delay" do
      backoff = Backoff.new(rng: fn -> 0.5 end, attempt: 20)
      {delay, _backoff} = Backoff.next_delay(backoff)
      # cap = min(100 * 2^20, 15000) = 15000, delay = 7500
      assert delay == 7500
    end

    test "RNG returning negative is clamped to 0" do
      backoff = Backoff.new(rng: fn -> -0.5 end)
      {delay, _backoff} = Backoff.next_delay(backoff)
      assert delay == 0
    end

    test "RNG returning 0.0 yields delay 0" do
      backoff = Backoff.new(rng: fn -> 0.0 end)
      {delay, _backoff} = Backoff.next_delay(backoff)
      assert delay == 0
    end

    test "RNG returning >= 1.0 is clamped to 0.999999" do
      backoff = Backoff.new(rng: fn -> 1.0 end)
      {delay, _backoff} = Backoff.next_delay(backoff)
      # trunc(100 * 0.999999) = 99
      assert delay == 99

      backoff = Backoff.new(rng: fn -> 1.5 end)
      {delay, _backoff} = Backoff.next_delay(backoff)
      assert delay == 99
    end

    test "custom base_ms and max_ms" do
      backoff = Backoff.new(base_ms: 200, max_ms: 1000, rng: fn -> 0.5 end)

      {delays, _backoff} =
        Enum.map_reduce(1..6, backoff, fn _i, b ->
          {delay, b} = Backoff.next_delay(b)
          {delay, b}
        end)

      # caps: 200, 400, 800, 1000, 1000, 1000
      # delays at 0.5: 100, 200, 400, 500, 500, 500
      assert delays == [100, 200, 400, 500, 500, 500]
    end
  end

  describe "reset/1" do
    test "resets attempt to 0" do
      backoff = Backoff.new(rng: fn -> 0.5 end)
      {_delay, backoff} = Backoff.next_delay(backoff)
      {_delay, backoff} = Backoff.next_delay(backoff)
      assert backoff.attempt == 2

      backoff = Backoff.reset(backoff)
      assert backoff.attempt == 0

      # next delay should use base cap again
      {delay, _backoff} = Backoff.next_delay(backoff)
      assert delay == 50
    end
  end
end
