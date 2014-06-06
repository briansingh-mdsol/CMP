# CMP for MCC-106898
The script is to replace existing Medidata.Core.Objects.dll with new ones. The affected Rave versions and nodes are as below table.

## Affected Rave Versions
|Product Name |Assembly Version |Product Version |Nodes| MCC |
|:---------------------------|:--------------------|:---------------------------|:----------|:----------|
|Medidata Rave® 2013.2.0	|5.6.5.45 | 20140415223636-b6d4a73 |Application nodes|MCC-91927|
|Medidata Rave® 2013.2.0.1	|5.6.5.50 | 20140425133920-42ad77c |Application nodes|MCC-91927|
|Medidata Rave® 2013.3.0	|5.6.5.66 | 20140425133901-edac9d8 |Application nodes|MCC-91927|
|Medidata Rave® 2013.3.0.1	|5.6.5.71 | 20140425160927-940900d |Application nodes|MCC-91927|
|Medidata Rave® 2013.4.0	|5.6.5.92 | 20140425133800-285b96c |Application nodes and Web nodes|MCC-91927 MCC-104473|
|Medidata Rave® 2013.4.0.1	|5.6.5.93 | 20140508213308-d2f1f2f |Application nodes and Web nodes|MCC-104473|

This script uses "Assembly Version (5.6.5.XX)" as identity to filter target sites.

## Prerequisites
Powershell 3.0 or above.

## Workflow of the script

### Workflow of patch mode
1. Connect WHOIS database to get deployment information for all sites (or say "URL" in Medidata language) and their sibling nodes.
2. Filter out those sites need to be patched.
3. Loopily execute step 4~6 on each site.
4.    Stop the core service of each sibling if it's an App server.
5.    Backup the original Medidata.Core.Objects.dll and replace it with the new dll on each sibling.
6.    Start the core service of each sibling if it's an App server.
7.    If any error happens between step 4~6, restore the dll from its backup. Otherwise, insert one record into site's RavePatches table. The PatchNumber is constantly "MCC-106898".

### Workflow of repair mode
1. Connect WHOIS database to get deployment information for all sites and their sibling nodes.
2. Filter out those sites need to be patched.
3. Loopily execute step 4~6 on each site.
4.    Get the product version of Medidata.Core.Objects.dll on each sibling.
5.    See if all siblings' file product versions are equal to the patch assembly's product version. If true go to step 6, otherwise 7.
6.    Insert a record in RavePatches table (the DateApplied column will be set with the value specified by **-repairDbTimestamp** argument) and goto step 3.
7.    Log that this site hasn't been patches and goto step 3.


## Features

- **Patch site as a whole or nothing.**
The script ensures all sibling nodes of a single site are all patched or none. If error happens in the middle, the script will try to restore those have been patched from the backup (See "Log file and backup" below), so as to avoid discrepancy among these siblings.
- **Safe to re-run.** The script was designed to be rerunnable safely. It means it will detect if the patch has been finished on the target site. So the script will automatically skip those patched sites.
- **Read from sites.txt file to specify sites.** User must list all target sites' URLs (not IP address) in this file. One site for each line. Any white line, empty line, or the line where the first non-empty charactor is "#" will be ignored. "#" character can be used as comment symbol. If no valid line in this file, or the file doesn't exist, the script will return without doing any patching. And the message will be like
```
> No site specified. Sites.txt doesn't exist or is empty.
```
- **In-place backup.** The backup of the original DLL will be reside in a sub folder called "MCC-106898" right beneath the its original location. And the backup file will be renamed with ".bak" suffix. Below is an example after patching. The backup will not be deleted when neither succeeded nor failed.
```
blah\
│   Medidata.Core.Objects.dll           <-- The new one
│
└───MCC-106898
        Medidata.Core.Objects.dll.bak   <-- The original one
```
- **Repair mode.** In some cases the record in RavePatches, which labels this CMP has been executed successfully against the underlying site, is missing. To repair this record, this script can be run in "repair mode" which will only compare file's produce version, detect if the record is missing, and insert one. To run repair mode, start the script with **-repairDbTimestamp** argument. See below for the detail.

## How to use

### Arguments
To run *"__patch mode__"*, which will stop/start core service and replace files.
```
PS ~> .\CMP-MCC106898.ps1 $whoisServerName [$whoisUser] [$whoisPwd] [$logFolder] [$serviceTimeoutSeconds] [$maxRetryTimes]
```
or to run *"__repair mode__"*, which only sees assembly 'product version' and conditionally insert a record into RavePatches table for the underlying site. 
```
PS ~> .\CMP-MCC106898.ps1 $whoisServerName [$whoisUser] [$whoisPwd] [$logFolder] -repairDbTimestamp 'MM/DD/YYYY HH:mm:ss'
```

- **-whoisServerName** is the server name of WHOIS database and is required.
- **-whoisUser** must be specified together with **$whoisPwd**. If specified, it will be used as the account for SQL authentication connection.
- **-whoisPwd** must be specified together with **$whoisUser**. If specified, it will be used as the password for SQL authentication connection. If either **$whoisUser** or **$whoisPwd** is empty, Windows authentication connection will be used.
- **-logFolder** is the directory for log file. This can be either absolute path or relative path. If it's a relative path, it will be under the script's directory. This is optional and default value is "Logs".
- **-serviceTimeoutSeconds** is the time out in seconds to wait for starting or stopping core service. This is optional and default value is 30.
- **-maxRetryTimes** is the retry times if starting or stopping core service failed. This is optional and default value is 3.
- **-repairDbTimestamp** is the timestamp used for repairing patch information in database. This timestamp will be inserted into RavePatches table. The format is 'MM/DD/YYYY HH:mm:ss' or 'MM/DD/YYYY'. This argument surpresses **-serviceTimeoutSeconds** and **-maxRetryTimes**. As if this argument specified the script will be run in "repair mode" where no core service nor assembly file will be manipulated. It only compares assembly's 'product version' and conditionally inserts the missing patch record into RavePatches table of the site.

*Notice: You may consider to increase timeout and retry times to reduce core service operation failure.*


### The log file
Log file will be generated under the specified log folder (by **$LogFolder$** parameter). Each execution creates a new log file. The file name is with time stamp and looks like "log_20140430 182656.407.txt". 


### The record in RavePatches table
A new record like below will be inserted into the RavePatches table of each target site only if the patching on that site succeeded. The existence of this PatchNumber is used to detect whether this site has been patched already, so as to ensure this script's rerunnability.

| id|	RaveVersion	|PatchNumber	|version	|Description	|DateApplied	|AppliedBy	|AppliedFrom	|Active	|AppServers	|WebServers	|Viewers	|BatchUploader	|NonSqlRun|
|:---|:----------	|:-----------	|:-------	|:------------	|:------------	|-------	|-----------	|----	|--------	|-------	|-------	|-------	|-------|
| 91|	5.6.5.45	|MCC-106898	|1	|Replace Medidata.Core.Objects.dll	|2014-05-01 15:14:59.537|NULL|	NULL	|1	|NULL	|NULL|	NULL|	NULL|	NULL|
