# SISTEMA DE DESPLIEGUE MINIMALISTA INTELIGENTE V5.1
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
Write-Host "   CONFIGURACION DE CLIENTE Y ENTORNO V5.1" -ForegroundColor Yellow
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

$DirectorioDestino = "$env:SystemRoot\Setup\Scripts"
$RutaConfigJson    = "$DirectorioDestino\config.json"
$RutaActualizador  = "$DirectorioDestino\Actualizador.ps1"
$NombreTarea = "Sistemas\AlertaTemprana"

if (-not (Test-Path $DirectorioDestino)) {
    New-Item -ItemType Directory -Path $DirectorioDestino -Force | Out-Null
}

try {
    $SerialUUID = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID
    $ID_Corto   = if ($SerialUUID) { $SerialUUID.Substring(0, 8).ToUpper() } else { "NODATA00" }
} catch {
    $ID_Corto = "ERROR_ID"
}

# CONTROL DE PROCESOS ACTIVOS (CRITERIO DEFENSIVO)
Write-Host "`n[*] Verificando que no existan instancias activas del agente..." -ForegroundColor Cyan
$ProcesosActivos = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*reporteClientes.ps1*" -or $_.CommandLine -like "*Actualizador.ps1*"
}
if ($ProcesosActivos) {
    Write-Host "[!] Alerta: Se detecto una ejecucion en curso. Deteniendo proceso..." -ForegroundColor Yellow
    foreach ($Proc in $ProcesosActivos) {
        Stop-Process -Id $Proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    Write-Host "[OK] Instancias previas finalizadas de forma segura." -ForegroundColor Green
} else {
    Write-Host "[OK] Archivos libres. Ningun proceso concurrente detectado." -ForegroundColor Green
}

$ApiKey = [Guid]::NewGuid().ToString()

# 1. Crear o actualizar JSON persistente de identificadores locales
$ConfigObject = @{
    ID_Corto       = $ID_Corto
    Empresa        = $Empresa.Trim().ToUpper()
    Equipo         = $EquipoNom.Trim().ToUpper()
    api_key        = $ApiKey
    modo_ejecucion = $ModoEjecucion
}
$ConfigObject | ConvertTo-Json | Out-File -FilePath $RutaConfigJson -Encoding utf8 -Force

# 2. Desplegar los 3 archivos del sistema
Write-Host "[*] Sembrando agente, actualizador y version en el equipo..." -ForegroundColor Cyan

foreach ($Archivo in @("reporteClientes.ps1", "Actualizador.ps1", "version.txt")) {
    $RutaOrigen = Join-Path $PSScriptRoot $Archivo
    $RutaDestino = Join-Path $DirectorioDestino $Archivo
    if (Test-Path $RutaOrigen) {
        Copy-Item -Path $RutaOrigen -Destination $RutaDestino -Force
        Write-Host "[OK] $Archivo copiado." -ForegroundColor Green
    } else {
        Write-Error "[-] No se encontro '$Archivo' en la ruta de origen."; exit
    }
}

# 3. CONTROL INTELIGENTE DE TAREAS PROGRAMADAS

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
            Write-Warning "[-] No se pudo actualizar la tarea programada."
        }
    } else {
        Write-Host "[OK] La tarea programada '$NombreTarea' ya apunta al actualizador. Omitiendo reprogramacion." -ForegroundColor Green
    }
} else {
    Write-Host "[*] Registrando nueva tarea programada bajo la cuenta SYSTEM..." -ForegroundColor Cyan
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
        Write-Host "[OK] Tarea programada registrada $MensajeHora." -ForegroundColor Green
    } catch {
        Write-Warning "[-] No se pudo registrar la tarea programada."
    }
}

# 4. FORZAR LOGICA COMPLETA DESDE EL ACTUALIZADOR
Write-Host "`n[*] Inicializando ejecucion medica y sincronizacion en la nube..." -ForegroundColor Cyan

if (Test-Path $RutaActualizador) {
    & $RutaActualizador -AccionFlasheada "MONITOREO"
    Write-Host "[OK] Sincronizacion procesada correctamente." -ForegroundColor Green
}

Write-Host "==================================================" -ForegroundColor Yellow
Write-Host " DESPLIEGUE PROCESADO CON CRITERIO DEFENSIVO" -BackgroundColor DarkCyan -ForegroundColor White
Write-Host " ID ASIGNADO: $ID_Corto" -ForegroundColor White
Write-Host "==================================================" -ForegroundColor Yellow
