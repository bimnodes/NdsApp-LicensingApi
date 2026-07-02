using System.Collections.Generic;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;
using NdsApp.LicensingApi.Models;
using NdsApp.LicensingApi.Options;
using NdsApp.LicensingApi.Services;
using Stripe;

namespace NdsApp.LicensingApi.Controllers;

[ApiController]
[Route("api/billing")]
public sealed class BillingController : ControllerBase
{
    private readonly ICustomerPortalContextService _customerPortalContextService;
    private readonly ILicensingService _licensingService;
    private readonly StripeOptions _stripeOptions;
    private readonly ILogger<BillingController> _logger;

    private const string MonthlyPlanCode = "PRO_MONTHLY_10";
    private const string AnnualPlanCode = "NDSAPP_ANNUAL_100";

    public BillingController(
        ICustomerPortalContextService customerPortalContextService,
        ILicensingService licensingService,
        IOptions<StripeOptions> stripeOptions,
        ILogger<BillingController> logger)
    {
        _customerPortalContextService = customerPortalContextService;
        _licensingService = licensingService;
        _stripeOptions = stripeOptions.Value;
        _logger = logger;
    }

    [HttpPost("checkout")]
    public async Task<IActionResult> CreateCheckoutSession(
        [FromBody] CreateCheckoutSessionRequest request,
        CancellationToken cancellationToken)
    {
        if (request.ActivationId == Guid.Empty || string.IsNullOrWhiteSpace(request.MachineHash))
        {
            return BadRequest(new
            {
                success = false,
                code = "invalid_checkout_request",
                message = "activation_id and machine_hash are required."
            });
        }

        if (string.IsNullOrWhiteSpace(_stripeOptions.SecretKey))
        {
            return StatusCode(StatusCodes.Status500InternalServerError, new
            {
                success = false,
                code = "stripe_secret_key_missing",
                message = "Stripe secret key is not configured."
            });
        }

        if (string.IsNullOrWhiteSpace(_stripeOptions.CheckoutSuccessUrl) ||
            string.IsNullOrWhiteSpace(_stripeOptions.CheckoutCancelUrl))
        {
            return StatusCode(StatusCodes.Status500InternalServerError, new
            {
                success = false,
                code = "checkout_urls_missing",
                message = "Stripe Checkout success and cancel URLs are not configured."
            });
        }

        var planCode = ResolveCheckoutPlanCode(request.PlanCode);
        if (planCode is null)
        {
            return BadRequest(new
            {
                success = false,
                code = "unsupported_checkout_plan",
                message = "The requested checkout plan is not supported."
            });
        }

        var priceId = ResolveCheckoutPriceId(planCode);
        if (string.IsNullOrWhiteSpace(priceId))
        {
            return StatusCode(StatusCodes.Status500InternalServerError, new
            {
                success = false,
                code = "checkout_price_missing",
                message = "Stripe Checkout price is not configured for the requested plan."
            });
        }

        JsonElement context;

        try
        {
            context = await _licensingService.CheckAsync(
                new CheckActivationRequest(request.ActivationId, request.MachineHash),
                cancellationToken);
        }
        catch (SupabaseRpcException ex)
        {
            _logger.LogError(
                ex,
                "Failed to load checkout activation context. Status code: {StatusCode}. Response: {ResponseBody}",
                ex.StatusCode,
                ex.ResponseBody);

            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "checkout_activation_context_failed",
                message = "Checkout activation context could not be loaded."
            });
        }

        if (GetBoolean(context, "success") != true)
        {
            return BadRequest(new
            {
                success = false,
                code = GetString(context, "code") ?? "checkout_activation_not_allowed",
                context = context
            });
        }

        var metadata = BuildCheckoutMetadata(request, context, planCode);

        try
        {
            var sessionService = new Stripe.Checkout.SessionService();
            var sessionOptions = new Stripe.Checkout.SessionCreateOptions
            {
                Mode = "subscription",
                ClientReferenceId = request.ActivationId.ToString("D"),
                CustomerEmail = GetString(context, "email"),
                SuccessUrl = _stripeOptions.CheckoutSuccessUrl,
                CancelUrl = _stripeOptions.CheckoutCancelUrl,
                AllowPromotionCodes = true,
                LineItems = new List<Stripe.Checkout.SessionLineItemOptions>
                {
                    new Stripe.Checkout.SessionLineItemOptions
                    {
                        Price = priceId,
                        Quantity = 1
                    }
                },
                Metadata = metadata,
                SubscriptionData = new Stripe.Checkout.SessionSubscriptionDataOptions
                {
                    Metadata = metadata
                }
            };

            var session = await sessionService.CreateAsync(
                sessionOptions,
                new RequestOptions { ApiKey = _stripeOptions.SecretKey },
                cancellationToken);

            return Ok(new
            {
                success = true,
                code = "checkout_session_created",
                url = session.Url,
                checkout_session_id = session.Id,
                plan_code = planCode,
                billing_interval = ResolveCheckoutBillingInterval(planCode),
                price_id = priceId
            });
        }
        catch (StripeException ex)
        {
            _logger.LogError(ex, "Failed to create Stripe Checkout session for activation {ActivationId}.", request.ActivationId);

            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "stripe_checkout_session_failed",
                message = "Stripe Checkout session could not be created."
            });
        }
    }

    [HttpPost("customer-portal")]
    public async Task<IActionResult> CreateCustomerPortalSession(
        [FromBody] CreateCustomerPortalSessionRequest request,
        CancellationToken cancellationToken)
    {
        if (request.ActivationId == Guid.Empty || string.IsNullOrWhiteSpace(request.MachineHash))
        {
            return BadRequest(new
            {
                success = false,
                code = "invalid_customer_portal_request",
                message = "activation_id and machine_hash are required."
            });
        }

        if (string.IsNullOrWhiteSpace(_stripeOptions.SecretKey))
        {
            return StatusCode(StatusCodes.Status500InternalServerError, new
            {
                success = false,
                code = "stripe_secret_key_missing",
                message = "Stripe secret key is not configured."
            });
        }

        if (string.IsNullOrWhiteSpace(_stripeOptions.CustomerPortalReturnUrl))
        {
            return StatusCode(StatusCodes.Status500InternalServerError, new
            {
                success = false,
                code = "customer_portal_return_url_missing",
                message = "Stripe customer portal return URL is not configured."
            });
        }

        JsonElement context;

        try
        {
            context = await _customerPortalContextService.GetContextAsync(request, cancellationToken);
        }
        catch (SupabaseRpcException ex)
        {
            _logger.LogError(
                ex,
                "Failed to load customer portal context. Status code: {StatusCode}. Response: {ResponseBody}",
                ex.StatusCode,
                ex.ResponseBody);

            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "customer_portal_context_failed",
                message = "Customer portal context could not be loaded."
            });
        }

        if (GetBoolean(context, "success") != true || GetBoolean(context, "allowed") != true)
        {
            return BadRequest(new
            {
                success = false,
                code = GetString(context, "code") ?? "customer_portal_not_allowed",
                context = context
            });
        }

        var stripeCustomerId = GetString(context, "stripe_customer_id");
        if (string.IsNullOrWhiteSpace(stripeCustomerId))
        {
            return BadRequest(new
            {
                success = false,
                code = "stripe_customer_missing",
                message = "No Stripe customer is linked to this activation."
            });
        }

        try
        {
            var sessionService = new Stripe.BillingPortal.SessionService();
            var session = await sessionService.CreateAsync(
                new Stripe.BillingPortal.SessionCreateOptions
                {
                    Customer = stripeCustomerId,
                    ReturnUrl = _stripeOptions.CustomerPortalReturnUrl
                },
                new RequestOptions { ApiKey = _stripeOptions.SecretKey },
                cancellationToken);

            return Ok(new
            {
                success = true,
                code = "customer_portal_session_created",
                url = session.Url,
                portal_session_id = session.Id,
                plan_code = GetString(context, "plan_code"),
                billing_interval = GetString(context, "billing_interval")
            });
        }
        catch (StripeException ex)
        {
            _logger.LogError(ex, "Failed to create Stripe Customer Portal session for customer {StripeCustomerId}.", stripeCustomerId);

            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                success = false,
                code = "stripe_customer_portal_session_failed",
                message = "Stripe Customer Portal session could not be created."
            });
        }
    }

    private string? ResolveCheckoutPriceId(string planCode)
    {
        if (string.Equals(planCode, MonthlyPlanCode, StringComparison.OrdinalIgnoreCase))
        {
            return _stripeOptions.NdsAppMonthlyPriceId;
        }

        if (string.Equals(planCode, AnnualPlanCode, StringComparison.OrdinalIgnoreCase))
        {
            return _stripeOptions.NdsAppAnnualPriceId;
        }

        return null;
    }

    private static string? ResolveCheckoutPlanCode(string? planCode)
    {
        if (string.IsNullOrWhiteSpace(planCode))
        {
            return MonthlyPlanCode;
        }

        if (string.Equals(planCode, MonthlyPlanCode, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(planCode, "monthly", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(planCode, "pro_monthly", StringComparison.OrdinalIgnoreCase))
        {
            return MonthlyPlanCode;
        }

        if (string.Equals(planCode, AnnualPlanCode, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(planCode, "annual", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(planCode, "yearly", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(planCode, "pro_yearly", StringComparison.OrdinalIgnoreCase))
        {
            return AnnualPlanCode;
        }

        return null;
    }

    private static string ResolveCheckoutBillingInterval(string planCode)
    {
        return string.Equals(planCode, AnnualPlanCode, StringComparison.OrdinalIgnoreCase)
            ? "year"
            : "month";
    }

    private static Dictionary<string, string> BuildCheckoutMetadata(
        CreateCheckoutSessionRequest request,
        JsonElement context,
        string planCode)
    {
        var metadata = new Dictionary<string, string>
        {
            ["ndsapp_activation_id"] = request.ActivationId.ToString("D"),
            ["ndsapp_machine_hash"] = request.MachineHash,
            ["ndsapp_plan_code"] = planCode,
            ["ndsapp_checkout_source"] = "revit_free_usage_exhausted"
        };

        AddMetadataIfPresent(metadata, "ndsapp_email", GetString(context, "email"));
        AddMetadataIfPresent(metadata, "ndsapp_license_id", GetString(context, "license_id"));
        AddMetadataIfPresent(metadata, "ndsapp_current_plan_code", GetString(context, "plan_code"));

        return metadata;
    }

    private static void AddMetadataIfPresent(Dictionary<string, string> metadata, string key, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value))
        {
            metadata[key] = value;
        }
    }

    private static string? GetString(JsonElement element, string propertyName)
    {
        return element.TryGetProperty(propertyName, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
    }

    private static bool? GetBoolean(JsonElement element, string propertyName)
    {
        return element.TryGetProperty(propertyName, out var value) &&
               (value.ValueKind == JsonValueKind.True || value.ValueKind == JsonValueKind.False)
            ? value.GetBoolean()
            : null;
    }
}
