# CMP for MCC-XXXXX
The script is automatic process of below three CMPs.

- http://cmptracker.mdsol.com/Modules/CMP/Complete/Completed.aspx?CMPNumber=71243
- http://cmptracker.mdsol.com/Modules/CMP/Complete/Completed.aspx?CMPNumber=71416
- http://cmptracker.mdsol.com/Modules/CMP/Complete/Completed.aspx?CMPNumber=71429

## Affected Rave Versions
Assembly Version of Medidata Rave® >= 5.6.5.144


## Prerequisites
Powershell 3.0 or above.

## Workflow of the script

### Workflow of patch mode
1. Connect WHOIS database to get deployment information for all sites (or say "URL" in Medidata language) and their sibling nodes.
2. Filter out those sites need to be patched.
3. Loopily execute step 4~6 on each site.
4.    Run SQL scripts against the database.
5.    Modify `MedidataRave/appsettings.config` and `Medidata.RaveWebServices.Web/web.config`.
6.    Restart IIS, core service, integration service.
7.    If any error happens between step 4~6, insert one record into site's RavePatches table.


## How to use

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
| 91|	5.6.5.144	|MCC-XXXXX	|1	| TBD	|2014-05-01 15:14:59.537|NULL|	NULL	|1	|NULL	|NULL|	NULL|	NULL|	NULL|
