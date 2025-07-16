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

  post "/tool" do
    Logger.info("[#{DateTime.utc_now()}] Received POST /tool request. Connection details: #{inspect(conn)}")

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

        Logger.info("DEBUG: Method: #{inspect(method)}, Params: #{inspect(params)}")
        Logger.info("DEBUG: Has 'name' key in params: #{Map.has_key?(params, "name")}")

        if method == "tools/call" && Map.has_key?(params, "name") do
          # Re-encode the received JSON-RPC request to send to SqlclProcess
          json_rpc_request = Jason.encode!(body)
          Logger.info("Sending JSON-RPC request to SQLcl process: #{json_rpc_request}")

          # Send initial headers to establish SSE connection
          conn = conn
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)

          # Subscribe this process to the SqlclProcess output
          SqlclWrapper.SqlclProcess.subscribe(self())
          Logger.info("[#{DateTime.utc_now()}] SSE request handler process subscribed to SqlclProcess for conn: #{inspect(conn.private)}")

          # Send the command asynchronously
          SqlclWrapper.SqlclProcess.send_command_async(json_rpc_request)
          Logger.info("[#{DateTime.utc_now()}] JSON-RPC command sent to SQLcl process for async processing.")

          # Loop to receive messages and chunk them to the client
          loop_sse_in_request_process(conn)
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

  # New helper function to manage the SSE loop in the request process
  defp loop_sse_in_request_process(conn) do
    Logger.debug("[#{DateTime.utc_now()}] SSE request handler process entering receive loop for conn: #{inspect(conn.private)}")
    receive do
      {:sqlcl_output, {:stdout, data}} ->
        Logger.info("[#{DateTime.utc_now()}] SSE request handler received SQLcl STDOUT: #{data}")
        case Jason.decode(data) do
          {:ok, %{"jsonrpc" => "2.0", "id" => _id, "result" => %{"content" => content}}} = json_rpc_response ->
            # This is a JSON-RPC result, indicating command completion
            Logger.info("[#{DateTime.utc_now()}] SSE request handler received JSON-RPC result: #{inspect(json_rpc_response)}")
            extracted_data = if is_list(content) do
              Enum.map_join(content, "", fn %{"type" => "text", "text" => text} -> text end)
            else
              data
            end
            # Send the data chunk
            case Plug.Conn.chunk(conn, "data: #{extracted_data}\n\n") do
              {:ok, updated_conn} ->
                Logger.info("[#{DateTime.utc_now()}] SSE request handler successfully chunked data. Sending close event.")
                # Send the close event and terminate the stream
                Plug.Conn.chunk(updated_conn, "event: close\ndata: Command completed.\n\n")
                updated_conn # Return the connection
              {:error, reason} ->
                Logger.error("[#{DateTime.utc_now()}] Failed to chunk STDOUT (JSON-RPC result): #{inspect(reason)}. Terminating stream."); conn # Return the connection on error
            end
          _ ->
            # This is not a JSON-RPC result, treat as regular data
            Logger.info("[#{DateTime.utc_now()}] SSE request handler received SQLcl STDOUT (non-JSON-RPC): #{data}")
            chunk_to_send = "data: #{data}\n\n"
            Logger.info("[#{DateTime.utc_now()}] SSE request handler attempting to chunk: #{inspect(chunk_to_send)}")
            case Plug.Conn.chunk(conn, chunk_to_send) do
              {:ok, updated_conn} ->
                Logger.info("[#{DateTime.utc_now()}] SSE request handler successfully chunked data.")
                loop_sse_in_request_process(updated_conn)
              {:error, reason} ->
                Logger.error("[#{DateTime.utc_now()}] Failed to chunk STDOUT: #{inspect(reason)}. Terminating stream."); conn # Return the connection on error
            end
        end
      {:sqlcl_output, {:stderr, data}} ->
        Logger.error("[#{DateTime.utc_now()}] SSE request handler received SQLcl STDERR: #{data}")
        case Plug.Conn.chunk(conn, "event: error\ndata: #{data}\n\n") do
          {:ok, updated_conn} -> loop_sse_in_request_process(updated_conn)
          {:error, reason} -> Logger.error("[#{DateTime.utc_now()}] Failed to chunk STDERR: #{inspect(reason)}. Terminating stream."); conn # Return the connection on error
        end
      {:sqlcl_output, {:exit, status}} ->
        Logger.info("[#{DateTime.utc_now()}] SSE request handler received SQLcl process exit: #{inspect(status)}")
        # Send a close event if the process exits
        Plug.Conn.chunk(conn, "event: close\ndata: SQLcl process exited with status #{inspect(status)}\n\n")
        conn # Return the connection
      {:cowboy_req, :disconnect, _reason, _req, _env} ->
        Logger.info("[#{DateTime.utc_now()}] SSE client disconnected for conn: #{inspect(conn.private)}")
        conn # Return the connection
      {:plug_conn, :sent} ->
        # This is an internal Plug message indicating the connection has been sent.
        # It's not an error, just re-enter the loop to wait for more SQLcl output.
        loop_sse_in_request_process(conn)
      msg ->
        Logger.info("[#{DateTime.utc_now()}] SSE request handler received unexpected message: #{inspect msg}. Re-entering loop.")
        loop_sse_in_request_process(conn)
    after 30_000 -> # Add a 30-second timeout for messages
      Logger.info("[#{DateTime.utc_now()}] SSE request handler process active, waiting for messages. Re-entering loop.")
      loop_sse_in_request_process(conn)
    end
  end
end
