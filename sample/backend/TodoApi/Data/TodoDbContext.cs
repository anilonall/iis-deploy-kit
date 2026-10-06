using Microsoft.EntityFrameworkCore;

namespace TodoApi.Data;

public sealed class TodoDbContext(DbContextOptions<TodoDbContext> options) : DbContext(options)
{
    public DbSet<Todo> Todos => Set<Todo>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Todo>(todo =>
        {
            todo.ToTable("todos");
            todo.Property(t => t.Title).HasMaxLength(200);
            todo.HasIndex(t => t.CreatedAtUtc);
        });
    }
}
