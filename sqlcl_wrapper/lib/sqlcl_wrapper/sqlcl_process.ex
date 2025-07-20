defmodule SqlclWrapper.SqlclProcess do
  use GenServer
  require Logger

  @sqlcl_path Application.compile_env(:sqlcl_wrapper, :sqlcl_executable, "sql.exe")

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    parent = Keyword.get(opts, :parent)
    Logger.info("Starting SQLcl process...")
    Logger.info("SQLcl executable path: #{@sqlcl_path}")

    try do
      # Redirect stderr to stdout so we can capture both streams
      port = Port.open({:spawn, "#{@sqlcl_path} -mcp 2>&1"}, [:binary, :exit_status])
      Logger.info("Port.open successful, Port: #{inspect(port)}")
      send(parent, {:sqlcl_process_started, self()})

      {:ok, %{port: port, parent: parent, request_map: %{}, server_ready_flag: false, stdout_buffer: "", initialized_sent_flag: false, initialized_received_flag: false}}
    catch
      error ->
        Logger.error("Port.open failed: #{inspect(error)}. Check if '#{@sqlcl_path}' is a valid executable and accessible.")
        send(parent, :sqlcl_process_failed_to_start)
        {:stop, :sqlcl_process_failed_to_start}
    end
  end

  @impl true
  def handle_call(:is_server_ready, _from, state) do
    {:reply, state.server_ready_flag, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    cap_req = ~s({  "jsonrpc": "2.0",  "id": 1,  "method": "tools/list",  "params": {     }})
    Port.command(state.port, cap_req <> "\n")
    {:reply, :pong, state}
  end

  @impl true
  def handle_call({:send_command, command}, from, state) do
    # If it's a JSON-RPC command, extract ID and store 'from'
    case Jason.decode(command) do
      {:ok, %{"id" => id} = _parsed_command} ->
        new_request_map = Map.put(state.request_map, id, from)
        Logger.info("Attempting to send JSON-RPC command to SQLcl process: #{command} to port: #{inspect state.port}")
        Logger.info("request map: #{inspect new_request_map, pretty: true}")
        Port.command(state.port, command <> "\n")
        Logger.info("JSON-RPC command sent to SQLcl process.")
        {:noreply, %{state | request_map: new_request_map}}
      {:ok, _parsed_command} -> # JSON but no ID, treat as raw command
        Logger.info("Attempting to send raw command (JSON, no ID) to SQLcl process: #{command}")
        Port.command(state.port, command <> "\n")
        Logger.info("Raw command (JSON, no ID) sent to SQLcl process.")
        GenServer.reply(from, :ok) # Acknowledge receipt for raw commands
        {:noreply, state}
      _ ->
        # It's a raw command (not JSON), no ID to track, just send it
        Logger.info("Attempting to send raw command to SQLcl process: #{command}")
        Port.command(state.port, command <> "\n")
        Logger.info("Raw command sent to SQLcl process.")
        GenServer.reply(from, :ok) # Acknowledge receipt for raw commands
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_notification, notification}, state) do
    Logger.info("Attempting to send notification to SQLcl process: #{notification}")
    Port.command(state.port, notification <> "\n")
    Logger.info("Notification sent to SQLcl process.")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, state) when port == state.port do
    Logger.info("SQLcl process exited with status: #{inspect(status)}")
    send(state.parent, {:sqlcl_output, {:exit, status}})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when port == state.port do
    Logger.debug("Received raw data: #{inspect(data)}")
    buffer = state.stdout_buffer <> IO.iodata_to_binary(data)
    {json_objects, remaining_buffer} = extract_json_objects(buffer)

    # Process all complete JSON objects
    state_after_json =
      Enum.reduce(json_objects, state, fn json_string, acc_state ->
        process_line(json_string, acc_state)
      end)

    # The remaining buffer might contain non-JSON log lines, or an incomplete JSON object.
    # We'll split it by lines and process what we can, leaving any partial line in the buffer.
    lines = String.split(remaining_buffer, ~r/\R/)
    # If the buffer ends with a newline, the last element of split is "", which is fine.
    # If it does not end with a newline, the last element is a partial line.
    last_is_partial = not (String.ends_with?(remaining_buffer, "\n") or String.ends_with?(remaining_buffer, "\r\n"))
    lines_to_process = if last_is_partial, do: Enum.slice(lines, 0, length(lines) - 1), else: lines
    new_buffer = if last_is_partial, do: List.last(lines), else: ""

    state_after_logs =
      Enum.reduce(lines_to_process, %{state_after_json | stdout_buffer: new_buffer}, fn line, acc_state ->
        process_line(line, acc_state)
      end)

    send(state.parent, {:sqlcl_output, {:stdout, data}})
    {:noreply, state_after_logs}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.info("[#{DateTime.utc_now()}] ***** Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      Port.close(state.port)
    end
    :ok
  end

  defp process_line(line, state) do
    # Trim whitespace and ignore empty lines
    trimmed_line = String.trim(line)
    Logger.debug("Processing line: #{trimmed_line}")
    if trimmed_line == "" do
      state
    else
      # Attempt to decode as JSON first
      case Jason.decode(trimmed_line) do
        {:ok, json_response} ->
          Logger.debug("Line is JSON, handling as RPC.")
          handle_json_rpc(json_response, state)
        _ ->
          # Not JSON, treat as a regular log/stderr message
          Logger.debug("Line is not JSON, handling as stderr.")
          handle_stderr(trimmed_line, state)
      end
    end
  end

  defp extract_json_objects(buffer, acc \\ []) do
    trimmed_buffer = String.trim_leading(buffer)
    if String.starts_with?(trimmed_buffer, "{") do
      case find_json_object(trimmed_buffer) do
        {:ok, json_string, rest} ->
          extract_json_objects(rest, [json_string | acc])
        {:incomplete, _rest} ->
          # Not enough data yet, return what we have and the remaining buffer
          {Enum.reverse(acc), trimmed_buffer}
      end
    else
      # No JSON object at the start of the buffer, or buffer is empty/whitespace
      {Enum.reverse(acc), trimmed_buffer}
    end
  end

  defp find_json_object(buffer) do
    # Scan the buffer to find the end of the first complete JSON object
    scan_for_json_end(buffer, 1, 1)
  end

  defp scan_for_json_end(_buffer, 0, index) do
    # This should not be called with level 0 initially, but if it is, we have an object.
    # This is the success case from the recursive call.
    {json, rest} = String.split_at(elem(String.codepoint_at(_buffer, 0), 1), index)
    {:ok, json, rest}
  end

  defp scan_for_json_end(buffer, level, index) do
    if index >= byte_size(buffer) do
      # Reached end of buffer without finding the closing brace
      {:incomplete, buffer}
    else
      case :binary.at(buffer, index) do
        ?{ -> scan_for_json_end(buffer, level + 1, index + 1)
        ?} ->
            if level - 1 == 0 do
              # Found the end of the object
              json_part = :binary.part(buffer, 0, index + 1)
              rest_part = :binary.part(buffer, index + 1, byte_size(buffer) - (index + 1))
              {:ok, json_part, rest_part}
            else
              scan_for_json_end(buffer, level - 1, index + 1)
            end
        _ -> scan_for_json_end(buffer, level, index + 1)
      end
    end
  end

  defp handle_stderr(line, state) do
    patterns_to_check = [
      "----------------------------------------"
    ]

    is_initial_ready_message = Enum.any?(patterns_to_check, fn pattern ->
      String.contains?(line, pattern)
    end)

    if is_initial_ready_message and not state.initialized_sent_flag do
      Logger.info("Initial SQLcl ready message received. Sending initialize JSON-RPC message.")
      initialize_message = ~s({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}, "clientInfo": {"name": "Elixir MCP Client", "version": "1.0"}, "protocolVersion": "2024-11-05"}})
      Port.command(state.port, initialize_message <> "\n")
      Process.sleep(200)
      Logger.info("Sent initialize message. #{inspect state} ")
      %{state | initialized_sent_flag: true}
    else
      # This is not a response to a command we sent, just a log line from SQLcl
      Logger.info("SQLcl log: #{line}")
      state
    end
  end

  defp handle_json_rpc(json_response, %{initialized_received_flag: false, initialized_sent_flag: true, server_ready_flag: false} = state) do
    Logger.info("Received response for initialize message. Sending initialized notification.")
    Logger.info("resp: #{inspect json_response, pretty: true}")
    state = %{state | initialized_received_flag: true, server_ready_flag: true}
    initialized_notification = ~s({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
    Port.command(state.port, initialized_notification <> "\n")
    Logger.info("Sent initialized notification. Server is now ready. #{inspect state.port}")
    Process.sleep(200)
    #cap_req = ~s({  "jsonrpc": "2.0",  "id": 1,  "method": "tools/list",  "params": {     }})
    #Port.command(state.port, cap_req <> "\n")
    # The server is now fully ready
    state
  end

  defp handle_json_rpc(%{"id" => id, "error" => _error} = json_response, state) do
    if from = Map.get(state.request_map, id) do
      # It's an error, but it's a valid JSON-RPC response for a call
      GenServer.reply(from, {:error, json_response})
      %{state | request_map: Map.delete(state.request_map, id)}
    else
      Logger.warning("Received a JSON-RPC error with an un-tracked ID: #{id}")
      state
    end
  end

  defp handle_json_rpc(%{"id" => id, "result" => _result} = json_response, state) do
    if from = Map.get(state.request_map, id) do
      GenServer.reply(from, {:ok, json_response})
      %{state | request_map: Map.delete(state.request_map, id)}
    else
      # Unmatched response, maybe log it
      Logger.warning("Received a JSON-RPC response with an un-tracked ID: #{id}")
      state
    end
  end

  defp handle_json_rpc(%{"method" => method, "params" => _params} = notification, state) do
    # This is a notification from the server.
    # We can forward it to the parent or handle it here.
    Logger.info("Received notification from SQLcl: #{method}")
    send(state.parent, {:sqlcl_notification, notification})
    state
  end

  defp handle_json_rpc(other, state) do
    # Catch-all for other JSON messages that don't fit the patterns above
    Logger.warning("Received an unhandled JSON message: #{inspect(other)}")
    state
  end

  # Client API
  def send_command(command, timeout \\ 5000) do # Default timeout of 5 seconds
    # Attempt to parse as JSON to determine if it's a request or notification
    Logger.info("doe sthis even work?")
    case Jason.decode(command) do
      {:ok, %{"id" => _id} = _parsed_command} ->
        GenServer.call(__MODULE__, {:send_command, command}, timeout)
      {:ok, _parsed_command} -> # JSON but no ID, treat as a notification
        GenServer.cast(__MODULE__, {:send_notification, command})
      _ ->
        # Not JSON, treat as a raw command (e.g., "exit", "show release")
        GenServer.call(__MODULE__, {:send_command, command}, timeout)
    end
  end
end
