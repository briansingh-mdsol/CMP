@echo off
if [%1]==[] (
	echo An argument is required. Read this batch code to find the details.
	exit 1
)
powershell .\CMP-MCC106898.ps1 -whoisServerName %1 -logFolder Logs -serviceTimeoutSeconds 60 -maxRetryTimes 5
@echo on