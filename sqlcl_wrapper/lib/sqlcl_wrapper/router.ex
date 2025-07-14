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
    Logger.info("Received GET /tool request. Connection details: #{inspect(conn)}")

    # Subscribe the current process to the SqlclProcess output
    SqlclWrapper.SqlclProcess.subscribe(self())

    conn
    |> put_resp_content_type("text/event-stream")
    |> send_chunked(200)
    # The stream is now managed by the SqlclProcess sending messages directly
  end

  post "/tool" do
    content_type = get_req_header(conn, "content-type") |> hd()

    case content_type do
      "application/json" ->
        # Body is already parsed by Plug.Parsers as a map
        body = conn.body_params
        Logger.info("Received POST /tool request with JSON body: #{inspect(body)}")

        # Expecting a JSON-RPC 2.0 request
        method = Map.get(body, "method")
        _id = Map.get(body, "id") # Unused, so prefix with underscore
        params = Map.get(body, "params", %{})

        if method == "tools/call" && Map.has_key?(params, "name") do
          # Re-encode the received JSON-RPC request to send to SqlclProcess
          json_rpc_request = Jason.encode!(body)
          Logger.info("Sending JSON-RPC request to SQLcl process: #{json_rpc_request}")

          case SqlclWrapper.SqlclProcess.send_command(json_rpc_request) do
            {:ok, %{"result" => result}} ->
              Logger.info("Received successful response from SQLcl process: #{inspect(result)}")
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(%{"result" => result}))
            {:ok, %{"error" => error}} ->
              Logger.error("Received error response from SQLcl process: #{inspect(error)}")
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(500, Jason.encode!(%{"error" => error}))
            {:error, reason} ->
              Logger.error("Error communicating with SQLcl process: #{inspect(reason)}")
              send_resp(conn, 500, "Internal Server Error: #{inspect(reason)}")
          end
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

  def send_sse_data(conn, data) do
    Plug.Conn.chunk(conn, "data: #{data}\n\n")
  end

  @impl true
  def handle_info({:sqlcl_output, {:stdout, data}}, conn) do
    Logger.info("Router received SQLcl STDOUT for SSE: #{data}")
    # Ensure the connection is still chunked before sending data
    if conn.state == :chunked do
      Plug.Conn.chunk(conn, "data: #{data}\n\n")
    else
      Logger.warning("Attempted to chunk data to a non-chunked connection. State: #{inspect(conn.state)}")
      conn
    end
  end

  @impl true
  def handle_info({:sqlcl_output, {:stderr, data}}, conn) do
    Logger.error("Router received SQLcl STDERR for SSE: #{data}")
    # You might want to send this as an SSE error event or just log it
    if conn.state == :chunked do
      Plug.Conn.chunk(conn, "event: error\ndata: #{data}\n\n")
    else
      Logger.warning("Attempted to chunk error data to a non-chunked connection. State: #{inspect(conn.state)}")
      conn
    end
  end

  @impl true
  def handle_info({:sqlcl_output, {:exit, status}}, conn) do
    Logger.info("Router received SQLcl process exit for SSE: #{inspect(status)}")
    # Close the connection when the SQLcl process exits
    if conn.state == :chunked do
      Plug.Conn.chunk(conn, "event: close\ndata: SQLcl process exited with status #{inspect(status)}\n\n")
      Plug.Conn.send_resp(conn, 200, "") # Close the connection
    else
      Logger.warning("Attempted to close a non-chunked connection on SQLcl exit. State: #{inspect(conn.state)}")
      conn
    end
  end

  def stream_sqlcl_output(conn) do
    # This function is no longer directly used for streaming,
    # but the handle_info callbacks now manage the chunking.
    conn
  end
end
