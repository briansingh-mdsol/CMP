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
	# Database connection string to query WHOIS
	[Parameter(Mandatory=$false, Position=1)]
	[string]$whoisConnectionString = "Server=localhost;Database=Rave1;uid=sa;pwd=!Qazse44;Connection Timeout=300",
	# Waiting timeout in seconds for stopping/starting core service. 
	[int]$serviceTimeoutSeconds = 30
)

Add-Type -AssemblyName "System.ServiceProcess"
Add-Type -AssemblyName "System.IO"
Add-Type -AssemblyName "System.Transactions"

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
	$whois = Get-SiteInfoFromWhoIs-Stub $whoisConnectionString | where {$targetVersions -contains $_.RaveVersion}
	Log-Info ([String]::Format("According to WHOIS, there are {0} sites to handle in all.", $whois.Length))
	Log-Info
	$index = 1
	$okCount = 0
	$ngCount = 0

	ForEach($site in $whois) {
		Log-Info ([String]::Format("[{0}/{1}] Working on site {2} (v{3})", @($index, $whois.Length, $site.Url, $site.RaveVersion)))
		$result = Patch-Site $site
		Log-Info
		$index++
		if($result){
			$okCount++
		}else{
			$ngCount++
		}
	}
	Log-Info ([String]::Format("{0} sites all finished. {1} succeeded, {2} failed. See log {3}", $whois.Length, $okCount, $ngCount, $logPath))
}

############### For develop only (begins from here) #################
############### Must remove before final release
function Get-SiteInfoFromWhoIs-Stub($connectionString){
	$tmp = @{}
	$tmp.ComputerName="win81"
	$tmp.CoreServiceName = "Spooler"
	$tmp.RaveVersion = "5.6.5.71"
	$tmp.NodeType = 1	# 0 is web; 1 is app
	$tmp.TargetAssemblyPath = "\\win81\C$\GitHub\Rave\Medidata.Core\Medidata.Core.Service\bin\release\Medidata.Core.Objects.dll"

	$tmp2 = @{}
	$tmp2.ComputerName="win81"
	$tmp2.CoreServiceName = "Spooler"
	$tmp2.RaveVersion = "5.6.5.71"
	$tmp2.NodeType = 1	# 0 is web; 1 is app
	$tmp2.TargetAssemblyPath = "\\win81\C$\GitHub\Rave\Medidata.Core\Medidata.Core.Service\bin\release\Medidata.Core.Objects.dll"

	$site = @{}
	$site.Url = "xxxxx.mdsol.com"
	$site.RaveVersion = "5.6.5.71"
	$site.PatchNumber = "CMP XXX"
	$site.DbConnectionString = "Server=localhost;Database=Rave1;uid=sa;pwd=!Qazse44;Connection Timeout=300"
	$site.Nodes = @($tmp, $tmp2)

	return @($site)
}
############### For develop only (ends up to above) #################

function Get-SiteInfoFromWhoIs($connectionString){
	$connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
	$array = @()

	# TODO: Awaiting Whois end development.
	Try{
		$connection.Open()
		$cmd = $connection.CreateCommand()
		$cmd.CommandText  = "select top 1 * from Users"
		$table = new-object "System.Data.DataTable"
		$table.Load($cmd.ExecuteReader())
 
		#$format = @{Expression={$_.FirstName}},@{Expression={$_.LastName}}

		#$table | Where-Object {$_.Surname -like "*sson" -and $_.Born -lt 1990} | format-table $format
		#$array = @($table | select -ExpandProperty FirstName)

		$array = $table | Select-object FirstName, LastName
	} finally {
		$connection.Dispose()
	}

	return $array
}

function Patch-Site($site){
	$connection = New-Object System.Data.SqlClient.SqlConnection $site.DbConnectionString
	$scope = New-Object System.Transactions.TransactionScope

	Try{
		$connection.Open()
		$needsPatch = (Check-IfNeedToPatch $site $connection)
		if($needsPatch){
			$site.Nodes | ForEach { Patch-NodeServer $_ }
			Insert-PatchInfo $site $connection 
		}else{
			Log-Info("This site has been patched.")
		}

		$scope.Complete()
	} catch {
		Log-Error($_.Exception.ToString())
	} finally {
		$connection.Dispose()
		$scope.Dispose()
	}
}

function Patch-NodeServer($node){
	try{
		if($node.NodeType -eq 0) {
			# Web server
			Log-Info ($node.ComputerName + " is a web server")
			Backup-Assembly $node
			Replace-Assembly $node
		}elseif($node.NodeType -eq 1){
			# App server
			Log-Info ($node.ComputerName + " is an application server")
			$service = get-Service $node.CoreServiceName -ComputerName $node.ComputerName -ErrorAction stop
			Stop-CoreService $service
			Backup-Assembly $node
			Replace-Assembly $node
			Start-CoreService $service
		}else{
			Log-Info ($node.ComputerName + " is an unknown type server. " + $node.NodeType)
		}
		return $true
	}catch{
		Log-Error($_.Exception.ToString())
		Restore-Assembly $node
		return $false
	}
}

function Check-IfNeedToPatch($site, $connection){
	$cmd = $connection.CreateCommand();
	$cmd.CommandType = [System.Data.CommandType]::Text
	$cmd.CommandText = "SELECT TOP 1 CAST(COUNT(*) AS Bit) FROM RavePatches WHERE RaveVersion = @raveVersion AND PatchNumber = @patchNumber"
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

function Stop-CoreService($service){
	if($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped){
		Log-Info "Stopping core service"
		$service.Stop()
		$serviceTimeoutTimeSpan = New-Object System.TimeSpan 0, 0, $serviceTimeoutSeconds
		$service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, $serviceTimeoutTimeSpan)
		$service.Refresh()
		Log-Info ("Core service is " + $service.Status)
	}
}

function Start-CoreService($service){
	if($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running){
		Log-Info "Starting core service" 
		$service.Start()
		$serviceTimeoutTimeSpan = New-Object System.TimeSpan 0, 0, $serviceTimeoutSeconds
		$service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, $serviceTimeoutTimeSpan)
		$service.Refresh()
		Log-Info ("Core service is " + $service.Status)
	}
}

function Backup-Assembly($node){
	$backupPath = [System.IO.Path]::Combine($backupDir, $node.ComputerName + "(" + $node.RaveVersion + ")", [System.IO.Path]::GetFileName($node.TargetAssemblyPath))
	ForceCopyFile $node.TargetAssemblyPath $backupPath
}

function Replace-Assembly($node){
	$patchFilePath = [System.IO.Path]::Combine($patchDir, $node.RaveVersion, [System.IO.Path]::GetFileName($node.TargetAssemblyPath))
	ForceCopyFile $patchFilePath $node.TargetAssemblyPath
}

function Restore-Assembly($node){
	$backupPath = [System.IO.Path]::Combine($backupDir, $node.ComputerName + "(" + $node.RaveVersion + ")", [System.IO.Path]::GetFileName($node.TargetAssemblyPath))
	if(Test-Path $backupPath){
		ForceCopyFile $backupPath $node.TargetAssemblyPath
	}
}

function ForceCopyFile($source, $destination){
	Log-Info ([String]::Format("Copy file {0} -> {1}", $source, $destination))
	if(!(Test-Path $destination)){
		new-item -force -path $destination -type file | Out-Null
	}
	[System.IO.File]::Copy($source, $destination, $true)
}

function Log-Info([string]$message){
	write-host ("> " + $message)
	([System.DateTime]::Now.ToString("dd/MMM/yyyy HH:mm:ss.fff") + " [Info] " + $message) | out-file -Filepath $logPath -append
}

function Log-Error([string]$message){
	write-error ("> " + $message) -Verbose 
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