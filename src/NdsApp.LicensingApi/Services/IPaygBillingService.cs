using System.Text.Json;

namespace NdsApp.LicensingApi.Services;

public interface IPaygBillingService
{
    Task<JsonElement> RunAsync(DateOnly periodStart, DateOnly periodEnd, CancellationToken cancellationToken);
}
