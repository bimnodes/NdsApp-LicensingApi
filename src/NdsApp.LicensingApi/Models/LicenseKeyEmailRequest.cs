namespace NdsApp.LicensingApi.Models;

public sealed class LicenseKeyEmailRequest
{
    public string ToEmail { get; init; } = string.Empty;

    public string LicenseKey { get; init; } = string.Empty;

    public string? Language { get; init; }

    public string? PlanCode { get; init; }

    public string? PlanName { get; init; }

    public DateTimeOffset? ValidUntil { get; init; }

    public int? MaxDevices { get; init; }
}
