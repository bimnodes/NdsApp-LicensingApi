namespace NdsApp.LicensingApi.Models;

public sealed record RequestLicenseKeyRequest(string Email, string? Language = null);
