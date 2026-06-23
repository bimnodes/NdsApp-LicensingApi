using System.Text.Json;
using NdsApp.LicensingApi.Models;

namespace NdsApp.LicensingApi.Services;

public interface ICustomerPortalContextService
{
    Task<JsonElement> GetContextAsync(CreateCustomerPortalSessionRequest request, CancellationToken cancellationToken);
}
