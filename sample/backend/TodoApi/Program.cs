using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.EventLog;
using TodoApi.Data;

var builder = WebApplication.CreateBuilder(args);

// Configuration comes from appsettings*.json and environment variables. On the IIS server the
// deploy kit stores secrets in the API app pool's environment variables (set-config.ps1), e.g.
// ConnectionStrings__Default -> ConnectionStrings:Default. Nothing secret lives in the package.
var connectionString = builder.Configuration.GetConnectionString("Default")
    ?? throw new InvalidOperationException("ConnectionStrings:Default is not configured.");

builder.Services.AddDbContext<TodoDbContext>(options => options.UseNpgsql(connectionString));

// Windows: bind Logging:EventLog (SourceName/LogName) so warnings and errors are written under the
// event source that setup-server.ps1 registered, instead of the shared ".NET Runtime" source.
if (OperatingSystem.IsWindows())
{
    builder.Services.Configure<EventLogSettings>(builder.Configuration.GetSection("Logging:EventLog"));
}

// The SPA lives on another origin (https://example.com -> https://api.example.com).
var allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
builder.Services.AddCors(options => options.AddDefaultPolicy(policy =>
    policy.WithOrigins(allowedOrigins).AllowAnyHeader().WithMethods("GET", "POST")));

var app = builder.Build();

app.UseHttpsRedirection();
app.UseCors();

// Health endpoint used by install-release.ps1, set-config.ps1 and startup-check.ps1.
// Returns only a status, never configuration or exception details.
app.MapGet("/api/health", async (TodoDbContext db, CancellationToken ct) =>
    await db.Database.CanConnectAsync(ct)
        ? Results.Ok(new { status = "ok" })
        : Results.Json(new { status = "database-unavailable" }, statusCode: StatusCodes.Status503ServiceUnavailable));

app.MapGet("/api/todos", async (TodoDbContext db, CancellationToken ct) =>
    await db.Todos.AsNoTracking().OrderByDescending(t => t.CreatedAtUtc).Take(100).ToListAsync(ct));

app.MapPost("/api/todos", async (CreateTodoRequest request, TodoDbContext db, CancellationToken ct) =>
{
    var title = request.Title?.Trim();
    if (string.IsNullOrEmpty(title) || title.Length > 200)
    {
        return Results.ValidationProblem(new Dictionary<string, string[]>
        {
            ["title"] = ["Title is required and must be at most 200 characters."],
        });
    }

    var todo = new Todo { Title = title, CreatedAtUtc = DateTime.UtcNow };
    db.Todos.Add(todo);
    await db.SaveChangesAsync(ct);
    return Results.Created($"/api/todos/{todo.Id}", todo);
});

app.Run();

internal sealed record CreateTodoRequest(string? Title);
