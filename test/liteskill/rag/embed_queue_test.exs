defmodule Liteskill.Rag.EmbedQueueTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Rag.{EmbedQueue, CohereClient}

  setup do
    Req.Test.set_req_test_to_shared()
    name = :"embed_queue_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {EmbedQueue, name: name, flush_ms: 50, batch_size: 5, max_retries: 2, backoff_ms: 1},
        id: name
      )

    %{queue: name, pid: pid}
  end

  defp stub_embed_success(embeddings) do
    Req.Test.stub(CohereClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      count = length(decoded["texts"])

      embs =
        if is_function(embeddings) do
          embeddings.(count)
        else
          embeddings
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"embeddings" => %{"float" => embs}}))
    end)
  end

  defp stub_embed_error(status, message) do
    Req.Test.stub(CohereClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(%{"message" => message}))
    end)
  end

  describe "embed/2" do
    test "flushes single caller on timeout", %{queue: name} do
      embedding = List.duplicate(0.1, 1024)
      stub_embed_success([embedding, embedding])

      assert {:ok, [^embedding, ^embedding]} =
               EmbedQueue.embed(
                 ["hello", "world"],
                 name: name,
                 input_type: "search_document",
                 plug: {Req.Test, CohereClient}
               )
    end

    test "flushes immediately when batch is full", %{queue: name} do
      stub_embed_success(fn count ->
        List.duplicate(List.duplicate(0.1, 4), count)
      end)

      # batch_size is 5, submit exactly 5 texts
      assert {:ok, results} =
               EmbedQueue.embed(
                 ["a", "b", "c", "d", "e"],
                 name: name,
                 input_type: "search_document",
                 plug: {Req.Test, CohereClient}
               )

      assert length(results) == 5
    end

    test "multiple concurrent callers get correct slices", %{queue: name} do
      stub_embed_success(fn count ->
        for i <- 1..count, do: List.duplicate(i / 1, 4)
      end)

      task1 =
        Task.async(fn ->
          EmbedQueue.embed(
            ["a", "b"],
            name: name,
            input_type: "search_document",
            plug: {Req.Test, CohereClient}
          )
        end)

      task2 =
        Task.async(fn ->
          EmbedQueue.embed(
            ["c", "d", "e"],
            name: name,
            input_type: "search_document",
            plug: {Req.Test, CohereClient}
          )
        end)

      {:ok, result1} = Task.await(task1)
      {:ok, result2} = Task.await(task2)

      assert length(result1) == 2
      assert length(result2) == 3
    end

    test "retries on 429 then succeeds", %{queue: name} do
      embedding = List.duplicate(0.1, 1024)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(CohereClient, fn conn ->
        call_num = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if call_num == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(429, Jason.encode!(%{"message" => "Rate limited"}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{"embeddings" => %{"float" => [embedding]}})
          )
        end
      end)

      assert {:ok, [^embedding]} =
               EmbedQueue.embed(
                 ["hello"],
                 name: name,
                 input_type: "search_document",
                 plug: {Req.Test, CohereClient}
               )

      assert Agent.get(counter, & &1) == 2
    end

    test "returns error after retries exhausted on 429", %{queue: name} do
      stub_embed_error(429, "Rate limited")

      assert {:error, %{status: 429}} =
               EmbedQueue.embed(
                 ["hello"],
                 name: name,
                 input_type: "search_document",
                 plug: {Req.Test, CohereClient}
               )
    end

    test "returns error immediately on non-retryable error", %{queue: name} do
      stub_embed_error(400, "Bad request")

      assert {:error, %{status: 400}} =
               EmbedQueue.embed(
                 ["hello"],
                 name: name,
                 input_type: "search_document",
                 plug: {Req.Test, CohereClient}
               )
    end

    test "propagates error to all callers in batch", %{queue: name} do
      stub_embed_error(500, "Internal error")

      task1 =
        Task.async(fn ->
          EmbedQueue.embed(
            ["a"],
            name: name,
            input_type: "search_document",
            plug: {Req.Test, CohereClient}
          )
        end)

      task2 =
        Task.async(fn ->
          EmbedQueue.embed(
            ["b"],
            name: name,
            input_type: "search_document",
            plug: {Req.Test, CohereClient}
          )
        end)

      assert {:error, _} = Task.await(task1)
      assert {:error, _} = Task.await(task2)
    end

    test "retries on 503 then succeeds", %{queue: name} do
      embedding = List.duplicate(0.1, 4)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(CohereClient, fn conn ->
        call_num = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if call_num == 0 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(503, Jason.encode!(%{"message" => "Service unavailable"}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{"embeddings" => %{"float" => [embedding]}})
          )
        end
      end)

      assert {:ok, [^embedding]} =
               EmbedQueue.embed(
                 ["hello"],
                 name: name,
                 input_type: "search_document",
                 plug: {Req.Test, CohereClient}
               )
    end
  end
end
