namespace NdsApp.LicensingApi.Models;

public sealed record ReportPluginUsageRequest(
    Guid ActivationId,
    string MachineHash,
    string PluginId,
    Guid ExecutionId,
    string ExecutionStatus);
