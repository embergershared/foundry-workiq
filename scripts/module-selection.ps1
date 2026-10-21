function Get-EnabledCatalogModules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Modules,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Features,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Composition
    )

    foreach ($module in $Modules) {
        $name = [string] $module['name']
        $flag = [string] $module['featureFlag']
        $enabled = if ($Composition.Contains($name)) {
            [bool] $Composition[$name]
        }
        elseif ($flag -and $Features.Contains($flag)) {
            [bool] $Features[$flag]
        }
        else {
            # Catalog membership is availability, not deployment authorization.
            $false
        }
        if ($enabled) { $module }
    }
}
