namespace AmbientContextMcp.Core.Models;

public static class EventSchemaCatalog
{
    public static IReadOnlyList<EventSchema> GetAll()
    {
        return AmbientContextCatalog.GetEventSchemas();
    }
}
