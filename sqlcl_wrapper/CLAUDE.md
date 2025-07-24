# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Elixir application that provides an MCP (Model Context Protocol) server wrapper around Oracle SQLcl. It enables AI assistants to interact with Oracle databases through SQLcl commands via a standardized protocol interface.

## Key Architecture Components

### Application Structure
- **SqlclWrapper.Application**: Main OTP application that supervises all components
- **SqlclWrapper.SqlclProcess**: GenServer that manages the SQLcl executable as a port process, handles JSON-RPC communication
- **SqlclWrapper.MCPServer**: Hermes-based MCP server that exposes database tools to AI clients
- **SqlclWrapper.Router**: Plug-based HTTP router for MCP connections via HTTP transport
- **SqlclWrapper.MCPClient**: Hermes-based MCP client for testing

### Core Process Flow
1. Application starts SqlclProcess GenServer which spawns `sql.exe -mcp` as a port
2. SQLcl process initialization involves JSON-RPC handshake (initialize → initialized)
3. MCPServer exposes 5 main tools: list-connections, connect, disconnect, run-sqlcl, run-sql
4. Tool calls are converted to JSON-RPC requests and sent to SQLcl via the port
5. Responses are parsed and returned to the MCP client

### MCP Tools Exposed
- `list-connections`: List available Oracle connections
- `connect`: Connect to a named Oracle database connection
- `disconnect`: Disconnect from current Oracle session
- `run-sqlcl`: Execute SQLcl commands
- `run-sql`: Execute SQL queries

## Development Commands

### Basic Operations
```bash
# Install dependencies
mix deps.get

# Compile the project
mix compile

# Run tests
mix test

# Run a specific test
mix test test/port_process_test.exs

# Start the application
mix run --no-halt

# Start interactive shell with application loaded
iex -S mix
```

### Configuration
- SQLcl executable path is configured in `config/config.exs` 
- Current path: `/mnt/c/Files/downloads/sqlcl-25.2.0.184.2054/sqlcl/bin/sql.exe`
- Test configurations are in `config/test.exs`

## Important Implementation Details

### Port Communication
- Uses Elixir Port to communicate with SQLcl process via stdin/stdout
- Implements JSON-RPC 2.0 protocol for structured communication
- Handles both synchronous requests (with ID) and asynchronous notifications
- Complex JSON parsing logic extracts complete JSON objects from streaming output

### State Management
- SqlclProcess maintains request tracking via `request_map` to correlate responses
- Server readiness is tracked with `server_ready_flag` and initialization flags
- Buffer management handles partial JSON objects and mixed JSON/log output

### Error Handling
- Timeout handling for SQLcl process startup and tool calls
- Graceful handling of malformed JSON and unexpected responses
- Port exit status monitoring and cleanup
- **IMPORTANT**: Avoid dangling case statements like `_ -> []` that silently fail. Instead, crash with descriptive error messages using pattern: `doh -> Logger.info("unexpected #{inspect doh}"); raise "Unexpected value: #{inspect doh}"`

### Testing Strategy
- Integration tests verify end-to-end SQLcl communication
- Mocked tests for isolated component testing
- Test helper modules provide shared testing utilities
- Async: false for tests that interact with the shared SQLcl process

## Dependencies
- `hermes_mcp` ~> 0.13: MCP protocol implementation
- `plug` ~> 1.18 & `bandit` ~> 1.6: HTTP server stack
- `jason` ~> 1.2: JSON encoding/decoding
- `httpoison` ~> 2.1: HTTP client (dev/test only)
- `mox` ~> 1.0: Mocking library (test only)