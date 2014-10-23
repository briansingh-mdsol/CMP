# CMP for MCC-132876
The script is automatic process of below three CMPs.

- http://cmptracker.mdsol.com/Modules/CMP/Complete/Completed.aspx?CMPNumber=71243
- http://cmptracker.mdsol.com/Modules/CMP/Complete/Completed.aspx?CMPNumber=71416
- http://cmptracker.mdsol.com/Modules/CMP/Complete/Completed.aspx?CMPNumber=71429

The work involves:
- connect to web server
    * update RWS web.config
    * update RAVE appsettings.config
- connect to rave database
    * fix RISS_IntegratedApplicationsConfigurations
    * fix Configuration
- Restart core service in all app Servers 
- Restart IIS in all web Servers 
- Restart all instances of the "Medidata Rave Integration Service"

## Affected Rave Versions
Assembly Version of Medidata Rave® >= 5.6.5.144

## Prerequisites
Powershell 3.0 or above.

## Workflow of the script

### Workflow of patch mode
1. Read "work" folder (at same level on file system as the Powershell script) to get list of sites to be patched (see How to Use - "work" folder file)
2. Connect WHOIS database to get deployment information for all sites (or say "URL" in Medidata language) and their sibling nodes.
3. Filter out those sites need to be patched.
4. Loopily execute step 5~8 on each site.
5.    Modify `Medidata.RaveWebServices.Web/web.config` and `MedidataRave/appsettings.config`.
6.    Run SQL scripts against the database to fix RISS_IntegratedApplicationsConfigurations and fix Configuration
7.    Restart IIS, core service, integration service.
8.    If any error happens between step 4~6, insert one record into site's RavePatches table.


## How to use

### Structure of files for running Powershell script
```
.
+-- CMP-MCC132876.ps1 
+-- work
|   +-- trainingj4.mdsol.com.json
|   +-- test02.fake.mdsol.com.json
```

### "work" folder file
- Each site to be patched will have its own file 
- The file name will be the name of the site followed by the .json extension e.g trainingj4.mdsol.com.json
- Content of file:
```
{
	"appIdOriginalRaveEdc" : "tocscvb1h9x",
	"appTokenOriginalRaveEdc" : "0a6643d39f827747342800a6643d3",
	"uuidOriginalRaveEdc" : "2b4a7352-fdef-11df-af92-12313x895625",
	"appIdOriginalRaveModules" : "1kdlvwrjbf4",
	"appTokenOriginalRaveModules" : "a17b5f2c40126a17b5f2c40126a17b5f2c40126",
	"uuidOriginalRaveModule" : "8e17b59e-af92-fdef-11df-95625b02313"
}
```
- The values for the above entries in the file are taken from the iMedidata database - apps table and are the values that RWS and Rave should use.

### Arguments

```
PS ~> .\CMP-MCCXXXXX.ps1 $whoisServerName [$whoisUser] [$whoisPwd] [$logFolder] [$serviceTimeoutSeconds] [$maxRetryTimes]
```

- **-whoisServerName** is the server name of WHOIS database and is required.
- **-whoisUser** must be specified together with **$whoisPwd**. If specified, it will be used as the account for SQL authentication connection.
- **-whoisPwd** must be specified together with **$whoisUser**. If specified, it will be used as the password for SQL authentication connection. If either **$whoisUser** or **$whoisPwd** is empty, Windows authentication connection will be used.
- **-logFolder** is the directory for log file. This can be either absolute path or relative path. If it's a relative path, it will be under the script's directory. This is optional and default value is "Logs".
- **-serviceTimeoutSeconds** is the time out in seconds to wait for starting or stopping core service. This is optional and default value is 30.
- **-maxRetryTimes** is the retry times if starting or stopping core service failed. This is optional and default value is 3.

*Notice: You may consider to increase timeout and retry times to reduce core service operation failure.*


### The log file
Log file will be generated under the specified log folder (by **$LogFolder$** parameter). Each execution creates a new log file. The file name is with time stamp and looks like "log_20140430 182656.407.txt". 


### The record in RavePatches table
A new record like below will be inserted into the RavePatches table of each target site only if the patching on that site succeeded. The existence of this PatchNumber is used to detect whether this site has been patched already, so as to ensure this script's rerunnability.

| id|	RaveVersion	|PatchNumber	|version	|Description	|DateApplied	|AppliedBy	|AppliedFrom	|Active	|AppServers	|WebServers	|Viewers	|BatchUploader	|NonSqlRun|
|:---|:----------	|:-----------	|:-------	|:------------	|:------------	|-------	|-----------	|----	|--------	|-------	|-------	|-------	|-------|
| TBD|	5.6.5.144	|MCC-132876	|1	| Automate CMPs (71243, 71416, 71429) for fixing sites, which have duplicate iMedidata apps after upgrade to Rave 2014.2.0	|TBD|NULL|	NULL	|1	|NULL	|NULL|	NULL|	NULL|	NULL|
