# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     MetadataApp.Repo.insert!(%MetadataApp.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias MetadataApp.Repo
alias MetadataApp.Catalogos
alias MetadataApp.Catalogos.Marca

for marca_descrip <- ["Coca Cola", "Pepsi Cola", "RC Cola"] do
  unless Repo.get_by(Marca, marca_descrip: marca_descrip) do
    {:ok, _marca} = Catalogos.crear_marca(%{"marca_descrip" => marca_descrip})
  end
end
