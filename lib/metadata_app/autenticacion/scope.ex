defmodule MetadataApp.Autenticacion.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `MetadataApp.Autenticacion.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias MetadataApp.Autenticacion.Usuario

  defstruct usuario: nil, empresa_activa: nil

  @doc """
  Creates a scope for the given usuario.

  Returns nil if no usuario is given.
  """
  def for_usuario(%Usuario{} = usuario) do
    %__MODULE__{usuario: usuario}
  end

  def for_usuario(nil), do: nil

  @doc "Fija la empresa activa de un scope ya construido (post-login, vía selector)."
  def con_empresa_activa(%__MODULE__{} = scope, empresa) do
    %{scope | empresa_activa: empresa}
  end
end
