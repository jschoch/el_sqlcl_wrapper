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
  def handle_call({:send_command, command_json}, from, state) do
    # Extract ID from the command_json
    parsed_command = Jason.decode!(command_json)
    id = Map.get(parsed_command, "id") # ID must be present for a call

    new_request_map = Map.put(state.request_map, id, from)

    Logger.info("Attempting to send command to SQLcl process: #{command_json}")
    Porcelain.Process.send_input(state.porcelain_pid, command_json <> "\n")
    Logger.info("Command sent to SQLcl process.")
    {:noreply, %{state | request_map: new_request_map}}
  end

  @impl true
  def handle_cast({:send_notification, notification_json}, state) do
    Logger.info("Attempting to send notification to SQLcl process: #{notification_json}")
    Porcelain.Process.send_input(state.porcelain_pid, notification_json <> "\n")
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
        # Not a valid JSON or not a map, broadcast to subscribers
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
  def send_command(command_json, timeout \\ 5000) do # Default timeout of 5 seconds
    # Determine if it's a request (has an ID) or a notification (no ID)
    parsed_command = Jason.decode!(command_json)
    if Map.has_key?(parsed_command, "id") do
      GenServer.call(__MODULE__, {:send_command, command_json}, timeout)
    else
      GenServer.cast(__MODULE__, {:send_notification, command_json})
    end
  end

  def subscribe(pid) do
    GenServer.cast(__MODULE__, {:subscribe, pid})
  end
end
