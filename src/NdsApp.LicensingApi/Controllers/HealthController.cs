using Microsoft.AspNetCore.Mvc;

namespace NdsApp.LicensingApi.Controllers;

[ApiController]
[Route("health")]
public sealed class HealthController : ControllerBase
{
    [HttpGet]
    public IActionResult Get()
    {
        return Ok(new
        {
            status = "ok",
            service = "NdsApp Licensing API",
            utc = DateTimeOffset.UtcNow
        });
    }
}
