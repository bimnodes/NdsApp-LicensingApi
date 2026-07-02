using System.Globalization;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;
using NdsApp.LicensingApi.Models;
using NdsApp.LicensingApi.Options;
using NdsApp.LicensingApi.Services;
using Stripe;

namespace NdsApp.LicensingApi.Controllers;

[ApiController]
[Route("api/stripe/webhook")]
public sealed class StripeWebhookController : ControllerBase
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly StripeOptions _stripeOptions;
    private readonly ILicensingService _licensingService;
    private readonly IEmailService _emailService;
    private readonly ILogger<StripeWebhookController> _logger;

    public StripeWebhookController(
        IOptions<StripeOptions> stripeOptions,
        ILicensingService licensingService,
        IEmailService emailService,
        ILogger<StripeWebhookController> logger)
    {
        _stripeOptions = stripeOptions.Value;
        _licensingService = licensingService;
        _emailService = emailService;
        _logger = logger;
    }

    [HttpPost]
    public async Task<IActionResult> Handle(CancellationToken cancellationToken)
    {
        var payload = await new StreamReader(Request.Body).ReadToEndAsync(cancellationToken);

        if (string.IsNullOrWhiteSpace(_stripeOptions.WebhookSecret))
        {
            _logger.LogError("Stripe webhook secret is not configured.");
            return StatusCode(StatusCodes.Status500InternalServerError, new
            {
                success = false,
                code = "stripe_webhook_secret_missing",
                message = "Stripe webhook secret is not configured."
            });
        }

        if (!Request.Headers.TryGetValue("Stripe-Signature", out var signatureHeader))
        {
            return Unauthorized(new
            {
                success = false,
                code = "stripe_signature_missing",
                message = "Stripe signature header is missing."
            });
        }

        Event stripeEvent;

        try
        {
            stripeEvent = EventUtility.ConstructEvent(
                payload,
                signatureHeader.ToString(),
                _stripeOptions.WebhookSecret,
                throwOnApiVersionMismatch: false);
        }
        catch (StripeException ex)
        {
            _logger.LogWarning(ex, "Stripe webhook event validation failed.");
            return Unauthorized(new
            {
                success = false,
                code = "stripe_event_validation_failed",
                message = "Stripe webhook event validation failed."
            });
        }

        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;

        if (!TryGetDataObject(root, out var dataObject))
        {
            _logger.LogWarning("Stripe event {EventType} does not contain data.object.", stripeEvent.Type);
            return Ok(new
            {
                success = true,
                received = true,
                event_type = stripeEvent.Type,
                handled = false,
                message = "Stripe event received but no data object was found."
            });
        }

        if (IsPaygInvoiceEvent(stripeEvent.Type, dataObject))
        {
            return await HandlePaygInvoiceEventAsync(stripeEvent.Type, dataObject, cancellationToken);
        }

        var syncRequest = BuildSyncRequest(stripeEvent.Type, dataObject);

        if (syncRequest is null)
        {
            _logger.LogInformation("Received Stripe event {EventType}. No license sync required.", stripeEvent.Type);
            return Ok(new
            {
                success = true,
                received = true,
                event_type = stripeEvent.Type,
                handled = false
            });
        }

        syncRequest = await ResolveMissingEmailAsync(syncRequest, cancellationToken);

        try
        {
            var syncResult = await _licensingService.SyncStripeSubscriptionAsync(syncRequest, cancellationToken);

            var syncCode = GetString(syncResult, "code");
            var syncSuccess = GetBoolean(syncResult, "success");

            _logger.LogInformation(
                "Received Stripe event {EventType}. Synced subscription {SubscriptionId}. Result: {SyncSuccess} {SyncCode}.",
                stripeEvent.Type,
                syncRequest.StripeSubscriptionId,
                syncSuccess,
                syncCode);

            try
            {
                await SendEmailForNewLicenseAsync(syncRequest, syncResult, syncCode, syncSuccess, cancellationToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogError(ex, "Failed to send license email after Stripe event {EventType}.", stripeEvent.Type);
                return StatusCode(StatusCodes.Status502BadGateway, new
                {
                    success = false,
                    code = "resend_license_email_failed",
                    message = "Stripe event was synced, but the email could not be sent."
                });
            }

            return Ok(new
            {
                success = true,
                received = true,
                event_type = stripeEvent.Type,
                handled = true,
                sync_result = RedactSensitiveFields(syncResult)
            });
        }
        catch (SupabaseRpcException ex)
        {
            _logger.LogError(
                ex,
                "Failed to sync Stripe event {EventType} with Supabase. Status code: {StatusCode}. Response: {ResponseBody}",
                stripeEvent.Type,
                ex.StatusCode,
                ex.ResponseBody);

            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "supabase_stripe_sync_failed",
                message = "Stripe event was received, but Supabase synchronization failed."
            });
        }
    }

    private async Task<IActionResult> HandlePaygInvoiceEventAsync(
        string eventType,
        JsonElement dataObject,
        CancellationToken cancellationToken)
    {
        var stripeInvoiceId = GetString(dataObject, "id");
        if (string.IsNullOrWhiteSpace(stripeInvoiceId))
        {
            return Ok(new
            {
                success = true,
                received = true,
                event_type = eventType,
                handled = false,
                message = "PayG invoice event received but invoice id was missing."
            });
        }

        try
        {
            var syncResult = await _licensingService.SyncPaygInvoiceStatusAsync(
                stripeInvoiceId,
                GetString(dataObject, "status"),
                eventType,
                dataObject.Clone(),
                cancellationToken);

            _logger.LogInformation(
                "Received Stripe PayG invoice event {EventType}. Invoice {StripeInvoiceId} synced.",
                eventType,
                stripeInvoiceId);

            return Ok(new
            {
                success = true,
                received = true,
                event_type = eventType,
                handled = true,
                payg_sync_result = RedactSensitiveFields(syncResult)
            });
        }
        catch (SupabaseRpcException ex)
        {
            _logger.LogError(
                ex,
                "Failed to sync Stripe PayG invoice event {EventType} with Supabase. Status code: {StatusCode}. Response: {ResponseBody}",
                eventType,
                ex.StatusCode,
                ex.ResponseBody);

            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "supabase_payg_invoice_sync_failed",
                message = "Stripe PayG invoice event was received, but Supabase synchronization failed."
            });
        }
    }

    private async Task SendEmailForNewLicenseAsync(
        StripeSubscriptionSyncRequest syncRequest,
        JsonElement syncResult,
        string? syncCode,
        bool? syncSuccess,
        CancellationToken cancellationToken)
    {
        if (syncSuccess != true || !string.Equals(syncCode, "license_created", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var keyField = "plain" + "_license" + "_key";
        var licenseKey = GetString(syncResult, keyField);
        var email = GetString(syncResult, "email") ?? syncRequest.Email;

        if (string.IsNullOrWhiteSpace(licenseKey) || string.IsNullOrWhiteSpace(email))
        {
            _logger.LogWarning("License email skipped because required delivery data is missing.");
            return;
        }

        await _emailService.SendLicenseCreatedEmailAsync(new LicenseEmailRequest
        {
            ToEmail = email,
            LicenseKey = licenseKey,
            ValidUntil = GetDateTimeOffset(syncResult, "valid_until"),
            MaxDevices = GetInt32(syncResult, "max_devices")
        }, cancellationToken);
    }

    private StripeSubscriptionSyncRequest? BuildSyncRequest(string eventType, JsonElement dataObject)
    {
        return eventType switch
        {
            "checkout.session.completed" => BuildCheckoutSessionCompletedRequest(dataObject),
            "customer.subscription.created" => BuildSubscriptionRequest(dataObject),
            "customer.subscription.updated" => BuildSubscriptionRequest(dataObject),
            "customer.subscription.deleted" => BuildSubscriptionRequest(dataObject, statusOverride: "canceled"),
            "invoice.payment_succeeded" => BuildInvoiceRequest(dataObject, statusOverride: "active"),
            "invoice.payment_failed" => BuildInvoiceRequest(dataObject, statusOverride: "past_due"),
            _ => null
        };
    }

    private StripeSubscriptionSyncRequest? BuildCheckoutSessionCompletedRequest(JsonElement dataObject)
    {
        var subscriptionId = GetString(dataObject, "subscription");
        if (string.IsNullOrWhiteSpace(subscriptionId))
        {
            return null;
        }

        var planCode = GetNestedString(dataObject, "metadata", "ndsapp_plan_code");
        var priceId = ResolveCheckoutPriceIdFromPlanCode(planCode);

        _logger.LogInformation(
            "Checkout session {CheckoutSessionId} completed for subscription {SubscriptionId}. Performing direct license sync from Checkout metadata.",
            GetString(dataObject, "id"),
            subscriptionId);

        return new StripeSubscriptionSyncRequest
        {
            Email =
                GetNestedString(dataObject, "customer_details", "email") ??
                GetString(dataObject, "customer_email") ??
                GetNestedString(dataObject, "metadata", "ndsapp_email"),
            StripeCustomerId = GetString(dataObject, "customer"),
            StripeSubscriptionId = subscriptionId,
            StripePriceId = priceId,
            StripeStatus = "active",
            CurrentPeriodStart = null,
            CurrentPeriodEnd = null,
            CheckoutSessionId = GetString(dataObject, "id"),
            RawData = dataObject.Clone()
        };
    }
    private StripeSubscriptionSyncRequest? BuildSubscriptionRequest(JsonElement dataObject, string? statusOverride = null)
    {
        var subscriptionId = GetString(dataObject, "id");
        if (string.IsNullOrWhiteSpace(subscriptionId))
        {
            return null;
        }
    
        return new StripeSubscriptionSyncRequest
        {
            Email = GetString(dataObject, "customer_email"),
            StripeCustomerId = GetString(dataObject, "customer"),
            StripeSubscriptionId = subscriptionId,
            StripePriceId = ResolvePriceId(GetSubscriptionPriceId(dataObject)),
            StripeStatus = statusOverride ?? GetString(dataObject, "status"),
            CurrentPeriodStart = GetSubscriptionPeriodTimestamp(dataObject, "current_period_start"),
            CurrentPeriodEnd = GetSubscriptionPeriodTimestamp(dataObject, "current_period_end"),
            RawData = dataObject.Clone()
        };
    }

    private StripeSubscriptionSyncRequest? BuildInvoiceRequest(JsonElement dataObject, string statusOverride)
    {
        var subscriptionId = GetInvoiceSubscriptionId(dataObject);
        if (string.IsNullOrWhiteSpace(subscriptionId))
        {
            return null;
        }
    
        return new StripeSubscriptionSyncRequest
        {
            Email = GetString(dataObject, "customer_email"),
            StripeCustomerId = GetString(dataObject, "customer"),
            StripeSubscriptionId = subscriptionId,
            StripePriceId = ResolvePriceId(GetInvoicePriceId(dataObject)),
            StripeStatus = statusOverride,
            CurrentPeriodStart = GetInvoiceLinePeriodTimestamp(dataObject, "start"),
            CurrentPeriodEnd = GetInvoiceLinePeriodTimestamp(dataObject, "end"),
            RawData = dataObject.Clone()
        };
    }

    private async Task<StripeSubscriptionSyncRequest> ResolveMissingEmailAsync(
        StripeSubscriptionSyncRequest request,
        CancellationToken cancellationToken)
    {
        if (!string.IsNullOrWhiteSpace(request.Email) ||
            string.IsNullOrWhiteSpace(request.StripeCustomerId) ||
            string.IsNullOrWhiteSpace(_stripeOptions.SecretKey))
        {
            return request;
        }

        try
        {
            var customerService = new CustomerService();
            var customer = await customerService.GetAsync(
                request.StripeCustomerId,
                options: null,
                requestOptions: new RequestOptions { ApiKey = _stripeOptions.SecretKey },
                cancellationToken: cancellationToken);

            if (string.IsNullOrWhiteSpace(customer.Email))
            {
                return request;
            }

            return new StripeSubscriptionSyncRequest
            {
                Email = customer.Email,
                StripeCustomerId = request.StripeCustomerId,
                StripeSubscriptionId = request.StripeSubscriptionId,
                StripePriceId = request.StripePriceId,
                StripeStatus = request.StripeStatus,
                CurrentPeriodStart = request.CurrentPeriodStart,
                CurrentPeriodEnd = request.CurrentPeriodEnd,
                CheckoutSessionId = request.CheckoutSessionId,
                RawData = request.RawData
            };
        }
        catch (StripeException ex)
        {
            _logger.LogWarning(ex, "Could not resolve Stripe customer email for customer {CustomerId}.", request.StripeCustomerId);
            return request;
        }
    }

    private string? ResolveCheckoutPriceIdFromPlanCode(string? planCode)
    {
        if (string.Equals(planCode, "PRO_MONTHLY_10", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(planCode, "monthly", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(planCode, "pro_monthly", StringComparison.OrdinalIgnoreCase))
        {
            return _stripeOptions.NdsAppMonthlyPriceId;
        }

        if (string.Equals(planCode, "NDSAPP_ANNUAL_100", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(planCode, "annual", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(planCode, "yearly", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(planCode, "pro_yearly", StringComparison.OrdinalIgnoreCase))
        {
            return _stripeOptions.NdsAppAnnualPriceId;
        }

        return null;
    }
    private string? ResolvePriceId(string? stripeEventPriceId)
    {
        if (!string.IsNullOrWhiteSpace(stripeEventPriceId))
        {
            return stripeEventPriceId;
        }

        return string.IsNullOrWhiteSpace(_stripeOptions.NdsAppAnnualPriceId)
            ? null
            : _stripeOptions.NdsAppAnnualPriceId;
    }

    private static bool IsPaygInvoiceEvent(string eventType, JsonElement dataObject)
    {
        if (!eventType.StartsWith("invoice.", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var billingType = GetNestedString(dataObject, "metadata", "ndsapp_billing_type");
        var paygInvoiceId = GetNestedString(dataObject, "metadata", "ndsapp_payg_invoice_id");

        return string.Equals(billingType, "payg_postpaid", StringComparison.OrdinalIgnoreCase) ||
               !string.IsNullOrWhiteSpace(paygInvoiceId);
    }

    private static bool TryGetDataObject(JsonElement root, out JsonElement dataObject)
    {
        dataObject = default;

        if (!root.TryGetProperty("data", out var data) ||
            data.ValueKind != JsonValueKind.Object ||
            !data.TryGetProperty("object", out dataObject) ||
            dataObject.ValueKind != JsonValueKind.Object)
        {
            return false;
        }

        return true;
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

        return value.ValueKind == JsonValueKind.True || value.ValueKind == JsonValueKind.False
            ? value.GetBoolean()
            : null;
    }

    private static int? GetInt32(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value) || value.ValueKind != JsonValueKind.Number)
        {
            return null;
        }

        return value.TryGetInt32(out var number) ? number : null;
    }

    private static DateTimeOffset? GetDateTimeOffset(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value))
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.String)
        {
            return DateTimeOffset.TryParse(
                value.GetString(),
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var parsed)
                ? parsed
                : null;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var seconds))
        {
            return DateTimeOffset.FromUnixTimeSeconds(seconds);
        }

        return null;
    }

    private static string? GetNestedString(JsonElement element, string objectPropertyName, string stringPropertyName)
    {
        if (!element.TryGetProperty(objectPropertyName, out var nested) || nested.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        return GetString(nested, stringPropertyName);
    }

    private static DateTimeOffset? GetUnixTimestamp(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var value) || value.ValueKind != JsonValueKind.Number)
        {
            return null;
        }

        return value.TryGetInt64(out var seconds) ? DateTimeOffset.FromUnixTimeSeconds(seconds) : null;
    }

    private static DateTimeOffset? GetSubscriptionPeriodTimestamp(JsonElement subscriptionObject, string periodPropertyName)
    {
        var rootPeriod = GetUnixTimestamp(subscriptionObject, periodPropertyName);
        if (rootPeriod is not null)
        {
            return rootPeriod;
        }
    
        var firstItem = GetFirstSubscriptionItem(subscriptionObject);
        if (firstItem is null)
        {
            return null;
        }
    
        return GetUnixTimestamp(firstItem.Value, periodPropertyName);
    }

    private static JsonElement? GetFirstSubscriptionItem(JsonElement subscriptionObject)
    {
        if (!subscriptionObject.TryGetProperty("items", out var items) ||
            items.ValueKind != JsonValueKind.Object ||
            !items.TryGetProperty("data", out var data) ||
            data.ValueKind != JsonValueKind.Array ||
            data.GetArrayLength() == 0)
        {
            return null;
        }
    
        var firstItem = data[0];
        return firstItem.ValueKind == JsonValueKind.Object ? firstItem : null;
    }

    private static string? GetSubscriptionPriceId(JsonElement subscriptionObject)
    {
        var firstItem = GetFirstSubscriptionItem(subscriptionObject);
        if (firstItem is null ||
            !firstItem.Value.TryGetProperty("price", out var price) ||
            price.ValueKind != JsonValueKind.Object)
        {
            return null;
        }
    
        return GetString(price, "id");
    }

    private static string? GetInvoiceSubscriptionId(JsonElement invoiceObject)
    {
        var subscriptionId = GetString(invoiceObject, "subscription");
        if (!string.IsNullOrWhiteSpace(subscriptionId))
        {
            return subscriptionId;
        }
    
        if (invoiceObject.TryGetProperty("parent", out var parent) &&
            parent.ValueKind == JsonValueKind.Object &&
            parent.TryGetProperty("subscription_details", out var subscriptionDetails) &&
            subscriptionDetails.ValueKind == JsonValueKind.Object)
        {
            subscriptionId = GetString(subscriptionDetails, "subscription");
            if (!string.IsNullOrWhiteSpace(subscriptionId))
            {
                return subscriptionId;
            }
        }
    
        var firstLine = GetFirstInvoiceLine(invoiceObject);
        if (firstLine is not null &&
            firstLine.Value.TryGetProperty("parent", out var lineParent) &&
            lineParent.ValueKind == JsonValueKind.Object &&
            lineParent.TryGetProperty("subscription_item_details", out var subscriptionItemDetails) &&
            subscriptionItemDetails.ValueKind == JsonValueKind.Object)
        {
            subscriptionId = GetString(subscriptionItemDetails, "subscription");
            if (!string.IsNullOrWhiteSpace(subscriptionId))
            {
                return subscriptionId;
            }
        }
    
        return null;
    }

    private static string? GetInvoicePriceId(JsonElement invoiceObject)
    {
        var firstLine = GetFirstInvoiceLine(invoiceObject);
        if (firstLine is null)
        {
            return null;
        }
    
        if (firstLine.Value.TryGetProperty("price", out var price) &&
            price.ValueKind == JsonValueKind.Object)
        {
            var priceId = GetString(price, "id");
            if (!string.IsNullOrWhiteSpace(priceId))
            {
                return priceId;
            }
        }
    
        if (firstLine.Value.TryGetProperty("pricing", out var pricing) &&
            pricing.ValueKind == JsonValueKind.Object &&
            pricing.TryGetProperty("price_details", out var priceDetails) &&
            priceDetails.ValueKind == JsonValueKind.Object)
        {
            return GetString(priceDetails, "price");
        }
    
        return null;
    }

    private static DateTimeOffset? GetInvoiceLinePeriodTimestamp(JsonElement invoiceObject, string periodPropertyName)
    {
        var firstLine = GetFirstInvoiceLine(invoiceObject);
        if (firstLine is null ||
            !firstLine.Value.TryGetProperty("period", out var period) ||
            period.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        return GetUnixTimestamp(period, periodPropertyName);
    }

    private static JsonElement? GetFirstInvoiceLine(JsonElement invoiceObject)
    {
        if (!invoiceObject.TryGetProperty("lines", out var lines) ||
            lines.ValueKind != JsonValueKind.Object ||
            !lines.TryGetProperty("data", out var data) ||
            data.ValueKind != JsonValueKind.Array ||
            data.GetArrayLength() == 0)
        {
            return null;
        }

        var firstLine = data[0];
        return firstLine.ValueKind == JsonValueKind.Object ? firstLine : null;
    }

    private static Dictionary<string, object?> RedactSensitiveFields(JsonElement syncResult)
    {
        var result = JsonSerializer.Deserialize<Dictionary<string, object?>>(syncResult.GetRawText(), JsonOptions)
            ?? new Dictionary<string, object?>();

        if (result.ContainsKey("plain_license_key"))
        {
            result["plain_license_key"] = null;
        }

        if (result.ContainsKey("license_id"))
        {
            result["license_id"] = "[redacted]";
        }

        return result;
    }
}
