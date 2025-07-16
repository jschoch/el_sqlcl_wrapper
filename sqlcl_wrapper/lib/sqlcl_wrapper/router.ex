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

  # Forward all MCP requests to the Hermes.Server
  #forward "/mcp", Hermes.Server.Transport.StreamableHTTP.Plug, server: SqlclWrapper.MCPServer

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
