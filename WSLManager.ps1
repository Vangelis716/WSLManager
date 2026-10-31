#Requires -Version 5.1
<#
.SYNOPSIS
    WPF GUI to manage WSL instances.
.PARAMETER StorageRoot
    Overrides the configured default location for new instances for this session only.
#>
param(
    [string]$StorageRoot
)

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $relaunch = '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    if ($StorageRoot) { $relaunch += '-StorageRoot', "`"$StorageRoot`"" }
    Start-Process powershell.exe -ArgumentList $relaunch
    return
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:LibDir = Join-Path $PSScriptRoot 'lib'
Import-Module (Join-Path $script:LibDir 'Wsl.psm1') -Force
Import-Module (Join-Path $script:LibDir 'Metadata.psm1') -Force
Import-Module (Join-Path $script:LibDir 'WslConfig.psm1') -Force

# Metadata lives in the user profile so it is independent of the (configurable) storage location.
$script:DefaultStorageRoot = 'D:\WSL'
$metaDir = Join-Path $env:APPDATA 'WSLManager'
$metaPath = Join-Path $metaDir 'wslmanager.json'
$legacyMeta = Join-Path $script:DefaultStorageRoot 'wslmanager.json'
if (-not (Test-Path -LiteralPath $metaPath) -and (Test-Path -LiteralPath $legacyMeta)) {
    New-Item -ItemType Directory -Force -Path $metaDir | Out-Null
    Move-Item -LiteralPath $legacyMeta $metaPath
    Remove-Item -LiteralPath "$legacyMeta.bak" -ErrorAction SilentlyContinue
}
Initialize-Metadata -Path $metaPath
if (-not (Get-ManagerSetting 'defaultProfile')) { Set-ManagerSetting 'defaultProfile' (Get-WslConfigProfile) }

$script:NeedsStorageSetup = -not $StorageRoot -and -not (Get-ManagerSetting 'storageRoot')
$script:StorageRoot = if ($StorageRoot) { $StorageRoot }
                      elseif (Get-ManagerSetting 'storageRoot') { Get-ManagerSetting 'storageRoot' }
                      elseif (Test-Path -LiteralPath 'D:\') { $script:DefaultStorageRoot }
                      else { Join-Path $env:LOCALAPPDATA 'WSL' }   # suggestion only, shown in the first-run prompt

$script:NamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
$script:Instances = @()
$script:LastSignature = ''
$script:SuppressSelection = $false
$script:SelectedGuid = $null
$script:OsFetching = @{}
$script:Tasks = New-Object System.Collections.ArrayList

#region Theme + window
# Dark theme lives in Application resources so it also applies to every dialog.
$script:App = [Windows.Application]::Current
if (-not $script:App) { $script:App = New-Object Windows.Application; $script:App.ShutdownMode = 'OnExplicitShutdown' }
$themeXml = [xml](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Theme.xaml') -Raw -Encoding UTF8)
$script:App.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $themeXml)))

if (-not ('WslManager.DarkTitleBar' -as [type])) {
    Add-Type -Namespace WslManager -Name DarkTitleBar -MemberDefinition @'
[DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
public static void Apply(IntPtr hwnd) {
    int on = 1;
    if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref on, 4);
}
'@
}

function Enable-DarkTitleBar([Windows.Window]$Window) {
    $Window.Add_SourceInitialized({
        [WslManager.DarkTitleBar]::Apply((New-Object Windows.Interop.WindowInteropHelper $this).Handle)
    })
}

$xaml = [xml](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'WSLManager.xaml') -Raw -Encoding UTF8)
$script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
Enable-DarkTitleBar $script:Window
$script:UI = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $name = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $script:UI[$name] = $script:Window.FindName($name) }
}
$script:UI.lblCpu.Text = "CPUs (max $([Environment]::ProcessorCount))"
#endregion

#region Helpers
function Set-Status([string]$Text) {
    $script:UI.txtStatus.Text = "[$(Get-Date -Format HH:mm:ss)] $Text"
}

function Show-ThemedDialog {
    <# Dark replacement for MessageBox. Returns $true for OK/Yes, $false otherwise. #>
    param([string]$Text, [string]$Icon = 'Information', [switch]$YesNo, [Windows.Window]$Owner = $script:Window)
    $win = New-Object Windows.Window
    $win.Title = 'WSL Manager'; $win.SizeToContent = 'WidthAndHeight'; $win.ResizeMode = 'NoResize'
    $win.MinWidth = 360; $win.MaxWidth = 620; $win.ShowInTaskbar = $false
    if ($Owner -and $Owner.IsLoaded) { $win.Owner = $Owner; $win.WindowStartupLocation = 'CenterOwner' }
    else { $win.WindowStartupLocation = 'CenterScreen' }
    Enable-DarkTitleBar $win

    $glyph, $brush = switch ($Icon) {
        'Error'   { [char]0x2716, 'DangerBrush' }
        'Warning' { [char]0x26A0, 'DangerBrush' }
        default   { [char]0x2139, 'AccentBrush' }
    }
    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '18'
    foreach ($w in 'Auto', '*') {
        $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; $grid.ColumnDefinitions.Add($cd)
    }
    foreach ($h in '*', 'Auto') {
        $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = $h; $grid.RowDefinitions.Add($rd)
    }
    $glyphText = New-Object Windows.Controls.TextBlock
    $glyphText.Text = $glyph; $glyphText.FontSize = 22; $glyphText.Margin = '0,0,14,0'
    $glyphText.Foreground = $script:App.FindResource($brush)
    $msg = New-Object Windows.Controls.TextBlock
    $msg.Text = $Text; $msg.TextWrapping = 'Wrap'; $msg.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($msg, 1)
    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'; $buttons.Margin = '0,18,0,0'
    [Windows.Controls.Grid]::SetRow($buttons, 1); [Windows.Controls.Grid]::SetColumnSpan($buttons, 2)
    $labels = if ($YesNo) { 'Yes', 'No' } else { , 'OK' }
    foreach ($l in $labels) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $l; $b.MinWidth = 80
        $b.IsDefault = $l -ne 'No'; $b.IsCancel = $l -ne 'Yes'
        $b.Tag = $l -ne 'No'
        $b.Add_Click({ [Windows.Window]::GetWindow($this).Tag = $this.Tag; [Windows.Window]::GetWindow($this).Close() })
        [void]$buttons.Children.Add($b)
    }
    [void]$grid.Children.Add($glyphText); [void]$grid.Children.Add($msg); [void]$grid.Children.Add($buttons)
    $win.Content = $grid
    $win.Tag = $false
    [void]$win.ShowDialog()
    [bool]$win.Tag
}

function Show-Message([string]$Text, [string]$Icon = 'Information') {
    [void](Show-ThemedDialog -Text $Text -Icon $Icon)
}

function Confirm-Action([string]$Text) {
    Show-ThemedDialog -Text $Text -Icon Warning -YesNo
}

function Invoke-UiAction([scriptblock]$Action) {
    try { & $Action }
    catch {
        $text = $_.Exception.Message
        Set-Status "Error: $text"
        try { Show-Message $text 'Error' } catch { [void][Windows.MessageBox]::Show($text, 'WSL Manager') }
    }
}

function Format-Size($Bytes) {
    if ($null -eq $Bytes) { return '' }
    '{0:N1} GB' -f ($Bytes / 1GB)
}

function Get-SelectedInstance {
    if (-not $script:SelectedGuid) { return $null }
    $script:Instances | Where-Object Guid -eq $script:SelectedGuid | Select-Object -First 1
}

function Test-NewName([string]$Name) {
    if (-not $Name) { return 'Name is required.' }
    if ($Name -notmatch $script:NamePattern) { return 'Name may only contain letters, digits, dot, dash and underscore.' }
    if ($script:Instances | Where-Object { $_.Name -eq $Name }) { return "An instance named '$Name' already exists." }
    $null
}

function Get-DesiredProfile($Instance) {
    <# Merged CPU/RAM/swap for an instance, or $null when it has no preference. #>
    $res = (Get-InstanceMeta $Instance.Guid).resources
    if (-not $res -or -not ($res.processors -or $res.memory -or $res.swap)) { return $null }
    $default = Get-ManagerSetting 'defaultProfile'
    $merged = @{}
    foreach ($k in 'processors', 'memory', 'swap') {
        $merged[$k] = if ($res[$k]) { $res[$k] } elseif ($default) { $default[$k] } else { $null }
    }
    $merged
}
#endregion

#region Background tasks
function Start-BgTask {
    <# Runs $Script in a separate runspace (with Wsl.psm1 loaded); $OnSuccess gets ($Result, $Context) on the UI thread. #>
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$Arguments = @(),
        [scriptblock]$OnSuccess,
        [scriptblock]$OnFailure,
        $Context,
        [switch]$NonBlocking
    )
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
    $iss.ImportPSModule([string[]]@((Join-Path $script:LibDir 'Wsl.psm1')))
    $rs = [RunspaceFactory]::CreateRunspace($iss)
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('ErrorActionPreference', 'Stop')
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script.ToString())
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    [void]$script:Tasks.Add([pscustomobject]@{
        PS = $ps; Runspace = $rs; Handle = $ps.BeginInvoke(); Description = $Description
        OnSuccess = $OnSuccess; OnFailure = $OnFailure; Context = $Context; Blocking = -not $NonBlocking
    })
    if (-not $NonBlocking) { Set-Status "$Description..." }
    Update-Busy
}

function Complete-BgTasks {
    foreach ($t in @($script:Tasks)) {
        if (-not $t.Handle.IsCompleted -or -not $script:Tasks.Contains($t)) { continue }
        $script:Tasks.Remove($t)
        $result = $null; $errorText = $null
        try {
            $result = $t.PS.EndInvoke($t.Handle)
            if ($t.PS.Streams.Error.Count) { $errorText = ($t.PS.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n" }
        } catch {
            $ex = $_.Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            $errorText = $ex.Message
        } finally {
            $t.PS.Dispose(); $t.Runspace.Dispose()
        }
        Invoke-UiAction {
            if ($errorText) {
                if ($t.OnFailure) { & $t.OnFailure $errorText $t.Context }
                if ($t.Blocking) {
                    Set-Status "$($t.Description) failed."
                    Show-Message "$($t.Description) failed:`n`n$errorText" 'Error'
                }
            } else {
                if ($t.Blocking) { Set-Status "$($t.Description) - done." }
                if ($t.OnSuccess) { & $t.OnSuccess $result $t.Context }
            }
        }
    }
    Update-Busy
}

function Test-Busy { [bool]($script:Tasks | Where-Object Blocking) }

function Update-Busy {
    $script:UI.pbBusy.Visibility = if ($script:Tasks.Count) { 'Visible' } else { 'Collapsed' }
    Update-ButtonState
}
#endregion

#region Generic form dialog
function Show-FormDialog {
    <#
        Fields: @{ Name; Label; Type = Text|Multiline|Combo|File|Check|Note; Default; Items (Combo: @(@{Label;Value})); Filter (File) }
        Returns a hashtable of values, or $null when cancelled.
    #>
    param(
        [string]$Title,
        [object[]]$Fields,
        [string]$OkText = 'OK',
        [scriptblock]$Validate
    )
    $win = New-Object Windows.Window
    $win.Title = $Title; $win.SizeToContent = 'Height'; $win.Width = 520
    $win.WindowStartupLocation = 'CenterOwner'; $win.Owner = $script:Window; $win.ResizeMode = 'NoResize'
    $win.ShowInTaskbar = $false
    Enable-DarkTitleBar $win

    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = '14'
    $controls = @{}
    foreach ($f in $Fields) {
        if ($f.Type -ne 'Check' -and $f.Label) {
            $lbl = New-Object Windows.Controls.TextBlock
            $lbl.Text = $f.Label; $lbl.Margin = '0,6,0,2'; $lbl.TextWrapping = 'Wrap'
            if ($f.Type -eq 'Note') { $lbl.Foreground = $script:App.FindResource('MutedBrush') }
            [void]$panel.Children.Add($lbl)
        }
        switch ($f.Type) {
            'Combo' {
                $c = New-Object Windows.Controls.ComboBox
                foreach ($item in $f.Items) {
                    $ci = New-Object Windows.Controls.ComboBoxItem
                    $ci.Content = $item.Label; $ci.Tag = $item.Value
                    [void]$c.Items.Add($ci)
                    if ($null -ne $f.Default -and $item.Value -eq $f.Default) { $c.SelectedItem = $ci }
                }
                if ($c.SelectedIndex -lt 0 -and $c.Items.Count) { $c.SelectedIndex = 0 }
                $c.Padding = '4'
                [void]$panel.Children.Add($c); $controls[$f.Name] = $c
            }
            { $_ -in 'File', 'Folder' } {
                $dock = New-Object Windows.Controls.DockPanel
                $btn = New-Object Windows.Controls.Button
                $btn.Content = 'Browse...'; $btn.Margin = '6,0,0,0'; $btn.Padding = '8,2'
                [Windows.Controls.DockPanel]::SetDock($btn, 'Right')
                $tb = New-Object Windows.Controls.TextBox
                $tb.Padding = '3'; $tb.Text = [string]$f.Default
                $btn.Tag = @{ TextBox = $tb; Filter = $f.Filter }
                if ($f.Type -eq 'Folder') {
                    $btn.Add_Click({
                        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                        $dlg.SelectedPath = $this.Tag.TextBox.Text
                        $dlg.ShowNewFolderButton = $true
                        if ($dlg.ShowDialog() -eq 'OK') { $this.Tag.TextBox.Text = $dlg.SelectedPath }
                    })
                } else {
                    $btn.Add_Click({
                        $dlg = New-Object Microsoft.Win32.OpenFileDialog
                        $dlg.Filter = $this.Tag.Filter
                        if ($dlg.ShowDialog()) { $this.Tag.TextBox.Text = $dlg.FileName }
                    })
                }
                [void]$dock.Children.Add($btn); [void]$dock.Children.Add($tb)
                [void]$panel.Children.Add($dock); $controls[$f.Name] = $tb
            }
            'Check' {
                $cb = New-Object Windows.Controls.CheckBox
                $cb.Content = $f.Label; $cb.Margin = '0,8,0,0'; $cb.IsChecked = [bool]$f.Default
                [void]$panel.Children.Add($cb); $controls[$f.Name] = $cb
            }
            'Note' { }
            default {
                $tb = New-Object Windows.Controls.TextBox
                $tb.Padding = '3'; $tb.Text = [string]$f.Default
                if ($f.Type -eq 'Multiline') { $tb.AcceptsReturn = $true; $tb.TextWrapping = 'Wrap'; $tb.Height = 60 }
                [void]$panel.Children.Add($tb); $controls[$f.Name] = $tb
            }
        }
    }

    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'; $buttons.Margin = '0,14,0,0'
    $ok = New-Object Windows.Controls.Button
    $ok.Content = $OkText; $ok.IsDefault = $true; $ok.Padding = '14,4'; $ok.Margin = '0,0,6,0'
    $cancel = New-Object Windows.Controls.Button
    $cancel.Content = 'Cancel'; $cancel.IsCancel = $true; $cancel.Padding = '14,4'
    [void]$buttons.Children.Add($ok); [void]$buttons.Children.Add($cancel)
    [void]$panel.Children.Add($buttons)
    $win.Content = $panel

    $state = @{ Controls = $controls; Validate = $Validate; Values = $null }
    $win.Tag = $state
    $ok.Add_Click({
        $w = [Windows.Window]::GetWindow($this)
        $s = $w.Tag
        $values = @{}
        foreach ($k in $s.Controls.Keys) {
            $c = $s.Controls[$k]
            $values[$k] = if ($c -is [Windows.Controls.ComboBox]) { if ($c.SelectedItem) { $c.SelectedItem.Tag } }
                          elseif ($c -is [Windows.Controls.CheckBox]) { [bool]$c.IsChecked }
                          else { $c.Text.Trim() }
        }
        if ($s.Validate) {
            $err = & $s.Validate $values
            if ($err) { [void](Show-ThemedDialog -Text $err -Icon Warning -Owner $w); return }
        }
        $s.Values = $values
        $w.DialogResult = $true
    })
    if ($win.ShowDialog()) { return $state.Values }
    $null
}
#endregion

#region Refresh / display
function Update-InstanceList {
    $script:Instances = @(Get-WslInstance | Sort-Object Name)
    Resolve-PendingMeta $script:Instances

    $rows = @(foreach ($i in $script:Instances) {
        $meta = Get-InstanceMeta $i.Guid
        $label = if ($meta.displayName -and $meta.displayName -ne $i.Name) { "$($meta.displayName) ($($i.Name))" } else { $i.Name }
        $os = if ($meta.os) { $meta.os.pretty } else { '' }
        $profileText = Format-Profile (Get-DesiredProfile $i)
        [pscustomobject]@{
            Guid         = $i.Guid
            DefaultMark  = if ($i.IsDefault) { '★' } else { '' }
            DisplayLabel = $label
            State        = $i.State
            OS           = $os
            Version      = $i.Version
            SizeText     = Format-Size $i.VhdSize
            ProfileText  = if ($profileText) { $profileText } else { '(active)' }
        }
    })
    $signature = ($rows | ForEach-Object { "$($_.Guid)|$($_.DisplayLabel)|$($_.State)|$($_.OS)|$($_.SizeText)|$($_.ProfileText)|$($_.DefaultMark)" }) -join ';'
    if ($signature -ne $script:LastSignature) {
        $script:LastSignature = $signature
        $script:SuppressSelection = $true
        $list = New-Object System.Collections.ArrayList
        foreach ($r in $rows) { [void]$list.Add($r) }
        $script:UI.gridInstances.ItemsSource = $list
        $script:UI.gridInstances.SelectedItem = $rows | Where-Object Guid -eq $script:SelectedGuid | Select-Object -First 1
        $script:SuppressSelection = $false
        if (-not ($script:Instances | Where-Object Guid -eq $script:SelectedGuid)) { $script:SelectedGuid = $null; Show-Detail }
    }

    # Detect OS for running instances that have not been checked yet (cheap: they are already booted).
    foreach ($i in $script:Instances | Where-Object State -eq 'Running') {
        if ((Get-InstanceMeta $i.Guid).os -or $script:OsFetching[$i.Guid]) { continue }
        Request-OsInfo $i -Quiet
    }
    Update-ProfileStatus
    Update-ButtonState
}

function Update-ProfileStatus {
    $owner = Get-ManagerSetting 'activeProfileOwner'
    $text = "VM profile: $(Format-Profile (Get-WslConfigProfile))"
    if ($owner) { $text += "  (applied for $owner)" }
    $script:UI.txtProfile.Text = $text
}

function Show-Detail {
    $inst = Get-SelectedInstance
    $ui = $script:UI
    $ui.panelDetail.IsEnabled = [bool]$inst
    if (-not $inst) {
        foreach ($n in 'txtDisplayName', 'txtDescription', 'txtRealName', 'txtCpu', 'txtMem', 'txtSwap', 'txtDiskSize') { $ui[$n].Text = '' }
        $ui.txtInfo.Text = ''; $ui.txtOs.Text = ''
        return
    }
    $meta = Get-InstanceMeta $inst.Guid
    $ui.txtDisplayName.Text = if ($meta.displayName) { $meta.displayName } else { $inst.Name }
    $ui.txtDescription.Text = [string]$meta.description
    $ui.txtRealName.Text = $inst.Name
    $ui.txtInfo.Text = "GUID  $($inst.Guid)`nVHDX  $($inst.VhdPath)`nSize  $(Format-Size $inst.VhdSize)   Default UID $($inst.DefaultUid)"
    $ui.txtOs.Text = if ($meta.os) { "$($meta.os.pretty)`nKernel $($meta.os.kernel)`nChecked $($meta.os.checked)" } else { 'Unknown - start the instance or click Detect.' }
    $res = $meta.resources
    $ui.txtCpu.Text = if ($res) { [string]$res.processors } else { '' }
    $ui.txtMem.Text = if ($res) { [string]$res.memory } else { '' }
    $ui.txtSwap.Text = if ($res) { [string]$res.swap } else { '' }
    $ui.txtDiskSize.Text = ''
}

function Update-ButtonState {
    $ui = $script:UI
    $busy = Test-Busy
    $inst = Get-SelectedInstance
    $running = $inst -and $inst.State -eq 'Running'
    $ui.btnNewOnline.IsEnabled = -not $busy
    $ui.btnImport.IsEnabled = -not $busy
    $ui.btnClone.IsEnabled = -not $busy -and $script:Instances.Count
    $ui.btnShutdownAll.IsEnabled = -not $busy
    $ui.btnDefaultProfile.IsEnabled = -not $busy
    $ui.btnStorage.IsEnabled = -not $busy
    $ui.btnStart.IsEnabled = -not $busy -and $inst -and -not $running
    $ui.btnStop.IsEnabled = -not $busy -and $running
    $ui.btnRestart.IsEnabled = -not $busy -and $running
    $ui.btnTerminal.IsEnabled = [bool]$inst
    $ui.btnOpenFiles.IsEnabled = [bool]$inst
    $ui.btnDelete.IsEnabled = -not $busy -and $inst
    $ui.btnRename.IsEnabled = -not $busy -and $inst -and -not $running
    $ui.btnResize.IsEnabled = -not $busy -and $inst -and -not $running
    $ui.btnRefreshOs.IsEnabled = -not $busy -and $inst -and -not $script:OsFetching[$inst.Guid]
    $ui.btnSetDefault.IsEnabled = -not $busy -and $inst -and -not $inst.IsDefault
}

function Request-OsInfo($Instance, [switch]$Quiet) {
    $script:OsFetching[$Instance.Guid] = $true
    Start-BgTask -Description "Detecting OS of $($Instance.Name)" -NonBlocking:$Quiet -Context $Instance.Guid `
        -Arguments $Instance.Name -Script { param($n) Get-WslOsInfo -Name $n } `
        -OnSuccess { param($result, $guid)
            $script:OsFetching.Remove($guid)
            Set-InstanceMeta -Guid $guid -Values @{ os = $result[0] }
            Update-InstanceList
            if ($script:SelectedGuid -eq $guid) { Show-Detail }
        } `
        -OnFailure { param($err, $guid) $script:OsFetching.Remove($guid) }
}
#endregion

#region Actions
function Start-SelectedInstance([switch]$Restart) {
    $inst = Get-SelectedInstance
    if (-not $inst) { return }
    $desired = Get-DesiredProfile $inst
    $needSwitch = $desired -and -not (Test-ProfileEqual $desired (Get-WslConfigProfile))

    if ($needSwitch) {
        $running = @($script:Instances | Where-Object { $_.State -eq 'Running' -and $_.Guid -ne $inst.Guid } | ForEach-Object Name)
        $msg = "Applying the profile of '$($inst.Name)' ($(Format-Profile $desired)) rewrites .wslconfig and restarts WSL."
        if ($running) { $msg += "`n`nThis will also stop: $($running -join ', ')" }
        if (-not (Confirm-Action "$msg`n`nContinue?")) { return }
        Set-WslConfigProfile -Resources $desired
        Set-ManagerSetting 'activeProfileOwner' $inst.Name
        Start-BgTask -Description "Applying profile and starting $($inst.Name)" -Arguments $inst.Name `
            -Script { param($n) Stop-WslAll; Start-Sleep -Seconds 2; Start-WslInstance -Name $n } `
            -OnSuccess { Update-InstanceList }
        return
    }

    $verb = if ($Restart) { 'Restarting' } else { 'Starting' }
    Start-BgTask -Description "$verb $($inst.Name)" -Arguments @($inst.Name, $Restart.IsPresent) `
        -Script { param($n, $restart)
            if ($restart) { Stop-WslInstance -Name $n }
            Start-WslInstance -Name $n
            Start-Sleep -Seconds 2
        } `
        -OnSuccess { Update-InstanceList }
}

function Stop-SelectedInstance {
    $inst = Get-SelectedInstance
    if (-not $inst) { return }
    Start-BgTask -Description "Stopping $($inst.Name)" -Arguments $inst.Name `
        -Script { param($n) Stop-WslInstance -Name $n } -OnSuccess { Update-InstanceList }
}

function Remove-SelectedInstance {
    $inst = Get-SelectedInstance
    if (-not $inst) { return }
    $v = Show-FormDialog -Title "Delete $($inst.Name)" -OkText 'Delete permanently' -Fields @(
        @{ Type = 'Note'; Label = "This unregisters '$($inst.Name)' and PERMANENTLY deletes its disk:`n$($inst.VhdPath) ($(Format-Size $inst.VhdSize))" }
        @{ Name = 'confirm'; Label = "Type the instance name to confirm:"; Type = 'Text' }
    ) -Validate { param($v) if ($v.confirm -cne $script:SelectedName) { 'The name does not match.' } }
    if (-not $v) { return }
    Start-BgTask -Description "Deleting $($inst.Name)" -Arguments $inst.Name -Context @{ Guid = $inst.Guid; BasePath = $inst.BasePath; Name = $inst.Name } `
        -Script { param($n) Remove-WslInstance -Name $n } `
        -OnSuccess { param($r, $ctx)
            Remove-InstanceMeta -Guid $ctx.Guid
            # Only remove a per-instance folder (named after the instance) and only when it is empty,
            # so a shared storage folder is never deleted.
            if ($ctx.BasePath -and (Split-Path $ctx.BasePath.TrimEnd('\') -Leaf) -eq $ctx.Name -and
                (Test-Path -LiteralPath $ctx.BasePath) -and -not (Get-ChildItem -LiteralPath $ctx.BasePath -Force)) {
                Remove-Item -LiteralPath $ctx.BasePath -Force
            }
            $script:SelectedGuid = $null
            Update-InstanceList
            Show-Detail
        }
}

function Get-MetaFields([string]$DefaultDescription = '') {
    @(
        @{ Name = 'displayName'; Label = 'Display name (optional)'; Type = 'Text' }
        @{ Name = 'description'; Label = 'Description (optional)'; Type = 'Multiline'; Default = $DefaultDescription }
    )
}

function New-OnlineInstance {
    Start-BgTask -Description 'Loading online distribution list' -Script { Get-WslOnlineList } -OnSuccess {
        param($list)
        $items = @($list | ForEach-Object { @{ Label = "$($_.FriendlyName)   [$($_.Name)]"; Value = $_.Name } })
        $v = Show-FormDialog -Title 'New instance from online catalog' -OkText 'Install' -Fields (@(
            @{ Name = 'distro'; Label = 'Distribution'; Type = 'Combo'; Items = $items }
            @{ Name = 'name'; Label = 'Instance name (letters, digits, . _ -)'; Type = 'Text' }
            @{ Name = 'location'; Label = "Folder (blank = $script:StorageRoot\<name>)"; Type = 'Text' }
        ) + (Get-MetaFields) + @(
            @{ Type = 'Note'; Label = 'Installation runs in a console window, where you create the Linux user on first start.' }
        )) -Validate { param($v) Test-NewName $v.name }
        if (-not $v) { return }
        $location = if ($v.location) { $v.location } else { Join-Path $script:StorageRoot $v.name }
        Add-PendingMeta -Name $v.name -Values @{ displayName = $v.displayName; description = $v.description }
        New-WslFromOnline -Distro $v.distro -Name $v.name -Location $location | Out-Null
        Set-Status "Installing $($v.distro) as $($v.name) in a console window - it appears here once registered."
    }
}

function New-CloneInstance {
    $src = Get-SelectedInstance
    $items = @($script:Instances | ForEach-Object { @{ Label = $_.Name; Value = $_.Name } })
    $v = Show-FormDialog -Title 'Clone instance' -OkText 'Clone' -Fields (@(
        @{ Name = 'source'; Label = 'Source instance'; Type = 'Combo'; Items = $items; Default = $(if ($src) { $src.Name }) }
        @{ Name = 'name'; Label = 'New instance name'; Type = 'Text' }
    ) + (Get-MetaFields) + @(
        @{ Type = 'Note'; Label = "The clone is created in $script:StorageRoot\<name>. The source is stopped during export." }
    )) -Validate { param($v) Test-NewName $v.name }
    if (-not $v) { return }

    $source = $script:Instances | Where-Object Name -eq $v.source
    if ($source.State -eq 'Running' -and -not (Confirm-Action "'$($source.Name)' is running and will be stopped for the export. Continue?")) { return }
    $srcMeta = Get-InstanceMeta $source.Guid
    $desc = if ($v.description) { $v.description } else { "Clone of $($source.Name)" }
    Add-PendingMeta -Name $v.name -Values @{ displayName = $v.displayName; description = $desc; os = $srcMeta.os; resources = $srcMeta.resources }
    Start-BgTask -Description "Cloning $($source.Name) to $($v.name) (this can take a while)" `
        -Arguments $source.Name, $v.name, (Join-Path $script:StorageRoot $v.name) -Context $v.name `
        -Script { param($s, $n, $loc)
            if ((Get-WslState)[$s] -eq 'Running') { Stop-WslInstance -Name $s }
            New-WslClone -Source $s -Name $n -Location $loc
        } `
        -OnSuccess { Update-InstanceList } `
        -OnFailure { param($err, $name) Remove-PendingMeta -Name $name }
}

function Import-VhdxInstance {
    $v = Show-FormDialog -Title 'Import existing VHDX' -OkText 'Import' -Fields (@(
        @{ Name = 'path'; Label = 'VHDX file (registered in place, not copied)'; Type = 'File'; Filter = 'Virtual disks (*.vhdx)|*.vhdx'; Default = $script:StorageRoot }
        @{ Name = 'name'; Label = 'Instance name'; Type = 'Text' }
        @{ Name = 'user'; Label = 'Default Linux user (optional, blank = root)'; Type = 'Text' }
    ) + (Get-MetaFields)) -Validate {
        param($v)
        if (-not (Test-Path -LiteralPath $v.path -PathType Leaf)) { return 'Select an existing .vhdx file.' }
        Test-NewName $v.name
    }
    if (-not $v) { return }
    Add-PendingMeta -Name $v.name -Values @{ displayName = $v.displayName; description = $v.description }
    Start-BgTask -Description "Importing $($v.path) as $($v.name)" -Arguments $v.name, $v.path, $v.user -Context $v.name `
        -Script { param($n, $p, $u) Register-WslVhdx -Name $n -Path $p -DefaultUser $u } `
        -OnSuccess { Update-InstanceList } `
        -OnFailure { param($err, $name) Remove-PendingMeta -Name $name }
}

function Save-SelectedDetail {
    $inst = Get-SelectedInstance
    if (-not $inst) { return }
    $ui = $script:UI
    $res = @{ processors = $ui.txtCpu.Text.Trim(); memory = $ui.txtMem.Text.Trim().ToUpper(); swap = $ui.txtSwap.Text.Trim().ToUpper() }
    $err = Test-ProfileValues -Resources $res
    if ($err) { Show-Message $err 'Warning'; return }
    $hasRes = $res.processors -or $res.memory -or $res.swap
    $display = $ui.txtDisplayName.Text.Trim()
    if ($display -eq $inst.Name) { $display = '' }
    Set-InstanceMeta -Guid $inst.Guid -Values @{
        displayName = $display
        description = $ui.txtDescription.Text.Trim()
        resources   = if ($hasRes) { $res } else { $null }
    }
    Update-InstanceList
    $msg = "Saved $($inst.Name)."
    if ($inst.State -eq 'Running' -and $hasRes -and -not (Test-ProfileEqual (Get-DesiredProfile $inst) (Get-WslConfigProfile))) {
        $msg += ' Profile takes effect on next Restart.'
    }
    Set-Status $msg
}

function Rename-SelectedInstance {
    $inst = Get-SelectedInstance
    $new = $script:UI.txtRealName.Text.Trim()
    if (-not $inst -or $new -ceq $inst.Name) { return }
    if ($inst.State -eq 'Running') { Show-Message 'Stop the instance before renaming.' 'Warning'; return }
    $err = Test-NewName $new
    if ($err) { Show-Message $err 'Warning'; return }
    if (-not (Confirm-Action "Rename WSL instance '$($inst.Name)' to '$new'?`n`nScripts, shortcuts and Windows Terminal profiles that use 'wsl -d $($inst.Name)' must be updated manually.")) { return }
    $ok = Rename-WslInstance -Guid $inst.Guid -NewName $new
    if (-not $ok) { Show-Message "The registry was updated, but WSL still reports the old name. Use 'Shutdown WSL' to make the rename take effect." 'Warning' }
    if ((Get-ManagerSetting 'activeProfileOwner') -eq $inst.Name) { Set-ManagerSetting 'activeProfileOwner' $new }
    Set-Status "Renamed $($inst.Name) to $new."
    Update-InstanceList
    Show-Detail
}

function Resize-SelectedDisk {
    $inst = Get-SelectedInstance
    $size = $script:UI.txtDiskSize.Text.Trim().ToUpper()
    if (-not $inst) { return }
    if ($size -notmatch '^\d+(MB|GB|TB)$') { Show-Message 'Enter a size like 256GB.' 'Warning'; return }
    if (-not (Confirm-Action "Set the maximum disk size of '$($inst.Name)' to $size?")) { return }
    Start-BgTask -Description "Resizing disk of $($inst.Name) to $size" -Arguments $inst.Name, $size `
        -Script { param($n, $s) Resize-WslDisk -Name $n -Size $s } -OnSuccess { Update-InstanceList }
}

function Edit-StorageLocation([switch]$FirstRun) {
    <# Returns $true when a location was saved. #>
    $note = if ($FirstRun) {
        "Welcome to WSL Manager. Choose the default folder where new WSL instances will be stored. New instances are created in <folder>\<name>.`n`nYou can change this later with Storage location."
    } else {
        'New instances (online install and clones) are created in <folder>\<name>. Existing instances stay where they are.'
    }
    $v = Show-FormDialog -Title 'Storage location' -OkText 'Save' -Fields @(
        @{ Type = 'Note'; Label = $note }
        @{ Name = 'root'; Label = 'Default storage folder'; Type = 'Folder'; Default = $script:StorageRoot }
    ) -Validate {
        param($v)
        if (-not $v.root) { return 'Choose a folder.' }
        if (-not [IO.Path]::IsPathRooted($v.root) -or $v.root -match '^\\\\') { return 'Use a full local path, e.g. E:\WSL.' }
        if (-not (Test-Path -LiteralPath (Split-Path $v.root -Qualifier))) { return "Drive $(Split-Path $v.root -Qualifier) does not exist." }
    }
    if (-not $v) { return $false }
    $root = $v.root.TrimEnd('\')
    if ($root -match '^[A-Za-z]:$') { $root += '\' }
    if (-not (Test-Path -LiteralPath $root)) {
        if (-not (Confirm-Action "Folder '$root' does not exist. Create it?")) { return $false }
        New-Item -ItemType Directory -Force -Path $root | Out-Null
    }
    Set-ManagerSetting 'storageRoot' $root
    $script:StorageRoot = $root
    Update-StorageStatus
    Set-Status "Default storage location set to $root."
    $true
}

function Request-InitialStorageLocation {
    <# First run: a storage location is required. Returns $false if the user gives up (app closes). #>
    while (-not (Edit-StorageLocation -FirstRun)) {
        if (-not (Confirm-Action "A default storage location is required to use WSL Manager.`n`nChoose a folder now? (No closes the app.)")) {
            return $false
        }
    }
    $true
}

function Update-StorageStatus {
    $script:UI.txtStorage.Text = "Storage: $script:StorageRoot"
}

function Edit-DefaultProfile {
    $d = Get-ManagerSetting 'defaultProfile'
    if (-not $d) { $d = @{} }
    $v = Show-FormDialog -Title 'Default VM profile' -OkText 'Save' -Fields @(
        @{ Type = 'Note'; Label = 'Used to fill blank fields of instance profiles. Blank here = WSL default.' }
        @{ Name = 'processors'; Label = "CPUs (max $([Environment]::ProcessorCount))"; Type = 'Text'; Default = $d.processors }
        @{ Name = 'memory'; Label = 'Memory (e.g. 24GB)'; Type = 'Text'; Default = $d.memory }
        @{ Name = 'swap'; Label = 'Swap (e.g. 8GB)'; Type = 'Text'; Default = $d.swap }
        @{ Name = 'apply'; Label = 'Apply to .wslconfig now (restarts WSL, stops all instances)'; Type = 'Check' }
    ) -Validate { param($v) Test-ProfileValues -Resources @{ processors = $v.processors; memory = $v.memory.ToUpper(); swap = $v.swap.ToUpper() } }
    if (-not $v) { return }
    $p = @{ processors = $v.processors; memory = $v.memory.ToUpper(); swap = $v.swap.ToUpper() }
    Set-ManagerSetting 'defaultProfile' $p
    if ($v.apply) {
        Set-WslConfigProfile -Resources $p
        Set-ManagerSetting 'activeProfileOwner' 'default profile'
        Start-BgTask -Description 'Applying default profile' -Script { Stop-WslAll } -OnSuccess { Update-InstanceList }
    }
    Update-InstanceList
}
#endregion

#region Wire events
$ui = $script:UI
$ui.gridInstances.Add_SelectionChanged({
    if ($script:SuppressSelection) { return }
    $item = $script:UI.gridInstances.SelectedItem
    $script:SelectedGuid = if ($item) { $item.Guid } else { $null }
    $inst = Get-SelectedInstance
    $script:SelectedName = if ($inst) { $inst.Name } else { $null }
    Show-Detail
    Update-ButtonState
})
$ui.gridInstances.Add_MouseDoubleClick({ Invoke-UiAction { $i = Get-SelectedInstance; if ($i) { Open-WslTerminal -Name $i.Name } } })

$ui.btnNewOnline.Add_Click({ Invoke-UiAction { New-OnlineInstance } })
$ui.btnClone.Add_Click({ Invoke-UiAction { New-CloneInstance } })
$ui.btnImport.Add_Click({ Invoke-UiAction { Import-VhdxInstance } })
$ui.btnStart.Add_Click({ Invoke-UiAction { Start-SelectedInstance } })
$ui.btnStop.Add_Click({ Invoke-UiAction { Stop-SelectedInstance } })
$ui.btnRestart.Add_Click({ Invoke-UiAction { Start-SelectedInstance -Restart } })
$ui.btnTerminal.Add_Click({ Invoke-UiAction { Open-WslTerminal -Name (Get-SelectedInstance).Name } })
$ui.btnDelete.Add_Click({ Invoke-UiAction { Remove-SelectedInstance } })
$ui.btnRefresh.Add_Click({ Invoke-UiAction { $script:LastSignature = ''; Update-InstanceList; Show-Detail; Set-Status 'Refreshed.' } })
$ui.btnShutdownAll.Add_Click({
    Invoke-UiAction {
        if (Confirm-Action 'Shut down WSL completely? All running instances will stop.') {
            Start-BgTask -Description 'Shutting down WSL' -Script { Stop-WslAll } -OnSuccess { Update-InstanceList }
        }
    }
})
$ui.btnDefaultProfile.Add_Click({ Invoke-UiAction { Edit-DefaultProfile } })
$ui.btnStorage.Add_Click({ Invoke-UiAction { Edit-StorageLocation } })
$ui.btnSave.Add_Click({ Invoke-UiAction { Save-SelectedDetail } })
$ui.btnRename.Add_Click({ Invoke-UiAction { Rename-SelectedInstance } })
$ui.btnResize.Add_Click({ Invoke-UiAction { Resize-SelectedDisk } })
$ui.btnRefreshOs.Add_Click({ Invoke-UiAction { Request-OsInfo (Get-SelectedInstance) } })
$ui.btnSetDefault.Add_Click({ Invoke-UiAction { Set-WslDefault -Name (Get-SelectedInstance).Name; Update-InstanceList; Update-ButtonState } })
$ui.btnOpenFolder.Add_Click({ Invoke-UiAction { Start-Process explorer.exe -ArgumentList "/select,`"$((Get-SelectedInstance).VhdPath)`"" } })
$ui.btnOpenFiles.Add_Click({ Invoke-UiAction { Start-Process explorer.exe -ArgumentList "\\wsl.localhost\$((Get-SelectedInstance).Name)" } })

# Fast timer: background task completion. Slow timer: state polling.
$script:TaskTimer = New-Object Windows.Threading.DispatcherTimer
$script:TaskTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:TaskTimer.Add_Tick({ Complete-BgTasks })
$script:StateTimer = New-Object Windows.Threading.DispatcherTimer
$script:StateTimer.Interval = [TimeSpan]::FromSeconds(5)
$script:StateTimer.Add_Tick({ try { Update-InstanceList } catch { Set-Status "Refresh failed: $($_.Exception.Message)" } })

$script:Window.Add_Loaded({
    Invoke-UiAction { Update-StorageStatus; Update-InstanceList; Show-Detail; Set-Status 'Ready.' }
    $script:TaskTimer.Start()
    $script:StateTimer.Start()
})
# First run: ask for the storage location once the main window is visible.
$script:Window.Add_ContentRendered({
    if (-not $script:NeedsStorageSetup) { return }
    $script:NeedsStorageSetup = $false
    if (-not (Request-InitialStorageLocation)) { $script:Window.Close() }
})
$script:Window.Add_Closed({ $script:TaskTimer.Stop(); $script:StateTimer.Stop() })
#endregion

[void]$script:Window.ShowDialog()
