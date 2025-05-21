enum MetricType {
    counter
    gauge
    histogram
    summary
}

class MetricDesc {
    [string]   $Name
    [string]   $Help
    [MetricType] $Type
    [string[]] $Labels

    MetricDesc([string] $Name, [MetricType] $Type, [string] $Help, [string[]] $Labels) {
        if (-not $this.IsValidName($Name)) {
            throw "Not a valid metric name: $Name"
        }
        foreach ($label in $Labels) {
            if (-not $this.IsValidName($label)) {
                throw "Not a valid label name: $label"
            }
        }
        $this.Name = $Name
        $this.Type = $Type
        $this.Help = $Help -replace "[\r\n]+", " " # Strip out new lines
        $this.Labels = $Labels
    }

    hidden [bool] IsValidName([string] $Name) {
        # Prometheus metric/label name regex: ^[a-zA-Z_][a-zA-Z0-9_]*$
        return $Name -match "^[a-zA-Z_][a-zA-Z0-9_]*$"
    }
}

class Metric {
    [MetricDesc] $Descriptor
    [float]      $Value
    [string[]]   $Labels

    Metric([MetricDesc] $Descriptor, [float] $Value, [string[]] $Labels) {
        if ($Descriptor.Labels.Count -ne $Labels.Count) {
            throw "Label count mismatch: Descriptor has $($Descriptor.Labels.Count), Metric has $($Labels.Count)"
        }
        $this.Descriptor = $Descriptor
        $this.Value = $Value
        $this.Labels = $Labels
    }

    [string] ToString() {
        if ($this.Descriptor.Labels.Count -gt 0) {
            $labelPairs = for ($i = 0; $i -lt $this.Descriptor.Labels.Count; $i++) {
                $l = $this.Descriptor.Labels[$i]
                $v = $this.Labels[$i]
                # Escape backslash, double quote and newlines per Prometheus exposition format
                $v = $v.Replace("\", "\\").Replace("""", "\""").Replace("`n", "\n")
                "$l=`"$v`""
            }
            $labelStr = "{" + ($labelPairs -join ",") + "}"
        }
        else {
            $labelStr = ""
        }
        return "$($this.Descriptor.Name)$labelStr $($this.Value)"
    }
}

class Channel {
    [System.Collections.Generic.List[Metric]] $Metrics = [System.Collections.Generic.List[Metric]]::new()

    [void] AddMetrics([Metric[]] $metrics) {
        $this.Metrics.AddRange($metrics)
    }

    [string] ToString() {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lastDesc = $null
        foreach ($m in $this.Metrics) {
            if ($m.Descriptor -ne $lastDesc) {
                $lastDesc = $m.Descriptor
                $lines.Add("# HELP $($lastDesc.Name) $($lastDesc.Help)")
                $lines.Add("# TYPE $($lastDesc.Name) $($lastDesc.Type)")
            }
            $lines.Add($m.ToString())
        }
        return $lines -join "`n"
    }
}

class Exporter {
    [System.Collections.Generic.List[ScriptBlock]] $Collectors = [System.Collections.Generic.List[ScriptBlock]]::new()
    [uint32] $Port

    Exporter([uint32] $Port) {
        $this.Port = $Port
    }

    [void] Register([ScriptBlock] $Collector) {
        $this.Collectors.Add($Collector)
    }

    [string] Collect() {
        [Metric[]] $collectedMetrics = @()
        foreach ($collector in $this.Collectors) {
            try {
                $output = & $collector *>&1

                foreach ($item in $output) {
                    if ($item -is [Metric]) {
                        $collectedMetrics += $item
                    }
                    else {
                        # Print Non-Metric Messages from Collector
                        New-LogMessage -Msg ("[Collector] {0}" -f $item.ToString())
                    }
                }
            }
            catch {
                New-LogMessage -Msg ("[ERR] [Collector] {0}" -f $_)
            }
        }

        $channel = [Channel]::new()
        $channel.AddMetrics($collectedMetrics)
        return $channel.ToString()
    }

    [void] Start() {
        $listener = [System.Net.HttpListener]::new()
        $prefix = "http://+:$($this.Port)/"
        $listener.Prefixes.Add($prefix)
        $listener.Start()

        New-LogMessage -Msg "Exporter listening on $prefix"

        try {
            while ($listener.IsListening) {
                $context = $listener.GetContextAsync().GetAwaiter().GetResult()
                $request = $context.Request
                $response = $context.Response

                try {
                    switch ($request.HttpMethod) {
                        'GET' {
                            switch ($request.Url.AbsolutePath) {
                                '/' {
                                    $metricsText = $this.Collect()
                                    $response.ContentType = "text/plain; version=0.0.4; charset=utf-8"
                                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($metricsText)
                                    $response.ContentLength64 = $bytes.Length
                                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                                }
                                '/metrics' {
                                    $metricsText = $this.Collect()
                                    $response.ContentType = "text/plain; version=0.0.4; charset=utf-8"
                                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($metricsText)
                                    $response.ContentLength64 = $bytes.Length
                                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                                }
                                '/healthz' {
                                    $response.StatusCode = 200
                                    $response.ContentType = "text/plain"
                                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("OK")
                                    $response.ContentLength64 = $bytes.Length
                                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                                }
                                default {
                                    $response.StatusCode = 404
                                    $msg = "Not Found"
                                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
                                    $response.ContentLength64 = $bytes.Length
                                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                                }
                            }
                        }
                        default {
                            $response.StatusCode = 405
                        }
                    }

                    $remoteAddr = if ($request.RemoteEndPoint) { $request.RemoteEndPoint.ToString() } else { "-" }
                    New-LogMessage -Msg "$remoteAddr `"$($request.HttpMethod) $($request.Url.AbsolutePath)`" $($response.StatusCode)"
                }
                catch {
                    $response.StatusCode = 500
                    New-LogMessage -Msg "Error: $_"
                }
                finally {
                    $response.OutputStream.Close()
                }

                [System.GC]::Collect()
            }
        }
        finally {
            New-LogMessage -Msg "Stopping exporter"
            $listener.Stop()
            $listener.Close()
        }
    }
}

function New-LogMessage([string] $Msg) {
    Write-Information "$(Get-Date -Format o) $Msg"
}

function New-MetricDescriptor(
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][MetricType] $Type,
    [Parameter(Mandatory)][string] $Help,
    [string[]] $Labels = @()
) {
    return [MetricDesc]::new($Name, $Type, $Help, $Labels)
}

function New-PrometheusExporter(
    [Parameter(Mandatory)][uint32] $Port
) {
    return [Exporter]::new($Port)
}

function Register-Collector (
    [Parameter(Mandatory)][Exporter] $Exporter,
    [Parameter(Mandatory)][ScriptBlock] $Collector
) {
    $Exporter.Register($Collector)
}

function New-Metric (
    [Parameter(Mandatory)][MetricDesc] $MetricDesc,
    [Parameter(Mandatory)][float] $Value,
    [string[]] $Labels = @()
) {
    return [Metric]::new($MetricDesc, $Value, $Labels)
}

Export-ModuleMember -Function New-MetricDescriptor, New-PrometheusExporter, New-Metric, Register-Collector