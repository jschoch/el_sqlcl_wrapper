defmodule SqlclWrapper.Router do
  use Plug.Router
  require Logger

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
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
    # The body is already parsed by Plug.Parsers
    body = conn.body_params
    Logger.info("Received POST /tool request with parsed body: #{inspect(body)}")

    # Assuming the body contains "tool_name" and "arguments" as per MCP spec
    tool_name = Map.get(body, "tool_name")
    arguments = Map.get(body, "arguments", %{})

    if tool_name do
      # Construct the JSON-RPC 2.0 request for tools/call
      # The ID should be dynamic, but for now, we'll use a fixed one or generate
      # This part needs to be properly integrated with SqlclProcess to send the actual JSON-RPC request
      # and receive the response. For now, we'll just log and send a placeholder response.
      json_rpc_request = %{
        jsonrpc: "2.0",
        id: 3, # Placeholder ID, should be dynamic
        method: "tools/call",
        params: %{
          name: tool_name,
          arguments: arguments
        }
      } |> Jason.encode!()

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
      send_resp(conn, 400, "Bad Request: 'tool_name' is missing.")
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  def send_sse_data(conn, data) do
    Plug.Conn.chunk(conn, "data: #{data}\n\n")
  end

  def stream_sqlcl_output(conn) do
    # This function is no longer needed as SqlclProcess sends messages directly.
    # The connection will be kept alive by the Cowboy server.
    # When the SqlclProcess sends :eof, the connection will be closed.
    conn
  end
end
