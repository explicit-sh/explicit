defmodule Explicit.Protocol do
  @moduledoc """
  JSON protocol helpers for the Unix socket communication.
  Wire format: 4-byte big-endian length prefix followed by a JSON object.
  Framing is handled by `:gen_tcp` via the `packet: 4` listen option.
  """

  def decode_request(payload) do
    # String.trim/1 is defensive — packet: 4 already strips framing, but
    # tolerates older clients that still send trailing whitespace.
    case Jason.decode(String.trim(payload)) do
      {:ok, %{"method" => method} = req} ->
        {:ok, method, Map.get(req, "params", %{})}

      {:ok, _} ->
        {:error, "missing 'method' field"}

      {:error, _} ->
        {:error, "invalid JSON"}
    end
  end

  def encode_ok(data) do
    Jason.encode!(%{ok: true, data: data})
  end

  def encode_error(message) do
    Jason.encode!(%{ok: false, error: message})
  end
end
