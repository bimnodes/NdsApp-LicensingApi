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
    private readonly StripeOptions _stripeOptions;
    private readonly ILogger<BillingController> _logger;

    public BillingController(
        ICustomerPortalContextService customerPortalContextService,
        IOptions<StripeOptions> stripeOptions,
        ILogger<BillingController> logger)
    {
        _customerPortalContextService = customerPortalContextService;
        _stripeOptions = stripeOptions.Value;
        _logger = logger;
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
