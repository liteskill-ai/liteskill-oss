defmodule Liteskill.Desktop do
  @moduledoc """
  Boundary module for desktop-mode functionality.

  Provides platform-specific path helpers and configuration persistence
  for the Tauri desktop app with bundled PostgreSQL.
  """

  use Boundary, top_level?: true, deps: [], exports: [PostgresManager]

  @doc "Returns true when running in desktop mode."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:liteskill, :desktop_mode, false)
  end

  @doc "Returns the platform-specific application data directory."
  @spec data_dir() :: String.t()
  def data_dir do
    Application.get_env(:liteskill, :desktop_data_dir) || default_data_dir()
  end

  @doc "Returns the PostgreSQL data directory."
  @spec pg_data_dir() :: String.t()
  def pg_data_dir, do: Path.join(data_dir(), "pg_data")

  @doc "Returns true when running on Windows."
  @spec windows?() :: boolean()
  def windows?, do: match?({:win32, _}, :os.type())

  @doc "Returns the PostgreSQL TCP port for Windows desktop mode."
  @spec pg_port() :: pos_integer()
  def pg_port, do: Application.get_env(:liteskill, :desktop_pg_port, 15_432)

  @doc "Returns the PostgreSQL Unix socket directory."
  @spec socket_dir() :: String.t()
  def socket_dir, do: Path.join(data_dir(), "pg_socket")

  @doc "Returns the path to bundled PostgreSQL binaries for the current architecture."
  @spec pg_bin_dir() :: String.t()
  # coveralls-ignore-start
  def pg_bin_dir do
    Application.app_dir(:liteskill, Path.join(["priv/postgres", arch_triple(), "bin"]))
  end

  # coveralls-ignore-stop

  @doc "Returns the path to bundled PostgreSQL share directory (for initdb -L)."
  @spec pg_share_dir() :: String.t()
  # coveralls-ignore-start
  def pg_share_dir do
    # Linux/macOS: compiled-in SHAREDIR offset is ../share/postgresql (standard --prefix layout).
    # Windows (EDB): compiled-in SHAREDIR offset is ../share (flat layout, no nesting).
    share_subpath =
      case :os.type() do
        {:win32, _} -> "share"
        _ -> Path.join("share", "postgresql")
      end

    Application.app_dir(
      :liteskill,
      Path.join(["priv/postgres", arch_triple(), share_subpath])
    )
  end

  # coveralls-ignore-stop

  @doc "Returns the architecture triple string for the current platform."
  @spec arch_triple() :: String.t()
  def arch_triple do
    {os_family, os_name} = :os.type()
    arch = :erlang.system_info(:system_architecture) |> to_string()

    cpu =
      cond do
        String.contains?(arch, "aarch64") or String.contains?(arch, "arm64") ->
          "aarch64"

        # coveralls-ignore-start
        String.contains?(arch, "x86_64") or String.contains?(arch, "amd64") ->
          "x86_64"

        # coveralls-ignore-stop

        # coveralls-ignore-start
        true ->
          arch |> String.split("-") |> hd()
          # coveralls-ignore-stop
      end

    # coveralls-ignore-start
    os =
      case {os_family, os_name} do
        {:unix, :darwin} -> "apple-darwin"
        {:unix, :linux} -> "unknown-linux-gnu"
        {:win32, _} -> "pc-windows-msvc"
        {:unix, name} -> "unknown-#{name}"
      end

    # coveralls-ignore-stop

    "#{cpu}-#{os}"
  end

  @doc "Returns the path to the desktop configuration JSON file."
  @spec config_path() :: String.t()
  def config_path, do: Path.join(data_dir(), "desktop_config.json")

  @doc """
  Loads or creates the desktop configuration file at the given path.

  On first run, generates cryptographically secure `encryption_key` and
  `secret_key_base` values, persists them as JSON, and returns the map.
  On subsequent runs, reads the existing file.
  """
  @spec load_or_create_config!(String.t()) :: map()
  def load_or_create_config!(path) do
    if File.exists?(path) do
      path |> File.read!() |> Jason.decode!()
    else
      config = %{
        "encryption_key" => Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false),
        "secret_key_base" => Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
      }

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(config, pretty: true))
      config
    end
  end

  defp default_data_dir do
    case :os.type() do
      # coveralls-ignore-start
      {:unix, :darwin} ->
        Path.join(System.get_env("HOME", "~"), "Library/Application Support/Liteskill")

      # coveralls-ignore-stop

      # coveralls-ignore-start
      {:unix, _} ->
        xdg =
          System.get_env(
            "XDG_DATA_HOME",
            Path.join(System.get_env("HOME", "~"), ".local/share")
          )

        Path.join(xdg, "liteskill")

      # coveralls-ignore-stop

      # coveralls-ignore-start
      {:win32, _} ->
        Path.join(
          System.get_env("APPDATA", "C:/Users/Default/AppData/Roaming"),
          "Liteskill"
        )

        # coveralls-ignore-stop
    end
  end
end
