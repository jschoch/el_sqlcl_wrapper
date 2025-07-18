defmodule SqlclWrapper.Router do
  use Plug.Router
  # this doesn't work
  #require Hermes.Server.Transport.StreamableHTTP.Plug

  plug Plug.Logger
  plug :match
  plug :dispatch

  alias Hermes.Server.Transport.StreamableHTTP

  forward "/mcp2", to: StreamableHTTP.Plug, init_opts: [server: SqlclWrapper.MCPServer]

  post "/mcp" do
    handle_mcp_request(conn)
  end

  get "/mcp" do
    handle_mcp_request(conn)
  end

  post "/tool" do
    handle_mcp_request(conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp handle_mcp_request(conn) do
    try do
      # Try to load the module at runtime
      plug_module = Hermes.Server.Transport.StreamableHTTP.Plug
      opts = plug_module.init([server: SqlclWrapper.MCPServer])
      plug_module.call(conn, opts)
    rescue
      UndefinedFunctionError ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "MCP Transport not available"}))
    end
  end
end
