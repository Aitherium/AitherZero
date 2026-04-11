#Requires -Version 7.0

<#
.SYNOPSIS
    Securely converts a SecureString to plain text with proper memory cleanup

.DESCRIPTION
    Converts a SecureString to plain text while properly managing unmanaged memory.
    Immediately zeros the BSTR memory after conversion to minimize exposure time.
    This is the recommended way to convert SecureString when plain text is required.

.PARAMETER SecureString
    The SecureString to convert

.NOTES
    This is a private helper function.
    Uses proper memory cleanup with try/finally to ensure the 
    unmanaged BSTR pointer is always zeroed and freed, even if an error occurs.
#>
function ConvertFrom-SecureStringSecurely {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Security.SecureString]$SecureString
    )
    
    if ($SecureString.Length -eq 0) {
        return [string]::Empty
    }
    
    $bstr = [IntPtr]::Zero
    try {
        # Convert SecureString to BSTR (unmanaged memory)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        
        # Convert BSTR to managed string - use PtrToStringBSTR for proper BSTR handling
        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        
        return $plainText
    }
    finally {
        # Always zero and free the BSTR memory, even if conversion failed
        if ($bstr -ne [IntPtr]::Zero) {
            # ZeroFreeBSTR zeroes the memory then frees it in one call
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}


