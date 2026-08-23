using System.Text.Json;

namespace NdsApp.LicensingApi.Services;

public interface ILicenseKeyIssuanceService
{
    Task<JsonElement> IssueAsync(string email, CancellationToken cancellationToken);
}
