defmodule MetadataApp.Permissions do
  @moduledoc """
  Placeholder mínimo de RBAC — todavía no existe un sistema de sesión/roles
  real en el proyecto. `contexto` (el mismo mapa que ya viaja a
  `MetadataApp.StateEngine.ejecutar_transicion/3`) hace las veces de "user":
  se espera que traiga `"rol"` (string) y/o `"roles"` (lista de strings).

  Reemplazar la implementación por el RBAC real cuando exista, sin cambiar
  la firma `can?/3` — es el único punto de integración que usa el motor
  (a través de la regla `requiere_rol`).
  """

  @spec can?(map(), String.t(), term()) :: boolean()
  def can?(contexto, rol_requerido, _recurso \\ nil) when is_map(contexto) do
    Map.get(contexto, "rol") == rol_requerido or rol_requerido in Map.get(contexto, "roles", [])
  end
end
