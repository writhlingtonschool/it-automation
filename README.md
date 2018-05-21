### it-automation is a collection of PowerShell scripts to aid day-to-day tasks.

## Synchronisation

**Scripts that synchronise various systems.**

#### `Set-ADAttributeFromGLPI`

Synchronises attributes from GLPI to Active Directory.  Requires GLPI REST API.

#### `Add-GitHubUsers`

Provisions and deprovisions GitHub users based on Active Directory group membership using GitHub SCIM.

## Auditing

**Script for auditing.**

#### `Get-ADInactiveUsers`

Gets inactive users (no authentication with x days) and sends the result in an e-mail.
