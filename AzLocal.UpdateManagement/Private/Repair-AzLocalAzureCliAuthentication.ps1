function Repair-AzLocalAzureCliAuthentication {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $requiredValues = @(
        $env:ACTIONS_ID_TOKEN_REQUEST_URL
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN
        $env:AZLOCAL_OIDC_CLIENT_ID
        $env:AZLOCAL_OIDC_TENANT_ID
    )
    if (-not $env:GITHUB_ACTIONS -or @($requiredValues | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        Write-Verbose 'Azure CLI OIDC renewal is unavailable outside a configured GitHub Actions step.'
        return $false
    }

    try {
        $separator = if ($env:ACTIONS_ID_TOKEN_REQUEST_URL.Contains('?')) { '&' } else { '?' }
        $requestUri = '{0}{1}audience={2}' -f $env:ACTIONS_ID_TOKEN_REQUEST_URL, $separator, [Uri]::EscapeDataString('api://AzureADTokenExchange')
        $oidcResponse = Invoke-RestMethod -Method Get -Uri $requestUri -Headers @{
            Authorization = "Bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)"
        } -ErrorAction Stop
        if (-not $oidcResponse -or [string]::IsNullOrWhiteSpace([string]$oidcResponse.value)) {
            throw 'GitHub OIDC endpoint returned no token.'
        }

        $loginOutput = & az login --service-principal `
            --username $env:AZLOCAL_OIDC_CLIENT_ID `
            --tenant $env:AZLOCAL_OIDC_TENANT_ID `
            --federated-token ([string]$oidcResponse.value) `
            --allow-no-subscriptions `
            --output none `
            --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI federated login failed: $(ConvertTo-ScrubbedCliOutput -Text (($loginOutput | Out-String).Trim()))"
        }

        if (-not [string]::IsNullOrWhiteSpace($env:AZLOCAL_OIDC_SUBSCRIPTION_ID)) {
            $accountOutput = & az account set --subscription $env:AZLOCAL_OIDC_SUBSCRIPTION_ID 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Azure CLI default subscription restore failed: $(ConvertTo-ScrubbedCliOutput -Text (($accountOutput | Out-String).Trim()))"
            }
        }

        Write-Verbose 'Azure CLI authentication renewed through GitHub OIDC.'
        return $true
    }
    catch {
        Write-Verbose "Azure CLI OIDC renewal failed: $(ConvertTo-ScrubbedCliOutput -Text $_.Exception.Message)"
        return $false
    }
}
