defmodule Explicit.Protocol do
  @moduledoc """
  JSON protocol helpers for the Unix socket communication.
  JSONL format: one JSON object per line.
  """

  def decode_request(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"method" => method} = req} ->
        {:ok, method, Map.get(req, "params", %{})}

      {:ok, _} ->
        {:error, "missing 'method' field"}

      {:error, _} ->
        {:error, "invalid JSON"}
    end
  end

  def encode_ok(data) do
    Jason.encode!(%{ok: true, data: data}) <> "\n"
  end

  def encode_error(message) do
    Jason.encode!(%{ok: false, error: message}) <> "\n"
  end
end
