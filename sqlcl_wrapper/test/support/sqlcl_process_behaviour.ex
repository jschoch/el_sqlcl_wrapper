defmodule SqlclWrapper.Test.SqlclProcessBehaviour do
  @callback subscribe(pid()) :: :ok
  @callback send_command_async(binary()) :: :ok
  @callback send_command(binary(), timeout()) :: {:ok, map()} | :ok
end
