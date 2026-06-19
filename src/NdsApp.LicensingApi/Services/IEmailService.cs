using NdsApp.LicensingApi.Models;

namespace NdsApp.LicensingApi.Services;

public interface IEmailService
{
    Task SendLicenseCreatedEmailAsync(LicenseEmailRequest request, CancellationToken cancellationToken);
}
