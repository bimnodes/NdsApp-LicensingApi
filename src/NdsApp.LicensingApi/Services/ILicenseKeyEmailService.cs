using NdsApp.LicensingApi.Models;

namespace NdsApp.LicensingApi.Services;

public interface ILicenseKeyEmailService
{
    Task SendAsync(LicenseKeyEmailRequest request, CancellationToken cancellationToken);
}
