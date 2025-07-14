defmodule MySseClient do
  require Logger

  def start_sse_stream do
    url = "http://localhost:4000/tool"
    Logger.info("Connecting to SSE stream at #{url}")

    # This is a simplified example. In a real application, you'd use a library
    # that handles SSE parsing and reconnection logic more robustly.
    HTTPoison.get(url, [], stream_to: self())
  end

  def handle_info({:http_response, %HTTPoison.Response{body: chunk}}, _state) do
    # Process each chunk received from the SSE stream
    # Each chunk might contain multiple SSE events.
    # A proper SSE client would parse these into individual events.
    Logger.info("Received SSE chunk: #{inspect(chunk)}")
    # Example: Simple parsing for 'data:' lines
    chunk
    |> String.split("\n\n", trim: true)
    |> Enum.each(fn event_string ->
      if String.starts_with?(event_string, "data:") do
        data = String.trim_leading(event_string, "data: ")
        Logger.info("Parsed SSE data event: #{data}")
        # Further process the data (e.g., JSON decode if it's JSON)
      else if String.starts_with?(event_string, "event: error") do
        data = String.trim_leading(event_string, "event: error\ndata: ")
        Logger.error("Parsed SSE error event: #{data}")
      else if String.starts_with?(event_string, "event: close") do
        Logger.info("SSE stream closed.")
      end
      end
    end)
    {:noreply, nil}
  end

  def handle_info({:http_error, reason}, _state) do
    Logger.error("SSE stream error: #{inspect(reason)}")
    {:noreply, nil}
  end

  # Other handle_info clauses for different message types
  def handle_info(msg, _state) do
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, nil}
  end
end
