<#
.SYNOPSIS
    Sets AD attributes based on information from GLPI

.EXAMPLE
    Set-ADAttributeFromGLPI.ps1

.LINK
    https://github.com/writhlingtonschool/it-automation
#>

param
(
    [string]$ADSearchBase,
    [string[]]$ADProperties,
    [string]$ADDomainUser,
    [string]$ADDomainPass,
    [string]$GLPIUser,
    [string]$GLPIPass,
    [string]$GLPIAppToken,
    [string]$GLPIAPIURI,
    [int]$MaximumChanges,
    [switch]$DryRun,
    [switch]$Verbose
)

# Enable verbose logging
if ( $Verbose -eq $True )
{
    $VerbosePreference = "continue"
}

# Attributes to set ([GLPI API attribute], [AD Attribute], [Valid Input (Regex)])
$attributes = New-Object System.Collections.ArrayList
$attributes += New-Object -TypeName PSCustomObject -Property @{ GLPIAttribute="locations_id"; ADAttribute="location"; ValidCharsRegex="^[>'é/a-zA-Z0-9- ]{3,64}$" }

# Active Directory
$ADDomainPassSecure = ConvertTo-SecureString -String "$ADDomainPass" -AsPlainText -Force
$ADDomainCredentials = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "$ADDomainUser", $ADDomainPassSecure

# GLPI
$GLPICredentials = [Convert]::ToBase64String( [Text.Encoding]::ASCII.GetBytes((` "{0}:{1}" -f "$GLPIUser", "$GLPIPass" )) )

# Instantiate arrays
$computersMatched = New-Object System.Collections.ArrayList
$computersToUpdate = New-Object System.Collections.ArrayList

# Starting message
Write-Host "Starting script..."

#
# Get AD computers
#
Write-Host "Getting AD computers..."
try
{
    $ADComputers = Get-ADComputer -SearchBase "$ADSearchBase" -Properties $ADProperties -Filter "*" -Credential $ADDomainCredentials
}
catch
{
    throw "Is ADSearchBase defined correctly? " + "$_.FullyQualifiedErrorId"
}

#
# Initialise GLPI REST API session
#
Write-Host "Initialising GLPI REST API..."
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add( "Authorization", ( "Basic {0}" -f $GLPICredentials ) )
$headers.Add( "App-Token", $glpiAppToken )
try
{
    $sessionToken = Invoke-RestMethod -Headers $headers -Method Get -Uri "$GLPIAPIURI/initSession/"
}
catch
{
    throw "Is glpiCredentials defined correctly? " + "$_.FullyQualifiedErrorId"
}

#
# Get GLPI computers
#
Write-Host "Getting GLPI computers..."
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add( "Session-Token", "$( $sessionToken.session_token )" )
$headers.Add( "App-Token", $glpiAppToken )
try
{
    $GLPIComputers = Invoke-RestMethod -Headers $headers -Method Get -Uri "$GLPIAPIURI/Computer?expand_dropdowns=true&range=1-99999"
}
catch
{
    throw "Failed to get GLPI computers: $_.FullyQualifiedErrorId"
}

#
# Kill GLPI REST API session
#
Write-Host "Killing GLPI REST API session..."
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add( "Session-Token", "$( $sessionToken.session_token )" )
$headers.Add( "App-Token", $glpiAppToken )
try
{
    Invoke-RestMethod -Headers $headers -Method Get -Uri $GLPIAPIURI/killSession | Out-Null
}
catch
{
    throw "Failed to kill GLPI REST API session: $_.FullyQualifiedErrorId"
}

#
# Ensure we have some AD computers to process
#
if ( $ADComputers.Count -lt 1 )
{
    throw "No AD computers are available to process (ADComputers is < 1 )"
}

#
# Ensure we have some GLPI computers to process
#
if ( $GLPIComputers.Count -lt 1 )
{
    throw "No GLPI computers are available to process (GLPIComputers is < 1)"
}

#
# Match AD to GLPI computers add them to an array of objects
#
Write-Host "Finding AD -> GLPI matches..."
ForEach ( $ADComputer in $ADComputers ) # Loop through AD computers
{
    ForEach ( $GLPIComputer in $GLPIComputers ) # Sub-loop through GLPI computers
    {
        if ( $( $ADComputer.Name ) -eq $( $GLPIComputer.name ) )
        {
            Write-Verbose "Matched $( $ADComputer.Name ) (AD) -> $( $GLPIComputer.name ) (GLPI)..."
            ForEach ( $attribute in $attributes )
            {
                $computersMatched += New-Object -TypeName PSCustomObject -Property @{
                    ADComputer="$( $ADComputer.Name )";
                    ADAttribute="$( $attribute.ADAttribute )";
                    ADAttributeVal="$( $ADComputer.$( $attribute.ADAttribute ) )";
                    GLPIAttributeVal="$( $GLPIComputer.$( $attribute.GLPIAttribute ) )"
                    GLPIAttribute="$( $attribute.GLPIAttribute )";
                    }
            }
        }
    }
}

#
# Ensure we have some matched computers to process
#
if ( $computersMatched.Count -lt 1 )
{
    throw "No matched computers are available to process (computersMatched is < 1)"
}

#
# Loop through matched computers and calculate proposed changes
#
Write-Host "Calculating proposed changes..."
ForEach ( $matchedComputer in $computersMatched )
{
    if ( "$( $matchedComputer.ADAttributeVal )" -eq "$( $matchedComputer.GLPIAttributeVal )" )
    {
        Write-Host "Not changing $( $matchedComputer.ADComputer )..."
    }
    else
    {
        Write-Host "Update staged for $( $matchedComputer.ADComputer )..."
        $computersToUpdate += New-Object -TypeName PSCustomObject -Property @{
            ADComputer="$( $matchedComputer.ADComputer )";
            ADAttribute="$( $matchedComputer.ADAttribute )";
            ADAttributeVal="$( $matchedComputer.ADAttributeVal )";
            GLPIAttributeVal="$( $matchedComputer.GLPIAttributeVal )";
            GLPIAttribute="$( $matchedComputer.GLPIAttribute )"
            }
    }
}

#
# Run update routine
#
Write-Host "Running update routine..."
if ( $computersToUpdate.Count -gt 0 )
    {
    Write-Verbose "There are $( $computersToUpdate.Count ) updates staged..."
    if ( $computersToUpdate.Count -lt $MaximumChanges )
    {
        ForEach ( $computerToUpdate in $computersToUpdate )
        {
            Write-Host "Running update routine for $( $computerToUpdate.ADComputer )..."
            $ValidInputRegex = $( $attributes | Where-Object { $_.ADAttribute -eq "$( $computerToUpdate.ADAttribute )" } | Select-Object -ExpandProperty ValidCharsRegex ) # Get regex for specific attribute
            if ( "$( $computerToUpdate.GLPIAttributeVal )" -match "$ValidInputRegex" )
            {
                Write-Verbose "$( $computerToUpdate.ADComputer ): regex test passed for GLPI value '$( $computerToUpdate.GLPIAttributeVal )'..."
                Write-Verbose "$( $computerToUpdate.ADComputer ): GLPI attribute '$( $matchedComputer.GLPIAttribute )' -> AD attribute '$( $matchedComputer.ADAttribute )'..."
                Write-Verbose "$( $computerToUpdate.ADComputer ): AD attribute value is '$( $matchedComputer.ADAttributeVal )'..."
                Write-Verbose "$( $computerToUpdate.ADComputer ): GLPI attribute value is '$( $matchedComputer.GLPIAttributeVal )'..."
                if ( $DryRun -eq $False )
                {
                    try
                    {
                        Write-Verbose "$( $computerToUpdate.ADComputer ): running Set-ADComputer..."
                        Set-ADComputer "$( $computerToUpdate.ADComputer )" -Replace @{$( $computerToUpdate.ADAttribute ) = "$( $computerToUpdate.GLPIAttributeVal )"} -Credential $ADDomainCredentials
                        Write-Host "Updated $( $computerToUpdate.ADComputer )..."
                    }
                    catch
                    {
                        Write-Warning "$( $computerToUpdate.ADComputer ): Failed to run Set-ADComputer: $_"
                    }
                }
            }
            else
            {
                Write-Warning "$( $computerToUpdate.ADComputer ): failed regex check for GLPI value '$( $computerToUpdate.GLPIAttributeVal )'..."
            }
        }
    }
    else
    {
        throw "There are $( $computersToUpdate.Count ) updates staged which is more than the maximum limit of $MaximumChanges."
    }
}
else
{
    Write-Host "No computers to update."
}

Write-Host "Finished script."