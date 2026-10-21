# Minimal, offline evaluator for the subset of ARM template expressions used by
# the naming layer in infra/core/naming.bicep.
#
# Purpose: prove that the *compiled* Bicep user-defined functions produce exactly
# the names the pre-refactor template produced, without deploying anything.
# Evaluating the emitted ARM is what makes the proof binding -- a PowerShell
# mirror alone would only prove the mirror agrees with itself.
#
# Any ARM function outside the supported set throws. That is deliberate: if the
# naming layer grows a new function, the equivalence test fails loudly instead
# of silently stopping to cover the new code path.

Set-StrictMode -Version Latest

class ArmExpressionParser {
    [string] $Text
    [int] $Pos

    ArmExpressionParser([string] $text) {
        $this.Text = $text
        $this.Pos = 0
    }

    [void] SkipWhitespace() {
        while ($this.Pos -lt $this.Text.Length -and [char]::IsWhiteSpace($this.Text[$this.Pos])) {
            $this.Pos++
        }
    }

    [char] Peek() {
        if ($this.Pos -ge $this.Text.Length) { return [char] 0 }
        return $this.Text[$this.Pos]
    }

    [void] Expect([char] $expected) {
        $this.SkipWhitespace()
        if ($this.Peek() -ne $expected) {
            throw "Expected '$expected' at offset $($this.Pos) in: $($this.Text)"
        }
        $this.Pos++
    }

    # ARM string literals are single-quoted; an embedded quote is doubled.
    [string] ReadString() {
        $this.Expect([char] "'")
        $sb = [System.Text.StringBuilder]::new()
        while ($true) {
            if ($this.Pos -ge $this.Text.Length) {
                throw "Unterminated string literal in: $($this.Text)"
            }
            $c = $this.Text[$this.Pos]
            if ($c -eq "'") {
                if (($this.Pos + 1) -lt $this.Text.Length -and $this.Text[$this.Pos + 1] -eq "'") {
                    [void] $sb.Append("'")
                    $this.Pos += 2
                    continue
                }
                $this.Pos++
                break
            }
            [void] $sb.Append($c)
            $this.Pos++
        }
        return $sb.ToString()
    }

    [string] ReadIdentifier() {
        $this.SkipWhitespace()
        $start = $this.Pos
        while ($this.Pos -lt $this.Text.Length) {
            $c = $this.Text[$this.Pos]
            if ([char]::IsLetterOrDigit($c) -or $c -eq '_' -or $c -eq '$') { $this.Pos++ } else { break }
        }
        if ($this.Pos -eq $start) {
            throw "Expected an identifier at offset $($this.Pos) in: $($this.Text)"
        }
        return $this.Text.Substring($start, $this.Pos - $start)
    }

    [hashtable] ParseExpression() {
        $node = $this.ParsePrimary()
        while ($true) {
            $this.SkipWhitespace()
            $c = $this.Peek()
            if ($c -eq '.') {
                $this.Pos++
                $property = $this.ReadIdentifier()
                $node = @{ Kind = 'Property'; Target = $node; Name = $property }
                continue
            }
            if ($c -eq '[') {
                $this.Pos++
                $index = $this.ParseExpression()
                $this.Expect([char] ']')
                $node = @{ Kind = 'Index'; Target = $node; Index = $index }
                continue
            }
            break
        }
        return $node
    }

    [hashtable] ParsePrimary() {
        $this.SkipWhitespace()
        $c = $this.Peek()

        if ($c -eq "'") {
            return @{ Kind = 'Literal'; Value = $this.ReadString() }
        }

        if ([char]::IsDigit($c) -or ($c -eq '-' -and ($this.Pos + 1) -lt $this.Text.Length -and [char]::IsDigit($this.Text[$this.Pos + 1]))) {
            $start = $this.Pos
            if ($c -eq '-') { $this.Pos++ }
            while ($this.Pos -lt $this.Text.Length -and [char]::IsDigit($this.Text[$this.Pos])) { $this.Pos++ }
            return @{ Kind = 'Literal'; Value = [int] $this.Text.Substring($start, $this.Pos - $start) }
        }

        $name = $this.ReadIdentifier()
        $namespace = ''
        $this.SkipWhitespace()

        # A namespaced user-defined function call: `__bicep.azName(...)`.
        if ($this.Peek() -eq '.') {
            $save = $this.Pos
            $this.Pos++
            $member = $this.ReadIdentifier()
            $this.SkipWhitespace()
            if ($this.Peek() -eq '(') {
                $namespace = $name
                $name = $member
            }
            else {
                # Not a call -- rewind and let ParseExpression handle the access.
                $this.Pos = $save
                return @{ Kind = 'Identifier'; Name = $name }
            }
        }

        $this.SkipWhitespace()
        if ($this.Peek() -ne '(') {
            if ($name -in @('true', 'false')) {
                return @{ Kind = 'Literal'; Value = ($name -eq 'true') }
            }
            if ($name -eq 'null') { return @{ Kind = 'Literal'; Value = $null } }
            return @{ Kind = 'Identifier'; Name = $name }
        }

        $this.Expect([char] '(')
        $arguments = @()
        $this.SkipWhitespace()
        if ($this.Peek() -ne ')') {
            while ($true) {
                $arguments += , $this.ParseExpression()
                $this.SkipWhitespace()
                if ($this.Peek() -eq ',') { $this.Pos++; continue }
                break
            }
        }
        $this.Expect([char] ')')
        return @{ Kind = 'Call'; Namespace = $namespace; Name = $name; Args = $arguments }
    }
}

function ConvertFrom-ArmExpression {
    <#
    .SYNOPSIS
        Parses an ARM expression string into an evaluable syntax tree.
    .PARAMETER Expression
        The raw property value, with or without the enclosing square brackets.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Expression
    )

    $text = $Expression
    if ($text.StartsWith('[') -and $text.EndsWith(']')) {
        $text = $text.Substring(1, $text.Length - 2)
    }

    $parser = [ArmExpressionParser]::new($text)
    $node = $parser.ParseExpression()
    $parser.SkipWhitespace()
    if ($parser.Pos -ne $parser.Text.Length) {
        throw "Trailing input at offset $($parser.Pos) in: $($parser.Text)"
    }
    return $node
}

function Invoke-ArmNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Node,
        [Parameter(Mandatory)] [hashtable] $Context
    )

    switch ($Node.Kind) {
        'Literal' { return $Node.Value }

        'Identifier' {
            throw "Bare identifier '$($Node.Name)' is not supported by the naming expression evaluator."
        }

        'Property' {
            $target = Invoke-ArmNode -Node $Node.Target -Context $Context
            return Get-ArmMember -Target $target -Name $Node.Name
        }

        'Index' {
            $target = Invoke-ArmNode -Node $Node.Target -Context $Context
            $index = Invoke-ArmNode -Node $Node.Index -Context $Context
            if ($index -is [int]) { return $target[$index] }
            return Get-ArmMember -Target $target -Name ([string] $index)
        }

        'Call' { return Invoke-ArmCall -Node $Node -Context $Context }

        default { throw "Unknown node kind '$($Node.Kind)'." }
    }
}

function Get-ArmMember {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Target,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Target) { throw "Cannot read member '$Name' from a null value." }
    if ($Target -is [hashtable] -or $Target -is [System.Collections.IDictionary]) {
        if (-not $Target.Contains($Name)) { throw "Key '$Name' is not present." }
        return $Target[$Name]
    }
    $property = $Target.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Property '$Name' is not present." }
    return $property.Value
}

function ConvertTo-ArmBoolean {
    <#
    .SYNOPSIS
        Coerces an ARM value to a boolean the way the ARM engine does.
    .DESCRIPTION
        PowerShell treats any non-empty string as true, so [bool] 'false' would
        silently invert a feature flag. Strings are compared explicitly instead.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Value
    )

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        switch ($Value.ToLowerInvariant()) {
            'true' { return $true }
            'false' { return $false }
            default { throw "Cannot convert the string '$Value' to a boolean." }
        }
    }
    if ($Value -is [int]) { return $Value -ne 0 }
    throw "Cannot convert a value of type '$($Value.GetType().Name)' to a boolean."
}

function Invoke-ArmCall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Node,
        [Parameter(Mandatory)] [hashtable] $Context
    )

    $name = $Node.Name
    $namespace = $Node.Namespace

    # User-defined function: resolve from the template's `functions` block and
    # evaluate its body against a fresh parameter scope.
    if ($namespace) {
        $member = $null
        foreach ($group in $Context.Functions) {
            if ($group.namespace -ne $namespace) { continue }
            $candidate = $group.members.PSObject.Properties[$name]
            if ($candidate) { $member = $candidate.Value; break }
        }
        if ($null -eq $member) {
            throw "User-defined function '$namespace.$name' was not found in the compiled template."
        }

        $declared = @()
        if ($member.PSObject.Properties['parameters']) { $declared = @($member.parameters) }
        if ($declared.Count -ne $Node.Args.Count) {
            throw "'$namespace.$name' expects $($declared.Count) arguments but received $($Node.Args.Count)."
        }

        $scope = @{}
        for ($i = 0; $i -lt $declared.Count; $i++) {
            $scope[$declared[$i].name] = Invoke-ArmNode -Node $Node.Args[$i] -Context $Context
        }

        $inner = @{
            Functions  = $Context.Functions
            Variables  = $Context.Variables
            Parameters = $scope
        }
        return Invoke-ArmNode -Node (ConvertFrom-ArmExpression -Expression $member.output.value) -Context $inner
    }

    # `if` and `coalesce` are lazy in ARM, and eager argument evaluation would
    # also drop nulls, so both are handled before the argument list is built.
    if ($name -eq 'if') {
        $condition = Invoke-ArmNode -Node $Node.Args[0] -Context $Context
        if ($condition) { return Invoke-ArmNode -Node $Node.Args[1] -Context $Context }
        return Invoke-ArmNode -Node $Node.Args[2] -Context $Context
    }

    if ($name -eq 'coalesce') {
        foreach ($arg in $Node.Args) {
            $candidate = Invoke-ArmNode -Node $arg -Context $Context
            if ($null -ne $candidate) { return $candidate }
        }
        return $null
    }

    # A List, not an array, so a null argument keeps its position instead of
    # being silently collapsed out of the pipeline.
    $values = [System.Collections.Generic.List[object]]::new()
    foreach ($arg in $Node.Args) {
        $values.Add((Invoke-ArmNode -Node $arg -Context $Context))
    }

    switch ($name) {
        'parameters' {
            $key = [string] $values[0]
            if (-not $Context.Parameters.ContainsKey($key)) {
                throw "Parameter '$key' has no value in the evaluation scope."
            }
            return $Context.Parameters[$key]
        }
        'variables' {
            $key = [string] $values[0]
            if (-not $Context.Variables.ContainsKey($key)) {
                throw "Variable '$key' has no value in the evaluation scope."
            }
            $value = $Context.Variables[$key]
            if ($value -is [string] -and $value.StartsWith('[') -and $value.EndsWith(']')) {
                return Invoke-ArmNode -Node (ConvertFrom-ArmExpression -Expression $value) -Context $Context
            }
            return $value
        }
        'format' {
            $format = [string] $values[0]
            $result = $format
            for ($i = 1; $i -lt $values.Count; $i++) {
                $result = $result.Replace("{$($i - 1)}", [string] $values[$i])
            }
            return $result
        }
        'concat' { return -join ($values | ForEach-Object { [string] $_ }) }
        'take' {
            $source = $values[0]
            $count = [Math]::Max(0, [int] $values[1])
            if ($source -is [string]) {
                return $source.Substring(0, [Math]::Min($source.Length, $count))
            }
            return @($source | Select-Object -First $count)
        }
        'length' {
            $source = $values[0]
            if ($source -is [string]) { return $source.Length }
            return @($source).Count
        }
        'max' { return [Math]::Max([int] $values[0], [int] $values[1]) }
        'min' { return [Math]::Min([int] $values[0], [int] $values[1]) }
        'add' { return [int] $values[0] + [int] $values[1] }
        'sub' { return [int] $values[0] - [int] $values[1] }
        'toLower' { return ([string] $values[0]).ToLowerInvariant() }
        'toUpper' { return ([string] $values[0]).ToUpperInvariant() }
        'replace' { return ([string] $values[0]).Replace([string] $values[1], [string] $values[2]) }
        'empty' {
            $source = $values[0]
            if ($null -eq $source) { return $true }
            if ($source -is [string]) { return $source.Length -eq 0 }
            return @($source).Count -eq 0
        }
        'string' { return [string] $values[0] }
        'equals' { return $values[0] -eq $values[1] }
        'not' { return -not $values[0] }
        'and' {
            foreach ($value in $values) { if (-not (ConvertTo-ArmBoolean $value)) { return $false } }
            return $true
        }
        'or' {
            foreach ($value in $values) { if (ConvertTo-ArmBoolean $value) { return $true } }
            return $false
        }
        'bool' { return ConvertTo-ArmBoolean $values[0] }
        'createObject' {
            $object = @{}
            for ($i = 0; ($i + 1) -lt $values.Count; $i += 2) {
                $object[[string] $values[$i]] = $values[$i + 1]
            }
            return $object
        }
        'union' {
            $merged = @{}
            foreach ($value in $values) {
                if ($null -eq $value) { continue }
                if ($value -is [System.Collections.IDictionary]) {
                    foreach ($key in $value.Keys) { $merged[[string] $key] = $value[$key] }
                    continue
                }
                foreach ($property in $value.PSObject.Properties) { $merged[$property.Name] = $property.Value }
            }
            return $merged
        }
        'json' {
            $text = [string] $values[0]
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return $text | ConvertFrom-Json -AsHashtable
        }
        'base64ToString' {
            return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string] $values[0]))
        }
        default {
            throw "ARM function '$name' is not supported by the naming expression evaluator. Add it deliberately, with a test."
        }
    }
    throw "Unreachable."
}

function Invoke-ArmExpression {
    <#
    .SYNOPSIS
        Evaluates an ARM expression from a compiled template, offline.
    .PARAMETER Expression
        The expression string, for example a `variables` entry from main.json.
    .PARAMETER Template
        The compiled ARM template, as returned by ConvertFrom-Json.
    .PARAMETER Parameters
        Values for `parameters('...')` lookups.
    .PARAMETER Variables
        Overrides for `variables('...')` lookups. Anything not supplied here is
        resolved from the template itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Expression,
        [Parameter(Mandatory)] [psobject] $Template,
        [hashtable] $Parameters = @{},
        [hashtable] $Variables = @{}
    )

    $resolved = @{}
    if ($Template.PSObject.Properties['variables']) {
        foreach ($property in $Template.variables.PSObject.Properties) {
            $resolved[$property.Name] = $property.Value
        }
    }
    foreach ($key in $Variables.Keys) { $resolved[$key] = $Variables[$key] }

    $functions = @()
    if ($Template.PSObject.Properties['functions']) { $functions = @($Template.functions) }

    $context = @{
        Functions  = $functions
        Variables  = $resolved
        Parameters = $Parameters
    }

    return Invoke-ArmNode -Node (ConvertFrom-ArmExpression -Expression $Expression) -Context $context
}
