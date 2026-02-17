defmodule Liteskill.McpServersTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.Authorization
  alias Liteskill.Authorization.EntityAcl
  alias Liteskill.McpServers
  alias Liteskill.McpServers.McpServer

  import Ecto.Query

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "owner-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "other-#{System.unique_integer([:positive])}@example.com",
        name: "Other",
        oidc_sub: "other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner, other: other}
  end

  describe "create_server/1" do
    test "creates server with valid attrs", %{owner: owner} do
      attrs = %{name: "My Server", url: "https://mcp.example.com", user_id: owner.id}

      assert {:ok, server} = McpServers.create_server(attrs)
      assert server.name == "My Server"
      assert server.url == "https://mcp.example.com"
      assert server.user_id == owner.id
      assert server.status == "active"
      assert server.global == false
      assert server.headers == %{}
    end

    test "creates server with all optional fields", %{owner: owner} do
      attrs = %{
        name: "Full Server",
        url: "https://mcp.example.com",
        user_id: owner.id,
        api_key: "secret-key",
        description: "A test server",
        headers: %{"X-Custom" => "value"},
        status: "inactive",
        global: true
      }

      assert {:ok, server} = McpServers.create_server(attrs)
      assert server.api_key == "secret-key"
      assert server.description == "A test server"
      assert server.headers == %{"X-Custom" => "value"}
      assert server.status == "inactive"
      assert server.global == true
    end

    test "creates owner ACL", %{owner: owner} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "ACL Test",
          url: "https://a.example.com",
          user_id: owner.id
        })

      acl =
        Liteskill.Repo.one!(
          from(a in EntityAcl,
            where: a.entity_type == "mcp_server" and a.entity_id == ^server.id
          )
        )

      assert acl.user_id == owner.id
      assert acl.role == "owner"
    end

    test "fails without required name", %{owner: owner} do
      attrs = %{url: "https://mcp.example.com", user_id: owner.id}

      assert {:error, %Ecto.Changeset{}} = McpServers.create_server(attrs)
    end

    test "fails without required url", %{owner: owner} do
      attrs = %{name: "Server", user_id: owner.id}

      assert {:error, %Ecto.Changeset{}} = McpServers.create_server(attrs)
    end

    test "fails without required user_id" do
      attrs = %{name: "Server", url: "https://mcp.example.com"}

      assert {:error, :forbidden} = McpServers.create_server(attrs)
    end

    test "fails with invalid status", %{owner: owner} do
      attrs = %{
        name: "Server",
        url: "https://mcp.example.com",
        user_id: owner.id,
        status: "bogus"
      }

      assert {:error, %Ecto.Changeset{}} = McpServers.create_server(attrs)
    end
  end

  describe "list_servers/1" do
    test "includes built-in servers", %{owner: owner} do
      servers = McpServers.list_servers(owner.id)
      assert Enum.any?(servers, &(&1.name == "Reports"))
    end

    test "lists own servers", %{owner: owner} do
      {:ok, _} =
        McpServers.create_server(%{name: "S1", url: "https://s1.example.com", user_id: owner.id})

      servers = McpServers.list_servers(owner.id)
      assert Enum.any?(servers, &(&1.name == "S1"))
    end

    test "includes global servers from other users", %{owner: owner, other: other} do
      {:ok, _} =
        McpServers.create_server(%{
          name: "Global",
          url: "https://global.example.com",
          user_id: other.id,
          global: true
        })

      servers = McpServers.list_servers(owner.id)
      assert Enum.any?(servers, &(&1.name == "Global"))
    end

    test "includes servers shared via ACL", %{owner: owner, other: other} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "Shared",
          url: "https://shared.example.com",
          user_id: other.id
        })

      {:ok, _} =
        Authorization.grant_access("mcp_server", server.id, other.id, owner.id, "viewer")

      servers = McpServers.list_servers(owner.id)
      assert Enum.any?(servers, &(&1.name == "Shared"))
    end

    test "excludes private servers from other users", %{owner: owner, other: other} do
      {:ok, _} =
        McpServers.create_server(%{
          name: "Private",
          url: "https://private.example.com",
          user_id: other.id
        })

      servers = McpServers.list_servers(owner.id)
      refute Enum.any?(servers, &(&1.name == "Private"))
    end

    test "db servers ordered by name", %{owner: owner} do
      {:ok, _} =
        McpServers.create_server(%{
          name: "Bravo",
          url: "https://b.example.com",
          user_id: owner.id
        })

      {:ok, _} =
        McpServers.create_server(%{
          name: "Alpha",
          url: "https://a.example.com",
          user_id: owner.id
        })

      servers = McpServers.list_servers(owner.id)
      db_names = servers |> Enum.filter(&is_struct(&1, McpServer)) |> Enum.map(& &1.name)
      assert db_names == ["Alpha", "Bravo"]
    end
  end

  describe "get_server/2" do
    test "returns own server", %{owner: owner} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "Mine",
          url: "https://mine.example.com",
          user_id: owner.id
        })

      assert {:ok, found} = McpServers.get_server(server.id, owner.id)
      assert found.id == server.id
    end

    test "returns global server from another user", %{owner: owner, other: other} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "Global",
          url: "https://global.example.com",
          user_id: other.id,
          global: true
        })

      assert {:ok, found} = McpServers.get_server(server.id, owner.id)
      assert found.id == server.id
    end

    test "returns not_found for others' private server", %{owner: owner, other: other} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "Private",
          url: "https://private.example.com",
          user_id: other.id
        })

      assert {:error, :not_found} = McpServers.get_server(server.id, owner.id)
    end

    test "returns server shared via ACL", %{owner: owner, other: other} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "ACL Shared",
          url: "https://acl.example.com",
          user_id: other.id
        })

      {:ok, _} =
        Authorization.grant_access("mcp_server", server.id, other.id, owner.id, "viewer")

      assert {:ok, found} = McpServers.get_server(server.id, owner.id)
      assert found.id == server.id
    end

    test "returns not_found for nonexistent id", %{owner: owner} do
      assert {:error, :not_found} = McpServers.get_server(Ecto.UUID.generate(), owner.id)
    end

    test "returns built-in server by id", %{owner: owner} do
      assert {:ok, server} = McpServers.get_server("builtin:reports", owner.id)
      assert server.name == "Reports"
      assert server.builtin == Liteskill.BuiltinTools.Reports
    end

    test "returns not_found for unknown built-in id", %{owner: owner} do
      assert {:error, :not_found} = McpServers.get_server("builtin:nonexistent", owner.id)
    end
  end

  describe "update_server/3" do
    test "owner can update own server", %{owner: owner} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "Old",
          url: "https://old.example.com",
          user_id: owner.id
        })

      assert {:ok, updated} = McpServers.update_server(server, owner.id, %{name: "New"})
      assert updated.name == "New"
    end

    test "non-owner cannot update", %{owner: owner, other: other} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "Server",
          url: "https://s.example.com",
          user_id: owner.id,
          global: true
        })

      assert {:error, :forbidden} = McpServers.update_server(server, other.id, %{name: "Hacked"})
    end

    test "returns changeset error for invalid update", %{owner: owner} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "Server",
          url: "https://s.example.com",
          user_id: owner.id
        })

      assert {:error, %Ecto.Changeset{}} =
               McpServers.update_server(server, owner.id, %{status: "bogus"})
    end
  end

  describe "delete_server/2" do
    test "owner can delete own server", %{owner: owner} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "Server",
          url: "https://s.example.com",
          user_id: owner.id
        })

      assert {:ok, _} = McpServers.delete_server(server.id, owner.id)
      servers = McpServers.list_servers(owner.id)
      refute Enum.any?(servers, &(&1.name == "Server"))
    end

    test "non-owner cannot delete", %{owner: owner, other: other} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "Server",
          url: "https://s.example.com",
          user_id: owner.id,
          global: true
        })

      assert {:error, :forbidden} = McpServers.delete_server(server.id, other.id)
    end

    test "returns not_found for nonexistent id", %{owner: owner} do
      assert {:error, :not_found} = McpServers.delete_server(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "api_key encryption" do
    test "api_key is stored encrypted in the database", %{owner: owner} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "Encrypted",
          url: "https://enc.example.com",
          user_id: owner.id,
          api_key: "my-secret-key"
        })

      # Read the raw database value
      raw =
        Liteskill.Repo.one!(
          from s in "mcp_servers",
            where: s.id == type(^server.id, :binary_id),
            select: s.api_key
        )

      # Raw DB value should be encrypted (base64), not plaintext
      assert raw != "my-secret-key"
      assert {:ok, _} = Base.decode64(raw)

      # But the Ecto schema should decrypt it transparently
      reloaded = Liteskill.Repo.get!(McpServer, server.id)
      assert reloaded.api_key == "my-secret-key"
    end

    test "nil api_key stays nil", %{owner: owner} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "No Key",
          url: "https://nokey.example.com",
          user_id: owner.id
        })

      reloaded = Liteskill.Repo.get!(McpServer, server.id)
      assert reloaded.api_key == nil
    end
  end

  describe "headers encryption" do
    test "headers are stored encrypted in the database", %{owner: owner} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "Encrypted Headers",
          url: "https://enc.example.com",
          user_id: owner.id,
          headers: %{"Authorization" => "Bearer secret-token"}
        })

      # Read the raw database value
      raw =
        Liteskill.Repo.one!(
          from s in "mcp_servers",
            where: s.id == type(^server.id, :binary_id),
            select: s.headers
        )

      # Raw DB value should be encrypted (base64), not plaintext JSON
      assert raw != nil
      refute raw =~ "secret-token"
      assert {:ok, _} = Base.decode64(raw)

      # But the Ecto schema should decrypt it transparently
      reloaded = Liteskill.Repo.get!(McpServer, server.id)
      assert reloaded.headers == %{"Authorization" => "Bearer secret-token"}
    end

    test "empty headers round-trip correctly", %{owner: owner} do
      {:ok, server} =
        McpServers.create_server(%{
          name: "No Headers",
          url: "https://noheaders.example.com",
          user_id: owner.id,
          headers: %{}
        })

      reloaded = Liteskill.Repo.get!(McpServer, server.id)
      assert reloaded.headers in [nil, %{}]
    end
  end

  describe "changeset/2" do
    test "validates status inclusion" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "https://s.example.com",
          user_id: Ecto.UUID.generate(),
          status: "unknown"
        })

      refute changeset.valid?
      assert errors_on(changeset)[:status]
    end

    test "accepts valid HTTPS URL" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "https://mcp.example.com/api",
          user_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end

    test "rejects localhost URL (SSRF protection)" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "https://localhost:3000",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:url]
    end

    test "rejects 127.x.x.x URLs (SSRF protection)" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "https://127.0.0.1:8080",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:url]
    end

    test "rejects 10.x private network URLs (SSRF protection)" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "https://10.0.0.1/api",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:url]
    end

    test "rejects 172.16-31.x private network URLs (SSRF protection)" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "https://172.16.0.1/api",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:url]
    end

    test "rejects 192.168.x private network URLs (SSRF protection)" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "https://192.168.1.1/api",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:url]
    end

    test "rejects AWS metadata URL (SSRF protection)" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "https://169.254.169.254/latest/meta-data",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:url]
    end

    test "rejects IPv6 loopback (SSRF protection)" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "https://[::1]:8080",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:url]
    end

    test "rejects plain HTTP URL" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "http://mcp.example.com:3000",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:url]
    end

    test "rejects invalid URL without scheme" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "not-a-url",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:url]
    end

    test "rejects URL with non-HTTP scheme" do
      changeset =
        McpServer.changeset(%McpServer{}, %{
          name: "S",
          url: "ftp://files.example.com",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:url]
    end

    test "allows private URLs when allow_private_urls option is true" do
      changeset =
        McpServer.changeset(
          %McpServer{},
          %{
            name: "Local Server",
            url: "https://localhost:3000",
            user_id: Ecto.UUID.generate()
          },
          allow_private_urls: true
        )

      assert changeset.valid?
    end

    test "allows 192.168.x URLs when allow_private_urls option is true" do
      changeset =
        McpServer.changeset(
          %McpServer{},
          %{
            name: "Internal Server",
            url: "https://192.168.1.100/mcp",
            user_id: Ecto.UUID.generate()
          },
          allow_private_urls: true
        )

      assert changeset.valid?
    end

    test "allows plain HTTP when allow_private_urls is true" do
      changeset =
        McpServer.changeset(
          %McpServer{},
          %{
            name: "Local Dev",
            url: "http://localhost:3000",
            user_id: Ecto.UUID.generate()
          },
          allow_private_urls: true
        )

      assert changeset.valid?
    end

    test "rejects plain HTTP when allow_private_urls is false" do
      changeset =
        McpServer.changeset(
          %McpServer{},
          %{
            name: "S",
            url: "http://example.com/mcp",
            user_id: Ecto.UUID.generate()
          }
        )

      refute changeset.valid?
      assert errors_on(changeset)[:url]
    end
  end
end
