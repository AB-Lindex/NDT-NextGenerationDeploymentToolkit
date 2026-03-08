if (!(Get-PackageProvider | Where-Object {$_.Name -eq 'NuGet'})) {
	"Installing NuGet"
	Install-PackageProvider -Name NuGet -Force 
}

$Module = 'SQLServer'
if (!(Get-Module -name $Module -ListAvailable)) {
	"Installing SQL Server Powershell Module"
	Install-Module -Name $Module -Scope AllUsers -force -AllowClobber
} else {
	"$Module is already installed"
}
$Module = 'DBATools'
if (!(Get-Module -name $Module -ListAvailable)) {
	"Installing DBATools Powershell Module"
	Install-Module -Name $Module -Scope AllUsers -force -AllowClobber
	Set-DbatoolsConfig -Name Import.SqlpsCheck -Value $false -PassThru | Register-DbatoolsConfig
} else {
	"$Module is already installed"
}

