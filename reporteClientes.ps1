# =========================================================================
# SISTEMA DE ALERTAS TEMPRANAS Y BITÁCORA DE TALLER MAESTRA V6.0
# AUTOR: JOSE OROZCO | INFRAESTRUCTURA DE ALTA DISPONIBILIDAD GITHUB RAW
# =========================================================================
param (
    [string]$AccionFlasheada = "MONITOREO",
    
    # PARÁMETROS PARA INTERCEPTAR CONTROL MANUAL DESDE EL ASISTENTE DEL SSD
    [string]$AccionTaller,
    [string]$DetalleTaller
)

$OutputEncoding = [System.Text.Encoding]::UTF8

# =========================================================================
# MODULO DE AUTO-ACTUALIZACION SILENCIOSA (GITHUB RAW - V6.2 CORREGIDA)
# =========================================================================
$UrlScriptRemoto  = "https://raw.githubusercontent.com/joseimportantes-bit/ReporteRemoto/main/reporteClientes.ps1"
$RutaLocalScript  = $MyInvocation.MyCommand.Path

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $CodigoRemoto = Invoke-RestMethod -Uri $UrlScriptRemoto -Method Get -TimeoutSec 15
    
    if (-not [string]::IsNullOrWhiteSpace($CodigoRemoto) -and $CodigoRemoto -match "SISTEMA DE ALERTAS") {
        $CodigoLocal = Get-Content -Path $RutaLocalScript -Raw
        
        # NORMALIZACIÓN TÉCNICA: Removemos espacios y saltos de línea para una comparación limpia
        $RemotoLimpio = $CodigoRemoto -replace '\s+', ''
        $LocalLimpio  = $CodigoLocal  -replace '\s+', ''
        
        # Si el contenido real cambió en GitHub, aplicamos el parche en caliente
        if ($RemotoLimpio -ne $LocalLimpio) {
            # Guardamos forzando codificación UTF-8 pura
            $CodigoRemoto | Out-File -FilePath $RutaLocalScript -Encoding utf8 -Force
            
            # Lanzamos la instancia de aviso y cerramos la vieja
            powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$RutaLocalScript" -AccionFlasheada "ACTUALIZACION"
            exit
        }
    }
} catch {
    # Absorción defensiva: Continúa localmente si falla la red
}

# =========================================================================

# 1. CARGAR CONFIGURACIÓN LOCAL (Firma de identidad sembrada por el instalador)
$RutaConfigJson = "$env:SystemRoot\Setup\Scripts\config.json"
if (Test-Path $RutaConfigJson) {
    $Config = Get-Content -Path $RutaConfigJson -Raw | ConvertFrom-Json
    $ID_Corto = $Config.ID_Corto.ToString().ToUpper()
    $Empresa  = $Config.Empresa.ToString().ToUpper()
    $Equipo   = $Config.Equipo.ToString().ToUpper()
} else {
    $ID_Corto = "DESCONOCIDO"; $Empresa = "GENERICO"; $Equipo = "GENERICO"
}

# 2. EXTRACCIÓN DE HARDWARE (Mapeo lógico de Workstation)
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

# 3. PROCESAMIENTO E INDEXACIÓN PARA SUS 4 DISCOS FÍSICOS
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

# 4. EJECUCIÓN DE MONITORES DE SÍNTOMAS DIARIOS (10:00 AM)
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
# 5. EMBUDO INTERCEPTOR: MONITOREO AUTOMÁTICO VS REGISTRO DE ASISTENTE SSD
# =========================================================================
$UrlGoogleSheet = "https://script.google.com/macros/s/AKfycbymkchj7VEC1Ik4d843O3YF-NnDapFe6wKfACEn4aXptIiilZ1wW9__AkCWY6hLoCqv/exec"

$AccionAuditoria = $AccionFlasheada
$StringDetalles  = "Escaneo completado sin novedades."

# Si pasas parámetros desde el script del SSD, destruye el flujo automático y clava tus notas
if (-not [string]::IsNullOrWhiteSpace($AccionTaller)) {
    $AccionAuditoria = $AccionTaller.Trim().ToUpper()
    $StringDetalles  = if (-not [string]::IsNullOrWhiteSpace($DetalleTaller)) { $DetalleTaller.Trim() } else { "Servicio tecnico ejecutado en taller." }
} else {
    # Flujo por defecto de la tarea programada diaria
    if ($HuboFalla) {
        $AccionAuditoria = "NOVEDAD"
        $StringDetalles  = $DetallesNovedad -join " | "
    } elseif ($AccionAuditoria -eq "ACTUALIZACION") {
        $StringDetalles  = "El agente aplico un parche de codigo en caliente desde GitHub con exito."
    }
}

# Construcción unificada del paquete JSON
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

# Envío directo hacia la Web App (Alineación exacta de 12 columnas en Inventario)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-RestMethod -Uri $UrlGoogleSheet -Method Post -Body $PayloadUnificado -ContentType "application/json" -TimeoutSec 15 | Out-Null
} catch {}
# =========================================================================



# COMENTARIO DE PRUEBA LOCAL 12345 
# Prueba de Actaulizacion en caliente 67890
# Prueba de Actualizacion en caliente 2:44 am, 01/01/2025
# COMENTARIO DE PRUEBA LOCAL 6789
# Version 6.2 - Verificada