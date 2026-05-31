# SISTEMA DE DESPLIEGUE WEB AUTÓNOMO V7.1 (EDICIÓN GITHUB DE ALTA DISPONIBILIDAD)
$OutputEncoding = [System.Text.Encoding]::UTF8

Clear-Host

# Verificar privilegios de Administrador
$Identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "[-] Este asistente requiere ejecutarse como Administrador."
    Write-Host "[!] Por favor, abra PowerShell como Administrador y vuelva a intentarlo." -ForegroundColor Yellow
    exit
}

Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "   INSTALADOR DE ENTORNOS DESDE GITHUB V7.1" -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Yellow

$Empresa = ""
while ([string]::IsNullOrWhiteSpace($Empresa)) {
    $Empresa = Read-Host "[?] Ingrese el NOMBRE DE LA EMPRESA"
}

$EquipoNom = ""
while ([string]::IsNullOrWhiteSpace($EquipoNom)) {
    $EquipoNom = Read-Host "[?] Ingrese el NOMBRE DEL EQUIPO (Asignado)"
}

Write-Host "`n==================================================" -ForegroundColor Yellow
Write-Host "   MODO DE EJECUCION" -ForegroundColor White
Write-Host " 1) Diario (hora aleatoria entre 9:00 y 12:00)"
Write-Host " 2) Al iniciar el PC (maximo 1 vez al dia)"
Write-Host "==================================================" -ForegroundColor Yellow

$ModoEjecucion = ""
while ($ModoEjecucion -notmatch "^[12]$") {
    $ModoEjecucion = Read-Host "[?] Seleccione una opcion [1-2]"
}

# CONFIGURACIÓN ESTRICTA DE RUTAS LOCALES
$DirectorioDestino = "$env:SystemRoot\Setup\Scripts"
$RutaConfigJson    = "$DirectorioDestino\config.json"
$RutaActualizador  = "$DirectorioDestino\Actualizador.ps1"

# ENDPOINT RAW DEL REPOSITORIO EN GITHUB
$UrlBase = "https://raw.githubusercontent.com/joseimportantes-bit/ReporteRemoto/main"

if (-not (Test-Path $DirectorioDestino)) {
    New-Item -ItemType Directory -Path $DirectorioDestino -Force | Out-Null
}

# CONTROL DE PROCESOS ACTIVOS (CRITERIO DEFENSIVO)
Write-Host "`n[*] Verificando que no existan instancias activas del agente..." -ForegroundColor Cyan
$ProcesosActivos = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*reporteClientes.ps1*" -or $_.CommandLine -like "*Actualizador.ps1*"
}

if ($ProcesosActivos) {
    Write-Host "[!] Alerta: Se detecto un escaneo medico en ejecucion. Deteniendo proceso..." -ForegroundColor Yellow
    foreach ($Proc in $ProcesosActivos) {
        Stop-Process -Id $Proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    Write-Host "[OK] Instancias previas finalizadas de forma segura." -ForegroundColor Green
} else {
    Write-Host "[OK] Archivos libres. Ningun proceso concurrente detectado." -ForegroundColor Green
}

try {
    $SerialUUID = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID
    $ID_Corto   = if ($SerialUUID) { $SerialUUID.Substring(0, 8).ToUpper() } else { "NODATA00" }
} catch {
    $ID_Corto = "ERROR_ID"
}

$ApiKey = [Guid]::NewGuid().ToString()

$ConfigObject = @{
    ID_Corto       = $ID_Corto
    Empresa        = $Empresa.Trim().ToUpper()
    Equipo         = $EquipoNom.Trim().ToUpper()
    api_key        = $ApiKey
    modo_ejecucion = $ModoEjecucion
}
$ConfigObject | ConvertTo-Json | Out-File -FilePath $RutaConfigJson -Encoding utf8 -Force

# DESCARDA DE ARCHIVOS DESDE GITHUB
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1. Descargar version.txt
Write-Host "`n[*] Descargando version.txt desde GitHub..." -ForegroundColor Cyan
try {
    $VersionRemota = Invoke-RestMethod "$UrlBase/version.txt" -Method Get -TimeoutSec 15
    $VersionRemota.Trim() | Out-File "$DirectorioDestino\version.txt" -Encoding utf8 -Force
    Write-Host "[OK] version.txt descargado." -ForegroundColor Green
} catch {
    Write-Error "[-] Error critico de red: $_"; exit
}

# 2. Descargar Actualizador.ps1
Write-Host "[*] Descargando Actualizador.ps1 desde GitHub..." -ForegroundColor Cyan
try {
    $ActualizadorCodigo = Invoke-RestMethod "$UrlBase/Actualizador.ps1" -Method Get -TimeoutSec 20
    $ActualizadorCodigo | Out-File "$DirectorioDestino\Actualizador.ps1" -Encoding utf8 -Force
    Write-Host "[OK] Actualizador.ps1 descargado." -ForegroundColor Green
} catch {
    Write-Error "[-] Error critico de red: $_"; exit
}

# 3. Descargar reporteClientes.ps1 con control de integridad
Write-Host "[*] Descargando reporteClientes.ps1 desde GitHub..." -ForegroundColor Cyan
try {
    $CodigoAgente = Invoke-RestMethod "$UrlBase/reporteClientes.ps1" -Method Get -TimeoutSec 20
} catch {
    Write-Error "[-] Error critico de red: GitHub rechazo la conexion o el archivo no es accesible: $_"; exit
}

if (-not [string]::IsNullOrWhiteSpace($CodigoAgente) -and $CodigoAgente -match "SISTEMA DE ALERTAS") {
    $CodigoAgente | Out-File "$DirectorioDestino\reporteClientes.ps1" -Encoding utf8 -Force
    Write-Host "[OK] reporteClientes.ps1 descargado y verificado." -ForegroundColor Green
} else {
    Write-Error "[-] Error de integridad: El archivo de GitHub no coincide con la firma del agente maestro."; exit
}

# CONTROL DE TAREAS PROGRAMADAS
$NombreTarea = "Sistemas\AlertaTemprana"

function Registrar-TareaAlerta {
    param([object]$Trigger)
    $ArgumentosCmd = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$RutaActualizador"""
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $ArgumentosCmd
    $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $NombreTarea -Trigger $Trigger -Action $Action -Principal $Principal -Settings $Settings -Force | Out-Null
}

# Crear semilla de ultimo_ejecucion.txt para modo inicio
if ($ModoEjecucion -eq "2" -and -not (Test-Path "$DirectorioDestino\ultimo_ejecucion.txt")) {
    "2000-01-01" | Out-File "$DirectorioDestino\ultimo_ejecucion.txt" -Encoding utf8 -Force
}

$TareaExiste = Get-ScheduledTask -TaskName $NombreTarea -ErrorAction SilentlyContinue
if ($TareaExiste) {
    $AccionActual = if ($TareaExiste.Actions.Arguments) { $TareaExiste.Actions.Arguments } else { "" }
    if ($AccionActual -like "*reporteClientes.ps1*") {
        Write-Host "[!] Tarea antigua detectada (apuntaba directo al agente). Actualizando al actualizador..." -ForegroundColor Yellow
        if ($ModoEjecucion -eq "2") {
            $Trigger = New-ScheduledTaskTrigger -AtStartup
            $MensajeHora = "al iniciar el PC"
        } else {
            $HoraBase = Get-Date "09:00"
            $MinutosAleatorios = Get-Random -Minimum 0 -Maximum 180
            $HoraTarea = $HoraBase.AddMinutes($MinutosAleatorios)
            $Trigger = New-ScheduledTaskTrigger -Daily -At $HoraTarea.ToString("HH:mm")
            $MensajeHora = "a las $($HoraTarea.ToString('HH:mm'))"
        }
        try {
            Registrar-TareaAlerta -Trigger $Trigger
            Write-Host "[OK] Tarea reprogramada $MensajeHora." -ForegroundColor Green
        } catch {
            Write-Warning "[-] No se pudo actualizar la tarea en el programador nativo."
        }
    } else {
        Write-Host "[OK] La tarea programada '$NombreTarea' ya apunta al actualizador. Omitiendo." -ForegroundColor Green
    }
} else {
    Write-Host "[*] Configurando tarea diaria automatica en el Programador de Windows..." -ForegroundColor Cyan
    try {
        if ($ModoEjecucion -eq "2") {
            $Trigger = New-ScheduledTaskTrigger -AtStartup
            $MensajeHora = "al iniciar el PC"
        } else {
            $HoraBase = Get-Date "09:00"
            $MinutosAleatorios = Get-Random -Minimum 0 -Maximum 180
            $HoraTarea = $HoraBase.AddMinutes($MinutosAleatorios)
            $Trigger = New-ScheduledTaskTrigger -Daily -At $HoraTarea.ToString("HH:mm")
            $MensajeHora = "a las $($HoraTarea.ToString('HH:mm'))"
        }
        Registrar-TareaAlerta -Trigger $Trigger
        Write-Host "[OK] Tarea diaria asignada $MensajeHora." -ForegroundColor Green
    } catch {
        Write-Warning "[-] No se pudo registrar la tarea en el programador nativo."
    }
}

# INICIALIZACIÓN COMPLETA
Write-Host "`n[*] Forzando primera ejecucion del agente para poblar la infraestructura..." -ForegroundColor Cyan
if (Test-Path $RutaActualizador) {
    & $RutaActualizador -AccionFlasheada "MONITOREO"
    Write-Host "[OK] Ficha tecnica e historial medico inicializados en la nube." -ForegroundColor Green
}

Write-Host "==================================================" -ForegroundColor Yellow
Write-Host " DESPLIEGUE DESDE GITHUB COMPLETADO DE FORMA EXITOSA" -BackgroundColor DarkCyan -ForegroundColor White
Write-Host " ID DE RASTREO ASIGNADO: $ID_Corto" -ForegroundColor White
Write-Host "==================================================" -ForegroundColor Yellow
