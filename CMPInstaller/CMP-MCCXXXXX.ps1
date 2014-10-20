#
# This is CMP for MCC-91927 and its job is to replace existing Medidata.Core.Objects.dll with new ones.
# The affected Rave versions and nodes are stated in README.md
#
# Notice: This script needs an associated stored procedure from WHOIS database, 
#         which returns the deployment information for affected sites and nodes.
#

param(
	# The server name of WHOIS database.
	[Parameter(Mandatory=$true, Position=1)]
	[string]$whoisServerName,
	# WHOIS database User Name
	[Parameter(Mandatory=$false, Position=2)]
	[string]$whoisUser = "",
	# WHOIS database User Password
	[Parameter(Mandatory=$false, Position=3)]
	[string]$whoisPwd = "",
	# Log output folder. Aboslute path or relative path.
	[Parameter(Mandatory=$false, Position=4)]
	[string]$logFolder = "logs",
	# Waiting timeout in seconds for stopping/starting core service. 
	[Parameter(Mandatory=$false, Position=5)]
	[int]$serviceTimeoutSeconds = 30,
	# How many times to retry stopping/starting core service.
	[Parameter(Mandatory=$false, Position=6)]
	[int]$maxRetryTimes = 3
)

Add-Type -AssemblyName "System.ServiceProcess"
Add-Type -AssemblyName "System.IO"
Add-Type -AssemblyName "System.Transactions"

$minPowerShellVersion = 3

$patchNumber = "MCC-106898"
$assemblyFileName = "Medidata.Core.Objects.dll"
if([string]::IsNullOrEmpty($whoisUser) -or [string]::IsNullOrEmpty($whoisPwd))
{    
	$whoisConnectionString = [string]::Format("Data Source={0};Initial Catalog=whois;Integrated Security=SSPI; Connection Timeout=600", $whoisServerName)
}
else
{
	$whoisConnectionString = [string]::Format("Data Source={0};Initial Catalog=whois;uid={1};Password={2}; Connection Timeout=600", $whoisServerName, $whoisUser, $whoisPwd)
}

$workDir = Split-Path -parent $PSCommandPath
$siteTxtPath = [System.IO.Path]::Combine($workDir, "sites.txt")
$targetSites = Get-Content sites.txt | Foreach {$_.Trim().toLower()} | ? { $_.Length -gt 0 -and $_ -notmatch '^#'}
$absoluteLogFolder = $logFolder
if(-not [System.IO.Path]::IsPathRooted($absoluteLogFolder)){
	$absoluteLogFolder = [System.IO.Path]::Combine($workDir, $logFolder)
}
New-Item -force -path $absoluteLogFolder -type directory | Out-Null
$logPath = [System.IO.Path]::Combine($absoluteLogFolder, "log_" + [System.DateTime]::Now.ToString("yyyyMMdd HHmmss fff") + ".txt")

function Main(){
	if ($minPowerShellVersion -gt $host.version.major)  
	{
		Log-Info "Older version of PowerShell is detected. Require PowerShell 3 and above."
		Return
	}
	if($targetSites.Count -eq 0) {
		Log-Info "No site specified. Sites.txt doesn't exist or is empty."
		Return
	}

	Print-Arguments

	Log-Info "Query WHOIS server to get the deployment information for all sites."
	$sites = Get-SiteInfoFromWhoIs $whoisConnectionString | where {$targetSites -contains $_.Url.ToLower()}
	Log-Info ([String]::Format("According to WHOIS, there are {0} URLs to handle in all.", $sites.Length))
	$index = 1; $okCount = 0; $ngCount = 0; $siblingCount = 0
	ForEach($site in $sites) {
		Log-Info ([String]::Format("[{0}/{1}] Working on {2} (v{3}) which has {4} siblings", @($index, $sites.Length, $site.Url, $site.RaveVersion, $site.Nodes.Count)))
		try{
			$result = Patch-Site $site
		}catch{
			Log-Error $_
		}
		$index++
		if ($result){ $okCount++ } else { $ngCount++ }
		$siblingCount += $site.Nodes.Count
		Log-Info
	}
	Log-Info ([String]::Format("{0} URLs ({1} siblings) all finished. {2} patched, {3} failed.", $sites.Length, $siblingCount, $okCount, $ngCount))
}

function Print-Arguments(){
	Log-Info "Arguments"
	Log-Info ("  -whoisServerName       : " + $whoisServerName)
	Log-Info ("  -whoisUser             : " + $whoisUser)
	$pwdDisplay = $whoisPwd
	if($whoisPwd) { $pwdDisplay = "********************" }
	Log-Info ("  -whoisPwd              : " + $pwdDisplay)
	Log-Info ("  -logFolder             : " + $logFolder)
	Log-Info ("  -serviceTimeoutSeconds : " + $serviceTimeoutSeconds)
	Log-Info ("  -maxRetryTimes         : " + $maxRetryTimes)
	Log-Info
}

function Get-SiteInfoFromWhoIs($connectionString){
	$connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
	$rows = @()

	Try{
		$connection.Open()
		$cmd = $connection.CreateCommand()
		$cmd.CommandType = [System.Data.CommandType]::StoredProcedure
		$cmd.CommandText = "usp_GetActiveRaveServerConfiguration"
		$table = New-Object "System.Data.DataTable"
		$table.Load($cmd.ExecuteReader())

		$rows = $table | `
				Where-Object { $_.RaveVersion -in @("5.6.5.144")} | `
				Select-object Url, RaveVersion, DbServer, DbName, Account, Password, Type, ServerName, ServiceName, ServerRootPath
	} finally {
		$connection.Dispose()
	}

	$sites = @()
	$currentSite
	ForEach($row in $rows){
		if($null -eq $currentSite -or $currentSite.Url -ne $row.Url){
			if($null -ne $currentSite){ 
				$sites += $currentSite	
			}
			$dbConnStr = [string]::Format("Server={0};Database={1};uid={2};pwd={3};Connection Timeout=300", 
											$row.DbServer, 
											$row.DbName, 
											(Decrypt $row.Account), 
											(Decrypt $row.Password))
			$currentSite = @{ Url=$row.Url; RaveVersion=$row.RaveVersion; Nodes = @(); DbConnectionString = $dbConnStr; PatchNumber=$patchNumber}
		}

		$node = @{ Type=$row.Type; ServerName = $row.ServerName; Site=$currentSite }
		if($node.Type -eq "App"){
			$node.CoreServiceName = [string]::Format("Medidata Core Service - ""{0}""", $row.ServiceName)
			$node.IntegrationServiceName = [string]::Format("Medidata Rave Integration Service - ""{0}""", $row.ServiceName)
		}else{
			$node.RwsWebConfigPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($row.ServerRootPath, "..\Medidata.RaveWebServices\App\Medidata.RaveWebServices.Web\appsettings.config"))
			$node.AppSettingsPath = [System.IO.Path]::Combine($row.ServerRootPath, "appsettings.config")
		}
		$currentSite.Nodes += $node
	}

	if($null -ne $currentSite){	
		$sites += $currentSite	
	}

	return $sites
}

function Patch-Site($site){
	$connection = New-Object System.Data.SqlClient.SqlConnection $site.DbConnectionString
	Try{
		$connection.Open()
		$needsPatch = (Check-IfNeedToPatch $site $connection)
		if($needsPatch){
			Patch-SingleSite $site $connection
		}else{
			Log-Info("This site has been patched.")
		}

		return $true
	} catch {
		Log-Error($_)
	} finally {
		$connection.Dispose()
	}

	return $false
}

function Patch-SingleSite($site, $connection){
	Patch-Database $site $connection
	$site.Nodes | Where-Object { $_.Type -eq "Web" } | ForEach { ModifyConfigFiles $_ }

	$site.Nodes | Where-Object { $_.Type -eq "App" } | ForEach { Restart-Services $_ }
	$site.Nodes | Where-Object { $_.Type -eq "Web" } | ForEach { Restart-IIS $_ }
	Insert-PatchInfo $site $connection ([System.DateTime]::Now)
}

function Check-IfNeedToPatch($site, $connection){
	$cmd = $connection.CreateCommand();
	$cmd.CommandType = [System.Data.CommandType]::Text
	$cmd.CommandText = "SELECT CAST(COUNT(*) AS Bit) FROM RavePatches WHERE RaveVersion = @raveVersion AND PatchNumber = @patchNumber"
	[void]$cmd.Parameters.AddWithValue("@raveVersion", $site.RaveVersion)
	[void]$cmd.Parameters.AddWithValue("@patchNumber", $site.PatchNumber)
	$count = $cmd.ExecuteScalar()
	return ($count -le 0)
}

function Insert-PatchInfo($site, $connection, [System.DateTime] $dataApplied){
	$cmd = $connection.CreateCommand()
	$cmd.CommandType = [System.Data.CommandType]::Text
	$cmd.CommandText = "INSERT INTO RavePatches([RaveVersion], [PatchNumber], [version], [Description], [DateApplied], [Active], [AppliedBy]) VALUES (@RaveVersion, @PatchNumber, @version, @Description, @dataApplied, 1, NULL)"
	[void]$cmd.Parameters.AddWithValue("@RaveVersion", $site.RaveVersion)
	[void]$cmd.Parameters.AddWithValue("@PatchNumber", $site.PatchNumber)
	[void]$cmd.Parameters.AddWithValue("@version", 1)
	[void]$cmd.Parameters.AddWithValue("@dataApplied", $dataApplied)
	[void]$cmd.Parameters.AddWithValue("@Description", "Replace Medidata.Core.Objects.dll")
	$count = $cmd.ExecuteNonQuery()
	return ($count -eq 1)
}

function Patch-Database($site, $connection){
	# Execute SQL to patch database
	#### TODO
}

function ModifyConfigFiles($node){
	# Full path of Medidata.RaveWebServices.Web/web.config
	$node.RwsWebConfigPath

	# Full path of MedidataRave/appsettings.config
	$node.AppSettingsPath

	#### TODO
}

function Restart-Services($node){
	# Restart core service
	$coreService = get-Service $node.CoreServiceName -ComputerName $node.ServerName -ErrorAction stop
	Ope-CoreService $node $coreService "stop"
	Ope-CoreService $node $coreService "start"

	# Restart integration service
	$integrationService = get-Service $node.IntegrationServiceName -ComputerName $node.ServerName -ErrorAction stop
	Ope-CoreService $node $integrationService "stop"
	Ope-CoreService $node $integrationService "start"
}

function Restart-IIS($node){
	$iis = get-Service "W3SVC" -ComputerName $node.ServerName -ErrorAction stop
	Ope-CoreService $node $iis "stop"
	Ope-CoreService $node $iis "start"
}

function Ope-CoreService($node, $service, [string]$startOrStop){
	[System.ServiceProcess.ServiceControllerStatus]$waitStatus = [System.ServiceProcess.ServiceControllerStatus]::Stopped
	if($startOrStop -eq "start"){
		$waitStatus = [System.ServiceProcess.ServiceControllerStatus]::Running
	}
	
	try{
		$tryTime = 1
		while(($tryTime -le $maxRetryTimes) -and ($service.Status -ne $waitStatus)){
			Log-Info ([string]::Format("Starting core service '{0}' at {1}", $node.CoreServiceName, $node.ServerName))
			try{
				if($startOrStop -eq "start"){
					$service.Start()
				}else{
					$service.Stop()
				}
				$serviceTimeoutTimeSpan = New-Object System.TimeSpan 0, 0, $serviceTimeoutSeconds
				$service.WaitForStatus($waitStatus, $serviceTimeoutTimeSpan)
				$service.Refresh()
			}catch{
				if($tryTime -eq $maxRetryTimes) { throw }
				$tryTime++
			}
			Log-Info ("The core service now is " + $service.Status)
		}
	}finally{
		$service.Dispose()
	}
}

function ForceCopyFile($source, $destination, $actionName){
	Log-Info ([String]::Format("{0} file {1} -> {2}", $actionName, $source, $destination))
	if(!(Test-Path $destination)){
		new-item -force -path $destination -type file | Out-Null
	}
	[System.IO.File]::Copy($source, $destination, $true)
}

function Log-Info([string]$message){
	$regex = [regex] "(.*)(\[[0-9]+/[0-9]+])(.*)"
	if($regex.IsMatch($message)){
		$groups = $regex.Match($message).Groups
		$defaultBgColor = $host.UI.RawUI.BackgroundColor
		write-host ("> " + $groups[1].Value) -NoNewline
		write-host $groups[2].Value -NoNewline -BackgroundColor "yellow" -ForegroundColor "blue"
		write-host $groups[3].Value -BackgroundColor $defaultBgColor
	}else{
		write-host ("> " + $message)
	}
}

function Log-Error($errorRecord){
	$message = $errorRecord.ScriptStackTrace + "`r`n" + $errorRecord.Exception.ToString()
	write-error $message
}

#
# The decryption algorithm was ported from the C# source code of RavePassword tool.
# "34W45O7EJ4L23S2J3432L5F67T28JSD9I" is standard Medidata Rave password generation key.
# 
function Decrypt([string]$data){
	$dataBytes = [System.Convert]::FromBase64String($data)
	$tripleDes = New-Object System.Security.Cryptography.TripleDESCryptoServiceProvider
	$hashMd5 =  New-Object System.Security.Cryptography.MD5CryptoServiceProvider
	$tripleDes.Key = $hashMd5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("34W45O7EJ4L23S2J3432L5F67T28JSD9I")) 
	$tripleDes.Mode = [System.Security.Cryptography.CipherMode]::ECB
	$tripleDes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
	$cTransform = $tripleDes.CreateDecryptor()
	$decryptedBytes = $cTransform.TransformFinalBlock($dataBytes,0, ($dataBytes.Length))
	[void]$tripleDes.Clear()
	return [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
}

try{
	Start-Transcript -Path $logPath -Force -Append 
	Main
} finally {
	Stop-Transcript
}
