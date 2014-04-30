# CMP for MCC-91927. 
The job is to replace existing Medidata.Core.Objects.dll with new ones. The affected Rave versions and nodes are as below table.

## Affected Rave Versions
|Version |Build Version |Nodes|
|---------|-----------------------|---------------|
|2013.2.0|	5.6.5.45 |Application nodes|
|2013.2.0.1	|5.6.5.50| Application nodes|
|2013.3.0	|5.6.5.66| Application nodes|
|2013.3.0.1	|5.6.5.71| Application nodes|
|2013.4.0		|5.6.5.92| Application nodes and Web nodes|

**Notice:** This script needs an associated stored procedure from WHOIS database, which returns the deployment information for affected sites and nodes.

## How to use

### Input
`PS ~> .\CMP-MCC91927.ps1 $WhoisDBServerName$ [$OpeCoreServiceTimeOutSeconds$] [$RetryCoreServiceTimes$]`

- **$WhoisDBServerName$** is the server name of WHOIS database and is required.
- **$OpeCoreServiceTimeOutSeconds$** is the time out in seconds to wait for starting or stopping core service. This is optinal and default value is 30 seconds.
- **$RetryCoreServiceTimes$** is the retry times if starting or stopping core service failed. This is optinal and default value is 3 times.


### Log file
Log file will be generated each time the script is run. A folder whose name is like "_$Timestamp$" (e.g. "_30Apr2014 18.26.56 407") will be created at the same directory of CMP-MCC91927.ps1. Within this folder, there will be a "log.txt" file. This is the log file and contains the same message with command prompt. Here also will be a "backup" folder where the patching target's original files will be backed up. See the following directory structure after running "CMP-MCC91927.ps1".

```
PS ~>
│   CMP-MCC91927.ps1
│
└───_30Apr2014 18.28.49 456
    │   log.txt
    │
    └───backup
        ├───Win81(5.6.5.45)
        │       Medidata.Core.Objects.dll
        │
        └───Win81(5.6.5.92)
                Medidata.Core.Objects.dll
```


