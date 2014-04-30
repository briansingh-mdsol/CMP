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
`PS > .\CMP-MCC91927.ps1 $WhoisDBServerName$ [$OpeCoreServiceTimeOutSeconds$] [$RetryCoreServiceTimes$]`

**$WhoisDBServerName$** is the server name of WHOIS database and is required.
**$OpeCoreServiceTimeOutSeconds$** is the time out in seconds to wait for starting or stopping core service. This is optinal and default value is 30 seconds.
**$RetryCoreServiceTimes$** is the retry times if starting or stopping core service failed. This is optinal and default value is 3 times.
