#
# This is CMP for MCC-91927 and its job is to replace existing Medidata.Core.Objects.dll with new ones.
# The affected Rave versions and nodes are stated in README.md
#
# Notice: This script needs an associated stored procedure from WHOIS database, 
#		 which returns the deployment information for affected sites and nodes.
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
$patchNumber = "MCC-132876"
$patchDescription = "Automate CMPs (71243, 71416, 71429) for fixing sites, which have duplicate iMedidata apps after upgrade to Rave 2014.2.0"

if([string]::IsNullOrEmpty($whoisUser) -or [string]::IsNullOrEmpty($whoisPwd))
{	
	$whoisConnectionString = [string]::Format("Data Source={0};Initial Catalog=whois;Integrated Security=SSPI; Connection Timeout=600", $whoisServerName)
}
else
{
	$whoisConnectionString = [string]::Format("Data Source={0};Initial Catalog=whois;uid={1};Password={2}; Connection Timeout=600", $whoisServerName, $whoisUser, $whoisPwd)
}

function GetTargetSites($workDir)
{
	$targetSites = @()
	Get-ChildItem $workDir -Filter *.json | 
		Foreach-Object{
			$json = (Get-Content $_.FullName -Raw) | ConvertFrom-Json
			Add-Member -InputObject $json -MemberType NoteProperty -Name site -Value $_.BaseName
			$targetSites += $json
		}
	return $targetSites		
}

$scriptDir = Split-Path -parent $PSCommandPath
$workDir = [System.IO.Path]::Combine($scriptDir, "work")
$targetSites = GetTargetSites $workDir
$absoluteLogFolder = $logFolder
if(-not [System.IO.Path]::IsPathRooted($absoluteLogFolder)){
	$absoluteLogFolder = [System.IO.Path]::Combine($scriptDir, $logFolder)
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
		Log-Info "No site specified. Folder doesn't exist or is empty."
		Return
	}

	Print-Arguments

	Log-Info "Query WHOIS server to get the deployment information for all sites."

	$whoisSites = Get-SiteInfoFromWhoIs $whoisConnectionString

	$sites = [array] (Merge-SiteInfo $targetSites $whoisSites)

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

function Merge-SiteInfo($targetSites, $whoisSites)
{
	$sites = @()
	foreach ($target in $targetSites) {
		$targetInfo = $target.psobject.Properties	
		$whoisInfo = FindWhoisSite $whoisSites $targetInfo["site"].Value
		if (-NOT ($whoisInfo -eq $null))
		{
			#Create merge object
			$obj = New-Object PSObject

			#Add whois site information to merge object
			Add-Member -InputObject $obj -MemberType NoteProperty -Name Url -Value $whoisInfo.Url
			Add-Member -InputObject $obj -MemberType NoteProperty -Name RaveVersion -Value $whoisInfo.RaveVersion
			Add-Member -InputObject $obj -MemberType NoteProperty -Name Nodes -Value $whoisInfo.Nodes
			Add-Member -InputObject $obj -MemberType NoteProperty -Name DbConnectionString -Value $whoisInfo.DbConnectionString
			Add-Member -InputObject $obj -MemberType NoteProperty -Name PatchNumber -Value $whoisInfo.PatchNumber

			#Add target site information to merge object
			Add-Member -InputObject $obj -MemberType NoteProperty -Name WorkRequestNumber -Value $patchNumber.TrimStart("MCC-")
			Add-Member -InputObject $obj -MemberType NoteProperty -Name AppIdOriginalRaveEdc -Value $targetInfo["appIdOriginalRaveEdc"].Value
			Add-Member -InputObject $obj -MemberType NoteProperty -Name AppTokenOriginalRaveEdc -Value $targetInfo["appTokenOriginalRaveEdc"].Value
			Add-Member -InputObject $obj -MemberType NoteProperty -Name UuidOriginalRaveEdc -Value $targetInfo["uuidOriginalRaveEdc"].Value
			Add-Member -InputObject $obj -MemberType NoteProperty -Name AppIdOriginalRaveModules -Value $targetInfo["appIdOriginalRaveModules"].Value
			Add-Member -InputObject $obj -MemberType NoteProperty -Name AppTokenOriginalRaveModules -Value $targetInfo["appTokenOriginalRaveModules"].Value
			Add-Member -InputObject $obj -MemberType NoteProperty -Name UuidOriginalRaveModule -Value $targetInfo["uuidOriginalRaveModule"].Value

			$sites += $obj
		}
		else
		{
			Log-Info("No WHOIS entry found for target site : " + $targetInfo["site"].Value)
		}
	}
	return $sites
}

function FindWhoisSite($whoisSites, $search)
{
	foreach ($site in $whoisSites) {
		if($site.Url -contains $search)
		{
			return $site
		}
	}
}

function Print-Arguments(){
	Log-Info "Arguments"
	Log-Info ("  -whoisServerName		: " + $whoisServerName)
	Log-Info ("  -whoisUser				: " + $whoisUser)
	$pwdDisplay = $whoisPwd
	if($whoisPwd) { $pwdDisplay = "********************" }
	Log-Info ("  -whoisPwd				: " + $pwdDisplay)
	Log-Info ("  -logFolder				: " + $logFolder)
	Log-Info ("  -serviceTimeoutSeconds	: " + $serviceTimeoutSeconds)
	Log-Info ("  -maxRetryTimes			: " + $maxRetryTimes)
	Log-Info
	Log-Info ("  -patchNumber			: " + $patchNumber)
	Log-Info ("  -patchDescription		: " + $patchDescription)
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
			$dbConnStr = [string]::Format("Server={0};Database={1};uid={2};pwd={3};Connection Timeout=300;MultipleActiveResultSets=True", 
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
			$node.RwsWebConfigPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($row.ServerRootPath, "..\Medidata.RaveWebServices\App\Medidata.RaveWebServices.Web\web.config"))
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
	$site.Nodes | Where-Object { $_.Type -eq "Web" } | ForEach { ModifyConfigFiles $_ $site }
	Patch-Database $site $connection
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
	[void]$cmd.Parameters.AddWithValue("@Description", $patchDescription)
	$count = $cmd.ExecuteNonQuery()
	return ($count -eq 1)
}

function Patch-Database($site, $connection){
	# Execute SQL to patch database

	# Fix Riss
	$FixRissUuidBackupTableName = 'BK_WR_' + $site.WorkRequestNumber + '_RISS_IntegratedApplicationsConfigurations'
	$FixRissUuidCreateBackupTable = 'CREATE TABLE ' + $FixRissUuidBackupTableName + ' (ID INT, UUID UNIQUEIDENTIFIER, MessageQueueUrl NVARCHAR(512), Updated DATETIME, BK_Timestamp DATETIME)' 
	$FixRissUuidUpdateRissTable = 'DECLARE @dt DATETIME = GETUTCDATE() UPDATE RISS_IntegratedApplicationsConfigurations SET UUID = LOWER(''' + $site.UuidOriginalRaveEdc + '''), MessageQueueUrl = NULL, Updated = @dt OUTPUT deleted.ID, deleted.UUID, deleted.MessageQueueURL, deleted.Updated, @dt INTO ' + $FixRissUuidBackupTableName
	$FixRissUuidGetResults = 'SELECT bk.ID AS ID, bk.UUID AS OldUUID, riac.UUID AS NewUUID, bk.MessageQueueURL AS OldURL, riac.MessageQueueURL AS NewURL, bk.Updated AS OldUpdated, riac.Updated AS NewUpdated, bk.BK_Timestamp AS ScriptTimestamp FROM ' + $FixRissUuidBackupTableName + ' bk JOIN RISS_IntegratedApplicationsConfigurations riac ON bk.ID = riac.ID'

	$sqlText = ""
	$sqlText = $sqlText + $FixRissUuidCreateBackupTable
	$sqlText = $sqlText + " "
	$sqlText = $sqlText + $FixRissUuidUpdateRissTable
	$sqlText = $sqlText + " "
	$sqlText = $sqlText + $FixRissUuidGetResults
	$sqlText = $sqlText + " "

	RunSqlText $connection $sqlText

	# Fix Api Id
	$FixApiIdBackupTableName = 'BK_WR_' + $site.WorkRequestNumber + '_Configuration'
	$FixApiIdCreateBackupTable = 'CREATE TABLE ' + $FixApiIdBackupTableName + ' (Tag VARCHAR(64), ConfigValue VARCHAR(2000), Updated DATETIME, BK_Timestamp DATETIME)'
	$FixApiIdCreateTempTable = 'DECLARE @ConfigTemp TABLE (Tag NVARCHAR(400), ConfigValue NVARCHAR(50)) INSERT INTO @ConfigTemp VALUES (''ApiID'', ''' + $site.AppIdOriginalRaveEdc + '''), (''iMedidataApiRaveToken'', ''' + $site.AppTokenOriginalRaveEdc + '''), (''iMedidataEdcAppID'', ''' + $site.UuidOriginalRaveEdc + '''), (''iMedidataModulesAppID'', ''' + $site.UuidOriginalRaveModule + ''')'
	$FixApiIdUpdateConfigurationTable = 'DECLARE @dt DATETIME = GETUTCDATE() UPDATE c SET ConfigValue = t.ConfigValue, Updated = @dt OUTPUT deleted.Tag, deleted.ConfigValue, deleted.Updated, @dt INTO ' + $FixApiIdBackupTableName + ' FROM Configuration c JOIN @ConfigTemp t ON t.Tag = c.Tag WHERE t.ConfigValue <> c.ConfigValue'
	$FixApiIdGetResults = 'SELECT * FROM ' + $FixApiIdBackupTableName

	$sqlText = ""
	$sqlText = $sqlText + $FixApiIdCreateBackupTable
	$sqlText = $sqlText + " "
	$sqlText = $sqlText + $FixApiIdCreateTempTable
	$sqlText = $sqlText + " "
	$sqlText = $sqlText + $FixApiIdUpdateConfigurationTable
	$sqlText = $sqlText + " "
	$sqlText = $sqlText + $FixApiIdGetResults
	$sqlText = $sqlText + " "

	RunSqlText $connection $sqlText
}

function RunSqlText($connection, $sqlText)
{
	$cmd = new-object System.Data.SqlClient.SqlCommand($sqlText, $connection);
	$reader = $cmd.ExecuteReader()

	$results = @()
	while ($reader.Read())
	{
		$row = @{}
		for ($i = 0; $i -lt $reader.FieldCount; $i++)
		{
			$row[$reader.GetName($i)] = $reader.GetValue($i)
		}
		$results += new-object psobject -property $row			
	}
}

function ModifyConfigFiles($node, $site){

	VerifyConfigFile $node.RwsWebConfigPath
	VerifyConfigFile $node.AppSettingsPath

	#Update Medidata.RaveWebServices.Web/web.config
	$rwsWebConfigBackupFilePath = CreateConfigFileBackup $node.RwsWebConfigPath
	try {
		UpdateRaveWebServicesWebConfig $node.RwsWebConfigPath $site.AppIdOriginalRaveEdc $site.AppTokenOriginalRaveEdc $site.AppIdOriginalRaveModules $site.AppTokenOriginalRaveModules
	} catch {
		RecoverConfigFileFromBackup $rwsWebConfigBackupFilePath $node.RwsWebConfigPath
		throw "Unable to update file: " + $node.RwsWebConfigPath
	}

	#Update MedidataRave/appsettings.config
	$appSettingsBackupFilePath = CreateConfigFileBackup $node.AppSettingsPath
	try {
		UpdateMedidataRaveAppsettingsConfig $node.AppSettingsPath $site.AppIdOriginalRaveEdc $site.AppTokenOriginalRaveEdc $site.AppIdOriginalRaveModules $site.AppTokenOriginalRaveModules
	} catch {
		RecoverConfigFileFromBackup $appSettingsBackupFilePath $node.AppSettingsPath
		throw "Unable to update file: " + $node.AppSettingsPath
	}
}

function VerifyConfigFile($configFilePath)
{
	if(-NOT (Test-Path $configFilePath))
	{
		throw "Could not access file: " + $configFilePath
	}
}

function CreateConfigFileBackup($configFilePath)
{
	$backupFilePath = $configFilePath + ".BACKUP.$([datetime]::now.ToString('yyyy-MM-dd_HH-mm-ss'))"
	Copy-Item $configFilePath $backupFilePath -Force
	return $backupFilePath
}

function RecoverConfigFileFromBackup($backupFilePath, $configFilePath)
{
	Log-Info("RecoverConfigFileFromBackup : " + $configFilePath)
	Copy-Item $backupFilePath $configFilePath -Force
}

function UpdateRaveWebServicesWebConfig($rwsWebConfigFilePath, $appIdOriginalRaveEdc, $appTokenOriginalRaveEdc, $appIdOriginalRaveModules, $appTokenOriginalRaveModules)
{
	$rwsWebConfig = New-Object System.Xml.XmlDocument
	$rwsWebConfig.Load($rwsWebConfigFilePath)

	$iMedidataEdcAppId = $rwsWebConfig.SelectSingleNode("//add[@key = 'iMedidataEdcAppId']")
	$iMedidataEdcAppId.value = $appIdOriginalRaveEdc

	$iMedidataEdcAppToken = $rwsWebConfig.SelectSingleNode("//add[@key = 'iMedidataEdcAppToken']")
	$iMedidataEdcAppToken.value = $appTokenOriginalRaveEdc

	$iMedidataModulesAppId = $rwsWebConfig.SelectSingleNode("//add[@key = 'iMedidataModulesAppId']")
	$iMedidataModulesAppId.value = $appIdOriginalRaveModules

	$iMedidataModulesAppToken = $rwsWebConfig.SelectSingleNode("//add[@key = 'iMedidataModulesAppToken']")
	$iMedidataModulesAppToken.value = $appTokenOriginalRaveModules

	$rwsWebConfig.Save($rwsWebConfigFilePath)
}

function UpdateMedidataRaveAppsettingsConfig($raveAppSettingsFilePath, $appIdOriginalRaveEdc, $appTokenOriginalRaveEdc, $appIdOriginalRaveModules, $appTokenOriginalRaveModules)
{
	$raveAppSettings = New-Object System.Xml.XmlDocument
	$raveAppSettings.Load($raveAppSettingsFilePath)

	$iMedidataApiRaveID = $raveAppSettings.SelectSingleNode("//add[@key = 'iMedidataApiRaveID']")
	$iMedidataApiRaveID.value = $appIdOriginalRaveEdc

	$iMedidataApiRaveToken = $raveAppSettings.SelectSingleNode("//add[@key = 'iMedidataApiRaveToken']")
	$iMedidataApiRaveToken.value = $appTokenOriginalRaveEdc

	$iMedidataApiRaveAdminID = $raveAppSettings.SelectSingleNode("//add[@key = 'iMedidataApiRaveAdminID']")
	$iMedidataApiRaveAdminID.value = $appIdOriginalRaveModules

	$iMedidataApiRaveAdminToken = $raveAppSettings.SelectSingleNode("//add[@key = 'iMedidataApiRaveAdminToken']")
	$iMedidataApiRaveAdminToken.value = $appTokenOriginalRaveModules

	$raveAppSettings.Save($raveAppSettingsFilePath)
}

function Restart-Services($node){
	# Restart core service
	$coreService = get-Service $node.CoreServiceName -ComputerName $node.ServerName -ErrorAction stop
	Restart_SingleService $node $coreService

	# Restart integration service
	$integrationService = get-Service $node.IntegrationServiceName -ComputerName $node.ServerName -ErrorAction stop
	Restart_SingleService $node $integrationService
}

function Restart-IIS($node){
	$iis = get-Service "W3SVC" -ComputerName $node.ServerName -ErrorAction stop
	Restart_SingleService $node $iis
}

function Restart_SingleService($node, $service){
	try{
		Ope-CoreService $node $service "stop"
		Ope-CoreService $node $service "start"
	}finally{
		$service.Dispose()
	}
}

function Ope-CoreService($node, $service, [string]$startOrStop){
	[System.ServiceProcess.ServiceControllerStatus]$waitStatus = [System.ServiceProcess.ServiceControllerStatus]::Stopped
	if($startOrStop -eq "start"){
		$waitStatus = [System.ServiceProcess.ServiceControllerStatus]::Running
	}
	
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
