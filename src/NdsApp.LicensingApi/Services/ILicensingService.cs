using System.Text.Json;
using NdsApp.LicensingApi.Models;

namespace NdsApp.LicensingApi.Services;

public interface ILicensingService
{
    Task<JsonElement> ActivateAsync(ActivateLicenseRequest request, CancellationToken cancellationToken);

    Task<JsonElement> CheckAsync(CheckActivationRequest request, CancellationToken cancellationToken);
}
