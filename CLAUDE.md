# Panel de Fleteros

Panel estático (HTML + CSS + JS sin framework) publicado en GitHub Pages.
Se mira sobre todo desde el celular.

## Qué es cada archivo

- `index.html` — la página. Referencia los assets con `?v=AAAAMMDD<letra>`.
- `app.js` — toda la lógica y el render del panel.
- `styles.css` — todos los estilos.
- `data.js` — **generado por el robot. NO EDITAR A MANO.**
- `historial-meses.json` — histórico de meses cerrados.
- `robot-nube.ps1` — el robot que baja los datos y escribe `data.js`.
- `empujar-panel.ps1` — empujón diario desde la PC local.
- `.github/workflows/actualizar-panel.yml` — corre el robot en Actions.

## Reglas que no se negocian

**Versionar los assets.** GitHub Pages sirve con `Cache-Control: max-age=600`.
Cada vez que cambie `app.js`, `styles.css` o `index.html` hay que subir el
`?v=` en las **tres** referencias de `index.html`. Sin eso, el cambio no se ve.

**Los tres indicadores van juntos.** Toda tabla que mida a un fletero lleva
rechazo, efectividad de entrega y cartón, en columnas. El rechazo siempre con
sus dos cifras: el % arriba y la plata abajo. Vara del rechazo en todo el
panel: boleta caída completa (nota de crédito ≥98% de la factura) y mínimo 20
boletas; abajo de ese mínimo va un guion, nunca un 0%.

**Probar en pantalla chica antes de dar algo por bueno.** `python -m http.server`
en la carpeta, y medir desborde con `scrollWidth > clientWidth` a 1200, 390 y
320 px. El celular manda.

**Encoding.** Los archivos están en UTF-8 con CRLF. Los parches se hacen con un
script Python que lee y escribe con `newline=""` y aborta si un ancla no es
única. Nunca con `\uXXXX` dentro de un heredoc de bash: las barras se colapsan
y el archivo queda truncado.

## Propio de este panel

Las reglas generales de los paneles —celular primero, archivos de datos que no
se tocan a mano, mirar Actions antes de gritar bug, claves, estilo de commit—
están en `~/.claude/CLAUDE.md` y valen acá también. Lo que sigue es lo que
pasa sólo en este repo.

Este workflow corre **seis veces por día hábil sobre runners de Windows**, que
son los más caros en minutos: si se lo toca, vale la pena mirar el gasto.

Ante "el panel no se actualizó": `gh run list --workflow=actualizar-panel.yml`.
Una corrida de las 07:20 ART suele salir entre 13:45 y 14:30, y la de 14:20
entre 18:45 y 19:45. Casi nunca es un bug: es la corrida que no salió todavía.
Para destrabarla, `gh workflow run actualizar-panel.yml --ref main`.

`gh` está autenticado como `tiendaperfecta` con scopes `repo` y `workflow`.
