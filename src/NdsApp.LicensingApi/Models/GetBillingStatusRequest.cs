namespace NdsApp.LicensingApi.Models;

public sealed record GetBillingStatusRequest(
    Guid ActivationId,
    string MachineHash);
