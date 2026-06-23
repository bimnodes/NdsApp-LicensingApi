using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;
using NdsApp.LicensingApi.Options;
using NdsApp.LicensingApi.Services;

namespace NdsApp.LicensingApi.Controllers;

[ApiController]
[Route("api/internal/payg-billing")]
public sealed class PaygBillingController : ControllerBase
{
    private const string BillingSecretHeaderName = "X-Payg-Billing-Secret";

    private readonly StripeOptions _stripeOptions;
    private readonly IPaygBillingService _paygBillingService;
    private readonly ILogger<PaygBillingController> _logger;

    public PaygBillingController(
        IOptions<StripeOptions> stripeOptions,
        IPaygBillingService paygBillingService,
        ILogger<PaygBillingController> logger)
    {
        _stripeOptions = stripeOptions.Value;
        _paygBillingService = paygBillingService;
        _logger = logger;
    }

    [HttpPost("run")]
    public async Task<IActionResult> Run(
        [FromQuery] DateOnly? periodStart,
        [FromQuery] DateOnly? periodEnd,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(_stripeOptions.PaygBillingSecret))
        {
            _logger.LogError("PayG billing secret is not configured.");
            return StatusCode(StatusCodes.Status500InternalServerError, new
            {
                success = false,
                code = "payg_billing_secret_missing",
                message = "PayG billing secret is not configured."
            });
        }

        if (!Request.Headers.TryGetValue(BillingSecretHeaderName, out var providedSecret) ||
            !SecretsMatch(_stripeOptions.PaygBillingSecret, providedSecret.ToString()))
        {
            return Unauthorized(new
            {
                success = false,
                code = "unauthorized"
            });
        }

        var resolvedPeriodEnd = periodEnd ?? GetFirstDayOfCurrentUtcMonth();
        var resolvedPeriodStart = periodStart ?? resolvedPeriodEnd.AddMonths(-1);

        if (resolvedPeriodEnd <= resolvedPeriodStart)
        {
            return BadRequest(new
            {
                success = false,
                code = "invalid_period",
                message = "Period end must be after period start."
            });
        }

        var result = await _paygBillingService.RunAsync(
            resolvedPeriodStart,
            resolvedPeriodEnd,
            cancellationToken);

        return Ok(result);
    }

    private static DateOnly GetFirstDayOfCurrentUtcMonth()
    {
        var utcNow = DateTimeOffset.UtcNow;
        return new DateOnly(utcNow.Year, utcNow.Month, 1);
    }

    private static bool SecretsMatch(string expected, string provided)
    {
        var expectedBytes = Encoding.UTF8.GetBytes(expected);
        var providedBytes = Encoding.UTF8.GetBytes(provided);

        return expectedBytes.Length == providedBytes.Length &&
               CryptographicOperations.FixedTimeEquals(expectedBytes, providedBytes);
    }
}
