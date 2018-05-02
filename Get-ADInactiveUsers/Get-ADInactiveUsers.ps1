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

# Variables
$Days = "90"
$ReportName = "Auto report: Enabled users with no on-site login within $Days days"
$SmtpServer = "x"
$From = "x"
$To = "x"
$OU = "x"

# Get users from AD
$Users = Search-AdAccount -UsersOnly -SearchBase "$OU" -AccountInactive -TimeSpan $Days |
Where Enabled -eq $True | Select Name, Enabled, LastLogonDate | ConvertTo-Html

# Create the e-mail body
$Body = "<p>The following users have not logged in on-site in over $Days days.</p>" + $Users

# Send the e-mail
Send-MailMessage -smtpserver $SmtpServer -from $From -to $To -subject $ReportName -body "$Body" -bodyashtml