<#
.SYNOPSIS
    This script searches for users that haven't authenticated to domain-joined PCs in x days

.PARAMETER SearchBase
    Active Directory LDAP search base e.g. "OU=Users,OU=Department,DC=domain,DC=uk"

.PARAMETER TimeSpan
    Allowed timespan in days until a user is considered inactive e.g. 90

.PARAMETER DomainUser
    Domain user with permission to perform the query e.g. "DOMAIN\user"

.PARAMETER DomainPass
    Password for the respective $DomainUser e.g. "Pa5sword"

.EXAMPLE
    Get-ADInactiveUsers.ps1 -SearchBase "OU=Users,OU=Department,DC=domain,DC=uk" -TimeSpan 90

.LINK
    https://github.com/writhlingtonschool/it-automation
#>

param
(
    [Parameter(Mandatory=$true)]$SearchBase,
    [Parameter(Mandatory=$true)]$TimeSpan,
    [Parameter(Mandatory=$true)]$DomainUser,
    [Parameter(Mandatory=$true)]$DomainPass
)

# Prepare PSCredential object
$DomainPassSecure=ConvertTo-SecureString -String "$DomainPass" -AsPlainText -Force
$DomainCredentials=New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $DomainUser, $DomainPassSecure

# Run the search
Search-AdAccount -UsersOnly -SearchBase "$SearchBase" -AccountInactive -TimeSpan $TimeSpan -Credential $DomainCredentials |
Where Enabled -eq $True | Select Name, Enabled, LastLogonDate