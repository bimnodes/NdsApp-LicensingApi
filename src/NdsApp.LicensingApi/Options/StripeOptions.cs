namespace NdsApp.LicensingApi.Options;

public sealed class StripeOptions
{
    public const string SectionName = "Stripe";

    public string SecretKey { get; init; } = string.Empty;

    public string WebhookSecret { get; init; } = string.Empty;

    public string NdsAppAnnualPriceId { get; init; } = string.Empty;
}
