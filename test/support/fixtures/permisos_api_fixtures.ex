defmodule MetadataApp.PermisosApiFixtures do
  @moduledoc """
  Helpers de test para SPEC-SYS-2209202601 (seguridad real de `/api`) --
  arma usuario + empresa + rol + permiso de catálogo, o el bypass de
  administrador, y deja el `conn` autenticado listo para pegarle a
  cualquier ruta de `/api`. Reusado por los tests de los 6 controllers
  que esta spec protegió.
  """

  import Plug.Conn

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, UsuarioEmpresa, Rol}
  alias MetadataApp.Permissions
  alias MetadataApp.AutenticacionFixtures

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  def empresa_fixture! do
    %Empresa{}
    |> Empresa.changeset(%{nombre: "Empresa API seguridad #{unique()}"})
    |> Repo.insert!()
  end

  defp usuario_en_empresa!(empresa) do
    usuario = AutenticacionFixtures.usuario_fixture()

    %UsuarioEmpresa{}
    |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id})
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()

    usuario
  end

  @doc "Usuario logueado, en `empresa`, SIN ningún permiso concedido -- para los casos 403."
  def usuario_sin_permiso!(empresa) do
    usuario_en_empresa!(empresa)
  end

  @doc "Usuario logueado, en `empresa`, con exactamente `{recurso, accion}` concedido vía un rol nuevo -- mismo camino real que CatalogoPermisosLive (conceder_permiso_catalogo/3)."
  def usuario_con_permiso!(empresa, recurso, accion) do
    usuario = usuario_en_empresa!(empresa)

    {:ok, rol} = Permissions.crear_rol(%{nombre: "rol_test_#{unique()}", empresa_id: empresa.id, descripcion: "rol de test"})
    {:ok, _} = Permissions.conceder_permiso_catalogo(rol.id, recurso, accion)
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

    usuario
  end

  @doc """
  Usuario logueado con el rol de sistema "administrador" en `empresa` --
  bypass total (R9). "administrador" es GLOBAL (empresa_id: nil,
  sembrado una sola vez por migración, `nombre` único en toda la tabla
  desde 2026-09-01) -- nunca se crea uno nuevo, se reusa el existente y
  se le asigna a este usuario SOLO en `empresa` (UsuarioRol es lo que
  scopea el bypass a una empresa puntual).
  """
  def usuario_administrador!(empresa) do
    usuario = usuario_en_empresa!(empresa)
    rol = Repo.get_by!(Rol, es_sistema: true, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

    usuario
  end

  @doc "Autentica `conn` como `usuario`, con `empresa` ya activa en sesión -- listo para pegarle a cualquier ruta de /api."
  def conn_autenticado(conn, usuario, empresa) do
    token = MetadataApp.Autenticacion.generate_usuario_session_token(usuario)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> put_session(:usuario_token, token)
    |> put_session(:empresa_activa_id, empresa.id)
  end
end
