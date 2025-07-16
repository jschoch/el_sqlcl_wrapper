import Config

# Configures the SQLcl executable path
config :sqlcl_wrapper,
  sqlcl_executable: "/mnt/c/Files/downloads/sqlcl-25.2.0.184.2054/sqlcl/bin/sql.exe"

# Configure logging
config :logger, :console,
  format: "[$level] $message\n",
  metadata: [:file, :line],
  level: :debug
