defmodule MetadataAppWeb.FallbackController do
  use MetadataAppWeb, :controller
  require Logger

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: MetadataApp.MetaErrores.traducir(changeset)})
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Registro no encontrado"}})
  end

  # --- RBAC (MetadataApp.Permissions) -------------------------------------

  def call(conn, {:error, :no_encontrado}) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Registro no encontrado"}})
  end

  def call(conn, {:error, :rol_de_sistema}) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: %{detail: "los roles de sistema no se editan ni se eliminan"}})
  end

  def call(conn, {:error, :rol_de_otra_empresa}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: "ese rol pertenece a otra empresa"}})
  end

  # --- Desenlaces del ciclo de MetadataApp.MetaStateEngine.ejecutar_transicion/3
  # (spec sección 7, Contrato 2) ------------------------------------------

  # Paso 1: rechazo estructural — la acción no existe desde el estado actual.
  def call(conn, {:error, {:transicion_invalida, %{estado_actual_id: estado_id}}}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      errors: %{detail: "transición inválida desde el estado actual", estado_actual_id: estado_id}
    })
  end

  # Paso 2: rechazo de negocio — información de proceso, no error de sistema.
  def call(conn, {:error, {:precondiciones, fallas}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{razones: fallas}})
  end

  # Paso 3: otro proceso ganó la carrera antes del commit.
  def call(conn, {:error, :conflicto_concurrencia}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "el registro cambió, recargue"}})
  end

  # Pasos 4-5a: falla de integridad. Error genérico al cliente — el detalle
  # real solo se loguea del lado del servidor, nada quedó persistido.
  def call(conn, {:error, {:postcondicion_fallida, razon}}) do
    Logger.error("StateEngine: postcondición transaccional falló: #{inspect(razon)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{errors: %{detail: "error interno, no se aplicó el cambio"}})
  end

  def call(conn, {:error, mensaje}) when is_binary(mensaje) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: mensaje}})
  end

  # Jerarquía operativa activa (Fase 5, 2026-08-11) -- CatalogoGenerico
  # devuelve esto cuando el catálogo exige branch/sales_unit/inventory
  # location y quien hace el POST no tiene ninguno activo elegido (ver
  # CatalogoGenerico.validar_campo_requerido_en_attrs/4). Mismos mensajes
  # que FichaLive.formatear_error/1 para el mismo caso.
  def call(conn, {:error, {:alcance_requerido, campo}}) do
    detalle =
      case campo do
        "branch_id" -> "No hay una Sucursal activa — elegí una desde la banda de pie antes de crear este registro."
        "sales_unit_id" -> "No hay una Unidad de Venta activa — elegí una desde la banda de pie antes de crear este registro."
        "inventory_id" -> "No hay un Almacén activo — elegí uno desde la banda de pie antes de crear este registro."
      end

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: detalle}})
  end
end
