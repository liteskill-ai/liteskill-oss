defmodule Liteskill.BuiltinSources.Wiki do
  @moduledoc """
  Built-in Wiki data source.

  Wiki is a collaborative document store where users create
  markdown pages. Documents are stored in the documents table
  with source_ref "builtin:wiki".
  """

  @behaviour Liteskill.BuiltinSources

  @impl true
  def id, do: "wiki"

  @impl true
  def name, do: "Wiki"

  @impl true
  def description, do: "Collaborative wiki pages in markdown"

  @impl true
  def icon, do: "hero-book-open-micro"
end
