defmodule MetadataAppWeb.PageController do
  use MetadataAppWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
