# Sets AD attributes based on information from GLPI
#
# Step 1: Get AD computers
# Step 2: Initialise GLPI REST API session
# Step 3: Get GLPI computers
# Step 4: Kill GLPI REST API session
# Step 5: Ensure we have some AD computers to process
# Step 6: Ensure we have some GLPI computers to process
# Step 7: Match AD to GLPI computers add them to an array of objects
# Step 8: Ensure we have some matched computers to process
# Step 9: Loop through matched computers and calculate proposed changes
# Step 10: Run update routine
# Step 11: Present results

# Import settings from configuration file
$workDir = Split-Path -Parent $MyInvocation.MyCommand.Path
[xml]$configFile = Get-Content "$workDir/Set-ADAttributeFromGLPI.xml" -ErrorAction Stop

# Attributes to set ([GLPI API attribute], [AD Attribute], [Valid Input (Regex)])
$attributes = @()
$attributes += New-Object -TypeName PSCustomObject -Property @{ GLPIAttribute="locations_id"; ADAttribute="RoomNumber"; ValidCharsRegex="^[>'é/a-zA-Z0-9- ]{1,64}$" }
$attributes += New-Object -TypeName PSCustomObject -Property @{ GLPIAttribute="serial"; ADAttribute="SerialNumber"; ValidCharsRegex="^[a-zA-Z0-9]{1,64}$" }

# Active Directory
$ADSearchBase = $configFile.Settings.ADSettings.ADSearchBase
$ADSearchFilter = $configFile.Settings.ADSettings.ADSearchFilter
$ADProperties = @( "*" )
$ADDomainUser = $configFile.Settings.ADSettings.ADDomainUser
$ADDomainPass = ConvertTo-SecureString -String $configFile.Settings.ADSettings.ADDomainPass -AsPlainText -Force
$ADDomainCredentials = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $ADDomainUser, $ADDomainPass
$ADDryRun = $false

# GLPI
$glpiCredentials = [Convert]::ToBase64String( [Text.Encoding]::ASCII.GetBytes((` "{0}:{1}" -f $configFile.Settings.GLPISettings.GLPIUser, $configFile.Settings.GLPISettings.GLPIPass )) )
$glpiAppToken = $configFile.Settings.GLPISettings.GLPIAppToken
$glpiRestApiUri = $configFile.Settings.GLPISettings.GLPIRestApiUri

# Instantiate arrays
$computersMatched = New-Object System.Collections.ArrayList
$computersToUpdate = @()
$computersToSkip = @()
$computersUpdated = @()
$computersFailed = @()

#
# Step 1: Get AD computers
#
Write-Host "[INFO] Getting AD computers..."
try
{
  $ADComputers = Get-ADComputer -Filter "$ADSearchFilter" -SearchBase "$ADSearchBase" -Properties $ADProperties
} catch
{
  Throw "Is ADSearchBase defined correctly? " + "$_.FullyQualifiedErrorId"
}

#
# Step 2: Initialise GLPI REST API session
#
Write-Host "[INFO] Initialising GLPI REST API..."
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add( "Authorization", ( "Basic {0}" -f $glpiCredentials ) )
$headers.Add( "App-Token", $glpiAppToken )
try
{
  $sessionToken = Invoke-RestMethod -Headers $headers -Method Get -Uri "$glpiRestApiUri/initSession/"
} catch
{
  throw "Is glpiCredentials defined correctly? " + "$_.FullyQualifiedErrorId"
}

#
# Step 3: Get GLPI computers
#
Write-Host "[INFO] Getting GLPI computers..."
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add( "Session-Token", "$( $sessionToken.session_token )" )
$headers.Add( "App-Token", $glpiAppToken )
try
{
  $glpiComputers = Invoke-RestMethod -Headers $headers -Method Get -Uri "$glpiRestApiUri/Computer?expand_dropdowns=true&range=3300-3319"
} catch
{
  throw "$_.FullyQualifiedErrorId"
}

#
# Step 4: Kill GLPI REST API session
#
Write-Host "[INFO] Killing GLPI REST API session..."
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add( "Session-Token", "$( $sessionToken.session_token )" )
$headers.Add( "App-Token", $glpiAppToken )
try
{
  Invoke-RestMethod -Headers $headers -Method Get -Uri $glpiRestApiUri/killSession
} catch
{
  throw "$_.FullyQualifiedErrorId"
}

#
# Step 5: Ensure we have some AD computers to process
#
if ( $ADComputers.Count -lt 1 )
{
  throw "No AD computers are available to process (ADComputers is < 1 )"
}

#
# Step 6: Ensure we have some GLPI computers to process
#
if ( $glpiComputers.Count -lt 1 )
{
  throw "No GLPI computers are available to process (glpiComputers is < 1)"
}

#
# Step 7: Match AD to GLPI computers add them to an array of objects
#
Write-Host "[INFO] Finding AD -> GLPI matches..."
ForEach ( $ADComputer in $ADComputers ) # Loop through AD computers
{
  ForEach ( $glpiComputer in $glpiComputers ) # Sub-loop through GLPI computers
  {
    if ( $( $ADComputer.Name ) -eq $( $glpiComputer.name ) )
    {
      Write-Warning "Found match $( $ADComputer.Name )..."
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
# Step 8: Ensure we have some matched computers to process
#
if ( $computersMatched.Count -lt 1 )
{
  throw "No matched computers are available to process (computersMatched is < 1)"
}

#
# Step 9: Loop through matched computers and calculate proposed changes
#
Write-Host "[INFO] Calculating proposed changes..."
ForEach ( $matchedComputer in $computersMatched )
{
  if ( "$( $matchedComputer.ADAttributeVal )" -eq "$( $matchedComputer.GLPIAttributeVal )" )
  {
    $computersToSkip += New-Object -TypeName PSCustomObject -Property @{
      ADComputer="$( $matchedComputer.ADComputer )";
      ADAttribute="$( $matchedComputer.ADAttribute )";
      ADAttributeVal="$( $matchedComputer.ADAttributeVal )";
      GLPIAttributeVal="$( $matchedComputer.GLPIAttributeVal )";
      GLPIAttribute="$( $matchedComputer.GLPIAttribute )"
      }
  } else
  {
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
# Step 10: Run update routine
#
Write-Host "[INFO] Running update routine..."
if ( $computersToUpdate.Count -gt 0 ) {
  ForEach ( $computerToUpdate in $computersToUpdate )
  {
    $validCharsRegex = $( $attributes | Where-Object { $_.ADAttribute -eq "$( $computerToUpdate.ADAttribute )" } | Select-Object -ExpandProperty ValidCharsRegex ) # Get regex for specific attribute
    if ( "$( $computerToUpdate.GLPIAttributeVal )" -match "$validCharsRegex" )
    {
      try
      {
        if ( $ADDryRun -eq $true )
        {
          Write-Host "[INFO] ADDryRun is true, not commiting changes..."
        } else
        {
          Write-Warning "Setting $( $computerToUpdate.ADComputer ) AD attribute $( $computerToUpdate.ADAttribute ) to GLPI Attribute Value $( $computerToUpdate.GLPIAttributeVal )..."
          Set-ADComputer "$( $computerToUpdate.ADComputer )" -Replace @{$( $computerToUpdate.ADAttribute ) = "$( $computerToUpdate.GLPIAttributeVal )"} -Credential $ADDomainCredentials
        }
        $computersToUpdate += New-Object -TypeName PSCustomObject -Property @{
          ADComputer="$( $computerToUpdate.ADComputer )";
          ADAttribute="$( $computerToUpdate.ADAttribute )";
          ADAttributeVal="$( $computerToUpdate.ADAttributeVal )";
          GLPIAttributeVal="$( $computerToUpdate.GLPIAttributeVal )";
          GLPIAttribute="$( $computerToUpdate.GLPIAttribute )"
          }
      } catch
      {
        $computersFailed += New-Object -TypeName PSCustomObject -Property @{
          ADComputer="$( $computerToUpdate.ADComputer )";
          ADAttribute="$( $computerToUpdate.ADAttribute )";
          ADAttributeVal="$( $computerToUpdate.ADAttributeVal )";
          GLPIAttributeVal="$( $computerToUpdate.GLPIAttributeVal )";
          GLPIAttribute="$( $computerToUpdate.GLPIAttribute )"
          }
      }
    } else
    {
      $computersFailed += New-Object -TypeName PSCustomObject -Property @{
        ADComputer="$( $computerToUpdate.ADComputer )";
        ADAttribute="$( $computerToUpdate.ADAttribute )";
        ADAttributeVal="$( $computerToUpdate.ADAttributeVal )";
        GLPIAttributeVal="$( $computerToUpdate.GLPIAttributeVal )";
        GLPIAttribute="$( $computerToUpdate.GLPIAttribute )"
        FailReason="Failed regex test"
        }
    }
  }
} else
{
  Write-Host "[INFO] No computers to update."
}

#
# Step 11: Present results
#
if ( $computersUpdated.Count -gt 0 )
{
  Write-Host "[INFO] Updated the following computers: "
  $( $computersUpdated )
}
if ( $computersFailed.Count -gt 0 )
{
  Write-Host "[INFO] Failed to update the following computers:"
  $( $computersFailed )
}