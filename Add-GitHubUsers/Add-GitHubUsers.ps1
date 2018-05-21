<#
.SYNOPSIS
    This script synchronises GitHub users with Active Directory using SCIM
.DESCRIPTION
    This module provisions and deprovisions GitHub users based on Active directory
    group membership.  Users are deprovisioned when they are disabled or expired.
.EXAMPLE
    Synchronise-GitHubUsers.ps1
.LINK
    https://github.com/writhlingtonschool/it-powershellmodules
#>

# Import settings from configuration file
$workDir = Split-Path -Parent $MyInvocation.MyCommand.Path
[xml]$configFile = Get-Content "$workDir/Add-GitHubUsers.xml" -ErrorAction Stop

# Configure PS to use TLS 1.2 for web requests
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# GitHub
$GHToken = $configFile.Settings.GHSettings.GHToken
$GHOrganization = $configFile.Settings.GHSettings.GHOrganization
$Base64GHToken = [System.Convert]::ToBase64String( [char[]]$GHToken );
$Headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$Headers.Add( "Authorization", 'Basic {0}' -f $Base64GHToken )
$Headers.Add( "Accept", 'application/vnd.github.cloud-9-preview+json+scim' )

# Active Directory with optional GitHub Team membership
$ADGroups = $configFile.Settings.ADSettings.ADGroups.Group
$DomainUser="$( $configFile.Settings.ADSettings.ADDomainUser )"
$DomainPass=ConvertTo-SecureString -String "$( $configFile.Settings.ADSettings.ADDomainPass )" -AsPlainText -Force
$DomainCredentials=New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $DomainUser, $DomainPass

# Script
$DryRun = $configFile.Settings.ScriptSettings.DryRun
$ProvisionUsers = $configFile.Settings.ScriptSettings.ProvisionUsers
$DeprovisionUsers = $configFile.Settings.ScriptSettings.DeprovisionUsers
$LogFile = "$workDir/Add-GitHubUsers-Log_$( Get-Date -UFormat '+%Y-%m-%d-T%H-%M-%S' ).log"

# Instantiate arrays
$ADUsers = New-Object System.Collections.ArrayList
$GHUsers = $Null
$UsersToProvision = New-Object System.Collections.ArrayList
$UsersToDeprovision = New-Object System.Collections.ArrayList
$Results = New-Object System.Collections.ArrayList

# Function that logs a message to a text file
function LogMessage
{
    param
    (
        [Parameter(Position=0)]
        [string]$Message
    )
    ((Get-Date).ToString() + " - " + $Message) >> "$LogFile"
}

# Function to update result array
function Update-Results
{
    <#
    .SYNOPSIS
        Updates a results array
    .DESCRIPTION
        This function is used to add context-specific information to a results array
    .EXAMPLE
        Update-Results -Subject "john.doe@microsoft.com" -Action "Provision" -Status "Success"
    .PARAMETER Subject
        An identifying attribute of a user object
    .PARAMETER Action
        The action being taken on the user
    .PARAMETER Status
        The result of the action
    #>
    param
    (
        [Parameter(Position=0)]
        [string]$Subject,

        [Parameter(Position=1)]
        [string]$Action,

        [Parameter(Position=2)]
        [string]$Status
    )

    $script:Results += New-Object -TypeName PSCustomObject -Property @{
        Date="$( Get-Date )"
        Subject="$Subject"
        Action="$Action"
        Status="$Status"
    }

    LogMessage -Message "$Status ($Action) for $Subject"
}

# Function to get results
function Get-Results
{
    <#
    .SYNOPSIS
        Gets entries stored in the $Results array
    .DESCRIPTION
        This function returns the entries stored in the $Results array and can be formatted
        for easy viewing
    .EXAMPLE
        Get-Results | Format-Table
    .EXAMPLE
        Get-Results | Where-Object Subject -eq "john.doe@microsoft.com"
    #>
    $x = New-Object System.Collections.ArrayList
    ForEach ( $Result in $Results )
    {
        $x += $Result
    }
    return $x
}

# Function to provision a GitHub user
function Add-GitHubUser
{
    <#
    .SYNOPSIS
        Provisions a GitHub user
    .DESCRIPTION
        This function provisions a GitHub user using information from an AD user object
    .EXAMPLE
        Add-GitHubUser -User $ADUser
    .PARAMETER User
        An AD user object
    #>
    param
    (
        [Parameter(Position=0)]
        [object[]]$User
    )

    $Body = @{
        active = "true"
        userName = "$( $User.Mail )"
        externalId = "$( $User.Mail )"
        name= @{ "givenName" = "$( $User.GivenName )"; "familyName" = "$( $User.Surname )" }
        emails=@( @{"value" = "$( $User.Mail )"} )
    } | ConvertTo-Json

    try
    {
        Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/scim/v2/organizations/$GHOrganization/Users" -Body $Body -Method Post | Out-Null
        Update-Results -Subject "$( $User.Mail )" -Action Provision -Status Success
    }
    catch
    {
        $Reason = "($( $_.Exception.Response.StatusCode.value__ ) $( $_.Exception.Response.StatusDescription ))"
        Update-Results -Subject "$( $User.Mail )" -Action Provision -Status "Failed $Reason"
    }
}

# Function to deprovision a GitHub user
function Remove-GitHubUser
{
    <#
    .SYNOPSIS
        Deprovisions a GitHub user
    .DESCRIPTION
        This function deprovisions a GitHub user
    .EXAMPLE
        Remove-GitHubUser -GHUserID "$GHUserID"
    .PARAMETER GHUserID
        The GitHub SCIM user ID
    #>
    param
    (
        [Parameter(Position=0)]
        [string]$GHUserID
    )

    try
    {
        Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/scim/v2/organizations/$GHOrganization/Users/$GHUserID" -Method Delete | Out-Null
        Update-Results -Subject "$GHUserID" -Action Deprovision -Status Success
    }
    catch
    {
        $Reason = "($( $_.Exception.Response.StatusCode.value__ ) $( $_.Exception.Response.StatusDescription ))"
        Update-Results -Subject "$GHUserID" -Action Deprovision -Status "Failed $Reason"
    }
}

# Function to validate e-mail addresses
function Test-EmailAddress
{
    <#
    .SYNOPSIS
        Tests an e-mail address to ensure it is valid
    .DESCRIPTION
        This function tests an e-mail address using native PowerShell casting.
        $True will be returned if the e-mail address is valid.
    .EXAMPLE
        Test-EmailAddress -EmailAddress "john.doe@microsoft.com"
    .PARAMETER EmailAddress
        An e-mail address that should be tested
    #>
    param(
        [string]$EmailAddress
    )

    try
    {
        $null = [mailaddress]$EmailAddress
        return $True
    }
    catch
    {
        return $False
    }
}

# Function to validate AD users for enabled and expiry status
function Test-ADUser
{
    <#
    .SYNOPSIS
        Tests an AD user to ensure it is not disabled or expired
    .DESCRIPTION
        This function provides a way to check whether an AD user is still valid for provisioning.
        $True will be returned when the AD user is not disabled or expired.
    .EXAMPLE
        Test-ADUser -User $ADUser
    .PARAMETER User
        An AD user object
    #>
    param
    (
        [Parameter(Position=0)]
        [object[]]$User
    )

    if ( $User.Enabled -eq $False ) # AD account is disabled
    {
        return $False
    }
    elseif ( $User.AccountExpirationDate -ne $Null -and $User.AccountExpirationDate -lt (Get-Date) ) # AD account is expired
    {
        return $False
    }
    else {
        return $True
    }
}

LogMessage -Message "Starting script..."

#
# Print out dry run warning
#
if ( $DryRun -eq $True ) { LogMessage -Message "DryRun is True, not committing changes..." }

#
# Get AD users from groups
#
LogMessage -Message "Getting AD users..."
ForEach ( $ADGroup in $ADGroups )
{
    LogMessage -Message "Gettings AD users in group $ADGroup..."
    try
    {
        $ADUsers += Get-ADGroupMember "$ADGroup" -Credential $DomainCredentials | Get-ADUser -Credential $DomainCredentials -Properties Mail, Enabled, AccountExpirationDate
    }
    catch
    {
        LogMessage -Message "Failed to get users in group: $ADGroup..."
        throw "Failed to get users in group: $ADGroup..."
    }
}

#
# Get provisioned GitHub users
#
LogMessage -Message "Getting GitHub users..."
try
{
    $GHUsers = Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/scim/v2/organizations/$GHOrganization/Users" -Method Get | Select-Object -ExpandProperty Resources
    # Add alias to GitHub users ArrayList for easy comparison
    $GHUsers | Add-Member AliasProperty -Name Mail -Value externalId
}
catch
{
    LogMessage -Message "Failed to get users in group: $ADGroup..."
    throw "Failed to get GitHub users"
}

#
# Compare AD and GH user objects
#

LogMessage -Message "Staging users that are present in AD but not in GitHub..."
$ADUsers | Where-Object { $GHUsers.Mail -notcontains $_.Mail } | ForEach-Object {
    Update-Results -Subject "$( $_.Mail )" -Action "Provision" -Status "Staged"
    $UsersToProvision += $_
}

LogMessage -Message "Staging users that are present in GitHub but not in AD..."
$GHUsers | Where-Object { $ADUsers.Mail -notcontains $_.Mail } | ForEach-Object {
    Update-Results -Subject "$( $_.Mail )" -Action "Deprovision" -Status "Staged"
    $UsersToDeprovision += $_
}

# Get already provisioned users
LogMessage -Message "Staging users that are present in both AD and GitHub..."
ForEach ( $ADUser in $ADUsers )
{
    ForEach ( $GHUser in $GHUsers )
    {
        if ( $ADUser.Mail -eq $GHUser.externalId )
        {
            # Check for deprovision
            if ( -not ( Test-ADUser( $ADUser ) ) ) # Check if AD account is disabled or expired
            {
                Update-Results -Subject "$( $ADUser.Mail )" -Action "Deprovision (Expired/disabled)" -Status "Staged"
                $UsersToDeprovision += $ADUser
            }
        }
    }
}

#
# Provision routine
#
if ( $ProvisionUsers -eq $True )
{
    if ( $UsersToProvision.Count -gt 0 ) # Ensure there are some users to provision
    {
        ForEach ( $UserToProvision in $UsersToProvision )
        {
            # Check for deprovision
            if ( -not ( Test-ADUser( $UserToProvision ) ) ) # Check if AD account is disabled or expired
            {
                Update-Results -Subject "$( $UserToProvision.Mail )" -Action "Provision" -Status "Skip (Expired/disabled)"
            }
            elseif ( -not ( Test-EmailAddress( $UserToProvision.Mail ) ) ) # Ensure the Mail attribute is valid
            {
                Update-Results -Subject "$( $UserToProvision.Mail )" -Action "Provision" -Status "Skip (AD Invalid Mail Attribute)"
            }
            else
            {
                Update-Results -Subject "$( $UserToProvision.Mail )" -Action "Provision" -Status "Processing"
                if ( $DryRun -eq $false )
                {
                    Add-GitHubUser -User $UserToProvision
                }
            }
        }
    }
    else
    {
        LogMessage -Message "No users to provision (UsersToProvision.Count is 0)..."
    }
}
else
{
    LogMessage -Message "ProvisionUsers is not true, skipping routine..."
}

#
# Deprovision routine
#
if ( $DeprovisionUsers -eq $True )
{
    if ( $UsersToDeprovision.Count -gt 0 ) # Ensure there are some users to deprovision
    {
        ForEach ( $UserToDeprovision in $UsersToDeprovision )
        {
            Update-Results -Subject "$( $UserToDeprovision.Mail )" -Action "Deprovision" -Status "Processing"
            if ( $DryRun -eq $false )
            {
                Remove-GitHubUser -GHUserID "$( $UserToDeprovision.id )"
            }
        }
    }
    else
    {
        LogMessage -Message "No users to deprovision (UsersToDeprovision.Count is 0)..."
    }
}
else
{
    LogMessage -Message "DeprovisionUsers is not true, skipping routine..."
}

Get-Results | Out-Host

LogMessage -Message "Finished script."