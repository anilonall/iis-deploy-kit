namespace TodoApi.Data;

public sealed class Todo
{
    public int Id { get; set; }

    public required string Title { get; set; }

    public bool IsDone { get; set; }

    /// <summary>UTC; stored as PostgreSQL <c>timestamptz</c>.</summary>
    public DateTime CreatedAtUtc { get; set; }
}
