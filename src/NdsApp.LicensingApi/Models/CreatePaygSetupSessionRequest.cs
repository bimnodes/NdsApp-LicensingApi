namespace NdsApp.LicensingApi.Models;

public sealed record CreatePaygSetupSessionRequest(
    Guid ActivationId,
    string MachineHash);
