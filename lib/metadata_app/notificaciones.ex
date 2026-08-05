defmodule MetadataApp.Notificaciones do
  @moduledoc """
  Bandeja de notificaciones por usuario, acotada a las @maximo más
  recientes — cada alta poda sola las viejas (ver podar/1), así la tabla
  nunca crece sin límite y no hace falta un job de limpieza aparte.

  Se alimenta de dos lugares:
    - `MetaAuditoria.registrar/6` (único choke point de altas/ediciones/
      bajas de FILAS de catálogo vía CatalogoGenerico) — cubre la gran
      mayoría de "cambios" reales de datos de negocio automáticamente.
    - Llamadas puntuales en pantallas de cuenta/admin que ya mandaban un
      `put_flash(:info, ...)` de éxito (ver crear/3 debajo).
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.Notificacion

  @maximo 30

  @doc """
  Topic de PubSub de la campanita de un usuario — UsuarioAuth.mount_current_scope/2
  suscribe acá a CUALQUIER LiveView autenticado (todas comparten el mismo
  MenuLayout/NotifBellComponent), así que un alta desde OTRO proceso/pestaña
  (ej. otra LiveView creando un registro vía CatalogoGenerico) llega al
  instante sin esperar a que esa pantalla se recargue sola.
  """
  def topic(usuario_id), do: "notificaciones:usuario:#{usuario_id}"

  @doc "Sin usuario real detrás (import/script/proceso interno) no hay a quién notificar — no es un error."
  def crear(usuario_id, mensaje, tipo \\ "info")
  def crear(nil, _mensaje, _tipo), do: :ok

  def crear(usuario_id, mensaje, tipo) do
    case %Notificacion{} |> Notificacion.changeset(%{usuario_id: usuario_id, mensaje: mensaje, tipo: tipo}) |> Repo.insert() do
      {:ok, notificacion} ->
        podar(usuario_id)
        Phoenix.PubSub.broadcast(MetadataApp.PubSub, topic(usuario_id), :nueva_notificacion)
        {:ok, notificacion}

      error ->
        error
    end
  end

  def listar(usuario_id, limite \\ @maximo) do
    from(n in Notificacion,
      where: n.usuario_id == ^usuario_id,
      order_by: [desc: n.inserted_at],
      limit: ^limite
    )
    |> Repo.all()
  end

  def contar_no_leidas(usuario_id) do
    from(n in Notificacion, where: n.usuario_id == ^usuario_id and n.leida == false, select: count())
    |> Repo.one()
  end

  def marcar_todas_leidas(usuario_id) do
    from(n in Notificacion, where: n.usuario_id == ^usuario_id and n.leida == false)
    |> Repo.update_all(set: [leida: true])
  end

  # Mantiene solo las @maximo más recientes del usuario — borra el resto
  # (no solo "una de más", así se auto-corrige si alguna vez se coló algo
  # por otro camino).
  defp podar(usuario_id) do
    ids_a_mantener =
      from(n in Notificacion,
        where: n.usuario_id == ^usuario_id,
        order_by: [desc: n.inserted_at],
        limit: @maximo,
        select: n.id
      )
      |> Repo.all()

    from(n in Notificacion, where: n.usuario_id == ^usuario_id and n.id not in ^ids_a_mantener)
    |> Repo.delete_all()
  end
end
