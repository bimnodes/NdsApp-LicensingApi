namespace NdsApp.LicensingApi.Models;

public sealed class LicenseEmailRequest
{
    public string ToEmail { get; init; } = string.Empty;

    public string LicenseKey { get; init; } = string.Empty;

    public DateTimeOffset? ValidUntil { get; init; }

    public int? MaxDevices { get; init; }
}
