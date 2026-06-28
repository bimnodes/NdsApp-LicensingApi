using System.Text.Json;

namespace NdsApp.LicensingApi.Models;

public sealed record ReportPluginUsageRequest(
    Guid ActivationId,
    string MachineHash,
    string PluginId,
    Guid ExecutionId,
    string ExecutionStatus,
    string? NdsAppVersion = null,
    string? RevitVersion = null,
    string? Language = null,
    int? DurationMs = null,
    int? SelectedElementsCount = null,
    int? ProcessedElementsCount = null,
    int? CreatedElementsCount = null,
    int? ModifiedElementsCount = null,
    int? DeletedElementsCount = null,
    int? InputCount = null,
    int? OutputCount = null,
    string? ComplexityBucket = null,
    string? ModelSizeBucket = null,
    string? ErrorCode = null,
    string? ErrorHash = null,
    JsonElement? Metrics = null,
    JsonElement? Metadata = null);
