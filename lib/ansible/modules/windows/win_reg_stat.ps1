#!powershell

# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#Requires -Module Ansible.ModuleUtils.Legacy

$ErrorActionPreference = "Stop"

$params = Parse-Args -arguments $args -supports_check_mode $true

$path = Get-AnsibleParam -obj $params -name "path" -type "str" -failifempty $true -aliases "key"
$name = Get-AnsibleParam -obj $params -name "name" -type "str" -aliases "entry","value"

$result = @{
    exists = $false
}

Function Get-NetHiveName($hive) {
    switch ($hive.ToUpper()) {
        "HKCR"  { "ClassesRoot" }
        "HKCC"  { "CurrentConfig" }
        "HKCU"  { "CurrentUser" }
        "HKLM"  { "LocalMachine" }
        "HKU"   { "Users" }
        default { $null }
    }
}

# map .NET class to registry type
Function Get-PropertyType($dotNetClass) {
    switch ($dotNetClass) {
        "Binary"    { "REG_BINARY" }
        "String"    { "REG_SZ" }
        "DWord"     { "REG_DWORD" }
        "QWord"     { "REG_QWORD" }
        "MultiString"   { "REG_MULTI_SZ" }
        "ExpandString"  { "REG_EXPAND_SZ" }
        "None"      { "REG_NONE" }
        default     { $null }
    }
}

Function Get-PropertyObject($hive, $net_hive, $path, $property) {
    $value = (Get-ItemProperty REGISTRY::$hive\$path).$property
    $type  = Get-PropertyType((Get-Item REGISTRY::$hive\$path).GetValueKind($property))
    
    if (! $type) { return $null }

#FIXME use switch
    if ($type -eq 'REG_EXPAND_SZ') {
        $raw_value = [Microsoft.Win32.Registry]::$net_hive.OpenSubKey($path).GetValue($property, $false, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } elseif ($type -eq 'REG_BINARY' -or $type -eq 'REG_NONE') {
        $raw_value = @()
        foreach ($byte in $value) {
            $hex_value = ('{0:x}' -f $byte).PadLeft(2, '0')
            $raw_value += "0x$hex_value"
        }
    } else {
        $raw_value = $value
    }

    return @{
        raw_value = $raw_value
        value = $value
        type = $type
    }
}

Function Test-RegistryProperty($hive, $path, $property) {
    try {
        $type = (Get-Item REGISTRY::$hive\$path).GetValueKind($property)
    } catch {
        $type = $null
    }

    return ($type -ne $null)
}


# Will validate the key parameter to make sure it matches known format
$hive = (Split-Path -Path $path -Qualifier).TrimEnd(':')
$reg_path = (Split-Path -Path $path -noQualifier).TrimStart('\')

# Used when getting the actual REG_EXPAND_SZ value as well as checking the hive is a known value
$net_hive = Get-NetHiveName -hive $hive
if (! $net_hive) {
    Fail-Json $result "invalid hive ($hive) in path"
}

if (Test-Path REGISTRY::$hive\$reg_path) {
    if ($name -eq $null) {
        $result.exists = $true
        $result.properties = @{}

        foreach ($property in (Get-ItemProperty REGISTRY::$hive\$reg_path).PSObject.Properties) {
            # Powershell adds in some metadata we need to filter out
            if (Test-RegistryProperty -hive $hive -path $reg_path -property $property.Name) {
                $property_object = Get-PropertyObject -hive $hive -net_hive $net_hive -path $reg_path -property $property.Name 
                if ($property_object -eq $null) {
                    Fail-Json $result "impossible error: bad Registry entry $hive\$reg_path\$property.Name"
                    break
                }
                $result.properties.Add($property.Name, $property_object) }
            }
        }

        $result.sub_keys = @()

        foreach ($sub_key in (Get-ChildItem REGISTRY::$hive\$reg_path -ErrorAction SilentlyContinue)) {
            $result.sub_keys += $sub_key.PSChildName
        }

    } else {
        $result.exists = Test-RegistryProperty -hive $hive -path $reg_path -property $name
        if ($result.exists -eq $true) {
            $property_object = Get-PropertyObject -hive $hive -net_hive $net_hive -path $reg_path -property $name
            if ($property_object -eq $null) {
                Fail-Json $result "impossible error: bad Registry entry $hive\$reg_path\$property.Name"
            }
            $result.raw_value = $property_object.raw_value
            $result.value = $property_object.value
            $result.type = $property_object.type
        }
    }
}

Exit-Json $result
