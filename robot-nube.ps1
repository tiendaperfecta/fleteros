# ============================================================================
# ROBOT NUBE (GitHub Actions) - Panel de Fleteros Tienda Perfecta S.A.
# Molde: robot de PPP (API completa, sin archivos locales) + envoltorio nube
# de Lago Puelo-Elebes (secretos por variable de entorno, bajada inteligente).
# DIFERENCIA CLAVE vs PPP: el carton NO sale de una planilla de Drive, sale
# de la propia API de Gescom (distribucion.reparto/get-info-items por reparto,
# items "Caja de Carton Recuperada" Buen/Mal Estado, salida vs entrada).
# Empresas 1 (Tienda Perfecta), 2 (Rambla de los Lobos) y 99 se FUSIONAN en
# una sola marca (decision de Lucas, 2/9/2026): no hay anillos por empresa.
# PREMIOS: pendientes de definir (no se sabe si pagan) -> el robot siempre
# publica premio 0. El dia que Lucas defina la escala, se cambia SOLO la
# funcion Calcular-Premio de aca abajo; la web ya sabe mostrarlo (o no).
# Si se corre SIN GITHUB_WORKSPACE entra en MODO PRUEBA LOCAL: usa las rutas
# y credenciales locales y escribe robot\data-nube-prueba.js sin publicar.
# ============================================================================

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$EN_NUBE = [bool]$env:GITHUB_WORKSPACE
if ($EN_NUBE) {
  $CARPETA_PROYECTO = $env:GITHUB_WORKSPACE
  $HIST_FILE = Join-Path $CARPETA_PROYECTO "historial-meses.json"
} else {
  $CARPETA_PROYECTO = "C:\Users\luqaa\Documents\TiendaPerfecta-Fleteros"
  $HIST_FILE = Join-Path $CARPETA_PROYECTO "robot\historial-meses.json"
}

# Choferes que no son fleteros reales (se van agregando a medida que Lucas los detecta).
$EXCLUIR = @("SIN CHOFER")
# Items de carton retornable (Buen Estado + Mal Estado, decidido con Lucas 2/9/2026).
$ITEMS_CARTON = @("1100000130", "1100000131")

function Log($msg) {
  # OJO: [Console] y no Write-Output — dentro de una funcion, Write-Output se
  # mezcla con el valor de retorno y contamina los datos (bug ya sufrido en PPP/LPE).
  [Console]::Out.WriteLine((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $msg)
}
Log "================ INICIO (NUBE) ================"

# --- Bajada inteligente: una sola por dia -----------------------------------
if ($EN_NUBE -and $env:GITHUB_EVENT_NAME -eq "schedule" -and -not $env:FORCE_MES) {
  $dataJsRepo = Join-Path $CARPETA_PROYECTO "data.js"
  if (Test-Path $dataJsRepo) {
    $cab = (Get-Content $dataJsRepo -TotalCount 3 -Encoding UTF8) -join " "
    $hoyStr = (Get-Date -Format "yyyy-MM-dd")
    if ($cab -match ("Ultima actualizacion: " + [regex]::Escape($hoyStr))) {
      Log "Datos de hoy ($hoyStr) ya publicados: no hace falta bajar de nuevo"
      Log "================ FIN (NUBE) ================"
      exit 0
    }
  }
}

# --- Credenciales (secretos GESCOM_* en la nube; archivo local si no) -------
$credU = ""; $credC = ""; $credR = ""
if ($env:GESCOM_USUARIO) {
  $credU = ([string]$env:GESCOM_USUARIO).Trim()
  $credC = ([string]$env:GESCOM_CLAVE).Trim()
  $credR = ([string]$env:GESCOM_REALM).Trim()
} else {
  $credArch = Join-Path $CARPETA_PROYECTO "robot\gescom-api.txt"
  foreach ($lin in Get-Content $credArch -Encoding UTF8) {
    $par = $lin.Split("=", 2)
    if ($par.Count -eq 2) {
      if ($par[0].Trim() -eq "USUARIO") { $credU = $par[1].Trim() }
      if ($par[0].Trim() -eq "CLAVE") { $credC = $par[1].Trim() }
      if ($par[0].Trim() -eq "REALM") { $credR = $par[1].Trim() }
    }
  }
}
if (-not $credU -or -not $credC -or -not $credR) { Log "ERROR: faltan credenciales de Gescom"; exit 1 }

$script:tokenApi = $null
function Get-TokenGescom {
  $cuerpo = @{ grant_type = "password"; client_id = "gcw-web-api"; username = $credU; password = $credC }
  $script:tokenApi = (Invoke-RestMethod -Method Post -Uri ("https://auth.gescom.online/realms/" + $credR + "/protocol/openid-connect/token") -Body $cuerpo -TimeoutSec 30).access_token
}
Get-TokenGescom
$BASE_API = "https://tiendaperfecta.gescom.online/data/cmd"

function Get-Api($ruta) {
  # Listados: GET con querystring. Reintenta con espera creciente (el server
  # rebota rafagas) y renueva el token si vencio (dura ~5 min, no 24 h).
  $esperas = @(0, 10, 30, 60, 120, 180)
  foreach ($espera in $esperas) {
    if ($espera -gt 0) { Start-Sleep -Seconds $espera }
    try {
      return Invoke-RestMethod -Uri "$BASE_API/$ruta" -Headers @{ Authorization = "Bearer $script:tokenApi" } -TimeoutSec 120
    } catch {
      $st = 0; try { $st = [int]$_.Exception.Response.StatusCode } catch {}
      if ($st -eq 401) { Get-TokenGescom; continue }
      Log "  reintento ($st) $($ruta.Split('?')[0])"
    }
  }
  throw "API sin respuesta: $ruta"
}

function Post-Api($ruta, $cuerpoObj) {
  # Comandos puntuales por reparto (get-info-items, etc.): POST con body JSON.
  $esperas = @(0, 5, 15, 30)
  $json = $cuerpoObj | ConvertTo-Json -Compress
  foreach ($espera in $esperas) {
    if ($espera -gt 0) { Start-Sleep -Seconds $espera }
    try {
      return Invoke-RestMethod -Uri "$BASE_API/$ruta" -Method Post -Headers @{ Authorization = "Bearer $script:tokenApi" } -Body $json -ContentType "application/json" -TimeoutSec 60
    } catch {
      $st = 0; try { $st = [int]$_.Exception.Response.StatusCode } catch {}
      if ($st -eq 401) { Get-TokenGescom; continue }
    }
  }
  return $null
}

function Desenrollar($x) {
  while ($x -is [array] -and $x.Count -eq 1 -and $x[0] -is [array]) { $x = $x[0] }
  return $x
}

# --- Mes en curso ------------------------------------------------------------
$hoy = (Get-Date).ToString("yyyy-MM-dd")
$mesIniDt = Get-Date -Day 1
$mesIni = $mesIniDt.ToString("yyyy-MM-01")
$mesActual = $mesIniDt.ToString("yyyy-MM")
$mesFinExcl = $mesIniDt.AddMonths(1).ToString("yyyy-MM-dd")
# Escape hatch / refresco de cierre: FORCE_MES=yyyy-MM recalcula ese mes.
if ($env:FORCE_MES -match '^\d{4}-\d{2}$') {
  $mesIniDt = [DateTime]($env:FORCE_MES + "-01")
  $mesIni = $mesIniDt.ToString("yyyy-MM-01")
  $mesActual = $mesIniDt.ToString("yyyy-MM")
  $mesFinExcl = $mesIniDt.AddMonths(1).ToString("yyyy-MM-dd")
  Log "FORZADO mes = $mesActual"
  if (Test-Path $HIST_FILE) {
    try {
      $hChk = Get-Content $HIST_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($hChk.$mesActual -and $hChk.$mesActual.cierreFinal -eq $true) {
        Log "Mes $mesActual ya cerrado definitivo: no hace falta re-bajar"
        Log "================ FIN (NUBE) ================"
        exit 0
      }
    } catch { }
  }
}

# --- 1) Repartos del mes (id + codigo + chofer + fecha) ----------------------
$repartosRaw = Get-Api "distribucion/api/v1/get-repartos?fechadesde=$mesIni&fechahasta=$mesFinExcl"
$listaRepartos = @(Desenrollar $repartosRaw)
if ($listaRepartos.Count -eq 0) {
  $mesIniDt = $mesIniDt.AddMonths(-1)
  $mesIni = $mesIniDt.ToString("yyyy-MM-01")
  $mesActual = $mesIniDt.ToString("yyyy-MM")
  $mesFinExcl = $mesIniDt.AddMonths(1).ToString("yyyy-MM-dd")
  $repartosRaw = Get-Api "distribucion/api/v1/get-repartos?fechadesde=$mesIni&fechahasta=$mesFinExcl"
  $listaRepartos = @(Desenrollar $repartosRaw)
}
$repInfo = @{}      # codigo (para atar ventas) -> {fecha, chofer, id (para get-info-items)}
$repAbiertos = 0
foreach ($rpx in $listaRepartos) {
  $fch = ([string]$rpx.fecha).Substring(0, 10)
  if ($fch -gt $hoy) { continue }
  if ($rpx.cerrado -ne $true) { $repAbiertos++ }
  $choR = ""
  if ($rpx.codigoChofer -and -not $choR) { $choR = (([string]$rpx.nombreChofer).Trim().ToUpper() -replace "\s+", " ") }
  $repInfo[[string]$rpx.codigo] = @{ fecha = $fch; chofer = $choR; id = [string]$rpx.id }
}
Log ("Repartos del mes ($mesActual): " + $repInfo.Count + " (sin cerrar: $repAbiertos)")
if ($repInfo.Count -eq 0) { Log "ERROR: la API no devolvio repartos; NO se publica nada"; exit 1 }

# --- 2) Catalogos -------------------------------------------------------------
$choferesRaw = Get-Api "ventas/api/v1/get-empleados?tipo=CHF"
$mapaChofer = @{}
foreach ($em in @(Desenrollar $choferesRaw)) { $mapaChofer[[string]$em.codigo] = (([string]$em.nombre).Trim().ToUpper() -replace "\s+", " ") }
$vendedoresRaw = Get-Api "ventas/api/v1/get-vendedores"
$mapaVend = @{}
foreach ($vd in @(Desenrollar $vendedoresRaw)) { $mapaVend[[string]$vd.codigo] = ([string]$vd.nombre).Trim() }
$proveedoresRaw = Get-Api "compras/api/v1/get-proveedores?pagesize=1000"
$mapaProvNombre = @{}
foreach ($pv in @(Desenrollar $proveedoresRaw)) { $mapaProvNombre[[string]$pv.codigo] = ([string]$pv.nombre).Trim() }
$clientesRaw = Get-Api "ventas/api/v1/get-clientes"
$cliLoc = @{}; $cliRaz = @{}
foreach ($cl in @(Desenrollar $clientesRaw)) {
  $cliLoc[[string]$cl.codigo] = ([string]$cl.localidad).Trim().ToUpper()
  $cliRaz[[string]$cl.codigo] = ([string]$cl.razonSocial).Trim()
}
$mapaArtProv = @{}
$artRaw = Get-Api "inventario/api/v2/get-articulos?pagesize=5000"
foreach ($ar in @(Desenrollar $artRaw)) {
  $cp = [string]$ar.codigoProveedor
  if ($cp) { $mapaArtProv[[string]$ar.codigo] = $cp }
}
$feriadosRaw = Get-Api "ventas/api/v1/get-feriados"
$feriadosWeb = @(@(Desenrollar $feriadosRaw) | ForEach-Object { [string]$_.fecha } | Sort-Object -Unique)
Log ("Catalogos: " + $mapaChofer.Count + " choferes, " + $mapaVend.Count + " vendedores, " + $mapaProvNombre.Count +
  " proveedores, " + $cliLoc.Count + " clientes, " + $mapaArtProv.Count + " articulos, " + $feriadosWeb.Count + " feriados")

# --- 3) Ventas (dia por dia, por fecha de CARGA, margen 21 dias) -------------
$ventasPorId = @{}
$diaDesc = $mesIniDt.AddDays(-21)
$hastaDesc = (Get-Date).Date
while ($diaDesc -le $hastaDesc) {
  $dd1 = $diaDesc.ToString("yyyy-MM-dd")
  $dd2 = $diaDesc.AddDays(1).ToString("yyyy-MM-dd")
  $pagV = 0
  $primerIdPrevio = ""
  while ($true) {
    $ventasRaw = Get-Api "ventas/api/v2/get?fechadesde=$dd1&fechahasta=$dd2&pagesize=500&pagestoskip=$pagV&pagestotake=1"
    $listaVen = @(Desenrollar $ventasRaw)
    $primerId = ""; if ($listaVen.Count -gt 0) { $primerId = [string]$listaVen[0].id }
    if ($pagV -gt 0 -and $primerId -eq $primerIdPrevio) { Log "AVISO: paginacion repetida en $dd1, se corta"; break }
    $primerIdPrevio = $primerId
    foreach ($vx in $listaVen) { $ventasPorId[[string]$vx.id] = $vx }
    if ($listaVen.Count -lt 500 -or $pagV -ge 30) { break }
    $pagV++
    Start-Sleep -Milliseconds 500
  }
  Start-Sleep -Milliseconds 400
  $diaDesc = $diaDesc.AddDays(1)
}
Log ("Ventas bajadas de la API: " + $ventasPorId.Count)
if ($ventasPorId.Count -eq 0) { Log "ERROR: la API no devolvio ventas; NO se publica nada"; exit 1 }

# --- 4) Efectividad OFICIAL por chofer/dia (repartos, boletas, items rech) ---
$entregas = @{}   # "fecha|CHOFER" -> {asig, real, reps{codigoReparto}, itemsRech}
foreach ($idv in @($ventasPorId.Keys)) {
  $vv = $ventasPorId[$idv]
  $repC = [string]$vv.codigoReparto
  if (-not $repC -or -not $repInfo.ContainsKey($repC)) { continue }
  $fechaRep = $repInfo[$repC].fecha
  $choferRep = $repInfo[$repC].chofer
  if (-not $choferRep -or $choferRep -in $EXCLUIR) { continue }
  $clave = "$fechaRep|$choferRep"
  if (-not $entregas[$clave]) { $entregas[$clave] = @{ asig = 0; real = 0; reps = @{}; itemsRech = 0.0 } }
  $entregas[$clave].reps[$repC] = $true
  $tipoV = [string]$vv.codigoTipoVenta
  $fpd = [string]$vv.fechaPedido
  $fpDia = ""; if ($fpd.Length -ge 10) { $fpDia = $fpd.Substring(0, 10) }
  $esDirecta = $false
  if ($null -ne $vv.ventaDirecta) { $esDirecta = [bool]$vv.ventaDirecta }
  if ($tipoV -eq "VEN") {
    if (-not $esDirecta) { $entregas[$clave].asig++; $entregas[$clave].real++ }
  } elseif ($tipoV -eq "DEV-CA") {
    $entregas[$clave].asig++; $entregas[$clave].real++
  } elseif ($tipoV -eq "DEV-RE") {
    if ($fpDia -and $fpDia -lt $fechaRep) {
      $entregas[$clave].asig++; $entregas[$clave].real++
    } else {
      $entregas[$clave].real--
      foreach ($itx in @($vv.items)) {
        $ufa = 1.0; if ($null -ne $itx.unidadFactor) { $ufa = [double]$itx.unidadFactor }
        $entregas[$clave].itemsRech += [Math]::Abs([double]$itx.cantidad) * $ufa
      }
    }
  }
  # AJU-MAS/AJU-MEN y demas tipos no cuentan (mismo criterio que Panel de Ventas).
}
$claves = @($entregas.Keys | Where-Object { $entregas[$_].asig -gt 0 } | Sort-Object)
$repartosCho = @{}   # chofer -> repartos hechos en el mes (para la tarjeta de asistencia)
foreach ($clave in $claves) {
  $choK = $clave.Split("|")[1]
  if (-not $repartosCho[$choK]) { $repartosCho[$choK] = 0 }
  $repartosCho[$choK] += $entregas[$clave].reps.Count
}
Log ("Efectividad oficial: " + $claves.Count + " registros dia/chofer")

# --- 5) CARTON: salida vs entrada de cajas retornables, por reparto ----------
# distribucion.reparto/get-info-items (repartoId = id interno, NO el codigo)
# trae por item {salida.unidadesTotales, entrada.unidadesTotales}. Sumamos los
# 2 codigos de "Caja de Carton Recuperada" (Buen + Mal Estado).
$cartones = @{}   # "fecha|CHOFER" -> {sal, vue}
$nRepCarton = 0
foreach ($repC in @($repInfo.Keys)) {
  $ri = $repInfo[$repC]
  if (-not $ri.chofer -or $ri.chofer -in $EXCLUIR) { continue }
  $items = Post-Api "distribucion.reparto/get-info-items" @{ repartoId = [long]$ri.id }
  if (-not $items) { continue }
  $sal = 0.0; $vue = 0.0
  foreach ($it in @($items)) {
    if ($ITEMS_CARTON -notcontains [string]$it.itemCodigo) { continue }
    if ($it.salida -and $null -ne $it.salida.unidadesTotales) { $sal += [double]$it.salida.unidadesTotales }
    if ($it.entrada -and $null -ne $it.entrada.unidadesTotales) { $vue += [double]$it.entrada.unidadesTotales }
  }
  if ($sal -gt 0 -or $vue -gt 0) {
    $claveC = $ri.fecha + "|" + $ri.chofer
    if (-not $cartones[$claveC]) { $cartones[$claveC] = @{ sal = 0.0; vue = 0.0 } }
    $cartones[$claveC].sal += $sal
    $cartones[$claveC].vue += [math]::Min($vue, $sal + $cartones[$claveC].vue)   # tope: no puede volver mas de lo que salio
    $nRepCarton++
  }
  Start-Sleep -Milliseconds 250
}
Log ("Carton (API): " + $nRepCarton + " repartos con caja de carton, " + $cartones.Count + " registros dia/chofer")

# --- 6) Estadisticas del mes (rechazos, motivos, zonas, vendedores, clientes) -
$motivos = @{}; $motivosPorChofer = @{}; $statsChofer = @{}
$zonaSac = @{}; $zonaRech = @{}; $vendSac = @{}; $vendRech = @{}; $cliRechAcum = @{}
$choProvFact = @{}; $choProvRech = @{}; $provFact = @{}; $provRech = @{}
$choRechImp = @{}
$cliDias = @{}; $facImp = @{}; $refImp = @{}; $facCho = @{}
$refMotivo = @{}; $choRefs = @{}
$factTotal = 0.0; $impRechTotal = 0.0

foreach ($idv in @($ventasPorId.Keys)) {
  $vv = $ventasPorId[$idv]
  $tipoV = [string]$vv.codigoTipoVenta
  if ($tipoV -ne "VEN" -and $tipoV -ne "DEV-RE") { continue }
  $fev = [string]$vv.fechaEntrega
  if ($fev.Length -lt 10) { continue }
  $feDia = $fev.Substring(0, 10)
  if ($feDia.Substring(0, 7) -ne $mesActual -or $feDia -gt $hoy) { continue }
  $chox = $mapaChofer[[string]$vv.codigoChofer]
  if (-not $chox -or $chox -in $EXCLUIR) { continue }
  $codCli = [string]$vv.codigoCliente
  $loc = ""; if ($cliLoc.ContainsKey($codCli)) { $loc = $cliLoc[$codCli] }
  $ven = ""; if ($vv.codigoVendedor -and $mapaVend.ContainsKey([string]$vv.codigoVendedor)) { $ven = $mapaVend[[string]$vv.codigoVendedor] }
  $impTot = 0.0
  foreach ($itx in @($vv.items)) {
    $ii = 0.0; if ($null -ne $itx.importeTotal) { $ii = [Math]::Abs([double]$itx.importeTotal) }
    $impTot += $ii
    $provC = $mapaArtProv[[string]$itx.codigoItem]
    $provN = "Otros"; if ($provC -and $mapaProvNombre[$provC]) { $provN = $mapaProvNombre[$provC] }
    $kcp = "$chox|$provN"
    if ($tipoV -eq "VEN") {
      if (-not $provFact.ContainsKey($provN)) { $provFact[$provN] = 0.0 }; $provFact[$provN] += $ii
      if (-not $choProvFact.ContainsKey($kcp)) { $choProvFact[$kcp] = 0.0 }; $choProvFact[$kcp] += $ii
    } else {
      if (-not $provRech.ContainsKey($provN)) { $provRech[$provN] = 0.0 }; $provRech[$provN] += $ii
      if (-not $choProvRech.ContainsKey($kcp)) { $choProvRech[$kcp] = 0.0 }; $choProvRech[$kcp] += $ii
    }
  }
  if ($tipoV -eq "VEN") {
    $kcli = "$codCli|$feDia"
    if (-not $cliDias[$kcli]) { $cliDias[$kcli] = @{ fac = @{}; cho = "" } }
    $cliDias[$kcli].fac[$idv] = $true
    $cliDias[$kcli].cho = $chox
    if (-not $facImp.ContainsKey($idv)) { $facImp[$idv] = 0.0 }
    $facImp[$idv] += $impTot
    $facCho[$idv] = $chox
    $factTotal += $impTot
    if ($loc) { $kz = $loc; if (-not $zonaSac[$kz]) { $zonaSac[$kz] = @{} }; $zonaSac[$kz][$idv] = $true }
    if ($ven) { $kv = $ven; if (-not $vendSac[$kv]) { $vendSac[$kv] = @{} }; $vendSac[$kv][$idv] = $true }
  } else {
    $refx = ""
    if ($null -ne $vv.ventaReferenciada -and $null -ne $vv.ventaReferenciada.id) { $refx = [string]$vv.ventaReferenciada.id }
    if (-not $refx) { $refx = $idv }
    if (-not $refImp.ContainsKey($refx)) { $refImp[$refx] = 0.0 }
    $refImp[$refx] += $impTot
    $impRechTotal += $impTot
    if (-not $choRechImp.ContainsKey($chox)) { $choRechImp[$chox] = 0.0 }
    $choRechImp[$chox] += $impTot
    if ($loc) { $kz = $loc; if (-not $zonaRech[$kz]) { $zonaRech[$kz] = @{} }; $zonaRech[$kz][$refx] = $true }
    if ($ven) { $kv = $ven; if (-not $vendRech[$kv]) { $vendRech[$kv] = @{} }; $vendRech[$kv][$refx] = $true }
    $raz = ""; if ($cliRaz.ContainsKey($codCli)) { $raz = $cliRaz[$codCli] }
    if ($raz) {
      $kc = "$raz|$loc"
      if (-not $cliRechAcum[$kc]) { $cliRechAcum[$kc] = @{} }
      $cliRechAcum[$kc][$refx] = $true
    }
    $choRefs["$chox|$refx"] = $true
    $motx = ([string]$vv.motivo).Trim() -replace "\s+", " "
    if (-not $motx) { $motx = "Sin especificar" }
    if (-not $motivos[$motx]) { $motivos[$motx] = 0 }
    $motivos[$motx]++
    if (-not $refMotivo.ContainsKey("$chox|$refx")) { $refMotivo["$chox|$refx"] = $motx }
  }
}

$cliRechTot = 0; $cliSac = 0
foreach ($kcli in @($cliDias.Keys)) {
  $dcl = $cliDias[$kcli]
  $nBol = $dcl.fac.Count
  if ($nBol -le 0) { continue }
  $cliSac++
  $cho9 = $dcl.cho
  if ($cho9 -and -not $statsChofer[$cho9]) { $statsChofer[$cho9] = @{ cliSac = 0; recTot = 0; compSac = 0; compRech = 0 } }
  if ($cho9) { $statsChofer[$cho9].cliSac++ }
  $bolComp = 0
  foreach ($fx in @($dcl.fac.Keys)) {
    $fiv = 0.0; if ($facImp.ContainsKey($fx)) { $fiv = $facImp[$fx] }
    $riv = 0.0; if ($refImp.ContainsKey($fx)) { $riv = $refImp[$fx] }
    if ($fiv -gt 0 -and $riv -ge (0.98 * $fiv)) { $bolComp++ }
  }
  if ($bolComp -ge $nBol) { $cliRechTot++; if ($cho9) { $statsChofer[$cho9].recTot++ } }
}
$cliEnt = $cliSac - $cliRechTot

$bolSac = 0; $bolCompTot = 0
foreach ($fx in @($facImp.Keys)) {
  $bolSac++
  $fiv = $facImp[$fx]
  $riv = 0.0; if ($refImp.ContainsKey($fx)) { $riv = $refImp[$fx] }
  $completa = ($fiv -gt 0 -and $riv -ge (0.98 * $fiv))
  if ($completa) { $bolCompTot++ }
  $choF = $facCho[$fx]
  if ($choF) {
    if (-not $statsChofer[$choF]) { $statsChofer[$choF] = @{ cliSac = 0; recTot = 0; compSac = 0; compRech = 0 } }
    $statsChofer[$choF].compSac++
    if ($completa) { $statsChofer[$choF].compRech++ }
  }
}
Log ("Clientes: $cliSac salieron, $cliEnt entregados. Boletas: $bolSac sacadas, $bolCompTot rechazadas completas")

foreach ($krf in @($choRefs.Keys)) {
  $ppk = $krf.Split("|"); $cho8 = $ppk[0]; $ref8 = $ppk[1]
  $fiv = 0.0; if ($facImp.ContainsKey($ref8)) { $fiv = $facImp[$ref8] }
  $riv = 0.0; if ($refImp.ContainsKey($ref8)) { $riv = $refImp[$ref8] }
  if (-not ($fiv -gt 0 -and $riv -ge (0.98 * $fiv))) { continue }
  $mot8 = $refMotivo[$krf]; if (-not $mot8) { $mot8 = "Sin especificar" }
  if (-not $motivosPorChofer[$cho8]) { $motivosPorChofer[$cho8] = @{} }
  if (-not $motivosPorChofer[$cho8][$mot8]) { $motivosPorChofer[$cho8][$mot8] = 0 }
  $motivosPorChofer[$cho8][$mot8]++
}
Log ("Motivos OK: " + ($motivos.Values | Measure-Object -Sum).Sum + " rechazos, " + $motivos.Count + " motivos, " + $motivosPorChofer.Count + " choferes con detalle")

# Top 8 por zona/vendedor (misma vara que el fletero: boleta COMPLETA, min 20 boletas)
function Top-Porcentaje($sacMap, $rechMap, $minBoletas) {
  $lista = foreach ($kk in @($sacMap.Keys)) {
    $sac = $sacMap[$kk].Count
    if ($sac -lt $minBoletas) { continue }
    $rech = 0
    if ($rechMap[$kk]) {
      foreach ($rf in @($rechMap[$kk].Keys)) {
        $fi = 0.0; if ($facImp.ContainsKey($rf)) { $fi = $facImp[$rf] }
        $ri = 0.0; if ($refImp.ContainsKey($rf)) { $ri = $refImp[$rf] }
        if ($fi -gt 0 -and $ri -ge (0.98 * $fi)) { $rech++ }
      }
      $rech = [math]::Min($rech, $sac)
    }
    if ($rech -eq 0) { continue }
    [PSCustomObject]@{ nombre = $kk; sac = $sac; rech = $rech; pct = [math]::Round(100.0 * $rech / $sac, 1) }
  }
  return @($lista | Sort-Object pct -Descending | Select-Object -First 8)
}
$anZonas = Top-Porcentaje $zonaSac $zonaRech 20
$anVend = Top-Porcentaje $vendSac $vendRech 20
$anClientes = @(foreach ($kk in @($cliRechAcum.Keys)) {
  $p = $kk.Split("|")
  [PSCustomObject]@{ nombre = $p[0]; loc = $p[1]; cantidad = $cliRechAcum[$kk].Count }
}) | Sort-Object cantidad -Descending | Select-Object -First 8
$anProveedores = @(foreach ($kp in @($provFact.Keys)) {
  $fv = $provFact[$kp]
  if ($fv -lt 1000000) { continue }
  $rv = 0.0; if ($provRech.ContainsKey($kp)) { $rv = $provRech[$kp] }
  [PSCustomObject]@{ nombre = $kp; fac = [math]::Round($fv); rech = [math]::Round($rv); pct = [math]::Round(100.0 * ($fv - $rv) / $fv, 1) }
}) | Sort-Object fac -Descending | Select-Object -First 8
$anImporte = [math]::Round($impRechTotal)
$anFacturado = [math]::Round($factTotal)
Log ("Analisis rechazos: " + $anZonas.Count + " zonas, " + $anVend.Count + " vendedores, " + $anClientes.Count + " clientes top, importe rechazado `$" + $anImporte)

# --- 7) Asistencia del mes (repartos / dias habiles lun-vie, tope 100%) ------
# Feriados NO se descuentan (mismo criterio que PPP/LP-Elebes: se compensan
# repartiendo otro dia). Se publican igual en window.__TP_DATA__.feriados
# por si el dia de mañana Lucas pide usarlos.
function HabilesDeMes($anio, $mes) {
  $dias = [DateTime]::DaysInMonth($anio, $mes)
  $n = 0
  for ($d = 1; $d -le $dias; $d++) {
    $dow = [int]([DateTime]::new($anio, $mes, $d)).DayOfWeek
    if ($dow -ge 1 -and $dow -le 5) { $n++ }
  }
  return $n
}
$habilesMes = HabilesDeMes $mesIniDt.Year $mesIniDt.Month
$asistCho = @{}
foreach ($cho in @($repartosCho.Keys)) {
  $asistCho[$cho] = [math]::Min(100, [math]::Round(100.0 * $repartosCho[$cho] / [math]::Max(1, $habilesMes)))
}

# --- Premios: PENDIENTE de definir con Lucas -> siempre 0 --------------------
function Calcular-Premio($efE, $efC, $asist) { return 0 }

# --- 8) Generar data.js -------------------------------------------------------
function NombreMostrar($chofer) {
  (($chofer.ToLower() -split "\s+") | ForEach-Object { if ($_.Length -gt 0) { $_.Substring(0,1).ToUpper() + $_.Substring(1) } }) -join " "
}
function JsonTxt($s) { return ([string]$s -replace '\\', '\\\\' -replace '"', "'") }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("/* GENERADO AUTOMATICAMENTE por robot-nube.ps1 (API Gescom, GitHub Actions) - NO EDITAR A MANO")
[void]$sb.AppendLine("   Ultima actualizacion: " + (Get-Date -Format "yyyy-MM-dd HH:mm") + " */")
[void]$sb.AppendLine("window.__TP_CONFIG__ = { SHEET_CSV_URL: '', umbrales: { bueno: 90, medio: 75 }, diasHistorial: 14 };")
[void]$sb.AppendLine("window.__TP_DATA__ = { registros: [")
$primero = $true
foreach ($clave in $claves) {
  $pcl = $clave.Split("|"); $fechaR = $pcl[0]; $choferR = $pcl[1]
  $ee = $entregas[$clave]
  $cc = $cartones[$clave]
  $ca = 0; $cr = 0
  if ($cc) { $ca = [int][math]::Round($cc.sal); $cr = [int][math]::Round($cc.vue) }
  $coma = ","; if ($primero) { $coma = " "; $primero = $false }
  $json = '{"fecha":"' + $fechaR + '","fletero":"' + (NombreMostrar $choferR) + '","zona":"",' +
    '"repartos":' + $ee.reps.Count + ',"entregas_asignadas":' + $ee.asig + ',"entregas_realizadas":' + $ee.real +
    ',"cartones_a_retornar":' + $ca + ',"cartones_retornados":' + $cr + '}'
  [void]$sb.AppendLine($coma + $json)
}
[void]$sb.AppendLine("] };")
$listaMot = @($motivos.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { '{"motivo":"' + (JsonTxt $_.Key) + '","cantidad":' + $_.Value + '}' })
[void]$sb.AppendLine("window.__TP_DATA__.motivos = [" + ($listaMot -join ",") + "];")
$listaFer = @($feriadosWeb | ForEach-Object { '"' + $_ + '"' }) -join ","
[void]$sb.AppendLine("window.__TP_DATA__.feriados = [" + $listaFer + "];")
$porFle = @(foreach ($cho in ($motivosPorChofer.Keys | Sort-Object)) {
  $lista = @($motivosPorChofer[$cho].GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { '{"motivo":"' + (JsonTxt $_.Key) + '","cantidad":' + $_.Value + '}' })
  '"' + (NombreMostrar $cho) + '":[' + ($lista -join ",") + ']'
})
[void]$sb.AppendLine("window.__TP_DATA__.motivosPorFletero = {" + ($porFle -join ",") + "};")
$itemsRechMes = @{}
foreach ($clave in $claves) {
  $choI = $clave.Split("|")[1]
  $eI = $entregas[$clave]
  if ($eI.itemsRech) { if (-not $itemsRechMes[$choI]) { $itemsRechMes[$choI] = 0.0 }; $itemsRechMes[$choI] += $eI.itemsRech }
}
$statsJson = @(foreach ($cho in ($statsChofer.Keys | Sort-Object)) {
  $sx = $statsChofer[$cho]
  $cs = 0; if ($sx.compSac) { $cs = $sx.compSac }
  $cr2 = 0; if ($sx.compRech) { $cr2 = $sx.compRech }
  $ri9 = 0; if ($choRechImp.ContainsKey($cho)) { $ri9 = [math]::Round($choRechImp[$cho]) }
  $iRech = 0; if ($itemsRechMes[$cho]) { $iRech = [int][math]::Round($itemsRechMes[$cho]) }
  $nRep = 0; if ($repartosCho[$cho]) { $nRep = $repartosCho[$cho] }
  '"' + (NombreMostrar $cho) + '":{"recTot":' + $sx.recTot + ',"recBol":' + $cr2 + ',"prodSuel":0,"itemsRech":' + $iRech +
    ',"impRech":' + $ri9 + ',"repartos":' + $nRep + ',"cliSac":' + $sx.cliSac + ',"cliEnt":' + ($sx.cliSac - $sx.recTot) +
    ',"compSac":' + $cs + ',"compEnt":' + ($cs - $cr2) + '}'
})
[void]$sb.AppendLine("window.__TP_DATA__.estadisticasFletero = {" + ($statsJson -join ",") + "};")
$jZonas = @($anZonas | ForEach-Object { '{"nombre":"' + (JsonTxt $_.nombre) + '","pct":' + (([string]$_.pct) -replace ",", ".") + ',"rech":' + $_.rech + ',"sac":' + $_.sac + '}' }) -join ","
$jVend = @($anVend | ForEach-Object { '{"nombre":"' + (JsonTxt $_.nombre) + '","pct":' + (([string]$_.pct) -replace ",", ".") + ',"rech":' + $_.rech + ',"sac":' + $_.sac + '}' }) -join ","
$jCli = @($anClientes | ForEach-Object { '{"nombre":"' + (JsonTxt $_.nombre) + '","loc":"' + (JsonTxt $_.loc) + '","cantidad":' + $_.cantidad + '}' }) -join ","
$jProv = @($anProveedores | ForEach-Object { '{"nombre":"' + (JsonTxt $_.nombre) + '","pct":' + (([string]$_.pct) -replace ",", ".") + '}' }) -join ","
[void]$sb.AppendLine('window.__TP_DATA__.analisisRechazos = {"importe":' + $anImporte + ',"facturado":' + $anFacturado + ',"zonas":[' + $jZonas + '],"vendedores":[' + $jVend + '],"clientes":[' + $jCli + '],"proveedores":[' + $jProv + ']};')
$porCho3 = @{}
foreach ($kcp in @($choProvFact.Keys)) {
  $pp3 = $kcp.Split("|"); $cho3 = $pp3[0]; $pr3 = $pp3[1]
  if ($cho3 -in $EXCLUIR) { continue }
  $fv = $choProvFact[$kcp]
  if ($fv -lt 100000) { continue }
  $rv = 0.0; if ($choProvRech.ContainsKey($kcp)) { $rv = $choProvRech[$kcp] }
  if (-not $porCho3[$cho3]) { $porCho3[$cho3] = New-Object System.Collections.ArrayList }
  [void]$porCho3[$cho3].Add([PSCustomObject]@{ prov = $pr3; fac = [math]::Round($fv); pct = [math]::Round(100.0 * ($fv - $rv) / $fv, 1) })
}
$jFleProv = @(foreach ($cho3 in ($porCho3.Keys | Sort-Object)) {
  $lst = @($porCho3[$cho3] | Sort-Object fac -Descending | Select-Object -First 6 | ForEach-Object { '{"prov":"' + (JsonTxt $_.prov) + '","pct":' + (([string]$_.pct) -replace ",", ".") + '}' })
  '"' + (NombreMostrar $cho3) + '":[' + ($lst -join ",") + ']'
})
[void]$sb.AppendLine("window.__TP_DATA__.proveedoresPorFletero = {" + ($jFleProv -join ",") + "};")

# --- Resumen del MES ANTERIOR (tarjeta de cierre de mes) ---------------------
$mB = 0; $mE = 0; $mR = 0; $mCA = 0; $mCR = 0
foreach ($clave in $claves) {
  $ee = $entregas[$clave]; $mB += $ee.asig; $mE += $ee.real; $mR += $ee.reps.Count
  $cc = $cartones[$clave]; if ($cc) { $mCA += $cc.sal; $mCR += $cc.vue }
}
$nFleteros = @($claves | ForEach-Object { $_.Split("|")[1] } | Sort-Object -Unique).Count
$hist = @{}
if (Test-Path $HIST_FILE) {
  try {
    $viejo = Get-Content $HIST_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($ph in $viejo.PSObject.Properties) { $hist[$ph.Name] = $ph.Value }
  } catch { Log "AVISO: no pude leer historial-meses.json, se regenera" }
}
$mesAntKey = ([DateTime]($mesActual + "-01")).AddMonths(-1).ToString("yyyy-MM")
$ma = $hist[$mesAntKey]
if ($ma) {
  $maEf = 0; if ($null -ne $ma.efGeneral) { $maEf = $ma.efGeneral }
  $maCarton = 0; if ($null -ne $ma.cartonGeneral) { $maCarton = $ma.cartonGeneral }
  $maBSac = 0; if ($null -ne $ma.boletasSac) { $maBSac = [int]$ma.boletasSac }
  $maBRech = 0; if ($null -ne $ma.boletasRech) { $maBRech = [int]$ma.boletasRech }
  $maCSac = 0; if ($null -ne $ma.clientesSac) { $maCSac = [int]$ma.clientesSac }
  $maCEnt = 0; if ($null -ne $ma.clientesEnt) { $maCEnt = [int]$ma.clientesEnt }
  $maPlata = 0; if ($null -ne $ma.plataRech) { $maPlata = [long]$ma.plataRech }
  $maReps = 0; if ($null -ne $ma.repartos) { $maReps = [int]$ma.repartos }
  $maFlet = 0; if ($null -ne $ma.fleteros) { $maFlet = [int]$ma.fleteros }
  $maPremios = 0; if ($null -ne $ma.premiosTotal) { $maPremios = [long]$ma.premiosTotal }
  $maMes = [int]$mesAntKey.Substring(5, 2); $maAnio = [int]$mesAntKey.Substring(0, 4)
  $maRank = @()
  if ($null -ne $ma.ranking) {
    foreach ($rk in @($ma.ranking)) {
      $rkAsist = 0; if ($null -ne $rk.asist) { $rkAsist = $rk.asist }
      $rkEfC = 0; if ($null -ne $rk.efC) { $rkEfC = $rk.efC }
      $rkPremio = 0; if ($null -ne $rk.premio) { $rkPremio = $rk.premio }
      $maRank += '{"nombre":"' + (JsonTxt $rk.nombre) + '","repartos":' + ([int]$rk.repartos) +
        ',"asist":' + (([string]$rkAsist) -replace ",", ".") + ',"efE":' + (([string]$rk.efE) -replace ",", ".") +
        ',"efC":' + (([string]$rkEfC) -replace ",", ".") + ',"premio":' + $rkPremio + '}'
    }
  }
  $maJson = '{"clave":"' + $mesAntKey + '","anio":' + $maAnio + ',"mes":' + $maMes +
    ',"efGeneral":' + (([string]$maEf) -replace ",", ".") + ',"cartonGeneral":' + (([string]$maCarton) -replace ",", ".") +
    ',"repartos":' + $maReps + ',"boletasEnt":' + ($maBSac - $maBRech) + ',"boletasSac":' + $maBSac +
    ',"clientesEnt":' + $maCEnt + ',"clientesSac":' + $maCSac + ',"plataRech":' + $maPlata +
    ',"premiosTotal":' + $maPremios + ',"fleteros":' + $maFlet + ',"ranking":[' + ($maRank -join ",") + ']}'
  [void]$sb.AppendLine("window.__TP_DATA__.mesAnterior = " + $maJson + ";")
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not $EN_NUBE) {
  $salidaPrueba = Join-Path $CARPETA_PROYECTO "robot\data-nube-prueba.js"
  [System.IO.File]::WriteAllText($salidaPrueba, $sb.ToString(), $utf8)
  Log "MODO PRUEBA LOCAL: data-nube-prueba.js generado, NO se publica"
  Log "================ FIN (NUBE) ================"
  exit 0
}
if ($env:FORCE_MES) {
  Log "FORCE_MES: solo se refresca el historial, no se reescribe data.js"
} else {
  [System.IO.File]::WriteAllText((Join-Path $CARPETA_PROYECTO "data.js"), $sb.ToString(), $utf8)
  Log "data.js generado"
}

# --- 9) Historial mensual (lo commitea el workflow) ---------------------------
$efGen = 0.0; if ($mB -gt 0) { $efGen = [math]::Round(100.0 * $mE / $mB, 1) }
$cartGen = 0.0; if ($mCA -gt 0) { $cartGen = [math]::Round(100.0 * $mCR / $mCA, 1) }
$flMes = @{}
foreach ($clave in $claves) {
  $choK = $clave.Split("|")[1]
  $eeK = $entregas[$clave]; $ccK = $cartones[$clave]
  if (-not $flMes[$choK]) { $flMes[$choK] = @{ reps = 0; bol = 0; ent = 0; cSal = 0.0; cVue = 0.0 } }
  $flMes[$choK].reps += $eeK.reps.Count
  $flMes[$choK].bol += $eeK.asig
  $flMes[$choK].ent += $eeK.real
  if ($ccK) { $flMes[$choK].cSal += $ccK.sal; $flMes[$choK].cVue += $ccK.vue }
}
$premiosTotalMes = 0
$rankFletero = @(foreach ($choK in $flMes.Keys) {
  $fk = $flMes[$choK]
  $efK = 0.0; if ($fk.bol -gt 0) { $efK = [math]::Round(100.0 * $fk.ent / $fk.bol, 1) }
  $efCK = 0.0; if ($fk.cSal -gt 0) { $efCK = [math]::Round(100.0 * $fk.cVue / $fk.cSal, 1) }
  $asistK = 0; if ($asistCho.ContainsKey($choK)) { $asistK = $asistCho[$choK] }
  $premioK = Calcular-Premio $efK $efCK $asistK
  $premiosTotalMes += $premioK
  [PSCustomObject]@{ nombre = (NombreMostrar $choK); repartos = $fk.reps; asist = $asistK; efE = $efK; efC = $efCK; premio = $premioK }
}) | Sort-Object efE -Descending
$esCierreFinal = $false
if ($env:FORCE_MES -and $repAbiertos -eq 0) { $esCierreFinal = $true }
$hEmp = @{ boletas = $mB; rechazadas = ($mB - $mE) }
$hist[$mesActual] = @{
  boletas = $mB; entregadas = $mE; repartos = $mR; efGeneral = $efGen
  boletasSac = $bolSac; boletasRech = $bolCompTot
  clientesSac = $cliSac; clientesEnt = $cliEnt
  cartonGeneral = $cartGen; cartonesSacados = $mCA; cartonesVueltos = $mCR
  plataRech = [long]$anImporte; premiosTotal = $premiosTotalMes; fleteros = $nFleteros
  ranking = $rankFletero
  cierreFinal = $esCierreFinal
  actualizado = (Get-Date -Format "yyyy-MM-dd")
}
if ($env:FORCE_MES) {
  if ($esCierreFinal) { Log "Mes $mesActual marcado como CIERRE FINAL (todos los camiones cerrados)" }
  else { Log "Mes $mesActual refrescado (aun $repAbiertos camiones sin cerrar; se reintentara)" }
}
[System.IO.File]::WriteAllText($HIST_FILE, ($hist | ConvertTo-Json -Depth 6), $utf8)
Log "Historial mensual actualizado ($mesActual)"
Log "================ FIN (NUBE) ================"
