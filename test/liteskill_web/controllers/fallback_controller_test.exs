defmodule LiteskillWeb.FallbackControllerTest do
  use LiteskillWeb.ConnCase, async: true

  alias LiteskillWeb.FallbackController

  test "handles {:error, :not_found}", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> FallbackController.call({:error, :not_found})

    assert json_response(conn, 404)["error"] == "not found"
  end

  test "handles {:error, :forbidden}", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> FallbackController.call({:error, :forbidden})

    assert json_response(conn, 403)["error"] == "forbidden"
  end

  test "handles {:error, %Ecto.Changeset{}} with structured errors", %{conn: conn} do
    changeset = %Ecto.Changeset{errors: [title: {"can't be blank", []}], valid?: false}

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> FallbackController.call({:error, changeset})

    resp = json_response(conn, 422)
    assert resp["error"] == "validation failed"
    assert resp["details"] == "title: can't be blank"
  end

  test "handles {:error, atom_reason} with humanized message", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> FallbackController.call({:error, :some_reason})

    assert json_response(conn, 422)["error"] == "some reason"
  end

  test "handles {:error, non_atom} with generic message", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> FallbackController.call({:error, "some string error"})

    assert json_response(conn, 422)["error"] == "some string error"
  end

  test "changeset errors with interpolation", %{conn: conn} do
    changeset = %Ecto.Changeset{
      errors: [
        password: {"should be at least %{count} character(s)", [count: 12, validation: :length]}
      ],
      valid?: false
    }

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> FallbackController.call({:error, changeset})

    resp = json_response(conn, 422)
    assert resp["error"] == "validation failed"
    assert resp["details"] == "password: should be at least 12 character(s)"
  end
end
