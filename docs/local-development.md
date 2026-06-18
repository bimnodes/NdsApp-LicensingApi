# Local development

This project uses .NET user secrets for local configuration.

Do not commit real keys to the repository.

## Prerequisites

- .NET 8 SDK
- Access to the Supabase project
- A local backend API key chosen by the developer

## Configure local secrets

From the project folder:

```bash
cd src/NdsApp.LicensingApi
```

Set the required values with placeholders replaced by your real local values:

```bash
dotnet user-secrets set "Backend:ApiKey" "YOUR_LOCAL_BACKEND_API_KEY"
dotnet user-secrets set "Supabase:Url" "https://YOUR_PROJECT_REF.supabase.co"
dotnet user-secrets set "Supabase:ServiceRoleKey" "YOUR_SUPABASE_SERVICE_ROLE_KEY"
```

For Stripe development, configure these later when the webhook endpoint is added:

```bash
dotnet user-secrets set "Stripe:SecretKey" "YOUR_STRIPE_TEST_SECRET_KEY"
dotnet user-secrets set "Stripe:WebhookSecret" "YOUR_STRIPE_TEST_WEBHOOK_SECRET"
```

## Run locally

```bash
dotnet restore
dotnet run
```

Use the local URL printed by the terminal.

## Health check

```bash
curl "https://localhost:PORT/health"
```

## Activate license example

```bash
curl -X POST "https://localhost:PORT/api/licensing/activate" \
  -H "Content-Type: application/json" \
  -H "x-api-key: YOUR_LOCAL_BACKEND_API_KEY" \
  -d '{
    "email": "customer@example.com",
    "licenseKey": "NDS-TEST-LICENSE-KEY",
    "machineHash": "TEST-MACHINE-HASH-001",
    "deviceLabel": "Test device",
    "revitVersion": "2026",
    "ndsAppVersion": "1.0.0"
  }'
```

## Check activation example

```bash
curl -X POST "https://localhost:PORT/api/licensing/check" \
  -H "Content-Type: application/json" \
  -H "x-api-key: YOUR_LOCAL_BACKEND_API_KEY" \
  -d '{
    "activationId": "00000000-0000-0000-0000-000000000000",
    "machineHash": "TEST-MACHINE-HASH-001"
  }'
```
