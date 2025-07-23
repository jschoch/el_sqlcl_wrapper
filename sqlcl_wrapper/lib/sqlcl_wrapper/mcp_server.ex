defmodule SqlclWrapper.MCPServer do
  use Hermes.Server,
    name: "SQLcl",
    version: "25.2.0.184.2054",
    capabilities: [:tools,:resources]

  require Logger
  alias Hermes.Server.Response


  @impl true
  def init(_client_info, frame) do
    Logger.info("Initializing SqlclWrapper.MCPServer...")

    # Register tools
    {:ok,frame
    |> assign(counter: 0)
    |> register_tool("list-connections",
        description: "List all available oracle named/saved connections in the connections storage",
        input_schema: %{
          filter: {:optional, :string}
        })
    |> register_tool("connect",
        description: "Provides an interface to connect to a specified database. If a database connection is already active, prompt the user for confirmation before switching to the new connection. If no connection exists, list the available schemas for selection.",
        input_schema: %{
          connection_name: {:required, :string, description: "The name of the connection to establish"},
          mcp_client: {:optional, :string, description: "The name of the MCP client"},
          model: {:optional, :string, description: "The name and version of the LLM in use"}
        })
    |> register_tool("disconnect",
        description: "This tool performs a disconnection from the current session in an Oracle database. If a user is connected, it logs out cleanly and returns to the SQL prompt without an active database connection.",
        input_schema: %{
          mcp_client: {:optional, :string, description: "The name of the MCP client"},
          model: {:optional, :string, description: "The name and version of the LLM in use"}
        })
    |> register_tool("run-sqlcl",
        description: "This tool executes SQLcl commands in the SQLcl CLI. If the given command requires a database connection, it prompts the user to connect using the connect tool.",
        input_schema: %{
          sqlcl: {:required, :string, description: "The SQLcl command to execute"},
          mcp_client: {:optional, :string, description: "The name of the MCP client"},
          model: {:optional, :string, description: "The name and version of the LLM in use"}
        })
    |> register_tool("run-sql",
        description: "This tool executes SQL queries in an Oracle database. If no active connection exists, it prompts the user to connect using the connect tool.",
        input_schema: %{
          sql: {:required, :string, description: "The SQL query to execute"},
          mcp_client: {:optional, :string, description: "The name of the MCP client"},
          model: {:optional, :string, description: "The name and version of the LLM in use"}
        })

    }
  end

  @impl true
  def handle_tool_call("list-connections", params, frame) do
    Logger.info("Handling list-connections tool with params: #{inspect(params)}\n\n#{inspect frame}\n\n")
    request_id = "list-connections-#{System.unique_integer([:monotonic])}"
    json_rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => request_id,
      "params" => %{
        "name" => "list-connections",
        "arguments" => params
      }
    }
    Logger.info("list connections frame: #{inspect frame}")
    case SqlclWrapper.SqlclProcess.send_command(Jason.encode!(json_rpc_request),5000) do
      {:ok, %{"result" => result}} ->
        Logger.info("LC result #{inspect result}")
        result = Response.json(Response.tool(),result)
        {:reply, result, frame}
      {:reply, %{"content" => content}} ->
          {:reply, content, frame}
      {:error, reason} ->
        Logger.error("Error calling list-connections: #{inspect(reason)}")
        {:reply, %{"error" => "Failed to list connections: #{inspect(reason)}"}, frame}
      :ok -> # For raw commands that return :ok
        {:reply, %{"content" => [%{type: "text", text: "Command sent successfully."}]}, frame}
      doh ->
        Logger.error("DOH! #{inspect doh}")
        {:error}
    end
  end

  @impl true
  def handle_tool_call("connect", %{"connection_name" => conn_name} = params, frame) do
    Logger.info("Handling connect tool for #{conn_name} with params: #{inspect(params)}")
    request_id = "connect-#{System.unique_integer([:monotonic])}"
    json_rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => request_id,
      "params" => %{
        "name" => "connect",
        "arguments" => params
      }
    }
    case SqlclWrapper.SqlclProcess.send_command(Jason.encode!(json_rpc_request)) do
      {:ok, %{"result" => result}} ->
        {:reply, result, frame}
      {:error, reason} ->
        Logger.error("Error calling connect: #{inspect(reason)}")
        {:reply, %{"error" => "Failed to connect: #{inspect(reason)}"}, frame}
      :ok ->
        {:reply, %{"content" => [%{type: "text", text: "Command sent successfully."}]}, frame}
    end
  end

  @impl true
  def handle_tool_call("disconnect", params, frame) do
    Logger.info("Handling disconnect tool with params: #{inspect(params)}")
    request_id = "disconnect-#{System.unique_integer([:monotonic])}"
    json_rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => request_id,
      "params" => %{
        "name" => "disconnect",
        "arguments" => params
      }
    }
    case SqlclWrapper.SqlclProcess.send_command(Jason.encode!(json_rpc_request)) do
      {:ok, %{"result" => result}} ->
        {:reply, result, frame}
      {:error, reason} ->
        Logger.error("Error calling disconnect: #{inspect(reason)}")
        {:reply, %{"error" => "Failed to disconnect: #{inspect(reason)}"}, frame}
      :ok ->
        {:reply, %{"content" => [%{type: "text", text: "Command sent successfully."}]}, frame}
    end
  end

  @impl true
  def handle_tool_call("run-sqlcl", %{"sqlcl" => command} = params, frame) do
    Logger.info("Handling run-sqlcl tool with command: #{command}, params: #{inspect(params)}")
    request_id = "run-sqlcl-#{System.unique_integer([:monotonic])}"
    json_rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => request_id,
      "params" => %{
        "name" => "run-sqlcl",
        "arguments" => params
      }
    }
    case SqlclWrapper.SqlclProcess.send_command(Jason.encode!(json_rpc_request)) do
      {:ok, %{"result" => result}} ->
        {:reply, result, frame}
      {:error, reason} ->
        Logger.error("Error calling run-sqlcl: #{inspect(reason)}")
        {:reply, %{"error" => "Failed to run sqlcl command: #{inspect(reason)}"}, frame}
      :ok ->
        {:reply, %{"content" => [%{type: "text", text: "Command sent successfully."}]}, frame}
    end
  end

  @impl true
  def handle_tool_call("run-sql", %{"sql" => query} = params, frame) do
    Logger.info("Handling run-sql tool with query: #{query}, params: #{inspect(params)}")
    request_id = "run-sql-#{System.unique_integer([:monotonic])}"
    json_rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => request_id,
      "params" => %{
        "name" => "run-sql",
        "arguments" => params
      }
    }
    case SqlclWrapper.SqlclProcess.send_command(Jason.encode!(json_rpc_request)) do
      {:ok, %{"result" => result}} ->
        {:reply, result, frame}
      {:error, reason} ->
        Logger.error("Error calling run-sql: #{inspect(reason)}")
        {:reply, %{"error" => "Failed to run sql query: #{inspect(reason)}"}, frame}
      :ok ->
        {:reply, %{"content" => [%{type: "text", text: "Command sent successfully."}]}, frame}
    end
  end

  # Fallback for unknown tools
  @impl true
  def handle_tool_call(tool_name, _params, frame) do
    Logger.warning("Unknown tool called: #{tool_name}")
    {:reply, %{"error" => "Unknown tool: #{tool_name}"}, frame}
  end
end
