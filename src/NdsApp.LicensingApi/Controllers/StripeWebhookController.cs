using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;
using NdsApp.LicensingApi.Options;
using Stripe;

namespace NdsApp.LicensingApi.Controllers;

[ApiController]
[Route("api/stripe/webhook")]
public sealed class StripeWebhookController : ControllerBase
{
    private readonly StripeOptions _stripeOptions;
    private readonly ILogger<StripeWebhookController> _logger;

    public StripeWebhookController(
        IOptions<StripeOptions> stripeOptions,
        ILogger<StripeWebhookController> logger)
    {
        _stripeOptions = stripeOptions.Value;
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
                _stripeOptions.WebhookSecret);
        }
        catch (StripeException ex)
        {
            _logger.LogWarning(ex, "Invalid Stripe webhook signature.");
            return Unauthorized(new
            {
                success = false,
                code = "invalid_stripe_signature",
                message = "Invalid Stripe webhook signature."
            });
        }

        var handled = stripeEvent.Type switch
        {
            "checkout.session.completed" => true,
            "invoice.payment_failed" => true,
            "customer.subscription.deleted" => true,
            "customer.subscription.updated" => true,
            _ => false
        };

        _logger.LogInformation("Received Stripe event {EventType}. Handled: {Handled}.", stripeEvent.Type, handled);

        return Ok(new
        {
            success = true,
            received = true,
            event_type = stripeEvent.Type,
            handled
        });
    }
}
