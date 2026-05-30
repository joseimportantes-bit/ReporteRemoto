# ACTUALIZADOR Y LANZADOR DEL SISTEMA DE ALERTAS TEMPRANAS V1.0
param(
    [string]$AccionFlasheada = "MONITOREO"
)

$OutputEncoding = [System.Text.Encoding]::UTF8

$Destino = "$env:SystemRoot\Setup\Scripts"
$UrlBase = "https://raw.githubusercontent.com/joseimportantes-bit/ReporteRemoto/main"
$RutaVer = "$Destino\version.txt"
$RutaAgente = "$Destino\reporteClientes.ps1"

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

& $RutaAgente -AccionFlasheada $AccionFlasheada
