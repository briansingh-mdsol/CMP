#
# This is CMP for MCC-91927 and its job is to replace existing Medidata.Core.Objects.dll with new ones.
# The affected Rave versions and nodes are 
#    - 2013.2.0		(5.6.5.45) Application nodes
#    - 2013.2.0.1	(5.6.5.50) Application nodes
#    - 2013.3.0		(5.6.5.66) Application nodes
#    - 2013.3.0.1	(5.6.5.71) Application nodes
#    - 2013.4.0		(5.6.5.92) Application nodes and Web nodes
#
# Notice: This script needs an associated stored procedure from WHOIS database, 
#         which returns the deployment information for affected sites and nodes.
#

param(
	# The server name of WHOIS database.
	[Parameter(Mandatory=$true, Position=1)]
	[string]$whoisServerName,
	# Waiting timeout in seconds for stopping/starting core service. 
	[Parameter(Mandatory=$false, Position=2)]
	[int]$serviceTimeoutSeconds = 30,
	# How many times to retry stopping/starting core service.
	[Parameter(Mandatory=$false, Position=3)]
	[int]$maxRetryTimes = 3
)

Add-Type -AssemblyName "System.ServiceProcess"
Add-Type -AssemblyName "System.IO"
Add-Type -AssemblyName "System.Transactions"

$patchNumber = "MCC-91927"
$assemblyFileName = "Medidata.Core.Objects.dll"
$whoisConnectionString = [string]::Format("Data Source={0};Initial Catalog=whois;Integrated Security=SSPI; Connection Timeout=600", $whoisServerName)
$workDir = Split-Path -parent $PSCommandPath
$patchDir = [System.IO.Path]::Combine($workDir, "patches")
$targetVersions = Get-ChildItem $patchDir | Foreach {$_.Name}
$timestamp = [System.DateTime]::Now.ToString("_ddMMMyyyy HH.mm.ss fff")
$backupDir = [System.IO.Path]::Combine($workDir, $timestamp, "backup")

# Prepare log.txt file
$logPath = [System.IO.Path]::Combine($workDir, $timestamp, "log.txt")
if(!(Test-Path $logPath)){
    new-item -Path $logPath -ItemType file -Force | Out-Null
}

function Main(){
	Log-Info "Query WHOIS server to get the deployment information for all sites."
	$whois = Get-SiteInfoFromWhoIs $whoisConnectionString | where {$targetVersions -contains $_.RaveVersion}
	Log-Info ([String]::Format("According to WHOIS, there are {0} sites to handle in all.", $whois.Length))
	$index = 1
	$okCount = 0
	$ngCount = 0

	ForEach($site in $whois) {
		Log-Info ([String]::Format("[{0}/{1}] Working on site {2} (v{3})", @($index, $whois.Length, $site.Url, $site.RaveVersion)))
		$result = Patch-Site $site
		$index++
		if($result){
			$okCount++
		}else{
			$ngCount++
		}
	}
	Log-Info ([String]::Format("{0} sites all finished. {1} succeeded, {2} failed. See log {3}", $whois.Length, $okCount, $ngCount, $logPath))
}

function Get-SiteInfoFromWhoIs($connectionString){
	$connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
	$rows = @()

	# TODO: Awaiting Whois end development.
	Try{
		$connection.Open()
		$cmd = $connection.CreateCommand()
		$cmd.CommandType = [System.Data.CommandType]::StoredProcedure
		$cmd.CommandText = "usp_GetActiveRaveConfigByVersion"
		$table = New-Object "System.Data.DataTable"
		$table.Load($cmd.ExecuteReader())

		$rows = $table | `
				Where-Object {($_.RaveVersion -eq "5.6.5.92") -or (($_.RaveVersion -in @('5.6.5.45', '5.6.5.50', '5.6.5.66', '5.6.5.71')) -and ($_.Type -eq "App"))} | `
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

		$node = @{ Type=$row.Type; ServerName = $row.ServerName; RaveVersion=$row.RaveVersion }
		if($node.Type -eq "App"){
			$node.TargetAssemblyPath = [System.IO.Path]::Combine($row.ServerRootPath, $assemblyFileName)
			$node.CoreServiceName = [string]::Format("Medidata Core Service - ""{0}""", $row.ServiceName)
		}else{
			$node.TargetAssemblyPath = [System.IO.Path]::Combine($row.ServerRootPath, "bin", $assemblyFileName)
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
	$scope = New-Object System.Transactions.TransactionScope

	Try{
		$connection.Open()
		$needsPatch = (Check-IfNeedToPatch $site $connection)
		if($needsPatch){
			$site.Nodes | ForEach { Backup-Assembly $_ }
			$site.Nodes | Where-Object { $_.Type -eq "App" } | ForEach { Stop-CoreService $_ }
			$site.Nodes | ForEach { Replace-Assembly $_ }
			$site.Nodes | Where-Object { $_.Type -eq "App" } | ForEach { Start-CoreService $_ }
			Insert-PatchInfo $site $connection 
		}else{
			Log-Info("This site has been patched.")
		}

		$scope.Complete()
		return $true
	} catch {
		$site.Nodes | ForEach { Restore-Assembly $_ }
		Log-Error($_)
	} finally {
		$connection.Dispose()
		$scope.Dispose()
	}

	return $false
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

function Insert-PatchInfo($site, $connection){
	$cmd = $connection.CreateCommand()
	$cmd.CommandType = [System.Data.CommandType]::StoredProcedure
	$cmd.CommandText = "dbo.spPatchesInsert"
	[void]$cmd.Parameters.AddWithValue("@RaveVersion", $site.RaveVersion)
	[void]$cmd.Parameters.AddWithValue("@PatchNumber", $site.PatchNumber)
	[void]$cmd.Parameters.AddWithValue("@version", 1)
	[void]$cmd.Parameters.AddWithValue("@Description", ($site.PatchNumber + " for MCC-91927"))
	[void]$cmd.ExecuteNonQuery()
}

function Stop-CoreService($node){
	Ope-CoreService $node "stop"
}

function Start-CoreService($node){
	Ope-CoreService $node "start"
}

function Ope-CoreService($node, [string]$startOrStop){
	[System.ServiceProcess.ServiceControllerStatus]$waitStatus = [System.ServiceProcess.ServiceControllerStatus]::Stopped
	if($startOrStop -eq "start"){
		$waitStatus = [System.ServiceProcess.ServiceControllerStatus]::Running
	}

	$service = get-Service $node.CoreServiceName -ComputerName $node.ServerName -ErrorAction stop
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
			}
			Log-Info ("The core service now is " + $service.Status)
			$tryTime++
		}
	}finally{
		$service.Dispose()
	}
}

function Backup-Assembly($node){
	$backupPath = [System.IO.Path]::Combine($backupDir, $node.ServerName + "(" + $node.RaveVersion + ")", [System.IO.Path]::GetFileName($node.TargetAssemblyPath))
	ForceCopyFile $node.TargetAssemblyPath $backupPath "Backup"
}

function Replace-Assembly($node){
	$patchFilePath = [System.IO.Path]::Combine($patchDir, $node.RaveVersion, [System.IO.Path]::GetFileName($node.TargetAssemblyPath))
	ForceCopyFile $patchFilePath $node.TargetAssemblyPath "Patch"
}

function Restore-Assembly($node){
	$backupPath = [System.IO.Path]::Combine($backupDir, $node.ServerName + "(" + $node.RaveVersion + ")", [System.IO.Path]::GetFileName($node.TargetAssemblyPath))
	if(Test-Path $backupPath){
		ForceCopyFile $backupPath $node.TargetAssemblyPath "Rollback"
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
	write-host ("> " + $message)
	([System.DateTime]::Now.ToString("dd/MMM/yyyy HH:mm:ss.fff") + " [Info] " + $message) | out-file -Filepath $logPath -append
}

function Log-Error($errorRecord){
	$message = $errorRecord.ScriptStackTrace + "`r`n" + $errorRecord.Exception.ToString()
	write-error $message
	([System.DateTime]::Now.ToString("dd/MMM/yyyy HH:mm:ss.fff") + " [Error] " + $message) | out-file -Filepath $logPath -append
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


Main