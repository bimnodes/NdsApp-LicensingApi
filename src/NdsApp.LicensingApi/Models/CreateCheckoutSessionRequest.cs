namespace NdsApp.LicensingApi.Models;

public sealed record CreateCheckoutSessionRequest(
    Guid ActivationId,
    string MachineHash,
    string? PlanCode);