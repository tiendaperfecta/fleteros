# Empujon diario del panel de fleteros.
#
# Por que existe: el robot esta programado en GitHub Actions a las 07:20 y 14:20
# ART, pero los cron gratis de GitHub llegan entre 20 minutos y 5 horas tarde
# (medido del 27 al 29/10/2026: la corrida de las 07:20 salia 13:45 y la de las
# 14:20 salia 18:45). Esta PC tiene reloj puntual, asi que lo empuja ella.
#
# Lo llama la tarea programada "Panel fleteros - empujon diario", lunes a viernes
# 07:30 y 15:30. No baja datos ni toca el panel: solo pide la corrida. El robot
# tiene candado por turno, asi que si GitHub ya la largo, esta no baja de nuevo.
#
# Para ver si viene andando:  Get-Content "$env:LOCALAPPDATA\panel-fleteros\empujar-panel.log" -Tail 20

$ErrorActionPreference = "Stop"

$carpetaLog = Join-Path $env:LOCALAPPDATA "panel-fleteros"
if (-not (Test-Path $carpetaLog)) { New-Item -ItemType Directory -Path $carpetaLog | Out-Null }
$log = Join-Path $carpetaLog "empujar-panel.log"

function Log($t) {
  Add-Content -Path $log -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $t) -Encoding UTF8
}

$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh) { $gh = "C:\Program Files\GitHub CLI\gh.exe" }
if (-not (Test-Path $gh)) { Log "FALLO: no esta instalado gh en esta PC"; exit 1 }

try {
  $salida = & $gh workflow run actualizar-panel.yml --ref main -R tiendaperfecta/fleteros 2>&1
  if ($LASTEXITCODE -eq 0) {
    Log "OK: corrida pedida"
  } else {
    Log ("FALLO (" + $LASTEXITCODE + "): " + ($salida -join " "))
  }
} catch {
  Log ("ERROR: " + $_.Exception.Message)
}

# El log no crece para siempre: se queda con las ultimas 500 lineas.
if ((Get-Item $log).Length -gt 200KB) {
  Set-Content -Path $log -Value (Get-Content $log -Tail 500) -Encoding UTF8
}
