# SISTEMA DE ALERTAS TEMPRANAS Y BITÁCORA DE TALLER V4.0
param (
    [string]$AccionFlasheada = "MONITOREO",
    
    # NUEVOS PARÁMETROS PARA CONTROL MANUAL DESDE EL ASISTENTE DEL SSD
    [string]$AccionTaller,
    [string]$DetalleTaller
)

$OutputEncoding = [System.Text.Encoding]::UTF8

# =========================================================================
# MODULO DE AUTO-ACTUALIZACION SILENCIOSA (CONTENEDOR ZIP REMOTE)
# =========================================================================
$IdArchivoDrive   = "12s39PHkRV3R5Jf03G7aEWfRe7Sb1j4Cy"
$UrlScriptRemoto  = "https://docs.google.com/uc?id=$IdArchivoDrive&export=download"
$RutaLocalScript  = $MyInvocation.MyCommand.Path

$RutaTempZipUpdate = "$env:TEMP\update_agente.zip"
$FolderTempUpdate  = "$env:TEMP\UpdateAgenteExtract"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $UrlScriptRemoto -OutFile $RutaTempZipUpdate -TimeoutSec 20 -ErrorAction SilentlyContinue
    
    if (Test-Path $RutaTempZipUpdate) {
        if (Test-Path $FolderTempUpdate) { Remove-Item -Path $FolderTempUpdate -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive -Path $RutaTempZipUpdate -DestinationPath $FolderTempUpdate -Force -ErrorAction SilentlyContinue
        $RutaScriptUnzipped = Join-Path $FolderTempUpdate "reporteClientes.ps1"
        
        if (Test-Path $RutaScriptUnzipped) {
            $CodigoRemoto = Get-Content -Path $RutaScriptUnzipped -Raw
            if ($CodigoRemoto -match "SISTEMA DE ALERTAS") {
                $CodigoLocal = Get-Content -Path $RutaLocalScript -Raw
                if ($CodigoRemoto -ne $CodigoLocal) {
                    $CodigoRemoto | Out-File -FilePath $RutaLocalScript -Encoding utf8 -Force
                    Remove-Item -Path $RutaTempZipUpdate -Force -ErrorAction SilentlyContinue
                    Remove-Item -Path $FolderTempUpdate -Recurse -Force -ErrorAction SilentlyContinue
                    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$RutaLocalScript" -AccionFlasheada "ACTUALIZACION"
                    exit
                }
            }
        }
    }
} catch {} finally {
    if (Test-Path $RutaTempZipUpdate) { Remove-Item -Path $RutaTempZipUpdate -Force -ErrorAction SilentlyContinue }
    if (Test-Path $FolderTempUpdate) { Remove-Item -Path $FolderTempUpdate -Recurse -Force -ErrorAction SilentlyContinue }
}
# =========================================================================

# 1. CARGAR CONFIGURACION LOCAL
$RutaConfigJson = "$env:SystemRoot\Setup\Scripts\config.json"
if (Test-Path $RutaConfigJson) {
    $Config = Get-Content -Path $RutaConfigJson -Raw | ConvertFrom-Json
    $ID_Corto = $Config.ID_Corto.ToString().ToUpper()
    $Empresa  = $Config.Empresa.ToString().ToUpper()
    $Equipo   = $Config.Equipo.ToString().ToUpper()
} else {
    $ID_Corto = "DESCONOCIDO"; $Empresa = "GENERICO"; $Equipo = "GENERICO"
}

# 2. EXTRACCION DE HARDWARE COMPLETA (INVENTARIO DINAMICO)
try {
    $NombreRed = $env:COMPUTERNAME
    $ProcInfo = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Name
    $ProcLimpio = ($ProcInfo -replace '\s+', ' ').Trim()
    $RamBytes = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
    $RamGB = [Math]::Round($RamBytes / 1GB)
    $OSLimpio = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    $CompSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $ModeloBase = "$($CompSystem.Manufacturer) $($CompSystem.Model)".Trim()
} catch {
    $NombreRed = "ERROR"; $ProcLimpio = "ERROR"; $RamGB = 0; $OSLimpio = "ERROR"; $ModeloBase = "ERROR"
}

$ListaDiscosProcesados = @()
try {
    $DiscosFisicos = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue
    foreach ($Disco in $DiscosFisicos) {
        $Index = $Disco.Index
        $Modelo = $Disco.Model.Trim()
        $CapacidadGB = [Math]::Round($Disco.Size / 1GB)
        $TipoMedio = "HDD"
        $DiskTypeQuery = Get-PhysicalDisk -DeviceNumber $Index -ErrorAction SilentlyContinue
        if ($DiskTypeQuery -and $DiskTypeQuery.MediaType -eq "SSD") { $TipoMedio = "SSD" }
        $ListaDiscosProcesados += "[$TipoMedio] $Modelo ($CapacidadGB GB)"
    }
} catch { $ListaDiscosProcesados += "ERROR_LECTURA" }

# 3. EJECUCION DE MONITORES DE FALLAS DIARIOS
$HuboFalla = $false
$DetallesNovedad = @()

function Limpiar-Texto ($TextoOriginal) {
    if ([string]::IsNullOrEmpty($TextoOriginal)) { return "" }
    $TextoLimpio = $TextoOriginal.Normalize([System.Text.NormalizationForm]::FormD)
    $TargetStr   = New-Object System.Text.StringBuilder
    foreach ($Char in $TextoLimpio.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($Char) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$TargetStr.Append($Char)
        }
    }
    return ($TargetStr.ToString() -replace '[^a-zA-Z0-9\s\.\,\:\-\[\]\(\)\/\=\*\#\_]', '')
}

try {
    $StatusSMART = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue
    $EstadisticasVida = Get-CimInstance -ClassName MSFT_StorageReliabilityCounter -Namespace root\Microsoft\Windows\Storage -ErrorAction SilentlyContinue
    $MapeoParticiones = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue

    foreach ($DiscoHardware in $MapeoParticiones) {
        $ModeloText = Limpiar-Texto $DiscoHardware.Model
        $IndexID = $DiscoHardware.Index

        if ($null -ne $StatusSMART) {
            $SmartTarget = $StatusSMART | Where-Object { $_.InstanceName -like "*_$IndexID" -or $_.InstanceName -like "*$IndexID" }
            if ($SmartTarget -and $SmartTarget.PredictFailure) {
                $HuboFalla = $true; $DetallesNovedad += "[FALLA S.M.A.R.T.] Disco $IndexID ($ModeloText)"
            }
        }
        if ($null -ne $EstadisticasVida) {
            $ContadorAsociado = $EstadisticasVida | Where-Object { ($null -ne $_.DeviceId -and [string]$_.DeviceId -eq [string]$IndexID) -or ($_.ObjectId -like "*Disk$IndexID*") }
            $ContadorFinal = if ($ContadorAsociado -is [array]) { $ContadorAsociado[0] } else { $ContadorAsociado }
            if ($ContadorFinal -and ($null -ne $ContadorFinal.WearLevel)) {
                $SaludCalculada = 100 - $ContadorFinal.WearLevel
                if ($SaludCalculada -lt 70) { 
                    $HuboFalla = $true; $DetallesNovedad += "[DESGASTE CRITICO] Disco $IndexID Salud: $SaludCalculada%"
                }
            }
        }
    }
} catch {}

try {
    $DiscoC = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    if ($DiscoC -and $DiscoC.Size -gt 0) {
        $PorcentajeLibre = [Math]::Round(($DiscoC.FreeSpace / $DiscoC.Size) * 100)
        if ($PorcentajeLibre -lt 10) {
            $HuboFalla = $true; $DetallesNovedad += "[ESPACIO BAJO] C: tiene solo el $PorcentajeLibre% libre."
        }
    }
} catch {}

try {
    $TiempoLimite = (Get-Date).AddDays(-1)
    $EventosCriticos = Get-WinEvent -LogName System -FilterHashtable @{ Id = 41, 6008; StartTime = $TiempoLimite } -ErrorAction SilentlyContinue
    if ($EventosCriticos) {
        $HuboFalla = $true; $DetallesNovedad += "[APAGADO FORZADO] Se detectaron $($EventosCriticos.Count) caidas electricas."
    }
} catch {}

# =========================================================================
# 4. MUTACIÓN DEL PAYLOAD: MONITOREO DIARIO AUTOMATICO VS MANUAL DE TALLER
# =========================================================================
$UrlGoogleSheet = "https://script.google.com/macros/s/AKfycbymkchj7VEC1Ik4d843O3YF-NnDapFe6wKfACEn4aXptIiilZ1wW9__AkCWY6hLoCqv/exec"

# Comportamiento por defecto (Ejecución Diaria Automática)
$AccionAuditoria = $AccionFlasheada
$StringDetalles  = "Escaneo completado sin novedades."

# FUNNEL INTERCEPTOR: Si le pasas parámetros desde RegistrarServicio.ps1, se reescribe el log
if (-not [string]::IsNullOrWhiteSpace($AccionTaller)) {
    $AccionAuditoria = $AccionTaller.Trim().ToUpper()
    $StringDetalles  = if (-not [string]::IsNullOrWhiteSpace($DetalleTaller)) { $DetalleTaller.Trim() } else { "Servicio tecnico ejecutado en taller." }
} else {
    # Si no hay parámetros manuales, aplica las reglas del motor de fallas diario
    if ($HuboFalla) {
        $AccionAuditoria = "NOVEDAD"
        $StringDetalles  = $DetallesNovedad -join " | "
    } elseif ($AccionAuditoria -eq "ACTUALIZACION") {
        $StringDetalles  = "El agente aplico un parche de codigo en caliente desde un contenedor ZIP con exito."
    }
}

# Armado final unificado del JSON
$PayloadUnificado = @{
    id_corto   = $ID_Corto
    empresa    = $Empresa
    equipo     = $Equipo
    fecha      = (Get-Date -Format 'yyyy-MM-dd')
    hora       = (Get-Date -Format 'HH:mm:ss')
    accion     = $AccionAuditoria
    detalles   = $StringDetalles
    hardware   = @{
        nombre_red        = $NombreRed.ToUpper()
        procesador        = $ProcLimpio
        ram_gb            = $RamGB
        sistema_operativo = $OSLimpio
        modelo_base       = $ModeloBase
        discos            = $ListaDiscosProcesados
    }
} | ConvertTo-Json -Compress

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-RestMethod -Uri $UrlGoogleSheet -Method Post -Body $PayloadUnificado -ContentType "application/json" -TimeoutSec 15 | Out-Null
} catch {}
# =========================================================================