defmodule MetadataApp.Vault do
  @moduledoc """
  Vault de Cloak.Ecto — cifra/descifra los campos marcados con
  `MetadataApp.Encriptado` (por ahora, solo `Integraciones.Credencial.api_key`).

  La clave real (`CLOAK_KEY`) SIEMPRE viene del entorno en runtime (ver
  `config/runtime.exs`, mismo criterio que `SECRET_KEY_BASE`) — dev/test
  usan una fija en `config/config.exs` solo para no depender de una
  variable de entorno en la laptop de cada quien. Perder esta clave en
  producción es IRRECUPERABLE: las credenciales cifradas con ella quedan
  ilegibles para siempre, no hay "recuperar contraseña" — tratarla con el
  mismo cuidado que SECRET_KEY_BASE, guardada en un gestor de secretos
  real, nunca solo "en el servidor".
  """
  use Cloak.Vault, otp_app: :metadata_app
end
