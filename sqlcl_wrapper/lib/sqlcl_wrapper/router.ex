defmodule SqlclWrapper.Router do
  use Plug.Router
  require Logger
  # this doesn't work
  #require Hermes.Server.Transport.StreamableHTTP.Plug

  plug Plug.Logger
  plug :match
  plug :dispatch

  alias Hermes.Server.Transport.StreamableHTTP

  forward "/mcp", to: StreamableHTTP.Plug, init_opts: [server: SqlclWrapper.MCPServer]

  post "/mcp2" do
    #handle_mcp_request(conn)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

end
