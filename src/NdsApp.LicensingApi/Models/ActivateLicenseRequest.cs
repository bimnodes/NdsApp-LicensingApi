namespace NdsApp.LicensingApi.Models;

public sealed record ActivateLicenseRequest(
    string Email,
    string LicenseKey,
    string MachineHash,
    string? DeviceLabel,
    string? RevitVersion,
    string? NdsAppVersion);
