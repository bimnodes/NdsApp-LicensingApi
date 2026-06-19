using System.Text.Json;

namespace NdsApp.LicensingApi.Models;

public sealed class StripeSubscriptionSyncRequest
{
    public string? Email { get; init; }

    public string? StripeCustomerId { get; init; }

    public string StripeSubscriptionId { get; init; } = string.Empty;

    public string? StripePriceId { get; init; }

    public string? StripeStatus { get; init; }

    public DateTimeOffset? CurrentPeriodStart { get; init; }

    public DateTimeOffset? CurrentPeriodEnd { get; init; }

    public string? CheckoutSessionId { get; init; }

    public JsonElement RawData { get; init; }
}
