# CMP for MCC-91927. 
The job is to replace existing Medidata.Core.Objects.dll with new ones. The affected Rave versions and nodes are as below table.

|Version |Build Version |Nodes|
|---------|-----------------------|---------------|
|2013.2.0|	5.6.5.45 |Application nodes|
|2013.2.0.1	|5.6.5.50| Application nodes|
|2013.3.0	|5.6.5.66| Application nodes|
|2013.3.0.1	|5.6.5.71| Application nodes|
|2013.4.0		|5.6.5.92| Application nodes and Web nodes|

**Notice:** This script needs an associated stored procedure from WHOIS database, which returns the deployment information for affected sites and nodes.
