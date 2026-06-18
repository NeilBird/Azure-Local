# Appendix: GitHub environments (optional governance wrapper)

> This is an **optional** appendix to [section 4.1 of the CI/CD README](../README.md#41-github-actions-with-openid-connect-recommended). You do **not** need any of it to run the pipelines. The required setup is a single **branch-scoped** federated credential plus one repo Secret and two repo Variables - all on the happy path in section 4.1. Read this only if you want approval gates, per-ring identities, or branch/wait-timer protections.

## Are GitHub environments required? No - they are optional

The pipelines authenticate to Azure with a **branch-scoped** federated credential (`...:ref:refs/heads/main`, the first `az ad app federated-credential create` block in section 4.1, Step 3). That single credential is all OIDC needs - leave the `environment` input **blank** and every workflow runs under the branch-scoped subject claim. The `environment:` line in each job evaluates to an empty string, GitHub attaches no environment, and `azure/login` exchanges the branch-scoped token. That is the correct, fully-supported minimal setup.

## What environments add (and when to bother)

A GitHub environment is a *governance* wrapper, **not** an OIDC requirement. Create them only when you want one or more of:

- **Required reviewers / manual approval gates** - e.g. a human must approve before the `apply-updates` job runs against the `Production` ring.
- **Deployment-branch restrictions** - only allow the workflow to target an environment from `main`.
- **Wait timers** - enforce a soak period between rings.
- **Per-environment secrets / variables** - e.g. a *different* `AZURE_CLIENT_ID` (a separate App Registration) per ring, so the pilot ring and the production ring use distinct identities with distinct RBAC scopes.

If you do **not** need any of those, skip this appendix entirely - the branch-scoped credential covers all runs. You can also add environments later without re-doing anything: create the environment, add its environment-scoped federated credential, and start passing its name in the `environment` input.

**Is OIDC the reason?** Yes - the only auth-level effect of naming an environment is that GitHub puts `environment:<name>` into the token's `subject` claim instead of `ref:refs/heads/main`, which is why a *named* run needs a matching **environment-scoped** federated credential (below). A *blank* run never needs one.

## Plan your GitHub environments

Environment-scoped subjects (`...:environment:<name>`) only succeed at workflow run time if a GitHub environment with the exact same name exists in the repo (names are **case-sensitive**). The `az` command will accept any string you put in `subject` - Entra ID does **not** validate it against GitHub - but a missing or mistyped environment fails the OIDC exchange at runtime with `AADSTS70021: No matching federated identity record found`. It is easiest to decide on environment names now (and ideally create them up-front under **your repo -> Settings -> Environments -> New environment**) so the strings you put into the federated credentials match what GitHub later sends in the token.

For the ring-based rollout pattern this guide describes, three are *suggested* (none are required):

| Environment | Purpose | Suggested protection rules |
|---|---|---|
| `DevTest` | Pilot ring - first cluster(s) to receive a new build. | Required reviewers: 0-1 (auto-promote acceptable). |
| `PreProduction` | Wave2 ring - broader validation before fleet-wide rollout. | Required reviewers: 1. |
| `Production` | Final ring - the bulk of the fleet. | Required reviewers: 2. Deployment branches: `main` only. Optional wait timer. |

Each environment becomes **one** federated credential, one `environment:` line in the workflow job, and one independent approval gate. A single app registration supports up to 20 federated credentials, so this comfortably scales if you later add more rings.

The names `DevTest`, `PreProduction`, and `Production` are just suggestions to match the ring pattern in this guide - **pick whatever names suit your organisation** (e.g. `Pilot`, `Wave2`, `Prod`, `Ring0`, `Ring1`, `Ring2`). Whatever you choose, use the **same name** in (a) the GitHub environment, (b) the federated credential `subject`, and (c) the `environment:` line of the workflow job that targets that ring.

> **GitHub environments and `UpdateRing` tag values are independent.** The `UpdateRing` tag lives on the cluster ARM resource and is what the PowerShell functions filter on (`-UpdateRing Wave1`). A GitHub environment is just an approval gate and federated credential subject. They do **not** have to share names, and the mapping is many-to-many: one GitHub environment can run updates across multiple `UpdateRing` values (different workflow runs pass different `-UpdateRing` parameters under the same approval gate), and multiple environments can target the same `UpdateRing` (e.g. a `PreProductionDryRun` environment that runs with `-WhatIf` against the `Production` ring). The workflow YAML decides which ring tag a given environment-gated run applies to.

## Environment-scoped federated credentials

Add **one** federated credential per environment, on top of the required branch-scoped credential. Inline JSON (Linux/macOS, or any shell that does not strip quotes):

```bash
# One per GitHub environment you created (e.g. DevTest, PreProduction, Production).
# Only needed if you pass an environment name in the workflow `environment` input.
az ad app federated-credential create `
    --id <appId-from-step-1> `
    --parameters '{
        "name": "GitHubActions-Production",
        "issuer": "https://token.actions.githubusercontent.com",
        "subject": "repo:<owner>/<repo>:environment:Production",
        "audiences": ["api://AzureADTokenExchange"]
    }'
```

On Windows PowerShell, pass the JSON via a file (see the quoting note in section 4.1, Step 3) and loop over the environment names:

```powershell
$paramsFile = Join-Path $env:TEMP 'fed-cred.json'

# Environment-scoped credentials, one per GitHub environment (names are
# case-sensitive and must match the environments in your repo at run time).
foreach ($envName in 'DevTest','PreProduction','Production') {
    @{
        name      = "GitHubActions-$envName"
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = "repo:<owner>/<repo>:environment:$envName"
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json | Out-File -FilePath $paramsFile -Encoding utf8 -Force

    Write-Host "Creating federated credential for $envName environment..."
    az ad app federated-credential create `
        --id <appId-from-step-1> `
        --parameters "@$paramsFile"
}

Remove-Item $paramsFile
```

## Creating the environments and pinning per-environment secrets (`gh` CLI)

The `gh` install / auth steps are in section 4.1, Step 4. With `gh` signed in as a repo **admin** (environment creation is admin-only - `gh api "/repos/$repo" --jq '.permissions'` must show `"admin": true`):

```powershell
$repo     = '<owner>/<repo>'
$clientId = '<appId-from-step-1>'
$envs     = 'DevTest','PreProduction','Production'

# 1. Create the GitHub environments (idempotent - PUT creates if missing, no-op if it exists).
#    The environment-scoped federated credentials above only succeed at run time if these exist.
#    There is no 'gh env create' command - use the REST API via gh api.
foreach ($envName in $envs) {
    Write-Host "Ensuring environment '$envName' exists in $repo..."
    gh api `
        --method PUT `
        -H "Accept: application/vnd.github+json" `
        "/repos/$repo/environments/$envName" | Out-Null
}

# 2. Optional, additive on top of the repo-level secret in section 4.1, Step 4 (NOT a
#    replacement) - pin AZURE_CLIENT_ID at each environment scope. GitHub resolves secrets
#    env-first then repo-first, so an env-scoped value shadows the repo-level one for jobs
#    targeting that env. Use this if you want a future repo-level CLIENT_ID rotation to require
#    an explicit per-env update before it applies to Production.
foreach ($envName in $envs) {
    gh secret set AZURE_CLIENT_ID --body $clientId --env $envName --repo $repo
}

# 3. Verify.
gh secret   list --env Production --repo $repo
gh api "/repos/$repo/environments" --jq '.environments[].name'
```

> **`no secrets found` at env scope is expected with OIDC + federated credentials.** When you authenticate with OIDC, `azure/login` does not need a stored client secret; the single repo-level secret carries only the OIDC App Registration's public `AZURE_CLIENT_ID`, and the federated-credential `subject` claim (which includes the environment name) is what restricts who can mint a token. Env-scoped secrets are only needed if you want to pin a different `AZURE_CLIENT_ID` per environment. The empty `gh secret list --env Production` output is the correct steady state, not a misconfiguration.

> **Protection rules are not set by this block.** `gh api PUT /environments/<name>` with no body creates a plain environment with no required reviewers, no deployment-branch policy, and no wait timer. For Production you almost certainly want at least required reviewers - the simplest path is to set those in the UI (**Settings -> Environments -> Production -> Configure**), or extend the `gh api` call with a JSON body per the [REST API reference](https://docs.github.com/en/rest/deployments/environments#create-or-update-an-environment). Required-reviewer values must be user/team **IDs**, not names, which is why the UI is often easier here.
