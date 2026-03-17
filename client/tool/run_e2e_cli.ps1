Param(
  [int]$BobWaitSeconds = 5
)

$ErrorActionPreference = "Stop"

function Info($m) { Write-Host ("[E2E] " + $m) }

Push-Location "e:\Messaging_App\client"

try {
  $statePath = Join-Path (Join-Path (Get-Location) "tool") "e2e_state.json"
  if (Test-Path $statePath) { Remove-Item $statePath -Force }

  Info "Starting Bob..."
  $bob = Start-Process -FilePath "dart" -ArgumentList @("run", "bin/client_bob.dart") -NoNewWindow -PassThru -RedirectStandardOutput "tool\bob.log" -RedirectStandardError "tool\bob.err.log"

  Info "Waiting up to ${BobWaitSeconds}s for Bob to write state..."
  $deadline = (Get-Date).AddSeconds($BobWaitSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $statePath) { break }
    Start-Sleep -Milliseconds 250
  }
  if (!(Test-Path $statePath)) {
    throw "Bob did not write state file at $statePath"
  }

  Info "Starting Alice..."
  $alice = Start-Process -FilePath "dart" -ArgumentList @("run", "bin/client_alice.dart") -NoNewWindow -PassThru -RedirectStandardOutput "tool\alice.log" -RedirectStandardError "tool\alice.err.log"

  Info "Waiting for Alice to finish..."
  $alice.WaitForExit()
  $aliceExit = $alice.ExitCode

  Info "Waiting for Bob to finish..."
  $bob.WaitForExit()
  $bobExit = $bob.ExitCode

  Info "Alice exit=$aliceExit, Bob exit=$bobExit"

  Info "Logs:"
  Info "  tool\alice.log / tool\alice.err.log"
  Info "  tool\bob.log   / tool\bob.err.log"

  if ($aliceExit -ne 0 -or $bobExit -ne 0) {
    throw "E2E failed (alice=$aliceExit, bob=$bobExit). See logs under client\tool\."
  }

  Info "E2E PASS"
} finally {
  Pop-Location
}

