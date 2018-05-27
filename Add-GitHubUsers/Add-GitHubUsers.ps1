<#
.SYNOPSIS
    This script synchronises GitHub users with Active Directory using SCIM

.DESCRIPTION
    This module provisions and deprovisions GitHub users based on Active directory
    group membership.  Users are deprovisioned when they are disabled or expired.

.EXAMPLE
    Add-GitHubUsers.ps1 -GHToken "askfj02jj208f9j0a98jf" -GHOrganization "myorganization" -ADGroups "Group1,Group2,Group3" -DomainUser "DOMAIN\user" -DomainPass "Pa5sword" -DryRun $True -Verbose $True

.PARAMETER GHToken
    GitHub token granting appropriate privileges

.PARAMETER GHOrganization
    The GitHub organization for provisioning into

.PARAMETER ADGroups
    An comma-separated list of AD groups to search

.PARAMETER DomainUser
    An AD domain user with permission to perform group and user lookups

.PARAMETER DomainPass
    The password for the respective $DomainUser

.PARAMETER DryRun
    Dry run will not commit any changes to GitHub

.PARAMETER Verbose
    Verbose will print out verbose information

.LINK
    https://github.com/writhlingtonschool/it-powershellmodules
#>

param
(
    [string]$GHToken,
    [string]$GHOrganization,
    [String]$ADGroups,
    [string]$DomainUser,
    [string]$DomainPass,
    [switch]$DryRun,
    [switch]$Verbose
)

# Configure PS to use TLS 1.2 for web requests
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Enable verbose logging
if( $Verbose -eq $True )
{
    $VerbosePreference = "continue"
}

# GitHub
$Base64GHToken = [System.Convert]::ToBase64String( [char[]]$GHToken );
$Headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$Headers.Add( "Authorization", 'Basic {0}' -f $Base64GHToken )
$Headers.Add( "Accept", 'application/vnd.github.cloud-9-preview+json+scim' )

# Active Directory
$ADGroups = $ADGroups -split ","
$DomainPassSecure = ConvertTo-SecureString -String "$DomainPass" -AsPlainText -Force
$DomainCredentials = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $DomainUser, $DomainPassSecure

# Instantiate arrays
$ADUsers = New-Object System.Collections.ArrayList
$GHUsers = $Null
$UsersToProvision = New-Object System.Collections.ArrayList
$UsersToDeprovision = New-Object System.Collections.ArrayList

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
        Write-Host "Successfully provisioned user $( $User.Mail )..."
    }
    catch
    {
        Write-Error "Failed to provision user $( $User.Mail )!..."
        $_
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
        Write-Host "Successfully deprovisioned user $GHUserID..."
    }
    catch
    {
        Write-Error "Failed to deprovision user $GHUserID!..."
        $_
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

Write-Host "Starting script..."

#
# Print out dry run warning
#
if ( $DryRun -eq $True ) { Write-Host "DryRun is True, not committing changes..." }

#
# Get AD users from groups
#
Write-Host "Getting AD users..."
ForEach ( $ADGroup in $ADGroups )
{
    Write-Verbose "Getting AD users in group $ADGroup..."
    try
    {
        $ADUsers += Get-ADGroupMember "$ADGroup" -Credential $DomainCredentials | Get-ADUser -Credential $DomainCredentials -Properties Mail, Enabled, AccountExpirationDate
    }
    catch
    {
        throw $_
    }
}

#
# Print out AD users
#
ForEach ( $ADUser in $ADUsers )
{
    if (-not ([string]::IsNullOrEmpty( $ADUser.Mail )))
    {
        Write-Verbose "Found AD user $( $ADUser.Mail )..."
    }
    else
    {
        Write-Verbose "Found AD user without Mail $( $ADUser.SID )..."
    }
}

#
# Get provisioned GitHub users
#
Write-Host "Getting GitHub users..."
try
{
    $GHUsers = Invoke-RestMethod -Headers $Headers -Uri "https://api.github.com/scim/v2/organizations/$GHOrganization/Users" -Method Get | Select-Object -ExpandProperty Resources
    # Add alias to GitHub users ArrayList for easy comparison
    $GHUsers | Add-Member AliasProperty -Name Mail -Value externalId
}
catch
{
    throw $_
}

#
# Print out GH users
#
ForEach ( $GHUser in $GHUsers )
{
    Write-Verbose "Found GH user $( $GHUser.Mail )..."
}

#
# Compare AD and GH user objects
#

Write-Host "Getting users that are present in AD but not in GitHub..."
$ADUsers | Where-Object { $GHUsers.Mail -notcontains $_.Mail } | ForEach-Object {
    Write-Verbose "Found user to provision: $( $_.Mail )..."
    $UsersToProvision += $_
}

Write-Host "Getting users that are present in GitHub but not in AD..."
$GHUsers | Where-Object { $ADUsers.Mail -notcontains $_.Mail } | ForEach-Object {
    Write-Verbose "Found user to deprovision: $( $_.Mail )..."
    $UsersToDeprovision += $_
}

# Get already provisioned users
Write-Host "Getting users that are present in both AD and GitHub..."
ForEach ( $ADUser in $ADUsers )
{
    ForEach ( $GHUser in $GHUsers )
    {
        if ( $ADUser.Mail -eq $GHUser.Mail )
        {
            # Check for deprovision
            if ( -not ( Test-ADUser( $ADUser ) ) ) # Check if AD account is disabled or expired
            {
                Write-Verbose "Found user to deprovision: $( $ADUser.Mail )..."
                $UsersToDeprovision += $ADUser
            }
        }
    }
}

#
# Provision routine
#
Write-Host "Starting provisioning routine..."
if ( $UsersToProvision.Count -gt 0 ) # Ensure there are some users to provision
{
    ForEach ( $UserToProvision in $UsersToProvision )
    {
        # Check for deprovision
        if ( -not ( Test-ADUser( $UserToProvision ) ) ) # Check if AD account is disabled or expired
        {
            Write-Warning "Staging $( $UserToProvision.Mail ) skipped (expired/disabled)..."
        }
        elseif ( -not ( Test-EmailAddress( $UserToProvision.Mail ) ) ) # Ensure the Mail attribute is valid
        {
            Write-Warning "Staging $( $UserToProvision.Mail ) skipped (invalid Mail attribute)..."
        }
        else
        {
            Write-Verbose "Staging $( $UserToProvision.Mail ) for provisioning..."
            if ( $DryRun -eq $false )
            {
                Add-GitHubUser -User $UserToProvision
            }
        }
    }
}
else
{
    Write-Verbose "No users to provision..."
}

#
# Deprovision routine
#
Write-Host "Starting deprovisioning routine..."
if ( $UsersToDeprovision.Count -gt 0 ) # Ensure there are some users to deprovision
{
    ForEach ( $UserToDeprovision in $UsersToDeprovision )
    {
        Write-Verbose "Staging $( $UserToDeprovision.Mail ) for deprovisioning..."
        if ( $DryRun -eq $false )
        {
            Remove-GitHubUser -GHUserID "$( $UserToDeprovision.id )"
        }
    }
}
else
{
    Write-Verbose "No users to deprovision..."
}

Write-Host "Finished script."