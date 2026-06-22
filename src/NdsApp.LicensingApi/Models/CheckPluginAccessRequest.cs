namespace NdsApp.LicensingApi.Models;

public sealed record CheckPluginAccessRequest(
    Guid ActivationId,
    string MachineHash,
    string PluginId);
