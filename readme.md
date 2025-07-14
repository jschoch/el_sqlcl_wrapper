# Project Summary: `el_sqlcl` Server Setup and Interaction

This document summarizes the steps taken to set up and interact with the `el_sqlcl` server, which acts as an MCP (Model Context Protocol) server for SQLcl.

## Server Setup

The `el_sqlcl` server is an Elixir application that wraps the SQLcl executable. To start the server:

1.  Navigate to the `el_sqlcl/sqlcl_wrapper` directory:
    ```bash
    cd el_sqlcl/sqlcl_wrapper
    ```
2.  Start the Elixir application using `mix run --no-halt`:
    ```bash
    mix run --no-halt
    ```
    This command will compile the necessary files and start the server. You should see output indicating "MCP Server started successfully".

## Server Interaction

The server exposes an endpoint (typically `http://localhost:4000/tool`) for interacting with SQLcl via MCP tools.

### Listing SQLcl Connections

To list available SQLcl connections, you can send a `POST` request to the `/tool` endpoint with the `list-connections` tool and its arguments.

Example `curl` command:

```bash
curl -X POST -H "Content-Type: application/json" -d '{"tool_name": "list-connections", "arguments": {"mcp_client": "cline", "model": "claude-sonnet-4"}}' http://localhost:4000/tool
```

This command sends a request to the running `el_sqlcl` server, which then uses the underlying SQLcl process to list the configured connections. The output of this command will appear in the terminal where the `mix run --no-halt` command is running.

### JSON-RPC 2.0 Handshake

The `el_sqlcl` server communicates with SQLcl using the JSON-RPC 2.0 protocol over standard I/O. A typical handshake and tool call sequence involves the following steps:

1.  **Initialize Request**: The client sends an `initialize` request to the server to establish the protocol version and capabilities. Note that the server might suggest a different protocol version if the requested one is unsupported.
    ```json
    {
      "jsonrpc": "2.0",
      "method": "initialize",
      "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {
          "name": "my-stdio-client",
          "version": "1.0.0"
        }
      },
      "id": 1
    }
    ```
2.  **Initialize Response**: The server responds to the `initialize` request, confirming its capabilities.
    ```json
    {
      "jsonrpc": "2.0",
      "id": 1,
      "result": {
        "protocolVersion":"2024-11-05",
        "capabilities":{
          "logging":{},
          "prompts":{"listChanged":true},
          "resources":{"subscribe":true,"listChanged":true},
          "tools":{"listChanged":true}
        },
        "serverInfo":{"name":"sqlcl-mcp-server","version":"1.0.0"}
      }
    }
    ```
3.  **Initialized Notification**: The client sends an `initialized` notification to inform the server that it is ready. This is a notification, so no response is expected.
    ```json
    {
      "jsonrpc": "2.0",
      "method": "notifications/initialized",
      "params": {}
    }
    ```
4.  **Tools/Call Request**: The client sends a `tools/call` request to invoke a specific MCP tool, such as `list-connections`.
    ```json
    {
      "jsonrpc": "2.0",
      "id": 2,
      "method": "tools/call",
      "params": {
        "name": "list-connections",
        "arguments": {}
      }
    }
    ```
5.  **Tools/Call Response**: The server responds with the result of the tool call.
    ```json
    {
      "jsonrpc":"2.0",
      "id":2,
      "result":{
        "content":[{"type":"text","text":"theconn,test123"}],
        "isError":false
      }
    }
    ```

## Changes Made

During the setup process, the following modifications were made to `el_sqlcl/sqlcl_wrapper/lib/sqlcl_wrapper/sqlcl_process.ex`:

*   **`handle_info` clauses updated**: The `handle_info` functions were modified to correctly parse messages from the `Porcelain` library, specifically for `stdout`, `stderr`, and `exit_status` events. This resolved `FunctionClauseError` issues.
*   **`-mcp` argument added**: The `sql.exe` executable is now spawned with the `-mcp` argument, ensuring it runs in Model Context Protocol mode, which is essential for its integration with the Elixir wrapper.
*   **Request/Notification Handling**: Refactored `send_command` and `handle_call` to differentiate between JSON-RPC requests (which expect a reply and have an `id`) and notifications (which do not expect a reply and do not have an `id`). This ensures proper routing of responses.

## Testing

The `test/porcelain_test.exs` file has been updated and now passes successfully. This test verifies the raw input and output of the `sqlcl.exe` process via the Porcelain wrapper, performing a full JSON-RPC 2.0 handshake with the server, including:

1.  Sending an `initialize` request with the correct protocol version.
2.  Receiving and asserting the `initialize` response.
3.  Sending an `initialized` notification (no reply expected).
4.  Sending a `tools/call` request to the `list-connections` tool.
5.  Receiving and asserting the `tools/call` response, including its content and `isError` status.

To run the test, use the following command from the `el_sqlcl/sqlcl_wrapper` directory:

```bash
mix test test/porcelain_test.exs
