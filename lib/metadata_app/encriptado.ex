defmodule MetadataApp.Encriptado do
  @moduledoc """
  Tipo Ecto para campos cifrados en reposo (Cloak.Ecto.Binary sobre
  `MetadataApp.Vault`) — hoy solo lo usa `Integraciones.Credencial.api_key`.
  A propósito NO se reusa como "tipo genérico de campo" del sistema de
  catálogos dinámicos (ver conversación 2026-08-06): un campo cifrado
  necesita que TODO el camino genérico (tabla, formulario, GET, filtros,
  orden, PostView) sepa nunca mostrarlo/filtrarlo/ordenarlo por su valor
  real — auditar eso en todo el sistema genérico es mucho más riesgo que
  el beneficio, para un caso de uso (credenciales de integración) que ya
  tiene su propia tabla dedicada, chica y auditable.
  """
  use Cloak.Ecto.Binary, vault: MetadataApp.Vault
end
