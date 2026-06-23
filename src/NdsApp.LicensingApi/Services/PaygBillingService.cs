using System.Globalization;
using System.Text.Json;
using Microsoft.Extensions.Options;
using NdsApp.LicensingApi.Options;
using Stripe;

namespace NdsApp.LicensingApi.Services;

public sealed class PaygBillingService : IPaygBillingService
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly ILicensingService _licensingService;
    private readonly StripeOptions _stripeOptions;
    private readonly ILogger<PaygBillingService> _logger;

    public PaygBillingService(
        ILicensingService licensingService,
        IOptions<StripeOptions> stripeOptions,
        ILogger<PaygBillingService> logger)
    {
        _licensingService = licensingService;
        _stripeOptions = stripeOptions.Value;
        _logger = logger;
    }

    public async Task<JsonElement> RunAsync(DateOnly periodStart, DateOnly periodEnd, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(_stripeOptions.SecretKey))
        {
            return ToJsonElement(new
            {
                success = false,
                code = "stripe_secret_key_missing",
                message = "Stripe secret key is not configured."
            });
        }

        var prepareResult = await _licensingService.PreparePaygBillingRunAsync(periodStart, periodEnd, cancellationToken);

        if (GetBoolean(prepareResult, "success") != true)
        {
            return prepareResult;
        }

        var billingRunId = GetGuid(prepareResult, "billing_run_id");
        if (billingRunId == Guid.Empty)
        {
            return ToJsonElement(new
            {
                success = false,
                code = "billing_run_id_missing",
                prepare_result = prepareResult
            });
        }

        var invoicesResult = await _licensingService.GetPaygBillingInvoicesAsync(billingRunId, cancellationToken);
        var invoices = GetArray(invoicesResult, "invoices").ToArray();

        var processed = 0;
        var failed = 0;
        var totalAmountCents = 0;

        foreach (var invoice in invoices)
        {
            var paygInvoiceId = GetGuid(invoice, "id");
            var stripeCustomerId = GetString(invoice, "stripe_customer_id");
            var amountCents = GetInt32(invoice, "total_amount_cents");
            var usageEventCount = GetInt32(invoice, "usage_event_count");

            if (paygInvoiceId == Guid.Empty || string.IsNullOrWhiteSpace(stripeCustomerId) || amountCents <= 0)
            {
                failed++;
                continue;
            }

            try
            {
                var stripeResult = await CreateStripeInvoiceAsync(
                    billingRunId,
                    paygInvoiceId,
                    stripeCustomerId,
                    amountCents,
                    usageEventCount,
                    periodStart,
                    periodEnd,
                    cancellationToken);

                await _licensingService.MarkPaygInvoiceCreatedAsync(
                    paygInvoiceId,
                    stripeResult.InvoiceId,
                    stripeResult.InvoiceItemId,
                    cancellationToken);

                processed++;
                totalAmountCents += amountCents;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                failed++;
                _logger.LogError(ex, "PayG Stripe invoice creation failed for PayG invoice {PaygInvoiceId}.", paygInvoiceId);

                await _licensingService.MarkPaygInvoiceFailedAsync(
                    paygInvoiceId,
                    ex.Message,
                    cancellationToken);
            }
        }

        var completeResult = await _licensingService.CompletePaygBillingRunAsync(billingRunId, cancellationToken);

        return ToJsonElement(new
        {
            success = failed == 0,
            code = failed == 0 ? "payg_billing_completed" : "payg_billing_completed_with_errors",
            billing_run_id = billingRunId,
            period_start = periodStart.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            period_end = periodEnd.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            invoice_count = invoices.Length,
            processed_invoice_count = processed,
            failed_invoice_count = failed,
            processed_amount_cents = totalAmountCents,
            prepare_result = prepareResult,
            complete_result = completeResult
        });
    }

    private async Task<StripeInvoiceCreationResult> CreateStripeInvoiceAsync(
        Guid billingRunId,
        Guid paygInvoiceId,
        string stripeCustomerId,
        int amountCents,
        int usageEventCount,
        DateOnly periodStart,
        DateOnly periodEnd,
        CancellationToken cancellationToken)
    {
        var requestOptions = new RequestOptions
        {
            ApiKey = _stripeOptions.SecretKey,
            IdempotencyKey = $"payg-invoice-{paygInvoiceId:N}"
        };

        var periodLabel = $"{periodStart:yyyy-MM-dd} to {periodEnd.AddDays(-1):yyyy-MM-dd}";
        var description = $"NdsApp PayG usage {periodLabel} ({usageEventCount} executions)";

        var metadata = new Dictionary<string, string>
        {
            ["ndsapp_billing_type"] = "payg_postpaid",
            ["ndsapp_billing_run_id"] = billingRunId.ToString("D"),
            ["ndsapp_payg_invoice_id"] = paygInvoiceId.ToString("D"),
            ["ndsapp_period_start"] = periodStart.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            ["ndsapp_period_end"] = periodEnd.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)
        };

        var invoiceItemService = new InvoiceItemService();
        var invoiceItem = await invoiceItemService.CreateAsync(
            new InvoiceItemCreateOptions
            {
                Customer = stripeCustomerId,
                Amount = amountCents,
                Currency = "eur",
                Description = description,
                Metadata = metadata
            },
            requestOptions,
            cancellationToken);

        var invoiceRequestOptions = new RequestOptions
        {
            ApiKey = _stripeOptions.SecretKey,
            IdempotencyKey = $"payg-invoice-create-{paygInvoiceId:N}"
        };

        var invoiceService = new InvoiceService();
        var invoice = await invoiceService.CreateAsync(
            new InvoiceCreateOptions
            {
                Customer = stripeCustomerId,
                CollectionMethod = "charge_automatically",
                AutoAdvance = true,
                PendingInvoiceItemsBehavior = "include",
                Description = description,
                Metadata = metadata
            },
            invoiceRequestOptions,
            cancellationToken);

        return new StripeInvoiceCreationResult(invoice.Id, invoiceItem.Id);
    }

    private static JsonElement ToJsonElement<T>(T value)
    {
        return JsonSerializer.SerializeToElement(value, JsonOptions);
    }

    private static IEnumerable<JsonElement> GetArray(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value) || value.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<JsonElement>();
        }

        return value.EnumerateArray();
    }

    private static string? GetString(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value))
        {
            return null;
        }

        return value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    }

    private static bool? GetBoolean(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null
        };
    }

    private static int GetInt32(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value))
        {
            return 0;
        }

        return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var result)
            ? result
            : 0;
    }

    private static Guid GetGuid(JsonElement element, string propertyName)
    {
        var raw = GetString(element, propertyName);
        return Guid.TryParse(raw, out var result) ? result : Guid.Empty;
    }

    private sealed record StripeInvoiceCreationResult(string InvoiceId, string InvoiceItemId);
}
