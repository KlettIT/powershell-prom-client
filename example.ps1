$ErrorActionPreference = "Stop"

Import-Module .\PrometheusExporter

function Get-DummyMetrics {
    $desc = New-MetricDescriptor -Name "dummy_metric" -Type gauge -Help "A dummy metric" -Labels @("source")
    return New-Metric -MetricDesc $desc -Value 1 -Labels @("test")
}

$exp = New-PrometheusExporter -Port 9700
Register-Collector -Exporter $exp -Collector ${function:Get-DummyMetrics}
$exp.Start()
