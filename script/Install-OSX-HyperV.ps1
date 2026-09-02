#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z]$')]
    [string]$Drive,

    [Parameter()]
    [string]$VmName = 'OSX',

    [Parameter()]
    [switch]$Rollback
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# OSX-Hyper-V host preparation script.
# The script is intentionally idempotent: rerunning it after a reboot reuses
# artifacts already created instead of starting destructive work again.
# It does not partition, format, or modify a physical Windows disk.

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
$TranscriptStarted = $false
$RebootRequired = $false

$CpuCount = 6
$MemoryBytes = 16GB
$OsDiskBytes = 160GB
$EfiDiskBytes = 1GB

function Write-Stage([string]$Name) {
    $script:Stage++
    $script:StageName = $Name
    Write-Host ""
    Write-Host "[$script:Stage/$StageTotal] $Name" -ForegroundColor Cyan
    Write-Host ('-' * 70) -ForegroundColor DarkGray
    Update-GlobalProgress 0 "Iniciando stage"
}

function Update-GlobalProgress([int]$StagePercent, [string]$Status) {
    $completed = ($script:Stage - 1) * 100
    $overall = [math]::Round(($completed + [math]::Max(0,[math]::Min(100,$StagePercent))) / $StageTotal)
    Write-Progress -Id 0 -Activity 'OSX-Hyper-V build' -Status "Stage $script:Stage/$StageTotal - $Status" -PercentComplete $overall
}

function Complete-Stage {
    Update-GlobalProgress 100 'Concluído'
    Write-Host "  [OK]   $script:StageName" -ForegroundColor Green
}

function Step([string]$Text) { Write-Host "  => $Text" -ForegroundColor Gray }
function Run([string]$Text) { Write-Host "  [RUN]  $Text" -ForegroundColor White }
function Ok([string]$Text) { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Warn([string]$Text) { Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Fail([string]$Text) { Write-Host "  [FAIL] $Text" -ForegroundColor Red }

function Assert-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]$id
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Execute o PowerShell como Administrador.'
    }
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Command-Exists([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-HyperVFeatureState {
    $output = & dism.exe /Online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1
    if ($LASTEXITCODE -ne 0) { return 'Unknown' }
    $text = $output -join "`n"
    if ($text -match '(?im)^\s*State\s*:\s*Enabled\s*$') { return 'Enabled' }
    if ($text -match '(?im)^\s*State\s*:\s*Disabled\s*$') { return 'Disabled' }
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
    if ($content -match '(?m)Cpuid1Data\s*:') {
        Ok 'CPUID spoof já está presente em src/config.yml.'
        return
    }

    # OCE-Build accepts repeated top-level sections and merges the patches.
    # Keep this block separate so the upstream config remains easy to diff.
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

function Find-MacRecoveryScript([string]$Repo) {
    $candidate = Get-ChildItem -LiteralPath $Repo -Filter 'macrecovery.py' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function New-EfiVhd {
    if (Test-Path -LiteralPath $EfiVhdPath) {
        Ok "EFI VHDX já existe: $EfiVhdPath"
        return
    }

    Ensure-Directory $VhdPath
    Run "New-VHD $EfiVhdPath -Dynamic -SizeBytes 1GB"
    New-VHD -Path $EfiVhdPath -Dynamic -SizeBytes $EfiDiskBytes | Out-Null

    $disk = Mount-VHD -Path $EfiVhdPath -Passthru
    try {
        $initialized = Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru -Confirm:$false
        $partition = $initialized | New-Partition -UseMaximumSize -AssignDriveLetter
        Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel EFI -Confirm:$false | Out-Null
        $letter = "$($partition.DriveLetter):"
        $efiSource = Join-Path $RepoPath 'dist\EFI'
        if (-not (Test-Path -LiteralPath $efiSource)) {
            throw "Build concluído, mas dist\EFI não foi encontrado em $RepoPath."
        }
        Copy-Item -LiteralPath $efiSource -Destination (Join-Path $letter 'EFI') -Recurse -Force

        $toolsSource = Join-Path $RepoPath 'dist\Tools'
        if (Test-Path -LiteralPath $toolsSource) {
            Copy-Item -LiteralPath $toolsSource -Destination (Join-Path $letter 'Tools') -Recurse -Force
        }
    }
    finally {
        Dismount-VHD -Path $EfiVhdPath -ErrorAction SilentlyContinue
    }

    Ok "EFI VHDX criado: $EfiVhdPath"
}

function New-OsVhd {
    if (Test-Path -LiteralPath $OsVhdPath) {
        Ok "Disco da VM já existe: $OsVhdPath"
        return
    }

    Ensure-Directory $VhdPath
    Run "New-VHD $OsVhdPath -Dynamic -SizeBytes 160GB"
    New-VHD -Path $OsVhdPath -Dynamic -SizeBytes $OsDiskBytes | Out-Null
    Ok "Disco principal criado: $OsVhdPath"
}

function Configure-Vm {
    $vm = Get-Vm $VmName
    if ($null -eq $vm) {
        $switch = Get-VMSwitch | Where-Object { $_.SwitchType -eq 'External' } | Select-Object -First 1
        if ($null -eq $switch) { $switch = Get-VMSwitch | Select-Object -First 1 }
        if ($null -eq $switch) { throw 'Nenhum Virtual Switch Hyper-V foi encontrado.' }

        Run "New-VM $VmName (Generation 2)"
        New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemoryBytes -NoVHD | Out-Null
        $adapter = Get-VMNetworkAdapter -VMName $VmName | Select-Object -First 1
        Connect-VMNetworkAdapter -VMName $VmName -Name $adapter.Name -SwitchName $switch.Name
        Add-VMHardDiskDrive -VMName $VmName -Path $EfiVhdPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0
        Add-VMHardDiskDrive -VMName $VmName -Path $OsVhdPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1
        Set-VM -Name $VmName -ProcessorCount $CpuCount -MemoryStartupBytes $MemoryBytes -AutomaticCheckpointsEnabled $false
        Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
        $efiDisk = Get-VMHardDiskDrive -VMName $VmName | Where-Object { $_.Path -eq $EfiVhdPath }
        Set-VMFirmware -VMName $VmName -FirstBootDevice $efiDisk
        Ok "VM '$VmName' criada e configurada."
        return
    }

    Warn "VM '$VmName' já existe; nenhuma VM foi removida ou recriada."
    $vmDisks = Get-VMHardDiskDrive -VMName $VmName
    if (-not ($vmDisks | Where-Object Path -eq $EfiVhdPath)) {
        Add-VMHardDiskDrive -VMName $VmName -Path $EfiVhdPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0
        Ok 'EFI VHDX conectado à VM existente.'
    }
    if (-not ($vmDisks | Where-Object Path -eq $OsVhdPath)) {
        Add-VMHardDiskDrive -VMName $VmName -Path $OsVhdPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1
        Ok 'OS VHDX conectado à VM existente.'
    }
    Set-VM -Name $VmName -ProcessorCount $CpuCount -MemoryStartupBytes $MemoryBytes -AutomaticCheckpointsEnabled $false
    Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
}

function Invoke-Rollback {
    Write-Host ''
    Write-Host 'ROLLBACK' -ForegroundColor Yellow
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    $vm = Get-Vm $VmName
    if ($null -ne $vm) {
        if ($vm.State -ne 'Off') { Stop-VM -Name $VmName -Force -ErrorAction SilentlyContinue }
        Remove-VM -Name $VmName -Force
        Ok "VM '$VmName' removida."
    } else { Step "VM '$VmName' não existe." }

    if (Test-Path -LiteralPath $RootPath) {
        Remove-Item -LiteralPath $RootPath -Recurse -Force
        Ok "Workspace removido: $RootPath"
    } else { Step 'Workspace não existe.' }
}

try {
    if ($Rollback) { Assert-Administrator; Invoke-Rollback; return }

    Write-Host ''
    Write-Host 'OSX-Hyper-V / macOS Sequoia' -ForegroundColor Cyan
    Write-Host 'Hyper-V Development Host' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    Write-Host "Workspace : $RootPath"
    Write-Host "VM        : $VmName"
    Write-Host "CPU       : $CpuCount vCPU"
    Write-Host 'RAM       : 16 GB'
    Write-Host 'OS Disk   : 160 GB dynamic'

    Ensure-Directory $RootPath
    Start-Transcript -Path $LogPath -Append -ErrorAction SilentlyContinue | Out-Null
    $TranscriptStarted = $true

    # 1
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
    Ok "Unidade ${Drive}: disponível."
    if (-not (Command-Exists 'dism.exe')) { throw 'DISM.exe não foi encontrado.' }
    Complete-Stage

    # 2
    Write-Stage 'Validando / habilitando Hyper-V'
    $state = Get-HyperVFeatureState
    Step "Estado Microsoft-Hyper-V-All: $state"
    if ($state -eq 'Disabled') { Enable-HyperV }
    elseif ($state -eq 'Enabled') { Ok 'Hyper-V já está habilitado.' }
    else { throw 'Não foi possível determinar o estado do recurso Hyper-V via DISM.' }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) { throw 'Módulo PowerShell Hyper-V não está disponível.' }
    Ok 'Módulo Hyper-V disponível.'
    Complete-Stage
    if ($RebootRequired) {
        Write-Host ''
        Warn 'Reinicialize o Windows antes de continuar.'
        Warn 'O script é idempotente: após o reboot, execute o mesmo comando novamente.'
        throw 'Reinicialização necessária para concluir a ativação do Hyper-V.'
    }

    # 3
    Write-Stage 'Preparando workspace'
    Ensure-Directory $RepoPath
    Ensure-Directory $RecoveryPath
    Ensure-Directory $VhdPath
    Ok "Workspace pronto em $RootPath"
    Complete-Stage

    # 4
    Write-Stage 'Obtendo OSX-Hyper-V'
    if (Test-Path -LiteralPath (Join-Path $RepoPath '.git')) {
        Push-Location $RepoPath
        try {
            Run 'git pull --ff-only'
            git pull --ff-only
            if ($LASTEXITCODE -ne 0) { throw 'git pull falhou.' }
        } finally { Pop-Location }
        Ok 'Repositório atualizado.'
    } else {
        # Remove only the empty directory created above if needed; never delete
        # a non-git directory supplied by the user.
        if ((Get-ChildItem -LiteralPath $RepoPath -Force | Measure-Object).Count -gt 0) {
            throw "$RepoPath existe mas não é um clone Git do OSX-Hyper-V. Não será removido automaticamente."
        }
        Run "git clone $RepoUrl $RepoPath"
        git clone $RepoUrl $RepoPath
        if ($LASTEXITCODE -ne 0) { throw 'git clone falhou.' }
        Ok 'OSX-Hyper-V clonado.'
    }
    Complete-Stage

    # 5
    Write-Stage 'Validando ferramentas'
    if (-not (Command-Exists 'git')) { throw 'Git não está disponível no PATH.' }
    Ok 'Git disponível.'
    if (Command-Exists 'python') { Ok 'Python disponível.' }
    elseif (Command-Exists 'py') { Ok 'Python Launcher (py) disponível.' }
    else {
        Warn 'Python não encontrado. O build do OSX-Hyper-V/OCE-Build será responsável pela ferramenta necessária quando possível.'
    }
    Complete-Stage

    # 6
    Write-Stage 'Configurando CPU / src/config.yml'
    $configPath = Join-Path $RepoPath 'src\config.yml'
    if (-not (Test-Path -LiteralPath $configPath)) { throw "Arquivo correto do projeto não encontrado: $configPath" }
    Step "Configuração: $configPath"
    Add-CometLakeSpoof $configPath
    Complete-Stage

    # 7
    Write-Stage 'Construindo OpenCore / EFI'
    $buildScript = Join-Path $RepoPath 'scripts\build.ps1'
    if (-not (Test-Path -LiteralPath $buildScript)) { throw "Build script não encontrado: $buildScript" }
    $efiDir = Join-Path $RepoPath 'dist\EFI'
    if (Test-Path -LiteralPath $efiDir) {
        Ok 'dist\EFI já existe; build será reutilizado.'
    } else {
        Run 'scripts\build.ps1'
        & $buildScript
        if ($LASTEXITCODE -ne 0) { throw "build.ps1 falhou (exit code $LASTEXITCODE)." }
        Ok 'OpenCore/EFI construído.'
    }
    Complete-Stage

    # 8
    Write-Stage 'Preparando macOS Sequoia Recovery'
    $recoveryDestination = Join-Path $RepoPath 'com.apple.recovery.boot'
    if (Test-Path -LiteralPath $recoveryDestination) {
        Ok 'Recovery já existe no repositório de build.'
    } else {
        $recoveryScript = Join-Path $RepoPath 'scripts\lib\create-macos-recovery.ps1'
        if (-not (Test-Path -LiteralPath $recoveryScript)) { throw "Script de Recovery não encontrado: $recoveryScript" }
        $macrecovery = Find-MacRecoveryScript $RepoPath
        if ($null -eq $macrecovery) {
            $ocPath = Join-Path $RootPath 'OpenCorePkg'
            if (-not (Test-Path -LiteralPath (Join-Path $ocPath '.git'))) {
                Run "git clone --depth 1 https://github.com/acidanthera/OpenCorePkg.git $ocPath"
                git clone --depth 1 'https://github.com/acidanthera/OpenCorePkg.git' $ocPath
                if ($LASTEXITCODE -ne 0) { throw 'Falha ao obter OpenCorePkg.' }
            }
            $macrecovery = Find-MacRecoveryScript $ocPath
        }
        if ($null -eq $macrecovery) { throw 'macrecovery.py não foi encontrado.' }
        Ensure-Directory $recoveryDestination
        if (Command-Exists 'python') { $py = 'python' } elseif (Command-Exists 'py') { $py = 'py' } else { throw 'Python é necessário para executar macrecovery.py.' }
        Push-Location $RepoPath
        try {
            Run "$py macrecovery.py -b Mac-7BA5B2D9E42DDD94 -m 00000000000000000 -o $recoveryDestination download"
            & $py $macrecovery -b 'Mac-7BA5B2D9E42DDD94' -m '00000000000000000' -o $recoveryDestination download
            if ($LASTEXITCODE -ne 0) { throw "macrecovery.py falhou (exit code $LASTEXITCODE)." }
        } finally { Pop-Location }
        Ok 'macOS Sequoia Recovery preparado.'
    }
    Complete-Stage

    # 9
    Write-Stage 'Criando EFI.vhdx'
    New-EfiVhd
    Complete-Stage

    # 10
    Write-Stage 'Criando disco principal da VM'
    New-OsVhd
    Complete-Stage

    # 11
    Write-Stage 'Criando / configurando VM Hyper-V'
    Configure-Vm
    Complete-Stage

    Write-Progress -Id 0 -Activity 'OSX-Hyper-V build' -Status 'BUILD COMPLETE' -PercentComplete 100
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Green
    Write-Host 'BUILD COMPLETE' -ForegroundColor Green
    Write-Host ('=' * 70) -ForegroundColor Green
    Write-Host ''
    Ok "VM: $VmName"
    Ok "Workspace: $RootPath"
    Ok "EFI: $EfiVhdPath"
    Ok "OS disk: $OsVhdPath"
    Write-Host ''
    Step 'Próximo passo: iniciar a VM no Hyper-V Manager e executar a instalação interativa do macOS.'
    Step 'Depois da instalação, configurar SSH no macOS para Pair to Mac / Visual Studio.'
}
catch {
    Write-Progress -Id 0 -Activity 'OSX-Hyper-V build' -Completed
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Red
    Fail 'BUILD FAILED'
    Write-Host ''
    Write-Host "Stage : $Stage/$StageTotal" -ForegroundColor Yellow
    Write-Host "Stage : $StageName" -ForegroundColor Yellow
    Write-Host "Erro  : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Host "Estado preservado em: $RootPath" -ForegroundColor Yellow
    Write-Host ''
    if ($RebootRequired) {
        Write-Host 'REINICIALIZAÇÃO NECESSÁRIA' -ForegroundColor Yellow
        Write-Host 'Após reiniciar, execute novamente o mesmo comando. Os stages anteriores serão reutilizados.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Rollback:' -ForegroundColor Yellow
    Write-Host ".\Install-OSX-HyperV.ps1 -Drive $Drive -VmName `"$VmName`" -Rollback" -ForegroundColor White
    exit 1
}
finally {
    if ($TranscriptStarted) { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null }
}
