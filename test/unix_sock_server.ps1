# Windows UDS paths must be absolute paths
$path = Join-Path $pwd "test.sock"

# Delete the existing socket file
if (Test-Path $path) { 
    Remove-Item $path -Force 
}

try {
    # Create the endpoint
    $endpoint = [System.Net.Sockets.UnixDomainSocketEndPoint]::new($path)
    $socket = [System.Net.Sockets.Socket]::new(
        [System.Net.Sockets.AddressFamily]::Unix, 
        [System.Net.Sockets.SocketType]::Stream, 
        [System.Net.Sockets.ProtocolType]::Unspecified
    )

    # Bind and listen
    $socket.Bind($endpoint)
    $socket.Listen(1)
    Write-Host "Listening on $path..." -ForegroundColor Cyan

    # Wait for connection
    $client = $socket.Accept()
    Write-Host "Connected!" -ForegroundColor Green

    # Echo loop
    $buffer = New-Object byte[] 1024
    while ($true) {
        $count = $client.Receive($buffer)
        if ($count -eq 0) {
            Write-Host "Client disconnected." -ForegroundColor Red
            break
        }
        $message = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $count)
        Write-Host "[RECV] $message" -ForegroundColor Yellow

        # Echo back
        $echo = [System.Text.Encoding]::UTF8.GetBytes("ECHO: $message")
        $client.Send($echo) | Out-Null
        Write-Host "[SENT] ECHO: $message" -ForegroundColor Green
    }
}
catch {
    Write-Error $_
}
finally {
    # Ensure resources are released
    if ($client) { $client.Close() }
    if ($socket) { $socket.Close() }
    if (Test-Path $path) { Remove-Item $path -Force }
    Write-Host "Server closed." -ForegroundColor Cyan
}