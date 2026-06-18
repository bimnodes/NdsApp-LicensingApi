namespace NdsApp.LicensingApi.Models;

public sealed record CheckActivationRequest(
    Guid ActivationId,
    string MachineHash);
