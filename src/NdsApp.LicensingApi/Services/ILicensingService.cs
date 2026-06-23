using System.Text.Json;
using NdsApp.LicensingApi.Models;

namespace NdsApp.LicensingApi.Services;

public interface ILicensingService
{
    Task<JsonElement> ActivateAsync(ActivateLicenseRequest request, CancellationToken cancellationToken);

    Task<JsonElement> CheckAsync(CheckActivationRequest request, CancellationToken cancellationToken);

    Task<JsonElement> CheckPluginAccessAsync(CheckPluginAccessRequest request, CancellationToken cancellationToken);

    Task<JsonElement> ReportPluginUsageAsync(ReportPluginUsageRequest request, CancellationToken cancellationToken);

    Task<JsonElement> SyncStripeSubscriptionAsync(StripeSubscriptionSyncRequest request, CancellationToken cancellationToken);

    Task<JsonElement> PreparePaygBillingRunAsync(DateOnly periodStart, DateOnly periodEnd, CancellationToken cancellationToken);

    Task<JsonElement> GetPaygBillingInvoicesAsync(Guid billingRunId, CancellationToken cancellationToken);

    Task<JsonElement> MarkPaygInvoiceCreatedAsync(Guid paygInvoiceId, string stripeInvoiceId, string stripeInvoiceItemId, CancellationToken cancellationToken);

    Task<JsonElement> MarkPaygInvoiceFailedAsync(Guid paygInvoiceId, string errorMessage, CancellationToken cancellationToken);

    Task<JsonElement> CompletePaygBillingRunAsync(Guid billingRunId, CancellationToken cancellationToken);

    Task<JsonElement> SyncPaygInvoiceStatusAsync(string stripeInvoiceId, string? stripeInvoiceStatus, string eventType, JsonElement rawData, CancellationToken cancellationToken);
}
