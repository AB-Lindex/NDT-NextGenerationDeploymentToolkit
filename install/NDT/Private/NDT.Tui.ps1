# NDT TUI - add-computer form. PowerShell 7 only; dot-sourced by ndt.psm1 on PS7.
# Presentation only: all validation lives in Get-NDTCatalog / Test-NDTComputerEntry, the only write path is Add-NDTComputer.
# Handlers are built with [scriptblock]::Create (not GetNewClosure) so they keep module scope and can call private functions.
# Pinned to Terminal.Gui 1.x as shipped by Microsoft.PowerShell.ConsoleGuiTools 0.7.x (API differs in 2.x).

$script:NdtTui = $null

function Import-NDTTerminalGui {
    if (-not ('Terminal.Gui.Application' -as [type])) {
        $mod = Get-Module -ListAvailable -Name Microsoft.PowerShell.ConsoleGuiTools |
            Sort-Object Version -Descending | Select-Object -First 1
        if (-not $mod) {
            throw 'Microsoft.PowerShell.ConsoleGuiTools is required. Install it with: Install-Module Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser'
        }
        $dir = Split-Path $mod.Path
        foreach ($dll in 'NStack.dll', 'Terminal.Gui.dll') { Add-Type -Path (Join-Path $dir $dll) }
    }
    $ver = [Terminal.Gui.Application].Assembly.GetName().Version
    if ($ver.Major -ne 1) { throw "Terminal.Gui $ver is loaded; this TUI is built for Terminal.Gui 1.x (ConsoleGuiTools 0.7.x)." }
}

function Update-NDTTuiList {
    param([Parameter(Mandatory)][hashtable]$List)
    for ($i = 0; $i -lt $List.Names.Count; $i++) {
        $n = $List.Names[$i]
        $detail = if ($List.Details[$i]) { '  ' + $List.Details[$i] } else { '' }
        if ($List.Multi) {
            if ($List.Locked.Contains($n))       { $mark = '[x]' }
            elseif ($List.Checked.Contains($n))  { $mark = '[' + ($List.Checked.IndexOf($n) + 1) + ']' }
            else                                 { $mark = '[ ]' }
        } else {
            $mark = if ($List.Checked.Contains($n)) { '(o)' } else { '( )' }
        }
        $List.Rows[$i] = "$mark $n$detail"
    }
    $List.View.SetNeedsDisplay()
}

function New-NDTTuiList {
    # Marker list. Multi: [n] = position in the order checked. Single: (o). Locked rows are shown checked and cannot be toggled.
    param(
        [Parameter(Mandatory)][string]$Id,
        [string[]]$Names,
        [string[]]$Details,
        [bool]$Multi,
        [string[]]$Locked = @(),
        [string[]]$Initial = @(),
        [int]$X, [int]$Y, [int]$Height,
        [Parameter(Mandatory)][Terminal.Gui.View]$Parent
    )
    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $Names) { $rows.Add($n) }

    $lv = [Terminal.Gui.ListView]::new()
    $lv.X      = [Terminal.Gui.Pos]::At($X)
    $lv.Y      = [Terminal.Gui.Pos]::At($Y)
    $lv.Width  = [Terminal.Gui.Dim]::Fill(1)
    $lv.Height = [Terminal.Gui.Dim]::Sized($Height)
    $lv.SetSource($rows)
    $Parent.Add($lv)

    $checked = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $Initial) { $checked.Add($n) }
    $list = @{
        Id = $Id; View = $lv; Names = $Names; Details = $Details; Multi = $Multi
        Rows = $rows; Checked = $checked
        Locked = [System.Collections.Generic.HashSet[string]]::new([string[]]$Locked)
    }
    $script:NdtTui.Lists[$Id] = $list
    Update-NDTTuiList -List $list

    $handler = [scriptblock]::Create("param(`$a) Invoke-NDTTuiListKey -Id '$Id' -EventArgs `$a")
    $lv.add_KeyPress([System.Action[Terminal.Gui.View+KeyEventEventArgs]]$handler)

    # Hides itself when everything fits; shows arrows and a thumb when the list overflows.
    $sb = [Terminal.Gui.ScrollBarView]::new($lv, $true, $false)
    $list.ScrollBar = $sb
    $sb.add_ChangedPosition([System.Action][scriptblock]::Create("Sync-NDTTuiScroll -Id '$Id' -FromBar"))
    $lv.add_DrawContent([System.Action[Terminal.Gui.Rect]][scriptblock]::Create("param(`$r) Sync-NDTTuiScroll -Id '$Id'"))
    $list
}

function Sync-NDTTuiScroll {
    param([string]$Id, [switch]$FromBar)
    $list = $script:NdtTui.Lists[$Id]
    $lv = $list.View; $sb = $list.ScrollBar
    if ($FromBar) {
        $lv.TopItem = $sb.Position
        if ($lv.TopItem -ne $sb.Position) { $sb.Position = $lv.TopItem }
        $lv.SetNeedsDisplay()
    } else {
        $sb.Size = $list.Names.Count
        $sb.Position = $lv.TopItem
        $sb.Refresh()
    }
}

function Invoke-NDTTuiListKey {
    param([string]$Id, $EventArgs)
    try {
        $key = $EventArgs.KeyEvent.Key
        if ($key -ne [Terminal.Gui.Key]::Space -and $key -ne [Terminal.Gui.Key]::Enter) { return }
        $EventArgs.Handled = $true
        $list = $script:NdtTui.Lists[$Id]
        $idx  = $list.View.SelectedItem
        if ($idx -lt 0 -or $idx -ge $list.Names.Count) { return }
        $name = $list.Names[$idx]
        if ($list.Multi) {
            if ($list.Locked.Contains($name)) { return }
            if ($list.Checked.Contains($name)) { [void]$list.Checked.Remove($name) } else { $list.Checked.Add($name) }
        } else {
            $list.Checked.Clear(); $list.Checked.Add($name)
        }
        Update-NDTTuiList -List $list
        Update-NDTTuiStatus
    } catch { Show-NDTTuiError -Message $_.Exception.Message }
}

function Show-NDTTuiError {
    param([string]$Message, [string]$Title = 'Error')
    $lines = @($Message -split "`n").Count
    $w = [Math]::Min(80, [Terminal.Gui.Application]::Driver.Cols - 4)
    $h = [Math]::Min(8 + $lines, [Terminal.Gui.Application]::Driver.Rows - 2)
    [void][Terminal.Gui.MessageBox]::ErrorQuery($w, $h, $Title, $Message, [NStack.ustring[]]@('OK'))
}

function Get-NDTTuiEntry {
    # Machine entry exactly as the form currently describes it (MAC kept separately).
    $s = $script:NdtTui
    $osSel = @($s.Lists.OS.Checked)
    $fin   = @($s.Lists.Finish.Checked)

    $e = [ordered]@{}
    if ($osSel.Count)                       { $e.OS = $osSel[0] } else { $e.OS = '' }
    $e.Computername = $s.Fields.Computername.Text.ToString().Trim()
    $ip = $s.Fields.IPAddress.Text.ToString().Trim()
    if ($ip)                                { $e.IPAddress = $ip }
    $e.AdminPassword = $s.Fields.AdminPassword.Text.ToString()

    $secs = @($s.Lists.Sections.Checked)
    if ($secs.Count) {
        $o = [ordered]@{}
        foreach ($n in $secs) { $o[$n] = $n }
        $e.Sections = $o
    }
    $grps = @($s.Lists.Groups.Checked)
    if ($grps.Count)                        { $e.DeploymentGroups = $grps }
    if ($fin.Count -and $fin[0] -ne '(inherit)') { $e.FinishAction = $fin[0] }
    if ($s.Fields.InstallNo.Checked)        { $e.Install = 'NO' }
    $e
}

function Update-NDTTuiStatus {
    $s = $script:NdtTui
    if (-not $s.Status) { return }
    $entry = Get-NDTTuiEntry
    $overlaps = @(Get-NDTSectionOverlap -Entry $entry -SectionKeys $s.SectionKeys)
    if (-not $overlaps.Count) {
        $s.Status.Text = 'No overlapping keys between machine fields and checked sections.'
        return
    }
    $lines = foreach ($o in ($overlaps | Select-Object -First 3)) {
        $winner = if ($o.Winner -eq '(machine)') { 'machine' } else { $o.Winner }
        '! {0} set by: {1} (wins), {2}' -f $o.Key, $winner, ($o.Losers -join ', ')
    }
    if ($overlaps.Count -gt 3) { $lines += "  (+$($overlaps.Count - 3) more)" }
    $s.Status.Text = ($lines -join "`n")
}

function Show-NDTTuiConfirm {
    # Returns $true if the user chose Save.
    param([string]$Text)
    $s   = $script:NdtTui
    $w   = [Math]::Min(80, $s.Driver.Cols - 4)
    $h   = [Math]::Min(26, $s.Driver.Rows - 2)
    $dlg = [Terminal.Gui.Dialog]::new('Confirm - add computer', $w, $h)

    $tv = [Terminal.Gui.TextView]::new()
    $tv.X = [Terminal.Gui.Pos]::At(0); $tv.Y = [Terminal.Gui.Pos]::At(0)
    $tv.Width = [Terminal.Gui.Dim]::Fill(0); $tv.Height = [Terminal.Gui.Dim]::Fill(2)
    $tv.ReadOnly = $true
    $tv.Text = $Text
    $dlg.Add($tv)

    $s.Confirmed = $false
    $save = [Terminal.Gui.Button]::new('Save', $true)
    $back = [Terminal.Gui.Button]::new('Back')
    $save.add_Clicked([System.Action][scriptblock]::Create('$script:NdtTui.Confirmed = $true; [Terminal.Gui.Application]::RequestStop()'))
    $back.add_Clicked([System.Action][scriptblock]::Create('[Terminal.Gui.Application]::RequestStop()'))
    $dlg.AddButton($save)
    $dlg.AddButton($back)

    [Terminal.Gui.Application]::Run($dlg)
    $s.Confirmed
}

function Invoke-NDTTuiSave {
    $s = $script:NdtTui
    try {
        try {
            $rawMac = $s.Fields.MAC.Text.ToString()
            if (-not $rawMac.Trim()) { throw 'MAC address is required.' }
            $mac = ConvertTo-NDTMac $rawMac
        }
        catch { Show-NDTTuiError -Message $_.Exception.Message -Title 'MAC address'; return }

        $entry = Get-NDTTuiEntry
        $check = Test-NDTComputerEntry -Entry $entry -MAC $mac -LocalPath $s.LocalPath
        if (-not $check.Valid) {
            Show-NDTTuiError -Message ($check.Errors -join "`n") -Title 'Fix these before saving'
            return
        }

        $shown = [ordered]@{}
        foreach ($k in $entry.Keys) { $shown[$k] = $entry[$k] }
        $shown.AdminPassword = '********'
        $text = "$mac`n" + ($shown | ConvertTo-Json -Depth 5)
        foreach ($o in $check.Overlaps) { $text += "`n! $($o.Key): $($o.Winner) wins over $($o.Losers -join ', ')" }
        foreach ($w in $check.Warnings) { $text += "`n! $w" }

        if (-not (Show-NDTTuiConfirm -Text $text)) { return }

        $splat = @{
            LocalPath    = $s.LocalPath
            MAC          = $mac
            Computername = $entry.Computername
            OS           = $entry.OS
            LocalAdmin   = $entry.AdminPassword
        }
        if ($entry.Contains('IPAddress'))        { $splat.IPAddress        = $entry.IPAddress }
        if ($entry.Contains('Sections'))         { $splat.Sections         = $entry.Sections }
        if ($entry.Contains('DeploymentGroups')) { $splat.DeploymentGroups = $entry.DeploymentGroups }
        if ($entry.Contains('FinishAction'))     { $splat.FinishAction     = $entry.FinishAction }
        if ($entry.Contains('Install'))          { $splat.Install          = $entry.Install }

        $s.Result = Add-NDTComputer @splat
        [Terminal.Gui.Application]::RequestStop()
    } catch { Show-NDTTuiError -Message $_.Exception.Message -Title 'Save failed' }
}

function Show-NDTComputerForm {
    param([Parameter(Mandatory)][string]$LocalPath)

    Import-NDTTerminalGui
    $catalog = Get-NDTCatalog -LocalPath $LocalPath

    $script:NdtTui = @{
        LocalPath = $LocalPath; Lists = @{}; Fields = @{}; Status = $null
        Result = $null; Confirmed = $false; Driver = $null
        SectionKeys = @{}
    }
    $s = $script:NdtTui
    foreach ($sec in $catalog.Sections) { if (-not $sec.System) { $s.SectionKeys[$sec.Name] = $sec.Keys } }

    [Terminal.Gui.Application]::Init()
    try {
        $s.Driver = [Terminal.Gui.Application]::Driver
        if ($s.Driver.Cols -lt 100 -or $s.Driver.Rows -lt 28) {
            throw "Terminal is $($s.Driver.Cols)x$($s.Driver.Rows); the form needs at least 100x28. Enlarge or maximise the terminal."
        }

        $win = [Terminal.Gui.Window]::new('NDT - Add computer  (Tab: next  Space: toggle  Ctrl+Q: cancel)')
        $win.X = [Terminal.Gui.Pos]::At(0); $win.Y = [Terminal.Gui.Pos]::At(0)
        $win.Width = [Terminal.Gui.Dim]::Fill(0); $win.Height = [Terminal.Gui.Dim]::Fill(0)

        $label = {
            param([string]$Text, [int]$X, [int]$Y)
            $l = [Terminal.Gui.Label]::new($Text)
            $l.X = [Terminal.Gui.Pos]::At($X); $l.Y = [Terminal.Gui.Pos]::At($Y)
            $win.Add($l)
        }
        $field = {
            param([string]$Name, [string]$Text, [int]$Y, [bool]$Secret, [string]$Initial)
            & $label $Text 1 $Y
            $f = [Terminal.Gui.TextField]::new($Initial)
            $f.X = [Terminal.Gui.Pos]::At(17); $f.Y = [Terminal.Gui.Pos]::At($Y)
            $f.Width = [Terminal.Gui.Dim]::Sized(27)
            $f.Secret = $Secret
            $win.Add($f)
            $s.Fields[$Name] = $f
        }

        & $field 'MAC'           'MAC address:'   0 $false ''
        & $field 'Computername'  'Computername:'  1 $false ''
        & $field 'IPAddress'     'IP / DHCP:'     2 $false 'DHCP'
        & $field 'AdminPassword' 'Admin password:' 3 $true ''

        # Left column: OS, FinishAction, Install:NO
        & $label 'OS (Space = select):' 1 5
        $osList = New-NDTTuiList -Id OS -Names @($catalog.OS.Name) -Details @($catalog.OS | ForEach-Object { '' }) -Multi $false -X 1 -Y 6 -Height 4 -Parent $win
        $osList.View.Width = [Terminal.Gui.Dim]::Sized(43)

        & $label 'FinishAction:' 1 11
        $finNames = @('(inherit)') + @($catalog.FinishActions)
        $finList = New-NDTTuiList -Id Finish -Names $finNames -Details @($finNames | ForEach-Object { '' }) -Multi $false -Initial @('(inherit)') -X 1 -Y 12 -Height 6 -Parent $win
        $finList.View.Width = [Terminal.Gui.Dim]::Sized(43)

        $inst = [Terminal.Gui.CheckBox]::new('Install: NO (never wipe this machine)')
        $inst.X = [Terminal.Gui.Pos]::At(1); $inst.Y = [Terminal.Gui.Pos]::At(19)
        $inst.add_Toggled([System.Action[bool]][scriptblock]::Create('param($prev) Update-NDTTuiStatus'))
        $win.Add($inst)
        $s.Fields.InstallNo = $inst

        # Right column: Sections, DeploymentGroups
        & $label 'Sections (order checked = precedence; [x] = system, always applied):' 47 0
        $secNames   = @($catalog.Sections.Name)
        $secDetails = @($catalog.Sections | ForEach-Object { $_.Preview })
        $secLocked  = @($catalog.Sections | Where-Object System | ForEach-Object { $_.Name })
        $secList = New-NDTTuiList -Id Sections -Names $secNames -Details $secDetails -Multi $true -Locked $secLocked -X 47 -Y 1 -Height 9 -Parent $win

        & $label 'DeploymentGroups (order checked = run order):' 47 11
        $grpList = New-NDTTuiList -Id Groups -Names @($catalog.Groups.Name) -Details @($catalog.Groups | ForEach-Object { "$($_.Steps) steps" }) -Multi $true -X 47 -Y 12 -Height 6 -Parent $win

        # Bottom: overlap warnings and buttons
        $status = [Terminal.Gui.Label]::new('')
        $status.X = [Terminal.Gui.Pos]::At(1); $status.Y = [Terminal.Gui.Pos]::At(21)
        $status.Width = [Terminal.Gui.Dim]::Fill(1); $status.Height = [Terminal.Gui.Dim]::Sized(3)
        $win.Add($status)
        $s.Status = $status
        Update-NDTTuiStatus

        $btnSave = [Terminal.Gui.Button]::new('Review & save', $true)
        $btnSave.X = [Terminal.Gui.Pos]::At(1); $btnSave.Y = [Terminal.Gui.Pos]::At(25)
        $btnSave.add_Clicked([System.Action][scriptblock]::Create('Invoke-NDTTuiSave'))
        $btnCancel = [Terminal.Gui.Button]::new('Cancel')
        $btnCancel.X = [Terminal.Gui.Pos]::At(20); $btnCancel.Y = [Terminal.Gui.Pos]::At(25)
        $btnCancel.add_Clicked([System.Action][scriptblock]::Create('[Terminal.Gui.Application]::RequestStop()'))
        $win.Add($btnSave); $win.Add($btnCancel)

        [Terminal.Gui.Application]::Top.Add($win)
        $s.Fields.MAC.SetFocus()
        [Terminal.Gui.Application]::Run()
    }
    finally {
        [Terminal.Gui.Application]::Shutdown()
    }
    $s.Result
}
