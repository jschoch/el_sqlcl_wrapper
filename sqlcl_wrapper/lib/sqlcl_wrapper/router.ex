defmodule SqlclWrapper.Router do
  use Plug.Router
  require Logger

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json", "text/plain"],
    json_decoder: Jason

  plug Plug.Logger, log: :info
  plug :match
  plug :dispatch

  get "/tool" do
    Logger.info("[#{DateTime.utc_now()}] Received GET /tool request. Connection details: #{inspect(conn)}")

    # Send initial headers to establish SSE connection
    conn = conn
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)

    # Spawn a new process to manage the SSE stream for this connection
    spawn(fn ->
      stream_sse_data(conn)
    end)

    # Return the connection, it's now managed by the spawned process
    conn
  end

  post "/tool" do
    content_type = get_req_header(conn, "content-type") |> hd()

    case content_type do
      "application/json" ->
        # Body is already parsed by Plug.Parsers as a map
        body = conn.body_params
        Logger.info("[#{DateTime.utc_now()}] Received POST /tool request with JSON body: #{inspect(body)}")

        # Expecting a JSON-RPC 2.0 request
        method = Map.get(body, "method")
        _id = Map.get(body, "id") # Unused, so prefix with underscore
        params = Map.get(body, "params", %{})

        if method == "tools/call" && Map.has_key?(params, "name") do
          # Re-encode the received JSON-RPC request to send to SqlclProcess
          json_rpc_request = Jason.encode!(body)
          Logger.info("Sending JSON-RPC request to SQLcl process: #{json_rpc_request}")

          # For tools/call, especially run-sql, we don't want to send the result back
          # immediately via the POST response, as it's streamed via SSE.
          # We just acknowledge that the command was sent.
          SqlclWrapper.SqlclProcess.send_command_async(json_rpc_request)
          Logger.info("[#{DateTime.utc_now()}] JSON-RPC command sent to SQLcl process for async processing.")
          send_resp(conn, 200, "Command accepted for SSE streaming.")
        else
          send_resp(conn, 400, "Bad Request: Invalid JSON-RPC 'tools/call' format.")
        end

      "text/plain" ->
        # Read the raw body for plain text commands (e.g., "exit")
        {:ok, raw_command, conn} = Plug.Conn.read_body(conn)
        Logger.info("Received POST /tool request with raw text body: #{inspect(raw_command)}")

        case SqlclWrapper.SqlclProcess.send_command(raw_command) do
          :ok -> # Raw commands acknowledge with :ok
            Logger.info("Raw command sent to SQLcl process.")
            send_resp(conn, 200, "OK")
          {:ok, response} -> # In case a raw command returns JSON (e.g., "show release")
            Logger.info("Received response for raw command: #{inspect(response)}")
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(response))
          {:error, reason} ->
            Logger.error("Error communicating with SQLcl process for raw command: #{inspect(reason)}")
            send_resp(conn, 500, "Internal Server Error: #{inspect(reason)}")
        end

      _ ->
        send_resp(conn, 415, "Unsupported Media Type: Only application/json and text/plain are supported.")
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp stream_sse_data(conn) do
    # Subscribe this new process to the SqlclProcess output
    SqlclWrapper.SqlclProcess.subscribe(self())
    Logger.info("[#{DateTime.utc_now()}] SSE stream manager process subscribed to SqlclProcess for conn: #{inspect(conn.id)}")

    # Loop to receive messages and chunk them to the client
    loop_stream(conn)
  end

  defp loop_stream(conn) do
    receive do
      {:sqlcl_output, {:stdout, data}} ->
        Logger.info("[#{DateTime.utc_now()}] SSE stream manager received SQLcl STDOUT: #{data}")
        # Attempt to parse the data as JSON-RPC response
        chunk_data = case Jason.decode(data) do
          {:ok, %{"jsonrpc" => "2.0", "id" => _id, "result" => %{"content" => content}}} ->
            # Extract text content from the list of content maps
            # Ensure content is a list before mapping
            if is_list(content) do
              Enum.map_join(content, "", fn %{"type" => "text", "text" => text} -> text end)
            else
              data # Fallback if content is not a list
            end
          _ ->
            # If not a recognized JSON-RPC response or not valid JSON, use raw data
            data
        end
        # The chunk_data already contains the necessary newlines from SQLcl output,
        # so we only need a single newline to terminate the SSE data line.
        case Plug.Conn.chunk(conn, "data: #{chunk_data}\n") do
          {:ok, updated_conn} -> loop_stream(updated_conn)
          {:error, reason} -> Logger.error("Failed to chunk STDOUT: #{inspect(reason)}"); :ok # Terminate stream on error
        end
      {:sqlcl_output, {:stderr, data}} ->
        Logger.error("[#{DateTime.utc_now()}] SSE stream manager received SQLcl STDERR: #{data}")
        case Plug.Conn.chunk(conn, "event: error\ndata: #{data}\n\n") do
          {:ok, updated_conn} -> loop_stream(updated_conn)
          {:error, reason} -> Logger.error("Failed to chunk STDERR: #{inspect(reason)}"); :ok # Terminate stream on error
        end
      {:sqlcl_output, {:exit, status}} ->
        Logger.info("[#{DateTime.utc_now()}] SSE stream manager received SQLcl process exit: #{inspect(status)}")
        # Attempt to send final close event, but don't rely on its return for closing the connection
        # The connection will be closed by the client or by the server when the process exits.
        # We should not call send_resp after chunking, as chunking already implies sending.
        Plug.Conn.chunk(conn, "event: close\ndata: SQLcl process exited with status #{inspect(status)}\n\n")
        :ok # Terminate this process
      {:cowboy_req, :disconnect, _reason, _req, _env} ->
        Logger.info("[#{DateTime.utc_now()}] SSE client disconnected for conn: #{inspect(conn.id)}")
        :ok # Terminate this process
      _ ->
        # Ignore other messages
        loop_stream(conn)
    end
  end
end
