@echo off
if [%1]==[] (
	echo An argument is required. Read this batch code to find the details.
	exit 1
)
powershell .\CMP-MCC106898.ps1 -whoisServerName %1 -logFolder Logs -repairDbTimestamp '06/02/2014 00:00:00'
@echo on