# Ver pty_mat_fabricante.exs para el formato general. Acá además hay
# un campo tipo "referencia" (pty_dsd_mat_lineas_sub_dsd_linea) -- se
# escribe con el valor NATURAL del registro destino (el mismo texto
# que se vería tipeado en el combo real), nunca un id: "ALIMENTOS" se
# resuelve contra pty_dsd_linea.exs, que tiene que cargarse ANTES
# (mix seed.cargar ya respeta ese orden solo, calculado por FK real).
[
  %{
    "pty_dsd_mat_lineas_sub_dsd_linea" => "ALIMENTOS",
    "pty_dsd_mat_lineas_sub_descripcion" => "ENLATADOS"
  },
  %{
    "pty_dsd_mat_lineas_sub_dsd_linea" => "ALIMENTOS",
    "pty_dsd_mat_lineas_sub_descripcion" => "CONGELADOS"
  }
]
