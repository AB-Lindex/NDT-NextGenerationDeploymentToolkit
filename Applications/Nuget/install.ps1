if (!(Get-PackageProvider | Where-Object {$_.Name -eq 'NuGet'})) {
	"Installing NuGet"
	Install-PackageProvider -Name NuGet -Force 
}
