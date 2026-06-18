# NdsApp Licensing API

Backend API for NdsApp licensing, Stripe webhooks, and activation validation.

## Purpose

This service will handle:

- License activation from the NdsApp installer.
- Periodic license checks from the NdsApp Revit add-in.
- Stripe webhook processing.
- Supabase RPC calls for license validation.

## Current status

Initial API skeleton.

## Security rules

Never commit real secrets to this repository.

Secrets must be configured locally or in the deployment platform:

- `Supabase:Url`
- `Supabase:ServiceRoleKey`
- `Stripe:SecretKey`
- `Stripe:WebhookSecret`
- `Backend:ApiKey`

Use `appsettings.example.json` only as a template.

## Local development

From the API project folder:

```bash
dotnet restore
dotnet run
```

Health check:

```text
GET /health
```
