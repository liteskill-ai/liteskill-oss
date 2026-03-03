defmodule Liteskill.Desktop.PostgresManager do
  @moduledoc """
  GenServer that manages the lifecycle of a bundled PostgreSQL instance
  for desktop mode.

  On init, runs the setup pipeline: ensure directories, initdb (if needed),
  start postgres, wait for ready, create database (if needed), run migrations.

  On terminate, stops postgres gracefully via `pg_ctl stop -m fast`.

  All system commands are injectable via `cmd_fn` for testability.
  Migrations are injectable via `migrate_fn`.

  On Windows, uses TCP (localhost + port) instead of Unix sockets.
  """

  use GenServer

  require Logger

  @default_pg_ready_poll_ms 500
  @default_pg_ready_timeout_ms 15_000
  @default_migrate_timeout_ms 120_000
  @default_log_max_bytes 10_485_760

  defstruct [
    :bin_dir,
    :share_dir,
    :data_dir,
    :socket_dir,
    :database,
    :cmd_fn,
    :migrate_fn,
    :pg_ready_poll_ms,
    :pg_ready_timeout_ms,
    :migrate_timeout_ms,
    :log_max_bytes,
    :port,
    pg_started: false,
    windows?: false
  ]

  @type t :: %__MODULE__{
          bin_dir: String.t(),
          share_dir: String.t(),
          data_dir: String.t(),
          socket_dir: String.t(),
          database: String.t(),
          cmd_fn: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()}),
          migrate_fn: (-> term()),
          pg_ready_poll_ms: pos_integer(),
          pg_ready_timeout_ms: pos_integer(),
          migrate_timeout_ms: pos_integer(),
          log_max_bytes: pos_integer(),
          port: pos_integer(),
          pg_started: boolean(),
          windows?: boolean()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    database = opts[:database] || "liteskill_desktop"

    if !Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, database) do
      raise ArgumentError, "invalid database name: #{inspect(database)}"
    end

    state = %__MODULE__{
      bin_dir: opts[:bin_dir] || Liteskill.Desktop.pg_bin_dir(),
      share_dir: opts[:share_dir] || Liteskill.Desktop.pg_share_dir(),
      data_dir: opts[:data_dir] || Liteskill.Desktop.pg_data_dir(),
      socket_dir: opts[:socket_dir] || Liteskill.Desktop.socket_dir(),
      database: database,
      cmd_fn: opts[:cmd_fn] || fn cmd, args, o -> System.cmd(cmd, args, o) end,
      migrate_fn: opts[:migrate_fn] || fn -> Liteskill.Release.migrate() end,
      pg_ready_poll_ms: opts[:pg_ready_poll_ms] || @default_pg_ready_poll_ms,
      pg_ready_timeout_ms: opts[:pg_ready_timeout_ms] || @default_pg_ready_timeout_ms,
      migrate_timeout_ms: opts[:migrate_timeout_ms] || @default_migrate_timeout_ms,
      log_max_bytes: opts[:log_max_bytes] || @default_log_max_bytes,
      windows?: Keyword.get(opts, :windows?, Liteskill.Desktop.windows?()),
      port: opts[:port] || Liteskill.Desktop.pg_port()
    }

    case setup_and_start(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %__MODULE__{pg_started: true} = state) do
    Logger.info("[PostgresManager] Stopping PostgreSQL…")
    pg_ctl = pg_bin(state, "pg_ctl")
    state.cmd_fn.(pg_ctl, ["stop", "-D", state.data_dir, "-m", "fast"], stderr_to_stdout: true)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Platform helpers --

  defp host_args(%__MODULE__{windows?: true, port: port}), do: ["-h", "localhost", "-p", to_string(port)]

  defp host_args(%__MODULE__{socket_dir: socket_dir}), do: ["-h", socket_dir]

  defp pg_bin(%__MODULE__{windows?: true, bin_dir: bin_dir}, name), do: Path.join(bin_dir, name <> ".exe")

  defp pg_bin(%__MODULE__{bin_dir: bin_dir}, name), do: Path.join(bin_dir, name)

  # -- Setup pipeline --

  defp setup_and_start(state) do
    with :ok <- ensure_directories(state),
         :ok <- ensure_executables(state),
         :ok <- maybe_initdb(state),
         :ok <- ensure_pg_config(state),
         :ok <- maybe_truncate_log(state),
         :ok <- cleanup_stale_pid(state),
         :ok <- start_postgres(state),
         state = %{state | pg_started: true},
         :ok <- wait_for_ready(state),
         :ok <- patch_libdir(state),
         :ok <- maybe_create_database(state),
         :ok <- patch_libdir_in_database(state),
         :ok <- run_migrations(state) do
      Logger.info("[PostgresManager] PostgreSQL ready — database: #{state.database}")
      {:ok, state}
    end
  end

  defp ensure_directories(%__MODULE__{windows?: true} = state) do
    File.mkdir_p!(state.data_dir)
    :ok
  end

  defp ensure_directories(state) do
    File.mkdir_p!(state.socket_dir)
    File.mkdir_p!(state.data_dir)
    :ok
  end

  defp ensure_executables(state) do
    for name <- ~w(postgres pg_ctl initdb pg_isready psql createdb) do
      path = pg_bin(state, name)

      if !File.exists?(path) do
        Logger.error("[PostgresManager] Missing bundled binary: #{path}")
        raise "PostgreSQL binary not found: #{path}"
      end

      # Defensive: ensure execute permission is set (some bundling tools strip it)
      File.chmod(path, 0o755)
    end

    # Log shared library status for debugging (pg_lib_dir returns colon-separated paths)
    lib_dirs = state |> pg_lib_dir() |> String.split(":")

    for dir <- lib_dirs do
      Logger.info("[PostgresManager] Checking #{dir}")

      case File.ls(dir) do
        {:ok, files} -> Logger.info("[PostgresManager]   contents: #{Enum.join(files, ", ")}")
        {:error, reason} -> Logger.warning("[PostgresManager]   Cannot list: #{reason}")
      end
    end

    ext = if :os.type() == {:unix, :darwin}, do: "dylib", else: "so"

    for lib <- ~w(plpgsql vector) do
      found = Enum.any?(lib_dirs, &File.exists?(Path.join(&1, "#{lib}.#{ext}")))
      Logger.info("[PostgresManager] #{lib}.#{ext} found=#{found}")
    end

    :ok
  end

  defp maybe_initdb(state) do
    pg_version_file = Path.join(state.data_dir, "PG_VERSION")

    if File.exists?(pg_version_file) do
      Logger.info("[PostgresManager] PostgreSQL data directory already initialized")
      :ok
    else
      Logger.info("[PostgresManager] Running initdb…")
      initdb = pg_bin(state, "initdb")

      case state.cmd_fn.(
             initdb,
             ["-D", state.data_dir, "-L", state.share_dir, "--no-locale", "-E", "UTF8"],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, code} -> {:error, {:initdb_failed, code, output}}
      end
    end
  end

  # Write dynamic_library_path into postgresql.conf so it persists across
  # restarts — including when PG is already running from a previous session.
  # The -o flag on pg_ctl start also sets it, but that only helps for fresh starts.
  defp ensure_pg_config(state) do
    conf_path = Path.join(state.data_dir, "postgresql.conf")
    lib_dir = pg_lib_dir(state)
    ext_dir = pg_extension_dir(state)
    marker = "# -- PostgresManager managed settings --"

    managed_block =
      "#{marker}\ndynamic_library_path = '#{lib_dir}'\nextension_control_path = '#{ext_dir}'\n"

    if File.exists?(conf_path) do
      contents = File.read!(conf_path)

      updated =
        if String.contains?(contents, marker) do
          # Replace existing managed block
          String.replace(
            contents,
            ~r/#{Regex.escape(marker)}\n(?:.*\n)*/,
            managed_block
          )
        else
          contents <> "\n" <> managed_block
        end

      File.write!(conf_path, updated)
    end

    :ok
  end

  defp cleanup_stale_pid(state) do
    pid_file = Path.join(state.data_dir, "postmaster.pid")

    if File.exists?(pid_file) do
      # Check if the PID in the file belongs to a running process.
      # If not, remove the stale pid file so pg_ctl start doesn't refuse.
      case File.read(pid_file) do
        {:ok, contents} ->
          pid_str = contents |> String.split("\n") |> hd() |> String.trim()

          if pid_str != "" and not process_alive?(pid_str, state) do
            Logger.info("[PostgresManager] Removing stale postmaster.pid (PID #{pid_str})")
            File.rm(pid_file)
          end

        # coveralls-ignore-start — race: file exists but read fails
        _ ->
          :ok
          # coveralls-ignore-stop
      end
    end

    :ok
  end

  # coveralls-ignore-start — System.cmd("tasklist") is not injectable and doesn't exist on Linux
  defp process_alive?(pid_str, %__MODULE__{windows?: true}) do
    {output, _} =
      System.cmd("tasklist", ["/FI", "PID eq #{pid_str}", "/NH"], stderr_to_stdout: true)

    String.contains?(output, pid_str)
  end

  # coveralls-ignore-stop

  defp process_alive?(pid_str, _state) do
    case Integer.parse(pid_str) do
      {pid, _} ->
        # kill -0 checks if process exists without sending a signal.
        # Works on both Linux and macOS (unlike /proc which is Linux-only).
        {_, code} = System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)
        code == 0

      # coveralls-ignore-start — PG always writes a numeric PID
      :error ->
        false
        # coveralls-ignore-stop
    end
  end

  defp start_postgres(state) do
    # If PostgreSQL is already running (e.g. from a previous session that
    # didn't shut down cleanly), stop it and restart fresh so our config
    # (dynamic_library_path, listen_addresses, etc.) is guaranteed applied.
    pg_isready = pg_bin(state, "pg_isready")

    pg_ctl = pg_bin(state, "pg_ctl")

    case state.cmd_fn.(pg_isready, host_args(state), stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("[PostgresManager] PostgreSQL already running — restarting with updated config")

        state.cmd_fn.(pg_ctl, ["stop", "-D", state.data_dir, "-m", "fast"], stderr_to_stdout: true)

      _ ->
        :ok
    end

    Logger.info("[PostgresManager] Starting PostgreSQL…")
    log_file = Path.join(state.data_dir, "postgresql.log")
    socket_options = pg_socket_options(state)

    # LC_ALL=C prevents macOS's locale subsystem from spawning helper threads
    # during setlocale(). PG 18 aborts with "postmaster became multithreaded
    # during startup" if it detects threads before it's ready.
    case state.cmd_fn.(
           pg_ctl,
           ["start", "-D", state.data_dir, "-l", log_file, "-w", "-o", socket_options],
           stderr_to_stdout: true,
           env: [{"LC_ALL", "C"}]
         ) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:pg_ctl_start_failed, code, output}}
    end
  end

  # PostgreSQL startup options passed via pg_ctl -o. Settings that involve
  # paths with spaces (dynamic_library_path, extension_control_path) are
  # written to postgresql.conf by ensure_pg_config instead — pg_ctl passes
  # -o options through shell word-splitting which breaks quoted paths.
  defp pg_socket_options(%__MODULE__{windows?: true, port: port}) do
    "-c listen_addresses=localhost -c port=#{port}" <>
      " -c shared_buffers=128MB -c max_connections=20"
  end

  defp pg_socket_options(%__MODULE__{socket_dir: socket_dir}) do
    "-c listen_addresses='' -c unix_socket_directories='#{socket_dir}'" <>
      " -c shared_buffers=128MB -c max_connections=20"
  end

  # Returns colon-separated search path for dynamic_library_path.
  # Server modules (plpgsql, dict_snowball) live in lib/postgresql/,
  # while extensions built separately (vector.so) are in lib/.
  defp pg_lib_dir(%__MODULE__{bin_dir: bin_dir}) do
    base = bin_dir |> Path.dirname() |> Path.join("lib")
    pkglib = Path.join(base, "postgresql")
    "#{pkglib}:#{base}"
  end

  # Returns path for extension_control_path GUC (PG 18+).
  # PG automatically appends /extension to each path component, so this
  # should return the share/postgresql directory, NOT share/postgresql/extension.
  defp pg_extension_dir(%__MODULE__{bin_dir: bin_dir}) do
    bin_dir |> Path.dirname() |> Path.join("share/postgresql")
  end

  defp wait_for_ready(state) do
    pg_isready = pg_bin(state, "pg_isready")
    deadline = System.monotonic_time(:millisecond) + state.pg_ready_timeout_ms
    do_wait_for_ready(state, pg_isready, deadline)
  end

  defp do_wait_for_ready(state, pg_isready, deadline) do
    case state.cmd_fn.(pg_isready, host_args(state), stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :pg_ready_timeout}
        else
          receive do
          after
            state.pg_ready_poll_ms -> do_wait_for_ready(state, pg_isready, deadline)
          end
        end
    end
  end

  # Strip $libdir/ from pg_proc.probin entries so PostgreSQL finds shared
  # libraries via dynamic_library_path instead of the compiled-in absolute path.
  # Runs on template1 (so new databases inherit the fix) and on postgres.
  # Idempotent — safe to run on every boot.
  defp patch_libdir(state) do
    psql = pg_bin(state, "psql")

    sql =
      "UPDATE pg_proc SET probin = replace(probin, '$libdir/', '')" <>
        " WHERE probin LIKE '$libdir/%'"

    for db <- ~w(template1 postgres) do
      state.cmd_fn.(
        psql,
        host_args(state) ++ ["-d", db, "-c", sql],
        stderr_to_stdout: true
      )
    end

    :ok
  end

  # Same fix applied to the target database (covers databases created before
  # the patch was introduced).
  defp patch_libdir_in_database(state) do
    psql = pg_bin(state, "psql")

    sql =
      "UPDATE pg_proc SET probin = replace(probin, '$libdir/', '')" <>
        " WHERE probin LIKE '$libdir/%'"

    state.cmd_fn.(
      psql,
      host_args(state) ++ ["-d", state.database, "-c", sql],
      stderr_to_stdout: true
    )

    :ok
  end

  defp maybe_create_database(state) do
    psql = pg_bin(state, "psql")

    case state.cmd_fn.(
           psql,
           host_args(state) ++
             [
               "-tAc",
               "SELECT 1 FROM pg_database WHERE datname='#{state.database}'"
             ],
           stderr_to_stdout: true
         ) do
      {output, 0} when output != "" ->
        if String.trim(output) == "1" do
          Logger.info("[PostgresManager] Database #{state.database} already exists")
          :ok
        else
          do_create_database(state)
        end

      _ ->
        do_create_database(state)
    end
  end

  defp do_create_database(state) do
    Logger.info("[PostgresManager] Creating database #{state.database}…")
    createdb = pg_bin(state, "createdb")

    case state.cmd_fn.(createdb, host_args(state) ++ [state.database], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        if String.contains?(output, "already exists") do
          Logger.info("[PostgresManager] Database #{state.database} already exists")
          :ok
        else
          {:error, {:createdb_failed, output}}
        end
    end
  end

  defp maybe_truncate_log(state) do
    log_file = Path.join(state.data_dir, "postgresql.log")

    case File.stat(log_file) do
      {:ok, %{size: size}} when size > state.log_max_bytes ->
        # coveralls-ignore-start
        Logger.info(
          "[PostgresManager] Truncating postgresql.log (#{div(size, 1_048_576)}MB > #{div(state.log_max_bytes, 1_048_576)}MB)"
        )

        # coveralls-ignore-stop

        File.write!(log_file, "")

      _ ->
        :ok
    end

    :ok
  end

  defp run_migrations(state) do
    Logger.info("[PostgresManager] Running migrations…")

    task = Task.async(fn -> state.migrate_fn.() end)

    case Task.yield(task, state.migrate_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, _result} ->
        :ok

      {:exit, reason} ->
        {:error, {:migration_failed, reason}}

      nil ->
        {:error, {:migration_timeout, state.migrate_timeout_ms}}
    end
  end
end
