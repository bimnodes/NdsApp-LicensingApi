namespace NdsApp.LicensingApi.Models;

public sealed record CreateCustomerPortalSessionRequest(
    Guid ActivationId,
    string MachineHash);
