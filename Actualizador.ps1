# ACTUALIZADOR Y LANZADOR DEL SISTEMA DE ALERTAS TEMPRANAS V1.1
param(
    [string]$AccionFlasheada = "MONITOREO"
)

$OutputEncoding = [System.Text.Encoding]::UTF8
$ScriptVersion = "1.3.0"
$NombreTarea = "Sistemas\AlertaTemprana"

$Destino = "$env:SystemRoot\Setup\Scripts"
$UrlBase = "https://raw.githubusercontent.com/joseimportantes-bit/ReporteRemoto/main"
$RutaVer = "$Destino\version.txt"
$RutaAgente = "$Destino\reporteClientes.ps1"
$RutaUltimo = "$Destino\ultimo_ejecucion.txt"
$RutaConfig = "$Destino\config.json"

function Registrar-TareaAlerta {
    param([object]$Trigger)
    $ArgumentosCmd = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$Destino\Actualizador.ps1"""
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $ArgumentosCmd
    $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $NombreTarea -Trigger $Trigger -Action $Action -Principal $Principal -Settings $Settings -Force | Out-Null
}

# =========================================================================
# VERIFICACION DE ACTUALIZACION (siempre corre)
# =========================================================================
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $VerRemoto = (Invoke-RestMethod "$UrlBase/version.txt" -TimeoutSec 15).Trim()
    $VerLocal = (Get-Content $RutaVer -Raw).Trim()

    if ($VerRemoto -ne $VerLocal) {
        $Codigo = Invoke-RestMethod "$UrlBase/reporteClientes.ps1" -TimeoutSec 20
        if ($Codigo -match "SISTEMA DE ALERTAS") {
            $Codigo | Out-File $RutaAgente -Encoding utf8 -Force
            $VerRemoto | Out-File $RutaVer -Encoding utf8 -Force
        }
    }
} catch {
    # Absorción defensiva: continúa con la versión local si falla la red
}

# =========================================================================
# RECONFIGURACION DE MODO DE EJECUCION (si cambió desde el sheet)
# =========================================================================
if (Test-Path $RutaConfig) {
    $Config = Get-Content $RutaConfig -Raw | ConvertFrom-Json
    $ModoDeseado = $Config.modo_ejecucion
    if ($ModoDeseado -eq "1" -or $ModoDeseado -eq "2") {
        $Tarea = Get-ScheduledTask -TaskName $NombreTarea -ErrorAction SilentlyContinue
        if ($Tarea -and $Tarea.Triggers) {
            $EsInicio = $Tarea.Triggers[0].StartBoundary -eq $null -and $Tarea.Triggers[0].Enabled
            $ModoActual = if ($EsInicio) { "2" } else { "1" }
            if ($ModoActual -ne $ModoDeseado) {
                Unregister-ScheduledTask -TaskName $NombreTarea -Confirm:$false
                if ($ModoDeseado -eq "2") {
                    $Trigger = New-ScheduledTaskTrigger -AtStartup
                } else {
                    $HoraBase = Get-Date "09:00"
                    $Min = Get-Random -Minimum 0 -Maximum 180
                    $Trigger = New-ScheduledTaskTrigger -Daily -At ($HoraBase.AddMinutes($Min).ToString("HH:mm"))
                }
                Registrar-TareaAlerta -Trigger $Trigger
            }
        }
    }
}

# =========================================================================
# CONTROL DE EJECUCION DIARIA (evita multiples envios en modo inicio)
# =========================================================================
$Hoy = Get-Date -Format "yyyy-MM-dd"
if (Test-Path $RutaUltimo) {
    $Ultimo = (Get-Content $RutaUltimo -Raw).Trim()
    if ($Ultimo -eq $Hoy) {
        exit
    }
}
$Hoy | Out-File $RutaUltimo -Encoding utf8 -Force

& $RutaAgente -AccionFlasheada $AccionFlasheada
