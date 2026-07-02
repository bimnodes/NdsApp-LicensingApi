namespace NdsApp.LicensingApi.Options;

public sealed class StripeOptions
{
    public const string SectionName = "Stripe";

    public string SecretKey { get; init; } = string.Empty;

    public string WebhookSecret { get; init; } = string.Empty;

    public string NdsAppAnnualPriceId { get; init; } = string.Empty;

    public string NdsAppMonthlyPriceId { get; init; } = string.Empty;

    public string PaygBillingSecret { get; init; } = string.Empty;

    public string CustomerPortalReturnUrl { get; init; } = string.Empty;

    public string CheckoutSuccessUrl { get; init; } = string.Empty;

    public string CheckoutCancelUrl { get; init; } = string.Empty;
}