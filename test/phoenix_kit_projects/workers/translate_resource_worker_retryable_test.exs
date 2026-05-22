defmodule PhoenixKitProjects.Workers.TranslateResourceWorkerRetryableTest do
  @moduledoc """
  Level 1 (pure-function, no DB) coverage for the worker's retry
  classification.

  `retryable?/1` decides whether a failed translation returns
  `{:error, _}` (Oban retries, up to `max_attempts`) or `{:discard, _}`
  (no retry — a deterministic failure would just re-fail and burn AI
  tokens on every attempt). The full contract lives here as a pure
  unit test because in CI the AI plugin isn't loaded, so the DB-backed
  `perform/1` path can only ever surface `:ai_not_installed` and never
  reaches these clauses (`retryable?/1` is `@doc false` public for
  exactly this seam).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitProjects.Workers.TranslateResourceWorker, as: Worker

  describe "retryable?/1 — transient → retry" do
    test "transient AI error atoms retry" do
      assert Worker.retryable?({:ai_error, :request_timeout})
      assert Worker.retryable?({:ai_error, :rate_limited})
    end

    test "transient AI error tuples retry" do
      assert Worker.retryable?({:ai_error, {:connection_error, :closed}})
      assert Worker.retryable?({:ai_error, {:exit, :timeout}})
    end

    test "provider 5xx allow-list retries" do
      for status <- [500, 502, 503, 504, 522, 524, 529] do
        assert Worker.retryable?({:ai_error, {:api_error, status}}),
               "expected provider #{status} to be retryable"
      end
    end
  end

  describe "retryable?/1 — deterministic → discard" do
    test "501/505 are deterministic config/integration mismatches" do
      for status <- [501, 505] do
        refute Worker.retryable?({:ai_error, {:api_error, status}}),
               "expected provider #{status} to be non-retryable"
      end
    end

    test "client 4xx errors do not retry" do
      for status <- [400, 404, 422] do
        refute Worker.retryable?({:ai_error, {:api_error, status}}),
               "expected client #{status} to be non-retryable"
      end
    end

    test "non-HTTP failures do not retry" do
      refute Worker.retryable?(:ai_not_installed)
      refute Worker.retryable?({:parse_error, :no_markers})
      refute Worker.retryable?({:persist_error, :some_changeset_error})
      refute Worker.retryable?(:some_unexpected_atom)
    end
  end
end
