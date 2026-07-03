using System.Text.Json;
using NdsApp.LicensingApi.Models;

namespace NdsApp.LicensingApi.Services;

public interface IBillingStatusContextService
{
    Task<JsonElement> GetContextAsync(GetBillingStatusRequest request, CancellationToken cancellationToken);
}
