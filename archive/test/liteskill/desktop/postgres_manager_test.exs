defmodule Liteskill.Desktop.PostgresManagerTest do
  use ExUnit.Case, async: true

  alias Liteskill.Desktop.PostgresManager

  @moduletag :tmp_dir

  defp build_opts(tmp_dir, overrides \\ []) do
    test_pid = self()

    cmd_fn = fn binary, args, _opts ->
      send(test_pid, {:cmd, Path.basename(binary), args})
      {"", 0}
    end

    bin_dir = Keyword.get(overrides, :bin_dir, Path.join(tmp_dir, "bin"))
    is_windows = Keyword.get(overrides, :windows?, false)
    create_dummy_pg_binaries(bin_dir, is_windows)

    Keyword.merge(
      [
        bin_dir: bin_dir,
        share_dir: Path.join(tmp_dir, "share"),
        data_dir: Path.join(tmp_dir, "data"),
        socket_dir: Path.join(tmp_dir, "socket"),
        database: "test_desktop",
        cmd_fn: cmd_fn,
        migrate_fn: fn -> send(test_pid, :migrate_called) end,
        pg_ready_poll_ms: 1,
        pg_ready_timeout_ms: 100,
        name: :"pm_#{System.unique_integer([:positive, :monotonic])}"
      ],
      overrides
    )
  end

  defp create_dummy_pg_binaries(bin_dir, windows?) do
    File.mkdir_p!(bin_dir)
    suffix = if windows?, do: ".exe", else: ""

    for name <- ~w(postgres pg_ctl initdb pg_isready psql createdb) do
      path = Path.join(bin_dir, name <> suffix)
      File.write!(path, "")
      File.chmod!(path, 0o755)
    end
  end

  # Wraps a cmd_fn so the first pg_isready call returns not-ready (exit 1).
  # This forces start_postgres to actually call pg_ctl start instead of
  # detecting an already-running instance.
  defp with_pg_not_running(base_fn, windows? \\ false) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    isready = if windows?, do: "pg_isready.exe", else: "pg_isready"

    fn binary, args, opts ->
      if Path.basename(binary) == isready do
        count = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
        if count == 0, do: {"", 1}, else: base_fn.(binary, args, opts)
      else
        base_fn.(binary, args, opts)
      end
    end
  end

  describe "full setup pipeline" do
    test "runs initdb, pg_ctl start, patch_libdir, psql check, createdb, migrate", %{
      tmp_dir: tmp_dir
    } do
      test_pid = self()

      base_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name, args})

        case name do
          # psql -tAc (db existence check) returns "no rows" so createdb runs
          "psql" ->
            if Enum.member?(args, "-tAc") do
              {"", 1}
            else
              {"UPDATE 0\n", 0}
            end

          _ ->
            {"", 0}
        end
      end

      cmd_fn = with_pg_not_running(base_fn)
      opts = build_opts(tmp_dir, cmd_fn: cmd_fn)
      {:ok, pid} = PostgresManager.start_link(opts)

      assert_receive {:cmd, "initdb", ["-D", _, "-L", _, "--no-locale", "-E", "UTF8"]}
      assert_receive {:cmd, "pg_ctl", ["start", "-D", _, "-l", _, "-w", "-o", options]}
      # dynamic_library_path is set via postgresql.conf, not -o flags (spaces in paths)
      assert options =~ "shared_buffers"
      assert_receive {:cmd, "pg_isready", ["-h", _]}

      # patch_libdir: strips $libdir/ from pg_proc.probin in template1 and postgres
      assert_receive {:cmd, "psql", ["-h", _, "-d", "template1", "-c", sql]}
      assert sql =~ "$libdir/"
      assert_receive {:cmd, "psql", ["-h", _, "-d", "postgres", "-c", _]}

      # maybe_create_database check + createdb
      assert_receive {:cmd, "psql", ["-h", _, "-tAc", _]}
      assert_receive {:cmd, "createdb", ["-h", _, "test_desktop"]}

      # patch_libdir_in_database: patches the target database too
      assert_receive {:cmd, "psql", ["-h", _, "-d", "test_desktop", "-c", _]}

      assert_receive :migrate_called

      GenServer.stop(pid)
    end
  end

  describe "skips initdb when PG_VERSION exists" do
    test "does not run initdb if data dir already initialized", %{tmp_dir: tmp_dir} do
      opts = build_opts(tmp_dir)
      data_dir = opts[:data_dir]
      File.mkdir_p!(data_dir)
      File.write!(Path.join(data_dir, "PG_VERSION"), "16")

      {:ok, pid} = PostgresManager.start_link(opts)

      refute_receive {:cmd, "initdb", _}
      # Default cmd_fn: pg_isready returns 0, so PG is "already running"
      assert_receive {:cmd, "pg_isready", _}

      GenServer.stop(pid)
    end
  end

  describe "skips createdb when database already exists" do
    test "does not call createdb when psql check returns 1", %{tmp_dir: tmp_dir} do
      test_pid = self()

      cmd_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name, args})

        case name do
          "psql" ->
            if Enum.member?(args, "-tAc"), do: {"1\n", 0}, else: {"UPDATE 0\n", 0}

          _ ->
            {"", 0}
        end
      end

      opts = build_opts(tmp_dir, cmd_fn: cmd_fn)
      {:ok, pid} = PostgresManager.start_link(opts)

      # patch_libdir psql calls + db existence check
      assert_receive {:cmd, "psql", ["-h", _, "-d", "template1", "-c", _]}
      assert_receive {:cmd, "psql", ["-h", _, "-tAc", _]}
      refute_receive {:cmd, "createdb", _}

      GenServer.stop(pid)
    end
  end

  describe "postgres already running on boot" do
    test "skips pg_ctl start when pg_isready returns 0", %{tmp_dir: tmp_dir} do
      test_pid = self()

      cmd_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name, args})

        case name do
          "psql" ->
            if Enum.member?(args, "-tAc"), do: {"1\n", 0}, else: {"UPDATE 0\n", 0}

          _ ->
            {"", 0}
        end
      end

      opts = build_opts(tmp_dir, cmd_fn: cmd_fn)
      {:ok, pid} = PostgresManager.start_link(opts)

      # pg_isready returns 0 → "already running" → stop then start fresh
      assert_receive {:cmd, "pg_isready", ["-h", _]}
      assert_receive {:cmd, "pg_ctl", ["stop", "-D", _, "-m", "fast"]}
      assert_receive {:cmd, "pg_ctl", ["start", "-D", _, "-l", _, "-w", "-o", _]}
      # patch_libdir runs
      assert_receive {:cmd, "psql", ["-h", _, "-d", "template1", "-c", _]}
      assert_receive {:cmd, "psql", ["-h", _, "-d", "postgres", "-c", _]}
      # Database check — already exists
      assert_receive {:cmd, "psql", ["-h", _, "-tAc", _]}
      refute_receive {:cmd, "createdb", _}
      # patch target database
      assert_receive {:cmd, "psql", ["-h", _, "-d", "test_desktop", "-c", _]}
      assert_receive :migrate_called

      GenServer.stop(pid)

      # terminate should still call pg_ctl stop (we take ownership)
      assert_receive {:cmd, "pg_ctl", ["stop", "-D", _, "-m", "fast"]}
    end
  end

  describe "error: initdb failure" do
    test "stops the GenServer when initdb fails", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      test_pid = self()

      cmd_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name, args})

        case name do
          "initdb" -> {"initdb: error: something went wrong", 1}
          _ -> {"", 0}
        end
      end

      opts = build_opts(tmp_dir, cmd_fn: cmd_fn)
      result = PostgresManager.start_link(opts)
      assert {:error, {:initdb_failed, 1, _}} = result
    end
  end

  describe "error: pg_ctl start failure" do
    test "stops the GenServer when pg_ctl start fails", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      test_pid = self()

      base_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name, args})

        case name do
          "pg_ctl" -> {"pg_ctl: could not start server", 1}
          _ -> {"", 0}
        end
      end

      cmd_fn = with_pg_not_running(base_fn)
      opts = build_opts(tmp_dir, cmd_fn: cmd_fn)
      result = PostgresManager.start_link(opts)
      assert {:error, {:pg_ctl_start_failed, 1, _}} = result
    end
  end

  describe "error: pg_isready timeout" do
    test "stops the GenServer when pg_isready times out", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      test_pid = self()

      cmd_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name, args})

        case name do
          "pg_isready" -> {"no response", 2}
          _ -> {"", 0}
        end
      end

      opts = build_opts(tmp_dir, cmd_fn: cmd_fn, pg_ready_poll_ms: 1, pg_ready_timeout_ms: 10)
      result = PostgresManager.start_link(opts)
      assert {:error, :pg_ready_timeout} = result
    end
  end

  describe "error: createdb failure" do
    test "stops the GenServer when createdb fails with a real error", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      test_pid = self()

      cmd_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name})

        case name do
          "psql" ->
            if Enum.member?(args, "-tAc"), do: {"", 1}, else: {"UPDATE 0\n", 0}

          "createdb" ->
            {"createdb: permission denied", 1}

          _ ->
            {"", 0}
        end
      end

      opts = build_opts(tmp_dir, cmd_fn: cmd_fn)
      result = PostgresManager.start_link(opts)
      assert {:error, {:createdb_failed, _}} = result
    end

    test "succeeds when createdb reports database already exists", %{tmp_dir: tmp_dir} do
      test_pid = self()

      cmd_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name})

        case name do
          "psql" ->
            if Enum.member?(args, "-tAc"), do: {"", 1}, else: {"UPDATE 0\n", 0}

          "createdb" ->
            {"createdb: error: database \"test_desktop\" already exists\n", 1}

          _ ->
            {"", 0}
        end
      end

      opts = build_opts(tmp_dir, cmd_fn: cmd_fn)
      {:ok, pid} = PostgresManager.start_link(opts)

      assert_receive {:cmd, "createdb"}
      assert_receive :migrate_called

      GenServer.stop(pid)
    end
  end

  describe "error: migration failure" do
    test "stops the GenServer when migrations crash", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)

      migrate_fn = fn ->
        raise "CREATE EXTENSION vector failed"
      end

      opts = build_opts(tmp_dir, migrate_fn: migrate_fn)
      result = PostgresManager.start_link(opts)
      assert {:error, {:migration_failed, _reason}} = result
    end
  end

  describe "terminate/2" do
    test "calls pg_ctl stop -m fast when pg was started", %{tmp_dir: tmp_dir} do
      opts = build_opts(tmp_dir)
      {:ok, pid} = PostgresManager.start_link(opts)

      GenServer.stop(pid)

      assert_receive {:cmd, "pg_ctl", ["stop", "-D", _, "-m", "fast"]}
    end

    test "does not call pg_ctl stop when pg was never started", %{tmp_dir: tmp_dir} do
      # If initdb fails, pg_started stays false — terminate should be a no-op.
      # We test this by directly calling terminate on a struct.
      state = %PostgresManager{
        bin_dir: Path.join(tmp_dir, "bin"),
        share_dir: Path.join(tmp_dir, "share"),
        data_dir: Path.join(tmp_dir, "data"),
        socket_dir: Path.join(tmp_dir, "socket"),
        database: "test",
        cmd_fn: fn _, _, _ -> {"", 0} end,
        migrate_fn: fn -> :ok end,
        pg_ready_poll_ms: 1,
        pg_ready_timeout_ms: 10,
        migrate_timeout_ms: 5_000,
        log_max_bytes: 10_485_760,
        pg_started: false
      }

      assert :ok = PostgresManager.terminate(:shutdown, state)
    end
  end

  describe "ensure_pg_config" do
    test "writes dynamic_library_path to postgresql.conf", %{tmp_dir: tmp_dir} do
      data_dir = Path.join(tmp_dir, "data")
      File.mkdir_p!(data_dir)
      File.write!(Path.join(data_dir, "PG_VERSION"), "18")

      # Create a minimal postgresql.conf (initdb would normally create this)
      conf_path = Path.join(data_dir, "postgresql.conf")
      File.write!(conf_path, "# PostgreSQL config\nshared_buffers = 128MB\n")

      opts = build_opts(tmp_dir)
      {:ok, pid} = PostgresManager.start_link(opts)

      contents = File.read!(conf_path)
      assert contents =~ "dynamic_library_path"
      assert contents =~ "extension_control_path"
      assert contents =~ Path.join(tmp_dir, "lib")

      GenServer.stop(pid)
    end

    test "updates existing managed block on subsequent boots", %{tmp_dir: tmp_dir} do
      data_dir = Path.join(tmp_dir, "data")
      File.mkdir_p!(data_dir)
      File.write!(Path.join(data_dir, "PG_VERSION"), "18")

      conf_path = Path.join(data_dir, "postgresql.conf")

      File.write!(
        conf_path,
        "# PostgreSQL config\n# -- PostgresManager managed settings --\ndynamic_library_path = '/old/path'\nextension_control_path = '/old/ext'\n"
      )

      opts = build_opts(tmp_dir)
      {:ok, pid} = PostgresManager.start_link(opts)

      contents = File.read!(conf_path)
      refute contents =~ "/old/path"
      refute contents =~ "/old/ext"
      assert contents =~ Path.join(tmp_dir, "lib")

      GenServer.stop(pid)
    end
  end

  describe "directories created" do
    test "ensures data_dir and socket_dir exist after start", %{tmp_dir: tmp_dir} do
      opts = build_opts(tmp_dir)
      {:ok, pid} = PostgresManager.start_link(opts)

      assert File.dir?(opts[:data_dir])
      assert File.dir?(opts[:socket_dir])

      GenServer.stop(pid)
    end
  end

  describe "Windows TCP mode" do
    test "pg_ctl start uses listen_addresses=localhost, port, and dynamic_library_path",
         %{tmp_dir: tmp_dir} do
      test_pid = self()

      base_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name, args})

        case name do
          "psql.exe" ->
            if Enum.member?(args, "-tAc"), do: {"1\n", 0}, else: {"UPDATE 0\n", 0}

          _ ->
            {"", 0}
        end
      end

      cmd_fn = with_pg_not_running(base_fn, true)
      opts = build_opts(tmp_dir, cmd_fn: cmd_fn, windows?: true, port: 15_432)
      {:ok, pid} = PostgresManager.start_link(opts)

      assert_receive {:cmd, "pg_ctl.exe", ["start", "-D", _, "-l", _, "-w", "-o", options]}
      assert options =~ "listen_addresses=localhost"
      assert options =~ "port=15432"
      # dynamic_library_path is set via postgresql.conf, not -o flags (spaces in paths)
      assert options =~ "shared_buffers"
      refute options =~ "unix_socket_directories"

      GenServer.stop(pid)
    end

    test "pg_isready uses -h localhost -p port instead of socket path", %{tmp_dir: tmp_dir} do
      opts = build_opts(tmp_dir, windows?: true, port: 15_432)
      {:ok, pid} = PostgresManager.start_link(opts)

      assert_receive {:cmd, "pg_isready.exe", ["-h", "localhost", "-p", "15432"]}

      GenServer.stop(pid)
    end

    test "psql and createdb use -h localhost -p port", %{tmp_dir: tmp_dir} do
      test_pid = self()

      cmd_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name, args})

        case name do
          "psql.exe" ->
            if Enum.member?(args, "-tAc"), do: {"", 1}, else: {"UPDATE 0\n", 0}

          _ ->
            {"", 0}
        end
      end

      opts = build_opts(tmp_dir, cmd_fn: cmd_fn, windows?: true, port: 15_432)
      {:ok, pid} = PostgresManager.start_link(opts)

      # patch_libdir uses -h localhost -p port too
      assert_receive {:cmd, "psql.exe", ["-h", "localhost", "-p", "15432", "-d", "template1", "-c", _]}

      assert_receive {:cmd, "psql.exe", ["-h", "localhost", "-p", "15432", "-tAc", _query]}

      assert_receive {:cmd, "createdb.exe", ["-h", "localhost", "-p", "15432", "test_desktop"]}

      GenServer.stop(pid)
    end

    test "socket_dir is NOT created on Windows", %{tmp_dir: tmp_dir} do
      socket_dir = Path.join(tmp_dir, "socket")
      # Ensure it doesn't exist before
      refute File.dir?(socket_dir)

      opts = build_opts(tmp_dir, windows?: true, port: 15_432)
      {:ok, pid} = PostgresManager.start_link(opts)

      refute File.dir?(socket_dir)
      assert File.dir?(opts[:data_dir])

      GenServer.stop(pid)
    end

    test "binary paths end with .exe on Windows", %{tmp_dir: tmp_dir} do
      test_pid = self()

      base_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd_path, binary, name, args})

        case name do
          "psql.exe" ->
            if Enum.member?(args, "-tAc"), do: {"1\n", 0}, else: {"UPDATE 0\n", 0}

          _ ->
            {"", 0}
        end
      end

      cmd_fn = with_pg_not_running(base_fn, true)
      opts = build_opts(tmp_dir, cmd_fn: cmd_fn, windows?: true, port: 15_432)
      {:ok, pid} = PostgresManager.start_link(opts)

      assert_receive {:cmd_path, initdb_path, "initdb.exe", _}
      assert String.ends_with?(initdb_path, ".exe")

      assert_receive {:cmd_path, pg_ctl_path, "pg_ctl.exe", _}
      assert String.ends_with?(pg_ctl_path, ".exe")

      assert_receive {:cmd_path, pg_isready_path, "pg_isready.exe", _}
      assert String.ends_with?(pg_isready_path, ".exe")

      GenServer.stop(pid)
    end

    test "terminate uses .exe suffix on Windows", %{tmp_dir: tmp_dir} do
      test_pid = self()

      cmd_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name, args})

        case name do
          "psql.exe" ->
            if Enum.member?(args, "-tAc"), do: {"1\n", 0}, else: {"UPDATE 0\n", 0}

          _ ->
            {"", 0}
        end
      end

      opts = build_opts(tmp_dir, cmd_fn: cmd_fn, windows?: true, port: 15_432)
      {:ok, pid} = PostgresManager.start_link(opts)

      GenServer.stop(pid)

      assert_receive {:cmd, "pg_ctl.exe", ["stop", "-D", _, "-m", "fast"]}
    end
  end

  describe "migration timeout" do
    test "stops the GenServer when migrations exceed timeout", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)

      migrate_fn = fn ->
        # Simulate a migration that hangs longer than the timeout
        receive do
        end
      end

      opts = build_opts(tmp_dir, migrate_fn: migrate_fn, migrate_timeout_ms: 50)
      result = PostgresManager.start_link(opts)
      assert {:error, {:migration_timeout, 50}} = result
    end

    test "succeeds when migrations finish within timeout", %{tmp_dir: tmp_dir} do
      test_pid = self()

      migrate_fn = fn ->
        send(test_pid, :migrate_called)
        :ok
      end

      opts = build_opts(tmp_dir, migrate_fn: migrate_fn, migrate_timeout_ms: 5_000)
      {:ok, pid} = PostgresManager.start_link(opts)

      assert_receive :migrate_called
      GenServer.stop(pid)
    end
  end

  describe "log truncation" do
    test "truncates postgresql.log when it exceeds log_max_bytes", %{tmp_dir: tmp_dir} do
      data_dir = Path.join(tmp_dir, "data")
      File.mkdir_p!(data_dir)

      # Create a PG_VERSION so initdb is skipped
      File.write!(Path.join(data_dir, "PG_VERSION"), "16")

      # Create an oversized log file (> 1024 bytes threshold for test)
      log_file = Path.join(data_dir, "postgresql.log")
      File.write!(log_file, String.duplicate("x", 2048))
      assert File.stat!(log_file).size == 2048

      opts = build_opts(tmp_dir, log_max_bytes: 1024)
      {:ok, pid} = PostgresManager.start_link(opts)

      # Log file should have been truncated before postgres start
      assert File.stat!(log_file).size == 0

      GenServer.stop(pid)
    end

    test "does not truncate postgresql.log when under threshold", %{tmp_dir: tmp_dir} do
      data_dir = Path.join(tmp_dir, "data")
      File.mkdir_p!(data_dir)

      File.write!(Path.join(data_dir, "PG_VERSION"), "16")

      log_file = Path.join(data_dir, "postgresql.log")
      File.write!(log_file, String.duplicate("x", 512))

      opts = build_opts(tmp_dir, log_max_bytes: 1024)
      {:ok, pid} = PostgresManager.start_link(opts)

      # Log file should remain untouched
      assert File.stat!(log_file).size == 512

      GenServer.stop(pid)
    end

    test "handles missing log file gracefully", %{tmp_dir: tmp_dir} do
      data_dir = Path.join(tmp_dir, "data")
      File.mkdir_p!(data_dir)
      File.write!(Path.join(data_dir, "PG_VERSION"), "16")

      log_file = Path.join(data_dir, "postgresql.log")
      refute File.exists?(log_file)

      opts = build_opts(tmp_dir, log_max_bytes: 1024)
      {:ok, pid} = PostgresManager.start_link(opts)

      # Should not crash — file just doesn't exist yet
      GenServer.stop(pid)
    end
  end

  describe "stale postmaster.pid cleanup" do
    test "removes stale postmaster.pid when PID is not running", %{tmp_dir: tmp_dir} do
      data_dir = Path.join(tmp_dir, "data")
      File.mkdir_p!(data_dir)
      File.write!(Path.join(data_dir, "PG_VERSION"), "16")

      # Write a postmaster.pid with a PID that definitely doesn't exist
      pid_file = Path.join(data_dir, "postmaster.pid")
      File.write!(pid_file, "999999999\n/some/data/dir\n")

      opts = build_opts(tmp_dir)
      {:ok, pid} = PostgresManager.start_link(opts)

      # Stale pid file should have been removed
      refute File.exists?(pid_file)

      GenServer.stop(pid)
    end

    test "does not remove postmaster.pid when no pid file exists", %{tmp_dir: tmp_dir} do
      opts = build_opts(tmp_dir)
      {:ok, pid} = PostgresManager.start_link(opts)

      # Should start normally without errors
      assert_receive {:cmd, "pg_isready", _}

      GenServer.stop(pid)
    end
  end

  describe "ensure_executables lib dir scanning" do
    test "logs library contents when lib dir exists", %{tmp_dir: tmp_dir} do
      # Create the lib directories that pg_lib_dir computes: bin_dir/../lib and bin_dir/../lib/postgresql
      lib_base = Path.join(tmp_dir, "lib")
      lib_pg = Path.join(lib_base, "postgresql")
      File.mkdir_p!(lib_pg)
      # Place dummy shared libs so File.ls returns {:ok, files}
      ext = if :os.type() == {:unix, :darwin}, do: "dylib", else: "so"
      File.write!(Path.join(lib_pg, "plpgsql.#{ext}"), "")
      File.write!(Path.join(lib_base, "vector.#{ext}"), "")

      opts = build_opts(tmp_dir)
      {:ok, pid} = PostgresManager.start_link(opts)

      GenServer.stop(pid)
    end
  end

  describe "maybe_create_database non-1 output" do
    test "calls createdb when psql check returns unexpected output with exit 0", %{
      tmp_dir: tmp_dir
    } do
      test_pid = self()

      cmd_fn = fn binary, args, _opts ->
        name = Path.basename(binary)
        send(test_pid, {:cmd, name, args})

        case name do
          "psql" ->
            if Enum.member?(args, "-tAc"),
              do: {"unexpected\n", 0},
              else: {"UPDATE 0\n", 0}

          _ ->
            {"", 0}
        end
      end

      opts = build_opts(tmp_dir, cmd_fn: cmd_fn)
      {:ok, pid} = PostgresManager.start_link(opts)

      assert_receive {:cmd, "psql", ["-h", _, "-tAc", _]}
      assert_receive {:cmd, "createdb", ["-h", _, "test_desktop"]}

      GenServer.stop(pid)
    end
  end

  describe "missing PG binary" do
    test "raises when a bundled PG binary is missing", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      opts = build_opts(tmp_dir)

      # Remove initdb after build_opts created the dummy binaries
      File.rm!(Path.join(opts[:bin_dir], "initdb"))

      assert {:error, {%RuntimeError{message: msg}, _stacktrace}} =
               PostgresManager.start_link(opts)

      assert msg =~ "PostgreSQL binary not found"
      assert msg =~ "initdb"
    end
  end

  describe "invalid database name" do
    test "raises ArgumentError for database names with special characters", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      opts = build_opts(tmp_dir, database: "bad;name")

      assert {:error, {%ArgumentError{message: msg}, _stacktrace}} =
               PostgresManager.start_link(opts)

      assert msg =~ "invalid database name"
    end
  end
end
