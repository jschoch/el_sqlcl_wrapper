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

    case Porcelain.spawn(@sqlcl_path, ["-mcp"], out: {:send, self()}, err: {:send, self()}) do
      %Porcelain.Process{} = p ->
        send(parent, {:sqlcl_process_started, self()})
        {:ok, %{porcelain_pid: p, parent: parent, subscribers: [], request_map: %{}, next_id: 1}}

      _ ->
        Logger.error("Failed to start SQLcl process. Check if '#{@sqlcl_path}' is a valid executable and accessible.")
        send(parent, :sqlcl_process_failed_to_start)
        {:stop, :sqlcl_process_failed_to_start}
    end
  end

  @impl true
  def handle_call({:send_command, command}, from, state) do
    # If it's a JSON-RPC command, extract ID and store 'from'
    case Jason.decode(command) do
      {:ok, parsed_command} when is_map(parsed_command) ->
        if Map.has_key?(parsed_command, "id") do
          id = Map.get(parsed_command, "id")
          new_request_map = Map.put(state.request_map, id, from)
          Logger.info("Attempting to send JSON-RPC command to SQLcl process: #{command}")
          Porcelain.Process.send_input(state.porcelain_pid, command <> "\n")
          Logger.info("JSON-RPC command sent to SQLcl process.")
          {:noreply, %{state | request_map: new_request_map}}
        else
          # It's a raw command (JSON but no ID), no ID to track, just send it
          Logger.info("Attempting to send raw command (JSON, no ID) to SQLcl process: #{command}")
          Porcelain.Process.send_input(state.porcelain_pid, command <> "\n")
          Logger.info("Raw command (JSON, no ID) sent to SQLcl process.")
          GenServer.reply(from, :ok) # Acknowledge receipt for raw commands
          {:noreply, state}
        end
      _ ->
        # It's a raw command (not JSON), no ID to track, just send it
        Logger.info("Attempting to send raw command to SQLcl process: #{command}")
        Porcelain.Process.send_input(state.porcelain_pid, command <> "\n")
        Logger.info("Raw command sent to SQLcl process.")
        GenServer.reply(from, :ok) # Acknowledge receipt for raw commands
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_notification, notification}, state) do
    Logger.info("Attempting to send notification to SQLcl process: #{notification}")
    Porcelain.Process.send_input(state.porcelain_pid, notification <> "\n")
    Logger.info("Notification sent to SQLcl process.")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    {:noreply, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_info({:exit_status, status}, state) do
    Logger.info("SQLcl process exited with status: #{inspect(status)}")
    send(state.parent, {:sqlcl_output, {:exit, status}})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({_pid, :data, :out, data}, state) do
    Logger.info("***** SQLcl STDOUT: #{data}")
    send(state.parent, {:sqlcl_output, {:stdout, data}})

    # Attempt to parse the data as JSON
    case Jason.decode(data) do
      {:ok, json_response} when is_map(json_response) ->
        if Map.has_key?(json_response, "id") do
          id = json_response["id"]
          if from = Map.get(state.request_map, id) do
            # Reply to the caller that initiated this request
            GenServer.reply(from, {:ok, json_response})
            {:noreply, %{state | request_map: Map.delete(state.request_map, id)}}
          else
            # If no matching request, broadcast to subscribers
            for pid <- state.subscribers do
              send(pid, {:sqlcl_output, {:stdout, data}})
            end
            {:noreply, state}
          end
        else
          # Not a JSON-RPC response with an ID, broadcast to subscribers
          for pid <- state.subscribers do
            send(pid, {:sqlcl_output, {:stdout, data}})
          end
          {:noreply, state}
        end
      _ ->
        # Not a valid JSON or not a map, broadcast raw data to subscribers
        for pid <- state.subscribers do
          send(pid, {:sqlcl_output, {:stdout, data}})
        end
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({_pid, :data, :err, data}, state) do
    Logger.error("***** SQLcl STDERR: #{data}")
    send(state.parent, {:sqlcl_output, {:stderr, data}})
    {:noreply, state}
  end

  # Client API
  def send_command(command, timeout \\ 5000) do # Default timeout of 5 seconds
    # Attempt to parse as JSON to determine if it's a request or notification
    case Jason.decode(command) do
      {:ok, parsed_command} when is_map(parsed_command) ->
        if Map.has_key?(parsed_command, "id") do
          GenServer.call(__MODULE__, {:send_command, command}, timeout)
        else
          # It's JSON but no ID, treat as a notification
          GenServer.cast(__MODULE__, {:send_notification, command})
        end
      _ ->
        # Not JSON, treat as a raw command (e.g., "exit", "show release")
        GenServer.call(__MODULE__, {:send_command, command}, timeout)
    end
  end

  def subscribe(pid) do
    GenServer.cast(__MODULE__, {:subscribe, pid})
  end
end
