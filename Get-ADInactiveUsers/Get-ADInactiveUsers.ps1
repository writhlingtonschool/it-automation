<#
.SYNOPSIS
    This script pulls a report of users who haven't authenticated to on-site PCs in 90 days

.DESCRIPTION
    This script requires a SMTP server and the Active Directory PowerShell module.

.EXAMPLE
    Get-InactiveUsers.ps1

.LINK
    https://github.com/writhlingtonschool/it-automation
#>

# Import settings from configuration file
$workDir = Split-Path -Parent $MyInvocation.MyCommand.Path
[xml]$configFile = Get-Content "$workDir/Get-ADInactiveUsers.xml" -ErrorAction Stop

# Variables
$Days = "90"
$ReportName = "Auto report: Enabled users with no on-site login within $Days days"
$SMTPServer = $configFile.Settings.SMTPSettings.SMTPServer
$SMTPFrom = $configFile.Settings.SMTPSettings.SMTPFrom
$SMTPTo = $configFile.Settings.SMTPSettings.SMTPTo
$ADSearchBase = $configFile.Settings.ADSettings.ADSearchBase

# Get users from AD
$Users = Search-AdAccount -UsersOnly -SearchBase "$ADSearchBase" -AccountInactive -TimeSpan $Days |
Where Enabled -eq $True | Select Name, Enabled, LastLogonDate | ConvertTo-Html

# Create the e-mail body
$Body = "<p>The following users have not logged in on-site in over $Days days.</p>" + $Users

# Send the e-mail
Send-MailMessage -smtpserver $SMTPServer -from $SMTPFrom -to $SMTPTo -subject $ReportName -body "$Body" -bodyashtml