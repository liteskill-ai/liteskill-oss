defmodule Liteskill.Rag.IngestWorkerTest do
  use Liteskill.DataCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.Rag
  alias Liteskill.Rag.{IngestWorker, EmbeddingClient, Source, Document}

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "ingest-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "ingest-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, collection} = Rag.create_collection(%{name: "Ingest Test"}, owner.id)

    %{owner: owner, collection: collection}
  end

  defp stub_url_fetch(body, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    content_type = Keyword.get(opts, :content_type, "text/html")

    Req.Test.stub(IngestWorker, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp stub_embed(count) do
    embeddings = List.duplicate(List.duplicate(0.1, 1024), count)

    Req.Test.stub(EmbeddingClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"embeddings" => %{"float" => embeddings}})
      )
    end)
  end

  defp base_args(collection_id, user_id, opts \\ []) do
    %{
      "url" => Keyword.get(opts, :url, "https://docs.example.com/api/guide"),
      "collection_id" => collection_id,
      "user_id" => user_id,
      "plug" => true
    }
  end

  describe "perform/1" do
    test "full e2e: fetches, chunks, embeds text/html", %{owner: owner, collection: coll} do
      body = "Hello world. This is a test document."
      stub_url_fetch(body)
      stub_embed(1)

      args = base_args(coll.id, owner.id)
      assert :ok = perform_job(IngestWorker, args)

      # Source created with domain name
      sources = Repo.all(from(s in Source, where: s.collection_id == ^coll.id))
      assert length(sources) == 1
      assert hd(sources).name == "docs.example.com"
      assert hd(sources).source_type == "web"

      # Document created
      docs = Repo.all(from(d in Document, where: d.source_id == ^hd(sources).id))
      assert length(docs) == 1
      assert hd(docs).title == "/api/guide"
      assert hd(docs).metadata["url"] == "https://docs.example.com/api/guide"
      assert hd(docs).metadata["content_type"] == "text/html"
      assert hd(docs).status == "embedded"
    end

    test "reuses existing source for same domain", %{owner: owner, collection: coll} do
      stub_url_fetch("First doc")
      stub_embed(1)

      args1 = base_args(coll.id, owner.id, url: "https://docs.example.com/page1")
      assert :ok = perform_job(IngestWorker, args1)

      stub_url_fetch("Second doc")
      stub_embed(1)

      args2 = base_args(coll.id, owner.id, url: "https://docs.example.com/page2")
      assert :ok = perform_job(IngestWorker, args2)

      sources = Repo.all(from(s in Source, where: s.collection_id == ^coll.id))
      assert length(sources) == 1

      docs = Repo.all(from(d in Document, where: d.source_id == ^hd(sources).id))
      assert length(docs) == 2
    end

    test "rejects binary content type image/png", %{owner: owner, collection: coll} do
      stub_url_fetch("binary", content_type: "image/png")

      args = base_args(coll.id, owner.id)
      assert {:cancel, :binary_content} = perform_job(IngestWorker, args)
    end

    test "rejects application/octet-stream", %{owner: owner, collection: coll} do
      stub_url_fetch("binary", content_type: "application/octet-stream")

      args = base_args(coll.id, owner.id)
      assert {:cancel, :binary_content} = perform_job(IngestWorker, args)
    end

    test "accepts application/json", %{owner: owner, collection: coll} do
      stub_url_fetch(~s({"key": "value"}), content_type: "application/json")
      stub_embed(1)

      args = base_args(coll.id, owner.id)
      assert :ok = perform_job(IngestWorker, args)
    end

    test "accepts text/plain", %{owner: owner, collection: coll} do
      stub_url_fetch("plain text content", content_type: "text/plain")
      stub_embed(1)

      args = base_args(coll.id, owner.id)
      assert :ok = perform_job(IngestWorker, args)
    end

    test "returns error on HTTP error status", %{owner: owner, collection: coll} do
      stub_url_fetch("Not Found", status: 404)

      args = base_args(coll.id, owner.id)
      assert {:error, {:http_status, 404}} = perform_job(IngestWorker, args)
    end

    test "returns error on 500 status", %{owner: owner, collection: coll} do
      stub_url_fetch("Server Error", status: 500)

      args = base_args(coll.id, owner.id)
      assert {:error, {:http_status, 500}} = perform_job(IngestWorker, args)
    end

    test "respects custom chunk options", %{owner: owner, collection: coll} do
      body = Enum.map_join(1..200, " ", fn i -> "word#{i}" end)
      stub_url_fetch(body)

      Req.Test.stub(EmbeddingClient, fn conn ->
        {:ok, req_body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(req_body)
        text_count = length(decoded["texts"])
        embeddings = List.duplicate(List.duplicate(0.1, 1024), text_count)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"embeddings" => %{"float" => embeddings}})
        )
      end)

      args =
        base_args(coll.id, owner.id)
        |> Map.put("chunk_opts", %{"chunk_size" => 100, "overlap" => 10})

      assert :ok = perform_job(IngestWorker, args)

      # With small chunk_size, should produce multiple chunks
      sources = Repo.all(from(s in Source, where: s.collection_id == ^coll.id))
      docs = Repo.all(from(d in Document, where: d.source_id == ^hd(sources).id))
      assert hd(docs).chunk_count > 1
    end

    test "passes custom headers to request", %{owner: owner, collection: coll} do
      Req.Test.stub(IngestWorker, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer test-token"]

        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, "authorized content")
      end)

      stub_embed(1)

      args =
        base_args(coll.id, owner.id)
        |> Map.put("headers", %{"Authorization" => "Bearer test-token"})

      assert :ok = perform_job(IngestWorker, args)
    end

    test "defaults to GET method", %{owner: owner, collection: coll} do
      stub_url_fetch("content")
      stub_embed(1)

      args = base_args(coll.id, owner.id)
      # No "method" key — should default to GET and succeed
      refute Map.has_key?(args, "method")
      assert :ok = perform_job(IngestWorker, args)
    end

    test "handles missing content-type header", %{owner: owner, collection: coll} do
      Req.Test.stub(IngestWorker, fn conn ->
        # Send response without explicit content-type (Plug defaults vary)
        conn
        |> Plug.Conn.send_resp(200, "plain content")
      end)

      stub_embed(1)

      args = base_args(coll.id, owner.id)
      assert :ok = perform_job(IngestWorker, args)
    end
  end

  describe "ingest_url/4" do
    test "enqueues Oban job", %{owner: owner, collection: coll} do
      assert {:ok, %Oban.Job{}} =
               Rag.ingest_url(coll.id, "https://example.com/docs", owner.id, plug: true)

      assert_enqueued(
        worker: IngestWorker,
        args: %{
          "url" => "https://example.com/docs",
          "collection_id" => coll.id,
          "user_id" => owner.id
        }
      )
    end

    test "passes custom method and headers", %{owner: owner, collection: coll} do
      assert {:ok, _} =
               Rag.ingest_url(coll.id, "https://example.com/api", owner.id,
                 method: "POST",
                 headers: %{"Authorization" => "Bearer token"},
                 plug: true
               )

      assert_enqueued(
        worker: IngestWorker,
        args: %{
          "method" => "POST",
          "headers" => %{"Authorization" => "Bearer token"}
        }
      )
    end

    test "passes custom chunk_opts", %{owner: owner, collection: coll} do
      assert {:ok, _} =
               Rag.ingest_url(coll.id, "https://example.com", owner.id,
                 chunk_size: 500,
                 overlap: 50,
                 plug: true
               )

      assert_enqueued(
        worker: IngestWorker,
        args: %{
          "chunk_opts" => %{"chunk_size" => 500, "overlap" => 50}
        }
      )
    end

    test "rejects unauthorized collection", %{collection: coll} do
      {:ok, other} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "ingest-other-#{System.unique_integer([:positive])}@example.com",
          name: "Other",
          oidc_sub: "ingest-other-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      assert {:error, :not_found} =
               Rag.ingest_url(coll.id, "https://example.com", other.id, plug: true)
    end

    test "returns not_found for nonexistent collection", %{owner: owner} do
      assert {:error, :not_found} =
               Rag.ingest_url(Ecto.UUID.generate(), "https://example.com", owner.id, plug: true)
    end
  end

  describe "unsupported HTTP method" do
    test "raises for unsupported method", %{owner: owner, collection: collection} do
      stub_url_fetch("content")
      stub_embed(1)

      args = base_args(collection.id, owner.id, url: "https://example.com")
      args = Map.put(args, "method", "PROPFIND")

      assert_raise ArgumentError, ~r/unsupported HTTP method/, fn ->
        perform_job(Liteskill.Rag.IngestWorker, args)
      end
    end
  end
end
