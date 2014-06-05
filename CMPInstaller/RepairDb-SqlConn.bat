@echo off
if [%3]==[] (
	echo Three arguments are required. Read this batch code to find the details.
	exit 1
)
powershell .\CMP-MCC106898.ps1 -whoisServerName %1 -whoisUser %2 -whoisPwd %3 -logFolder Logs -repairDbTimestamp '06/02/2014 00:00:00'
@echo on