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

## Cómo trabajar acá, sin que haya que pedirlo

Estas cosas se hacen solas, no hace falta que el usuario escriba ningún comando:

- **Antes de abrir `app.js`, `data.js`, `robot-nube.ps1` o `historial-meses.json`**
  (todos de 20 KB para arriba): indexar primero y leer sólo el tramo que importa,
  en vez de cargar el archivo entero. Lo mismo con los logs de Actions.
- **Ante cualquier cambio visual** (tablas, colores, tipografía, layout, cómo
  entra algo en el celular): aplicar criterio de diseño frontend sin que lo
  pidan, y verificar el resultado renderizado, no sólo el código.
- **Si se toca `.github/workflows/`**: revisar de paso corridas desperdiciadas,
  falta de timeouts y acciones sin pinear. El workflow corre seis veces por día
  hábil sobre runners de Windows, que son los más caros en minutos.
- **Ante "el panel no se actualizó"**: mirar primero las corridas
  (`gh run list --workflow=actualizar-panel.yml`). El cron gratuito de GitHub
  llega tarde por horas, no por minutos — una corrida de 07:20 ART suele salir
  13:45–14:30. Casi nunca es un bug: es la corrida que todavía no salió.
- **Ante "no se ve el cambio"**: confirmar que subió el `?v=` antes de buscar
  cualquier otra cosa.

## Git

Commitear en español, en una línea, describiendo el efecto para el usuario del
panel y no el detalle técnico. Identidad: `tiendaperfecta`. `gh` está
autenticado con scopes `repo` y `workflow`, así que se puede pushear y disparar
el workflow directo.
