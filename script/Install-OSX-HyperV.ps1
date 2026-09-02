#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z]$')]
    [string]$Drive,

    [Parameter()]
    [string]$VmName = 'OSX',

    [Parameter()]
    [ValidateSet('15')]
    [string]$MacOSVersion = '15',

    [Parameter()]
    [switch]$Rollback
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Drive = $Drive.TrimEnd(':').ToUpperInvariant()
$RootPath = "${Drive}:\OSX-Hyper-V"
$RepoPath = Join-Path $RootPath 'OSX-Hyper-V'
$RecoveryPath = Join-Path $RootPath 'Recovery'
$VhdPath = Join-Path $RootPath 'VirtualDisks'
$EfiVhdPath = Join-Path $VhdPath 'EFI.vhdx'
$OsVhdPath = Join-Path $VhdPath "$VmName.vhdx"
$LogPath = Join-Path $RootPath 'install.log'
$RepoUrl = 'https://github.com/Qonfused/OSX-Hyper-V.git'
$StageTotal = 11
$Stage = 0
$StageName = ''
$StageWatch = [System.Diagnostics.Stopwatch]::new()
$TranscriptStarted = $false
$RebootRequired = $false
$UseAnsiProgress = $true

$CpuCount = 6
$MemoryBytes = 16GB
$OsDiskBytes = 160GB
# 5 GB follows the current upstream VM helper and leaves enough room for
# modern Recovery images while retaining a small EFI disk.
$EfiDiskBytes = 5GB

function Write-ProgressLine([int]$Percent, [string]$Status) {
    $Percent = [math]::Max(0, [math]::Min(100, $Percent))
    $completed = [math]::Floor(42 * $Percent / 100)
    $bar = ('━' * $completed) + ('─' * (42 - $completed))
    $elapsed = $StageWatch.Elapsed.ToString('mm\:ss')
    $time = Get-Date -Format 'HH:mm:ss'
    $line = "{0}  [{1}] {2,3}%  {3}  ({4})" -f $time, $bar, $Percent, $Status, $elapsed

    if ($script:UseAnsiProgress) {
        Write-Host ("`r`e[2K{0}" -f $line) -NoNewline
    }
    else {
        $overall = [math]::Round((($script:Stage - 1) * 100 + $Percent) / $StageTotal)
        Write-Progress -Id 0 -Activity 'OSX-Hyper-V build' -Status "Stage $script:Stage/$StageTotal - $Status" -PercentComplete $overall
    }
}

function Write-Stage([string]$Name) {
    $script:Stage++
    $script:StageName = $Name
    $script:StageWatch.Restart()
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $script:Stage, $StageTotal, $Name) -ForegroundColor Cyan
    Write-ProgressLine 0 'Iniciando'
}

function Complete-Stage {
    Write-ProgressLine 100 'Concluído'
    if ($script:UseAnsiProgress) { Write-Host '' }
    else { Write-Progress -Id 0 -Activity 'OSX-Hyper-V build' -Status 'Concluído' -PercentComplete ([math]::Round($script:Stage * 100 / $StageTotal)) }
    Ok $script:StageName
    $script:StageWatch.Stop()
}

function Step([string]$Text) { Write-Host "  => $Text" -ForegroundColor Gray }
function Run([string]$Text) { Write-Host "  [RUN]  $Text" -ForegroundColor White }
function Ok([string]$Text) { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Warn([string]$Text) { Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Fail([string]$Text) { Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Update-Progress([int]$StagePercent, [string]$Status) { Write-ProgressLine $StagePercent $Status }

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$id
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Execute o PowerShell como Administrador.'
    }
}

function Test-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Test-Command([string]$Name) { return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

function Get-HyperVFeatureState {
    $output = & dism.exe /Online /Get-FeatureInfo "/FeatureName:Microsoft-Hyper-V-All" 2>&1
    if ($LASTEXITCODE -ne 0) { return 'Unknown' }
    $text = $output -join "`n"
    if ($text -match '(?i)(Enabled|Habilitado|Ativado)') { return 'Enabled' }
    if ($text -match '(?i)(Disabled|Desabilitado|Desativado)') { return 'Disabled' }
    return 'Unknown'
}

function Enable-HyperV {
    Run 'dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V-All /All /NoRestart'
    & dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V-All /All /NoRestart
    if ($LASTEXITCODE -ne 0) { throw "DISM falhou ao habilitar Hyper-V (exit code $LASTEXITCODE)." }
    $script:RebootRequired = $true
    Ok 'Hyper-V habilitado; reinicialização necessária.'
}

function Get-Vm([string]$Name) {
    try { return Get-VM -Name $Name -ErrorAction Stop } catch { return $null }
}

function Add-CometLakeSpoof([string]$ConfigPath) {
    $content = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if ($content -match '(?m)Cpuid1Data\s*:') { Ok 'CPUID spoof já está presente em src/config.yml.'; return }
    $block = @"

################################################################################
# Intel 11th Gen and newer CPU compatibility for Hyper-V
################################################################################
Kernel:
  Emulate:
    Cpuid1Data: Data | <55 06 0A 00 00 00 00 00 00 00 00 00 00 00 00 00>
    Cpuid1Mask: Data | <FF FF FF FF 00 00 00 00 00 00 00 00 00 00 00 00>
"@
    Add-Content -LiteralPath $ConfigPath -Value $block -Encoding UTF8
    Ok 'CPUID spoof Comet Lake adicionado ao src/config.yml.'
}

function Invoke-MacRecoveryDownload {
    $recoveryDestination = Join-Path $RecoveryPath 'com.apple.recovery.boot'
    Test-Directory $recoveryDestination

    $dmg = Get-ChildItem -LiteralPath $recoveryDestination -Filter '*.dmg' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $chunklist = Get-ChildItem -LiteralPath $recoveryDestination -Filter '*.chunklist' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dmg -and $chunklist) {
        Ok "Recovery já disponível: $($dmg.Name) + $($chunklist.Name)"
        return $recoveryDestination
    }

    # Reuse the upstream recovery wrapper. It invokes OCE-Build's bootstrap
    # and therefore does not require a separately installed Python runtime.
    $recoveryScript = Join-Path $RepoPath 'scripts\lib\create-macos-recovery.ps1'
    if (-not (Test-Path -LiteralPath $recoveryScript)) { throw "Script de Recovery não encontrado: $recoveryScript" }

    Update-Progress 10 'Baixando macOS Recovery'
    Run "create-macos-recovery.ps1 -version $MacOSVersion"
    & $recoveryScript -pwd $RepoPath -version $MacOSVersion -outdir $recoveryDestination
    if ($LASTEXITCODE -ne 0) { throw "create-macos-recovery.ps1 falhou (exit code $LASTEXITCODE)." }
    Update-Progress 90 'Validando arquivos do Recovery'

    $dmg = Get-ChildItem -LiteralPath $recoveryDestination -Filter '*.dmg' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $chunklist = Get-ChildItem -LiteralPath $recoveryDestination -Filter '*.chunklist' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dmg -or -not $chunklist) { throw 'O download do Recovery terminou sem BaseSystem.dmg e/ou BaseSystem.chunklist.' }

    Ok "Recovery $MacOSVersion baixado e validado: $([math]::Round($dmg.Length / 1MB,1)) MB"
    return $recoveryDestination
}

function Initialize-EfiVhd {
    Test-Directory $VhdPath
    if (-not (Test-Path -LiteralPath $EfiVhdPath)) {
        Run "New-VHD $EfiVhdPath -Dynamic -SizeBytes 5GB"
        New-VHD -Path $EfiVhdPath -Dynamic -SizeBytes $EfiDiskBytes | Out-Null
    }

    $vm = Get-Vm $VmName
    if ($null -ne $vm -and $vm.State -ne 'Off') {
        throw "A VM '$VmName' está em execução. Desligue-a antes de preparar o EFI VHDX."
    }

    # An attached VHDX may not be mountable by the host. Temporarily detach it
    # from an existing, powered-off VM and restore the original controller slot.
    $attachedEfi = $null
    if ($null -ne $vm) {
        $attachedEfi = Get-VMHardDiskDrive -VMName $VmName | Where-Object Path -eq $EfiVhdPath | Select-Object -First 1
        if ($null -ne $attachedEfi) {
            Remove-VMHardDiskDrive -VMName $VmName -ControllerType $attachedEfi.ControllerType -ControllerNumber $attachedEfi.ControllerNumber -ControllerLocation $attachedEfi.ControllerLocation
            Ok 'EFI VHDX temporariamente desconectado da VM para atualização.'
        }
    }

    $vhd = Get-VHD -Path $EfiVhdPath
    if ($vhd.Size -lt $EfiDiskBytes) {
        Run "Resize-VHD $EfiVhdPath para 5GB"
        Resize-VHD -Path $EfiVhdPath -SizeBytes $EfiDiskBytes
    }

    $mounted = $false
    try {
        $disk = Mount-VHD -Path $EfiVhdPath -Passthru
        $mounted = $true
        $disk = Get-Disk -Number $disk.Number
        if ($disk.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false | Out-Null
            $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
            Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel EFI -Confirm:$false -Force | Out-Null
        }
        else {
            $partition = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -eq 'Basic' -or $_.FileSystem -eq 'FAT32' } | Select-Object -First 1
            if ($null -eq $partition) { throw "Não foi encontrada uma partição utilizável no EFI VHDX." }
            if (-not $partition.DriveLetter) { $partition | Add-PartitionAccessPath -AssignDriveLetter | Out-Null }
            $partition = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.PartitionNumber -eq $partition.PartitionNumber }
            $supported = Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
            if ($supported.SizeMax -gt $partition.Size) { Resize-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -Size $supported.SizeMax }
        }

        $mountRoot = "$($partition.DriveLetter):"
        $efiSource = Join-Path $RepoPath 'dist\EFI'
        if (-not (Test-Path -LiteralPath $efiSource)) { throw "Build concluído, mas dist\EFI não foi encontrado em $RepoPath." }
        Test-Directory (Join-Path $mountRoot 'EFI')
        Copy-Item -Path (Join-Path $efiSource '*') -Destination (Join-Path $mountRoot 'EFI') -Recurse -Force

        $toolsSource = Join-Path $RepoPath 'dist\Tools'
        if (Test-Path -LiteralPath $toolsSource) {
            Test-Directory (Join-Path $mountRoot 'Tools')
            Copy-Item -Path (Join-Path $toolsSource '*') -Destination (Join-Path $mountRoot 'Tools') -Recurse -Force
        }

        $scriptsSource = Join-Path $RepoPath 'dist\Scripts'
        if (Test-Path -LiteralPath $scriptsSource) {
            Test-Directory (Join-Path $mountRoot 'Scripts')
            Copy-Item -Path (Join-Path $scriptsSource '*') -Destination (Join-Path $mountRoot 'Scripts') -Recurse -Force
        }

        # This is the critical part missing from the previous version:
        # Recovery must live beside EFI at the root of the FAT32 boot VHDX.
        $recoverySource = Join-Path $RecoveryPath 'com.apple.recovery.boot'
        if (-not (Test-Path -LiteralPath $recoverySource)) { throw "Recovery não encontrado em $recoverySource." }
        $recoveryTarget = Join-Path $mountRoot 'com.apple.recovery.boot'
        Test-Directory $recoveryTarget
        Copy-Item -Path (Join-Path $recoverySource '*') -Destination $recoveryTarget -Recurse -Force

        $files = Get-ChildItem -LiteralPath $recoveryTarget -File
        $dmg = $files | Where-Object Extension -ieq '.dmg' | Select-Object -First 1
        $chunklist = $files | Where-Object Extension -ieq '.chunklist' | Select-Object -First 1
        if (-not $dmg -or -not $chunklist) { throw 'EFI VHDX preparado sem os arquivos de Recovery esperados.' }

        Ok "EFI VHDX preparado com EFI + Recovery ($([math]::Round(($dmg.Length + $chunklist.Length) / 1MB,1)) MB)"
    }
    finally {
        if ($mounted) { Dismount-VHD -Path $EfiVhdPath -ErrorAction SilentlyContinue }
        if ($null -ne $attachedEfi) {
            Add-VMHardDiskDrive -VMName $VmName -Path $EfiVhdPath -ControllerType $attachedEfi.ControllerType -ControllerNumber $attachedEfi.ControllerNumber -ControllerLocation $attachedEfi.ControllerLocation
            Ok 'EFI VHDX reconectado à VM.'
        }
    }

    Optimize-VHD -Path $EfiVhdPath -Mode Full -ErrorAction SilentlyContinue
}

function Initialize-OsVhd {
    Test-Directory $VhdPath
    if (Test-Path -LiteralPath $OsVhdPath) { Ok "Disco da VM já existe: $OsVhdPath"; return }
    Run "New-VHD $OsVhdPath -Dynamic -SizeBytes 160GB"
    New-VHD -Path $OsVhdPath -Dynamic -SizeBytes $OsDiskBytes | Out-Null
    Ok "Disco principal criado: $OsVhdPath"
}

function Initialize-Vm {
    $vm = Get-Vm $VmName
    if ($null -eq $vm) {
        $switch = Get-VMSwitch | Where-Object { $_.SwitchType -eq 'External' } | Select-Object -First 1
        if ($null -eq $switch) { $switch = Get-VMSwitch | Select-Object -First 1 }
        if ($null -eq $switch) { throw 'Nenhum Virtual Switch Hyper-V foi encontrado.' }
        New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemoryBytes -NoVHD | Out-Null
        $adapter = Get-VMNetworkAdapter -VMName $VmName | Select-Object -First 1
        Connect-VMNetworkAdapter -VMName $VmName -Name $adapter.Name -SwitchName $switch.Name
        Add-VMHardDiskDrive -VMName $VmName -Path $EfiVhdPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0
        Add-VMHardDiskDrive -VMName $VmName -Path $OsVhdPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1
        Set-VM -Name $VmName -ProcessorCount $CpuCount -MemoryStartupBytes $MemoryBytes -AutomaticCheckpointsEnabled $false
        Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
        $efiDisk = Get-VMHardDiskDrive -VMName $VmName | Where-Object Path -eq $EfiVhdPath
        Set-VMFirmware -VMName $VmName -FirstBootDevice $efiDisk
        Ok "VM '$VmName' criada e configurada."
        return
    }

    if ($vm.State -ne 'Off') { throw "A VM '$VmName' precisa estar desligada para ser reconfigurada." }
    Warn "VM '$VmName' já existe; nenhuma VM foi removida ou recriada."
    $vmDisks = Get-VMHardDiskDrive -VMName $VmName
    if (-not ($vmDisks | Where-Object Path -eq $EfiVhdPath)) { Add-VMHardDiskDrive -VMName $VmName -Path $EfiVhdPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 }
    if (-not ($vmDisks | Where-Object Path -eq $OsVhdPath)) { Add-VMHardDiskDrive -VMName $VmName -Path $OsVhdPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1 }
    Set-VM -Name $VmName -ProcessorCount $CpuCount -MemoryStartupBytes $MemoryBytes -AutomaticCheckpointsEnabled $false
    Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
    $efiDisk = Get-VMHardDiskDrive -VMName $VmName | Where-Object Path -eq $EfiVhdPath
    Set-VMFirmware -VMName $VmName -FirstBootDevice $efiDisk
}

function Invoke-Rollback {
    Write-Host ''
    Write-Host 'ROLLBACK' -ForegroundColor Yellow
    $vm = Get-Vm $VmName
    if ($null -ne $vm) {
        if ($vm.State -ne 'Off') { Stop-VM -Name $VmName -Force -ErrorAction SilentlyContinue }
        Remove-VM -Name $VmName -Force
        Ok "VM '$VmName' removida."
    }
    if (Test-Path -LiteralPath $RootPath) { Remove-Item -LiteralPath $RootPath -Recurse -Force; Ok "Workspace removido: $RootPath" }
}

try {
    if ($Rollback) { Assert-Administrator; Invoke-Rollback; return }

    Write-Host ''
    Write-Host 'OSX-Hyper-V / macOS Sequoia' -ForegroundColor Cyan
    Write-Host 'Hyper-V Development Host' -ForegroundColor DarkGray
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    Write-Host "Workspace : $RootPath"
    Write-Host "VM        : $VmName"
    Write-Host "CPU       : $CpuCount vCPU"
    Write-Host 'RAM       : 16 GB'
    Write-Host 'OS Disk   : 160 GB dynamic'
    Write-Host 'EFI Disk  : 5 GB dynamic (EFI + macOS Recovery)'

    Test-Directory $RootPath
    Start-Transcript -Path $LogPath -Append -ErrorAction SilentlyContinue | Out-Null
    $TranscriptStarted = $true

    if ($env:TERM -eq 'dumb' -or $Host.Name -match 'ISE') { $script:UseAnsiProgress = $false }

    Write-Stage 'Validando host Windows'
    Assert-Administrator
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor
    Step "Sistema : $($os.Caption)"
    Step "CPU     : $($cpu.Name)"
    Step "Cores   : $($cpu.NumberOfCores)"
    Step "Threads : $($cpu.NumberOfLogicalProcessors)"
    Step "RAM     : $([math]::Round($os.TotalVisibleMemorySize / 1MB,2)) GB"
    if (-not (Test-Path -LiteralPath "${Drive}:\")) { throw "A unidade ${Drive}: não existe." }
    if (-not (Test-Command 'dism.exe')) { throw 'DISM.exe não foi encontrado.' }
    if (-not (Test-Command 'git')) { throw 'Git não está disponível no PATH.' }
    Ok "Unidade ${Drive}: disponível."
    Ok 'Git e DISM disponíveis.'
    Complete-Stage

    Write-Stage 'Validando / habilitando Hyper-V'
    $state = Get-HyperVFeatureState
    Step "Estado Microsoft-Hyper-V-All: $state"
    if ($state -eq 'Disabled') { Enable-HyperV }
    elseif ($state -eq 'Enabled') { Ok 'Hyper-V já está habilitado.' }
    else { throw 'Não foi possível determinar o estado do recurso Hyper-V via DISM.' }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) { throw 'Módulo PowerShell Hyper-V não está disponível.' }
    Ok 'Módulo Hyper-V disponível.'
    Complete-Stage
    if ($RebootRequired) { Warn 'Reinicialize o Windows e execute novamente o mesmo comando.'; throw 'Reinicialização necessária para concluir a ativação do Hyper-V.' }

    Write-Stage 'Preparando workspace'
    Test-Directory $RepoPath; Test-Directory $RecoveryPath; Test-Directory $VhdPath
    Ok "Workspace pronto em $RootPath"
    Complete-Stage

    Write-Stage 'Obtendo OSX-Hyper-V'
    if (Test-Path -LiteralPath (Join-Path $RepoPath '.git')) {
        Push-Location $RepoPath
        try { git pull --ff-only; if ($LASTEXITCODE -ne 0) { throw 'git pull falhou.' } }
        finally { Pop-Location }
        Ok 'Repositório atualizado.'
    }
    else {
        if ((Get-ChildItem -LiteralPath $RepoPath -Force | Measure-Object).Count -gt 0) { throw "$RepoPath existe mas não é um clone Git do OSX-Hyper-V. Não será removido automaticamente." }
        Run "git clone $RepoUrl $RepoPath"
        git clone $RepoUrl $RepoPath
        if ($LASTEXITCODE -ne 0) { throw 'git clone falhou.' }
        Ok 'OSX-Hyper-V clonado.'
    }
    Complete-Stage

    Write-Stage 'Validando ferramentas'
    Ok 'OCE-Build/macrecovery será utilizado pelo wrapper upstream.'
    Complete-Stage

    Write-Stage 'Configurando CPU / src/config.yml'
    $configPath = Join-Path $RepoPath 'src\config.yml'
    if (-not (Test-Path -LiteralPath $configPath)) { throw "Arquivo correto do projeto não encontrado: $configPath" }
    Add-CometLakeSpoof $configPath
    Complete-Stage

    Write-Stage 'Construindo OpenCore / EFI'
    $buildScript = Join-Path $RepoPath 'scripts\build.ps1'
    if (-not (Test-Path -LiteralPath $buildScript)) { throw "Build script não encontrado: $buildScript" }
    $efiDir = Join-Path $RepoPath 'dist\EFI'
    if (Test-Path -LiteralPath $efiDir) { Ok 'dist\EFI já existe; build será reutilizado.' }
    else { Run 'scripts\build.ps1'; & $buildScript; if ($LASTEXITCODE -ne 0) { throw "build.ps1 falhou (exit code $LASTEXITCODE)." }; Ok 'OpenCore/EFI construído.' }
    Complete-Stage

    Write-Stage 'Baixando macOS Sequoia Recovery'
    $recoveryDestination = Invoke-MacRecoveryDownload
    Step "Staging: $recoveryDestination"
    Complete-Stage

    Write-Stage 'Preparando EFI.vhdx (EFI + Recovery)'
    Initialize-EfiVhd
    Complete-Stage

    Write-Stage 'Criando disco principal da VM'
    Initialize-OsVhd
    Complete-Stage

    Write-Stage 'Criando / configurando VM Hyper-V'
    Initialize-Vm
    Complete-Stage

    if (-not $script:UseAnsiProgress) { Write-Progress -Id 0 -Activity 'OSX-Hyper-V build' -Completed }
    elseif ($script:Stage -gt 0) { Write-ProgressLine 100 'BUILD COMPLETE'; Write-Host '' }
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Green
    Write-Host 'BUILD COMPLETE' -ForegroundColor Green
    Write-Host ('=' * 70) -ForegroundColor Green
    Ok "VM: $VmName"
    Ok "EFI + Recovery: $EfiVhdPath"
    Ok "OS disk: $OsVhdPath"
    Write-Host ''
    Step 'A VM está pronta para iniciar o OpenCore e carregar o macOS Recovery.'
    Step 'No OpenCore, a entrada do Recovery deve aparecer como EFI/macOS Base System.'
    Step 'Após instalar o macOS, configure SSH/Remote Login para Pair to Mac.'
}
catch {
    if ($script:UseAnsiProgress) { Write-Host '' } else { Write-Progress -Id 0 -Activity 'OSX-Hyper-V build' -Completed }
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Red
    Fail 'BUILD FAILED'
    Write-Host "Stage : $Stage/$StageTotal" -ForegroundColor Yellow
    Write-Host "Stage : $StageName" -ForegroundColor Yellow
    Write-Host "Erro  : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Host "Estado preservado em: $RootPath" -ForegroundColor Yellow
    Write-Host "Rollback: .\Install-OSX-HyperV.ps1 -Drive $Drive -VmName `"$VmName`" -Rollback" -ForegroundColor White
    if ($RebootRequired) { Write-Host 'REINICIALIZAÇÃO NECESSÁRIA: execute novamente após o reboot.' -ForegroundColor Yellow }
    exit 1
}
finally {
    if ($TranscriptStarted) { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
}